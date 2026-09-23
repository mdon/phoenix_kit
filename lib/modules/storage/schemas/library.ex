defmodule PhoenixKit.Modules.Storage.Library do
  @moduledoc """
  A storage library: a partition of the file store (V202).

  Every file, media folder and folder link belongs to exactly one library.
  **System** libraries are site-wide and managed by admins; everything that
  existed before V202 lives in the default one, **Media**
  (`PhoenixKit.Modules.Storage.Libraries.media_uuid/0`). **User** libraries
  (a later phase) belong to a user.

  `key_prefix` is the first segment of the object key for files stored in the
  library from now on. `nil` keeps the historical layout, which is what Media
  uses, so nothing about an existing install's keys changes.

  Go through `PhoenixKit.Modules.Storage.Libraries` rather than this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(system user)
  @visibilities ~w(site private)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          kind: String.t(),
          owner_uuid: UUIDv7.t() | nil,
          visibility: String.t(),
          key_prefix: String.t() | nil,
          settings: map(),
          is_default: boolean(),
          trashed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_libraries" do
    field :name, :string
    field :kind, :string, default: "system"
    field :visibility, :string, default: "site"
    field :key_prefix, :string
    field :settings, :map, default: %{}
    field :is_default, :boolean, default: false
    field :trashed_at, :utc_datetime

    belongs_to :owner, PhoenixKit.Users.Auth.User,
      foreign_key: :owner_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc "A new system library: a name and an object-key prefix."
  def create_system_changeset(library, attrs) do
    library
    |> cast(attrs, [:name, :key_prefix])
    |> put_change(:kind, "system")
    |> put_change(:visibility, "site")
    |> validate_name()
    |> validate_required([:key_prefix])
    |> validate_format(:key_prefix, ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/)
    |> unique_constraint(:key_prefix, name: :phoenix_kit_storage_libraries_key_prefix_index)
  end

  @doc "Renames a library. Its kind, owner and key prefix never change here."
  def rename_changeset(library, attrs) do
    library
    |> cast(attrs, [:name])
    |> validate_name()
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint(:name,
      name: :phoenix_kit_storage_libraries_owner_name_index,
      message: "is already the name of another library"
    )
  end
end
