defmodule PhoenixKit.Modules.Storage.Profiles do
  @moduledoc """
  Storage profiles: where a library's bytes live (V205).

  A library points at a profile (`PhoenixKit.Modules.Storage.StorageProfile`),
  and the profile lists its buckets with how it uses each
  (`PhoenixKit.Modules.Storage.ProfileBucket`: role, what it stores, write
  priority, serve order, status) and how many copies an object gets. A
  library with no profile uses the **Default**, seeded by V205 from the
  install's buckets and `storage_redundancy_copies` under a fixed uuid
  (`default_uuid/0`), so an install that never touches profiles behaves as
  it did before.

  Every change to a profile or its buckets bumps its `revision`
  (`bump_revision/1`). A file records the profile and revision it was
  placed by (`placed_profile_uuid` / `placed_revision`, NULL meaning the
  Default at revision 1), which is how the reconciler finds the files that
  are not where their library's profile wants them.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.{Library, ProfileBucket, StorageProfile}
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Settings

  @default_uuid "00000000-0000-7000-8000-000000000002"

  @doc "The uuid of the Default profile, fixed on every install."
  @spec default_uuid() :: String.t()
  def default_uuid, do: @default_uuid

  @doc "Whether `uuid` is the Default profile's."
  @spec default?(term()) :: boolean()
  def default?(%StorageProfile{uuid: uuid}), do: default?(uuid)
  def default?(uuid), do: to_string(uuid) == @default_uuid

  @doc """
  The site's profiles, the Default first, each with its buckets. A user's own
  profile (V206) is not here: the site's profile editor and pickers read this,
  and a user's storage is not something an admin assigns or edits.
  """
  @spec list_profiles() :: [StorageProfile.t()]
  def list_profiles do
    from(p in StorageProfile,
      where: is_nil(p.owner_uuid),
      order_by: [desc: p.is_default, asc: fragment("lower(?)", p.name)]
    )
    |> repo().all()
    |> preload_buckets()
  end

  @doc "A profile with its buckets, or nil (also for anything not a uuid)."
  @spec get_profile(term()) :: StorageProfile.t() | nil
  def get_profile(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %StorageProfile{} = profile <- repo().get(StorageProfile, uuid) do
      preload_buckets(profile)
    else
      _ -> nil
    end
  end

  @doc "The Default profile, with its buckets."
  @spec default_profile() :: StorageProfile.t() | nil
  def default_profile, do: get_profile(@default_uuid)

  @doc """
  How many copies of an original the Default keeps (1 when there is no
  Default yet, as `storage_redundancy_copies` defaulted to).
  """
  @spec default_copies() :: pos_integer()
  def default_copies do
    from(p in StorageProfile, where: p.uuid == ^@default_uuid, select: p.copies_originals)
    |> repo().one() || 1
  end

  @doc """
  The uuid of the profile `library` uses: its own, or the Default. Takes a
  library, a library uuid, or nil (a file with no library is in Media).
  """
  @spec profile_uuid_for(Library.t() | term()) :: String.t()
  def profile_uuid_for(%Library{storage_profile_uuid: nil}), do: @default_uuid
  def profile_uuid_for(%Library{storage_profile_uuid: uuid}), do: to_string(uuid)
  def profile_uuid_for(nil), do: profile_uuid_for(Libraries.media_uuid())

  def profile_uuid_for(library_uuid) do
    case Libraries.get_library(library_uuid) do
      %Library{} = library -> profile_uuid_for(library)
      nil -> @default_uuid
    end
  end

  @doc """
  The profile `library` uses, with its buckets (see `profile_uuid_for/1`).
  Falls back to the Default when the library's own is gone.
  """
  @spec for_library(Library.t() | term()) :: StorageProfile.t() | nil
  def for_library(library) do
    library |> profile_uuid_for() |> get_profile() || default_profile()
  end

  @doc "The profile a file's library uses."
  @spec for_file(StorageFile.t()) :: StorageProfile.t() | nil
  def for_file(%StorageFile{library_uuid: library_uuid}), do: for_library(library_uuid)

  @doc """
  The number of copies `profile` wants of an object: `:original` for an
  original upload, `:derived` for anything made from one.
  """
  @spec copies(StorageProfile.t(), :original | :derived) :: pos_integer()
  def copies(%StorageProfile{copies_originals: n}, :original), do: n
  def copies(%StorageProfile{copies_variants: n}, :derived), do: n

  @doc "Creates a profile with no buckets."
  @spec create_profile(map()) :: {:ok, StorageProfile.t()} | {:error, Ecto.Changeset.t()}
  def create_profile(attrs) do
    %StorageProfile{}
    |> StorageProfile.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, profile} -> {:ok, preload_buckets(profile)}
      error -> error
    end
  end

  @doc "Updates a profile's name or copy counts; a real change bumps its revision."
  @spec update_profile(StorageProfile.t(), map()) ::
          {:ok, StorageProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%StorageProfile{} = profile, attrs) do
    changeset = StorageProfile.changeset(profile, attrs)

    transact(fn ->
      with {:ok, updated} <- repo().update(changeset) do
        if placement_changed?(changeset), do: bump_revision(updated.uuid)
        {:ok, updated.uuid}
      end
    end)
    |> reload()
  end

  # A rename moves no bytes, and neither does how many copies an upload
  # needs (it applies to the next upload): neither makes every file stale.
  defp placement_changed?(changeset),
    do: Map.drop(changeset.changes, [:name, :min_copies_on_write]) != %{}

  @doc """
  Deletes a profile. The Default cannot be deleted
  (`{:error, :default}`), nor a profile a library uses
  (`{:error, :in_use}`).
  """
  @spec delete_profile(StorageProfile.t()) ::
          {:ok, StorageProfile.t()} | {:error, :default | :in_use | Ecto.Changeset.t()}
  def delete_profile(%StorageProfile{} = profile) do
    cond do
      default?(profile) ->
        {:error, :default}

      libraries_using(profile.uuid) > 0 ->
        {:error, :in_use}

      true ->
        profile
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:uuid,
          name: :phoenix_kit_storage_libraries_profile_fkey,
          message: "is used by a library"
        )
        |> repo().delete()
    end
  end

  @doc "How many libraries (trashed ones included) use `profile_uuid` explicitly."
  @spec libraries_using(term()) :: non_neg_integer()
  def libraries_using(profile_uuid) do
    from(l in Library, where: l.storage_profile_uuid == ^profile_uuid, select: count())
    |> repo().one()
  end

  @doc """
  Adds `bucket_uuid` to `profile`, or changes how the profile uses it, and
  bumps the profile's revision.
  """
  @spec put_bucket(StorageProfile.t(), term(), map()) ::
          {:ok, ProfileBucket.t()} | {:error, Ecto.Changeset.t()}
  def put_bucket(%StorageProfile{uuid: profile_uuid}, bucket_uuid, attrs) do
    with :ok <- check_same_owner(profile_uuid, bucket_uuid) do
      do_put_bucket(profile_uuid, bucket_uuid, attrs)
    end
  end

  # A user's bucket is only ever in its owner's profile, and a user's profile
  # holds only the site's buckets and its owner's own: nobody's storage is
  # reachable through somebody else's profile.
  defp check_same_owner(profile_uuid, bucket_uuid) do
    profile_owner =
      repo().one(from(p in StorageProfile, where: p.uuid == ^profile_uuid, select: p.owner_uuid))

    bucket_owner =
      repo().one(
        from(b in PhoenixKit.Modules.Storage.Bucket,
          where: b.uuid == ^bucket_uuid,
          select: b.owner_uuid
        )
      )

    if is_nil(bucket_owner) or bucket_owner == profile_owner,
      do: :ok,
      else: {:error, :foreign_bucket}
  end

  defp do_put_bucket(profile_uuid, bucket_uuid, attrs) do
    row =
      repo().get_by(ProfileBucket, profile_uuid: profile_uuid, bucket_uuid: bucket_uuid) ||
        %ProfileBucket{profile_uuid: profile_uuid, bucket_uuid: bucket_uuid}

    changeset = ProfileBucket.changeset(row, attrs)

    transact(fn ->
      with {:ok, saved} <- repo().insert_or_update(changeset) do
        if row.__meta__.state == :built or moves_bytes?(changeset),
          do: bump_revision(profile_uuid)

        {:ok, saved}
      end
    end)
  end

  # What a file's placement depends on: what a bucket stores, its status,
  # and its role (a file needs a copy it may serve). The serve order is read
  # when a request is served, and a write priority or storage class only
  # applies to the next write: changing them makes no file stale.
  defp moves_bytes?(changeset),
    do: Map.take(changeset.changes, [:stores, :status, :role]) != %{}

  @doc "Takes `bucket_uuid` out of `profile` and bumps the profile's revision."
  @spec remove_bucket(StorageProfile.t(), term()) :: :ok
  def remove_bucket(%StorageProfile{uuid: profile_uuid}, bucket_uuid) do
    {:ok, :ok} =
      transact(fn ->
        {count, _} =
          from(r in ProfileBucket,
            where: r.profile_uuid == ^profile_uuid and r.bucket_uuid == ^bucket_uuid
          )
          |> repo().delete_all()

        if count > 0, do: bump_revision(profile_uuid)
        {:ok, :ok}
      end)

    :ok
  end

  @doc """
  Puts a newly created bucket into the Default profile, the way every new
  bucket joined the pool before profiles: primary, stores everything,
  active, its `priority` as the write priority (0 is the shuffled pool),
  served after the Default's other buckets (a local one before the remote
  ones).
  """
  @spec add_to_default(PhoenixKit.Modules.Storage.Bucket.t()) :: :ok
  def add_to_default(bucket) do
    serve_order =
      from(r in ProfileBucket,
        where: r.profile_uuid == ^@default_uuid,
        select: coalesce(max(r.serve_order), 0)
      )
      |> repo().one()

    # Profiles are seeded by V205; before that (or on a database repair has
    # not reached yet) there is no Default to add to.
    if repo().get(StorageProfile, @default_uuid) do
      {:ok, _} =
        put_bucket(%StorageProfile{uuid: @default_uuid}, bucket.uuid, %{
          role: "primary",
          stores: "all",
          status: "active",
          write_priority: write_priority(bucket.priority),
          serve_order: serve_order + 1
        })
    end

    :ok
  end

  @doc false
  # A bucket's `priority` as a profile's write priority: 0 was "the
  # shuffled pool", which is `nil` here.
  def write_priority(priority) when is_integer(priority) and priority > 0, do: priority
  def write_priority(_priority), do: nil

  @doc """
  Takes `bucket_uuid` out of every profile, bumping each one's revision.
  Called when an empty bucket is deleted.
  """
  @spec remove_bucket_everywhere(term()) :: :ok
  def remove_bucket_everywhere(bucket_uuid) do
    {:ok, :ok} =
      transact(fn ->
        {_count, profile_uuids} =
          from(r in ProfileBucket, where: r.bucket_uuid == ^bucket_uuid, select: r.profile_uuid)
          |> repo().delete_all()

        Enum.each(Enum.uniq(profile_uuids), &bump_revision/1)
        {:ok, :ok}
      end)

    :ok
  end

  @doc """
  Points `library` at `profile_uuid` (nil for the Default). Its files
  become stale unless the new profile is the one they were placed by.
  """
  @spec set_library_profile(Library.t(), term()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_library_profile(%Library{} = library, profile_uuid) do
    profile_uuid = if default?(profile_uuid), do: nil, else: profile_uuid
    target = profile_uuid && get_profile(profile_uuid)

    cond do
      profile_uuid && is_nil(target) ->
        {:error, :not_found}

      # Where a user library keeps its bytes is chosen when it is created and
      # does not change: not off the user's own storage, and not onto anyone's.
      user_profile?(library.storage_profile_uuid) or (target && target.owner_uuid != nil) ->
        {:error, :user_storage_locked}

      true ->
        do_set_library_profile(library, profile_uuid)
    end
  end

  @doc false
  # Points a NEW user library at its own profile (V206). The one way a library
  # gets a user's profile; `set_library_profile/2` refuses it.
  def assign_user_profile(
        %Library{kind: "user", owner_uuid: owner} = library,
        %StorageProfile{
          owner_uuid: owner
        } = profile
      )
      when is_binary(owner) do
    do_set_library_profile(library, profile.uuid)
  end

  defp user_profile?(nil), do: false

  defp user_profile?(uuid),
    do:
      repo().exists?(
        from(p in StorageProfile, where: p.uuid == ^uuid and not is_nil(p.owner_uuid))
      )

  defp do_set_library_profile(library, profile_uuid) do
    library
    |> Ecto.Changeset.change(storage_profile_uuid: profile_uuid)
    |> Ecto.Changeset.foreign_key_constraint(:storage_profile_uuid,
      name: :phoenix_kit_storage_libraries_profile_fkey
    )
    |> repo().update()
    |> tap(&if(match?({:ok, _}, &1), do: ReconcileJob.enqueue()))
  end

  # ===== A user's own storage (V206) =====

  @doc """
  Creates the profile of a user's own storage, in one of two modes:

    * `:only` — the user's bucket is the profile's one `primary`: everything
      the library stores lives there.
    * `:backup` — the site's buckets stay the primaries and the user's bucket
      is a `backup` of the originals. The site buckets are a **snapshot of the
      Default profile taken now**: a site bucket added later is not used by
      this library (removing or disabling one already reaches every profile).
      An original is kept on every one of those site buckets that stores
      originals (not only as many as the Default's copy count: placement writes
      all primaries before any backup, so the backup would otherwise never get
      one) and on the backup, at most 5 copies in all. An upload still succeeds
      on the Default's terms; the backup copy is made by the reconciler if the
      write missed it. Sizes and tiles are not backed up (they can be
      regenerated).

  The profile is the user's (`owner_uuid`), named by its own uuid (the name is
  never shown), and `bucket` must be theirs. Returns `{:error, :no_site_storage}`
  for `:backup` on a site with no site bucket to back up.
  """
  @spec create_user_profile(String.t(), PhoenixKit.Modules.Storage.Bucket.t(), :only | :backup) ::
          {:ok, StorageProfile.t()} | {:error, :no_site_storage | :foreign_bucket | term()}
  def create_user_profile(owner_uuid, %{owner_uuid: owner_uuid} = bucket, mode)
      when is_binary(owner_uuid) and mode in [:only, :backup] do
    transact(fn ->
      with {:ok, rows, copies} <- user_profile_plan(mode, bucket),
           {:ok, profile} <- insert_user_profile(owner_uuid, copies),
           :ok <- insert_user_profile_rows(profile, rows) do
        {:ok, profile.uuid}
      end
    end)
    |> case do
      {:ok, uuid} -> {:ok, get_profile(uuid)}
      error -> error
    end
  end

  def create_user_profile(_owner_uuid, _bucket, _mode), do: {:error, :foreign_bucket}

  defp user_profile_plan(:only, bucket) do
    row = %{
      bucket_uuid: bucket.uuid,
      role: "primary",
      stores: "all",
      write_priority: nil,
      serve_order: 1,
      status: "active"
    }

    {:ok, [row], %{copies_originals: 1, copies_variants: 1, min_copies_on_write: 1}}
  end

  # Placement writes every primary before any backup, up to the copy count, so
  # a backup only gets a copy when the profile wants MORE copies than it has
  # primaries and replicas. The profile therefore wants one original on every
  # site bucket that stores originals, plus the backup (at most 5 copies: with
  # more site buckets than that, the first four by serve order are kept). The
  # upload still succeeds on the Default's terms (`min_copies_on_write`); a
  # backup the write missed is made by the reconciler.
  @max_copies 5

  defp user_profile_plan(:backup, bucket) do
    case default_profile() do
      %StorageProfile{buckets: [_ | _] = rows} = default ->
        site_rows =
          rows
          |> Enum.filter(&(&1.status in ["active", "read_only"] and &1.bucket.owner_uuid == nil))
          |> Enum.map(
            &%{
              bucket_uuid: &1.bucket_uuid,
              role: &1.role,
              stores: &1.stores,
              write_priority: &1.write_priority,
              serve_order: &1.serve_order,
              status: &1.status
            }
          )
          |> keep_room_for_backup()

        if Enum.all?(site_rows, &(&1.stores == "derived")) do
          {:error, :no_site_storage}
        else
          originals = Enum.count(site_rows, &(&1.stores in ["all", "originals"]))

          backup = %{
            bucket_uuid: bucket.uuid,
            role: "backup",
            stores: "originals",
            write_priority: nil,
            serve_order: Enum.max(Enum.map(site_rows, & &1.serve_order)) + 1,
            status: "active"
          }

          {:ok, site_rows ++ [backup],
           %{
             copies_originals: originals + 1,
             copies_variants: min(default.copies_variants, length(site_rows)),
             min_copies_on_write: min(default.min_copies_on_write, originals)
           }}
        end

      _ ->
        {:error, :no_site_storage}
    end
  end

  # At most `@max_copies - 1` site rows, by serve order, so the backup fits in
  # the copy count.
  defp keep_room_for_backup(rows) do
    rows |> Enum.sort_by(& &1.serve_order) |> Enum.take(@max_copies - 1)
  end

  defp insert_user_profile(owner_uuid, copies) do
    %StorageProfile{}
    |> StorageProfile.changeset(Map.put(copies, :name, "user-storage-#{Ecto.UUID.generate()}"))
    |> Ecto.Changeset.put_change(:owner_uuid, owner_uuid)
    |> repo().insert()
  end

  defp insert_user_profile_rows(profile, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      {bucket_uuid, attrs} = Map.pop!(row, :bucket_uuid)

      case put_bucket(profile, bucket_uuid, attrs) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  What each of these libraries keeps its files on, for the ones on a user's own
  storage (V206): `%{library_uuid => %{mode: :only | :backup, bucket: Bucket.t()}}`.
  A library on the site's storage has no entry. One query.
  """
  @spec user_storage_for([Library.t()]) :: %{
          String.t() => %{mode: :only | :backup, bucket: PhoenixKit.Modules.Storage.Bucket.t()}
        }
  def user_storage_for([]), do: %{}

  def user_storage_for(libraries) do
    uuids = Enum.map(libraries, & &1.uuid)

    from(l in Library,
      join: p in StorageProfile,
      on: p.uuid == l.storage_profile_uuid and not is_nil(p.owner_uuid),
      join: pb in ProfileBucket,
      on: pb.profile_uuid == p.uuid,
      join: b in PhoenixKit.Modules.Storage.Bucket,
      on: b.uuid == pb.bucket_uuid and not is_nil(b.owner_uuid),
      where: l.uuid in ^uuids,
      select: {l.uuid, pb.role, b}
    )
    |> repo().all()
    |> Enum.group_by(fn {library_uuid, _role, _bucket} -> to_string(library_uuid) end)
    |> Map.new(fn {library_uuid, rows} ->
      {_uuid, role, bucket} = hd(rows)
      {library_uuid, %{mode: if(role == "backup", do: :backup, else: :only), bucket: bucket}}
    end)
  end

  @doc """
  Removes a user's own profile (V206) and the buckets that were in it and are
  in no profile now: what is left of a user's storage once their library is
  purged. A site profile, or one a library still uses, is left alone.

  Returns `:ok`, or `{:error, reason}` for the first bucket that could not go
  (one that still holds file locations cannot be deleted).
  """
  @spec delete_user_profile(term()) :: :ok | {:error, term()}
  def delete_user_profile(profile_uuid) do
    case get_profile(profile_uuid) do
      %StorageProfile{owner_uuid: owner} = profile when is_binary(owner) ->
        if libraries_using(profile.uuid) > 0,
          do: {:error, :in_use},
          else: remove_user_profile(profile)

      _ ->
        :ok
    end
  end

  defp remove_user_profile(profile) do
    bucket_uuids = Enum.map(profile.buckets, & &1.bucket_uuid)

    {:ok, _} =
      repo().transaction(fn ->
        from(r in ProfileBucket, where: r.profile_uuid == ^profile.uuid) |> repo().delete_all()
        repo().delete!(profile)
      end)

    bucket_uuids
    |> Storage.get_buckets()
    |> Enum.filter(&(is_binary(&1.owner_uuid) and not in_any_profile?(&1.uuid)))
    |> each_ok(fn bucket ->
      case Storage.delete_bucket(bucket) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp in_any_profile?(bucket_uuid),
    do: repo().exists?(from(r in ProfileBucket, where: r.bucket_uuid == ^bucket_uuid))

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Bumps a profile's revision: every file it placed is stale, and the
  reconciler is queued to bring them up to date.
  """
  @spec bump_revision(term()) :: :ok
  def bump_revision(profile_uuid) do
    from(p in StorageProfile, where: p.uuid == ^profile_uuid)
    |> repo().update_all(
      inc: [revision: 1],
      set: [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    ReconcileJob.enqueue()
    :ok
  end

  defp preload_buckets(profile_or_profiles) do
    rows = from(r in ProfileBucket, order_by: [asc: r.serve_order, asc: r.inserted_at])
    repo().preload(profile_or_profiles, buckets: {rows, :bucket})
  end

  defp reload({:ok, uuid}) do
    profile = get_profile(uuid)

    # The Default's copy count is what `storage_redundancy_copies` was; the
    # row is kept in step for code that still reads it.
    if profile.is_default,
      do:
        Settings.update_setting("storage_redundancy_copies", to_string(profile.copies_originals))

    {:ok, profile}
  end

  defp reload(error), do: error

  defp transact(fun) do
    repo().transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
