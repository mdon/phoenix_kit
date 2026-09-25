defmodule PhoenixKit.Modules.Storage.VariantSets do
  @moduledoc """
  Variant sets: which derived files a library's uploads get (V205).

  A library points at a set (`PhoenixKit.Modules.Storage.VariantSet`), and
  the set's sizes are its `PhoenixKit.Modules.Storage.Dimension` rows. A
  library with no set uses the **Default**, seeded by V205 with every size
  the install had, under a fixed uuid (`default_uuid/0`). Size names are
  unique per set, so two sets can each have a `thumbnail` of a different
  size.

  ## Standard slots

  A size's name is part of every file URL, and core and modules ask for
  some by name, so every set has the five standard slots
  (`standard_slots/0`): `thumbnail`, `small`, `medium`, `large` and
  `video_thumbnail`. A set may change their size, format and quality, but
  not delete or rename them, and `small`, `medium` and `large` keep the
  aspect ratio (`aspect_slots/0`); only `thumbnail` may be cropped. A new
  set starts with the Default's standard slots.

  ## Spec hash

  A generated instance records which spec of its size made it
  (`FileInstance.spec_hash`, `spec_hash/2`), and a set records a `revision`
  bumped on every change to it or its sizes. A file records the set and
  revision its variants were made by (`placed_variant_set_uuid` /
  `placed_variant_revision`, NULL meaning the Default at revision 1). The
  reconciler regenerates the instances of a stale file whose spec changed.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.{Dimension, Library, VariantSet}
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries

  @default_uuid "00000000-0000-7000-8000-000000000003"
  @standard_slots ~w(thumbnail small medium large video_thumbnail)
  @aspect_slots ~w(small medium large)

  @doc "The uuid of the Default variant set, fixed on every install."
  @spec default_uuid() :: String.t()
  def default_uuid, do: @default_uuid

  @doc "Whether `uuid` is the Default set's."
  @spec default?(term()) :: boolean()
  def default?(%VariantSet{uuid: uuid}), do: default?(uuid)
  def default?(uuid), do: to_string(uuid) == @default_uuid

  @doc "The sizes every set has."
  @spec standard_slots() :: [String.t()]
  def standard_slots, do: @standard_slots

  @doc "The standard slots that always keep the aspect ratio."
  @spec aspect_slots() :: [String.t()]
  def aspect_slots, do: @aspect_slots

  @doc "Every set, the Default first."
  @spec list_variant_sets() :: [VariantSet.t()]
  def list_variant_sets do
    from(s in VariantSet, order_by: [desc: s.is_default, asc: fragment("lower(?)", s.name)])
    |> repo().all()
  end

  @doc "The sets a user library may choose."
  @spec list_selectable() :: [VariantSet.t()]
  def list_selectable do
    from(s in VariantSet,
      where: s.selectable or s.is_default,
      order_by: [desc: s.is_default, asc: fragment("lower(?)", s.name)]
    )
    |> repo().all()
  end

  @doc "A set, or nil (also for anything not a uuid)."
  @spec get_variant_set(term()) :: VariantSet.t() | nil
  def get_variant_set(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(VariantSet, uuid)
      :error -> nil
    end
  end

  @doc "The Default set."
  @spec default_variant_set() :: VariantSet.t() | nil
  def default_variant_set, do: get_variant_set(@default_uuid)

  @doc """
  The uuid of the set `library` uses: its own, or the Default. Takes a
  library, a library uuid, or nil (a file with no library is in Media).
  """
  @spec set_uuid_for(Library.t() | term()) :: String.t()
  def set_uuid_for(%Library{variant_set_uuid: nil}), do: @default_uuid
  def set_uuid_for(%Library{variant_set_uuid: uuid}), do: to_string(uuid)
  def set_uuid_for(nil), do: set_uuid_for(Libraries.media_uuid())

  def set_uuid_for(library_uuid) do
    case Libraries.get_library(library_uuid) do
      %Library{} = library -> set_uuid_for(library)
      nil -> @default_uuid
    end
  end

  @doc "The set `library` uses; the Default when its own is gone."
  @spec for_library(Library.t() | term()) :: VariantSet.t() | nil
  def for_library(library) do
    library |> set_uuid_for() |> get_variant_set() || default_variant_set()
  end

  @doc "The set a file's library uses."
  @spec for_file(StorageFile.t()) :: VariantSet.t() | nil
  def for_file(%StorageFile{library_uuid: library_uuid}), do: for_library(library_uuid)

  @doc "A set's sizes, ordered as the admin arranged them."
  @spec list_dimensions(term()) :: [Dimension.t()]
  def list_dimensions(set_uuid) do
    from(d in Dimension,
      where: d.variant_set_uuid == ^set_uuid,
      order_by: [asc: d.order, asc: d.name]
    )
    |> repo().all()
  end

  @doc "The standard slots `set_uuid` has no size for."
  @spec missing_standard_slots(term()) :: [String.t()]
  def missing_standard_slots(set_uuid) do
    present =
      from(d in Dimension, where: d.variant_set_uuid == ^set_uuid, select: d.name)
      |> repo().all()

    @standard_slots -- present
  end

  @doc """
  Creates a set. It starts with a copy of the Default's standard slots,
  so it keeps the contract every set has.
  """
  @spec create_variant_set(map()) :: {:ok, VariantSet.t()} | {:error, Ecto.Changeset.t()}
  def create_variant_set(attrs) do
    changeset = VariantSet.changeset(%VariantSet{}, attrs)

    transact(fn ->
      with {:ok, set} <- repo().insert(changeset) do
        copy_standard_slots(set.uuid)
        {:ok, set}
      end
    end)
  end

  defp copy_standard_slots(set_uuid) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      from(d in Dimension,
        where: d.variant_set_uuid == ^@default_uuid and d.name in ^@standard_slots
      )
      |> repo().all()
      |> Enum.map(fn d ->
        d
        |> Map.take([
          :name,
          :width,
          :height,
          :quality,
          :format,
          :applies_to,
          :enabled,
          :maintain_aspect_ratio,
          :alternative_formats,
          :order
        ])
        |> Map.merge(%{
          uuid: UUIDv7.generate(),
          variant_set_uuid: set_uuid,
          inserted_at: now,
          updated_at: now
        })
      end)

    repo().insert_all(Dimension, rows)
  end

  @doc """
  Updates a set's name or flags. Turning variant or tile generation on or
  off bumps its revision; a rename or `selectable` does not.
  """
  @spec update_variant_set(VariantSet.t(), map()) ::
          {:ok, VariantSet.t()} | {:error, Ecto.Changeset.t()}
  def update_variant_set(%VariantSet{} = set, attrs) do
    changeset = VariantSet.changeset(set, attrs)

    transact(fn ->
      with {:ok, updated} <- repo().update(changeset) do
        if Map.drop(changeset.changes, [:name, :selectable]) != %{},
          do: bump_revision(updated.uuid)

        {:ok, updated.uuid}
      end
    end)
    |> case do
      {:ok, uuid} -> {:ok, get_variant_set(uuid)}
      error -> error
    end
  end

  @doc """
  Deletes a set and its sizes. The Default cannot be deleted
  (`{:error, :default}`), nor a set a library uses (`{:error, :in_use}`).
  """
  @spec delete_variant_set(VariantSet.t()) ::
          {:ok, VariantSet.t()} | {:error, :default | :in_use | Ecto.Changeset.t()}
  def delete_variant_set(%VariantSet{} = set) do
    cond do
      default?(set) ->
        {:error, :default}

      libraries_using(set.uuid) > 0 ->
        {:error, :in_use}

      true ->
        set
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:uuid,
          name: :phoenix_kit_storage_libraries_variant_set_fkey,
          message: "is used by a library"
        )
        |> repo().delete()
    end
  end

  @doc "How many libraries (trashed ones included) use `set_uuid` explicitly."
  @spec libraries_using(term()) :: non_neg_integer()
  def libraries_using(set_uuid) do
    from(l in Library, where: l.variant_set_uuid == ^set_uuid, select: count())
    |> repo().one()
  end

  @doc """
  Points `library` at `set_uuid` (nil for the Default). A user library may
  only use a selectable set (`{:error, :not_selectable}`).
  """
  @spec set_library_variant_set(Library.t(), term()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t() | :not_found | :not_selectable}
  def set_library_variant_set(%Library{} = library, set_uuid) do
    set_uuid = if default?(set_uuid), do: nil, else: set_uuid
    set = set_uuid && get_variant_set(set_uuid)

    cond do
      set_uuid && is_nil(set) ->
        {:error, :not_found}

      library.kind == "user" and match?(%VariantSet{selectable: false}, set) ->
        {:error, :not_selectable}

      true ->
        library
        |> Ecto.Changeset.change(variant_set_uuid: set_uuid)
        |> Ecto.Changeset.foreign_key_constraint(:variant_set_uuid,
          name: :phoenix_kit_storage_libraries_variant_set_fkey
        )
        |> repo().update()
    end
  end

  @doc "Bumps a set's revision: every file whose variants it made is stale."
  @spec bump_revision(term()) :: :ok
  def bump_revision(set_uuid) do
    from(s in VariantSet, where: s.uuid == ^set_uuid)
    |> repo().update_all(
      inc: [revision: 1],
      set: [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    :ok
  end

  @doc """
  The spec hash of the variant `dimension` makes in `format` (its own
  format when not given; nil keeps the original's). Only what changes the
  pixels counts: width, height, quality, format and whether the aspect
  ratio is kept. V205 stamped existing instances with the same text in SQL
  (`PhoenixKit.Migrations.Postgres.V205.spec_hash_sql/1`).
  """
  @spec spec_hash(Dimension.t()) :: String.t()
  @spec spec_hash(Dimension.t(), String.t() | nil) :: String.t()
  def spec_hash(%Dimension{} = dimension), do: spec_hash(dimension, dimension.format)

  def spec_hash(%Dimension{} = d, format) do
    aspect = if d.maintain_aspect_ratio, do: "t", else: "f"

    "v1|w=#{d.width}|h=#{d.height}|q=#{d.quality}|f=#{format}|a=#{aspect}"
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

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
