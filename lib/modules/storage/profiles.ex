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

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.{Library, ProfileBucket, StorageProfile}
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob

  @default_uuid "00000000-0000-7000-8000-000000000002"

  @doc "The uuid of the Default profile, fixed on every install."
  @spec default_uuid() :: String.t()
  def default_uuid, do: @default_uuid

  @doc "Whether `uuid` is the Default profile's."
  @spec default?(term()) :: boolean()
  def default?(%StorageProfile{uuid: uuid}), do: default?(uuid)
  def default?(uuid), do: to_string(uuid) == @default_uuid

  @doc "Every profile, the Default first, each with its buckets."
  @spec list_profiles() :: [StorageProfile.t()]
  def list_profiles do
    from(p in StorageProfile, order_by: [desc: p.is_default, asc: fragment("lower(?)", p.name)])
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

  # A rename moves no bytes, so it does not make every file stale.
  defp placement_changed?(changeset),
    do: Map.drop(changeset.changes, [:name]) != %{}

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
    row =
      repo().get_by(ProfileBucket, profile_uuid: profile_uuid, bucket_uuid: bucket_uuid) ||
        %ProfileBucket{profile_uuid: profile_uuid, bucket_uuid: bucket_uuid}

    changeset = ProfileBucket.changeset(row, attrs)

    transact(fn ->
      with {:ok, saved} <- repo().insert_or_update(changeset) do
        if row.__meta__.state == :built or changeset.changes != %{},
          do: bump_revision(profile_uuid)

        {:ok, saved}
      end
    end)
  end

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

    if profile_uuid && is_nil(get_profile(profile_uuid)) do
      {:error, :not_found}
    else
      library
      |> Ecto.Changeset.change(storage_profile_uuid: profile_uuid)
      |> Ecto.Changeset.foreign_key_constraint(:storage_profile_uuid,
        name: :phoenix_kit_storage_libraries_profile_fkey
      )
      |> repo().update()
      |> tap(&if(match?({:ok, _}, &1), do: ReconcileJob.enqueue()))
    end
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

  defp reload({:ok, uuid}), do: {:ok, get_profile(uuid)}
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
