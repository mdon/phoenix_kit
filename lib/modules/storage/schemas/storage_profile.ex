defmodule PhoenixKit.Modules.Storage.StorageProfile do
  @moduledoc """
  A storage profile: where a library's bytes live (V205).

  A library points at a profile (`storage_profile_uuid`; NULL means the
  Default, `PhoenixKit.Modules.Storage.Profiles.default_uuid/0`). The profile
  lists its buckets (`PhoenixKit.Modules.Storage.ProfileBucket`: role, what
  each stores, write priority, serve order, status) and says how many copies
  an object gets:

    * `copies_originals` — copies of an original upload (1..5);
    * `copies_variants` — copies of a derived file: a size, a tile, a
      render (1..5; a variant can be regenerated, so 1 is usually enough);
    * `min_copies_on_write` — an upload fails unless at least this many
      copies were written (1..`copies_originals`); the rest are made by the
      reconciler.

  `revision` goes up on every change to the profile or its buckets. A file
  records the profile and revision it was placed by, and is stale, for the
  reconciler, when either differs from its library's.

  Go through `PhoenixKit.Modules.Storage.Profiles` rather than this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          is_default: boolean(),
          copies_originals: pos_integer(),
          copies_variants: pos_integer(),
          min_copies_on_write: pos_integer(),
          revision: pos_integer(),
          buckets:
            [PhoenixKit.Modules.Storage.ProfileBucket.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_profiles" do
    field :name, :string
    field :is_default, :boolean, default: false
    field :copies_originals, :integer, default: 1
    field :copies_variants, :integer, default: 1
    field :min_copies_on_write, :integer, default: 1
    field :revision, :integer, default: 1

    has_many :buckets, PhoenixKit.Modules.Storage.ProfileBucket,
      foreign_key: :profile_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc "Name and copy counts. `is_default` and `revision` are never cast."
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :copies_originals, :copies_variants, :min_copies_on_write])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :copies_originals, :copies_variants, :min_copies_on_write])
    |> validate_length(:name, max: 255)
    |> validate_number(:copies_originals, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_number(:copies_variants, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_min_copies()
    |> unique_constraint(:name, name: :phoenix_kit_storage_profiles_name_index)
    |> check_constraint(:min_copies_on_write, name: :phoenix_kit_storage_profiles_copies_check)
  end

  defp validate_min_copies(changeset) do
    case get_field(changeset, :copies_originals) do
      copies when is_integer(copies) ->
        validate_number(changeset, :min_copies_on_write,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: copies
        )

      _ ->
        changeset
    end
  end
end
