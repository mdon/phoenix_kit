defmodule PhoenixKit.Modules.Storage.Folder do
  @moduledoc """
  Schema for media folders.

  Provides hierarchical organization for media files. Folders are purely
  metadata — storage buckets are unaware of folder structure.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @folder_colors ~w(default red orange amber yellow lime green emerald teal cyan sky blue violet purple fuchsia pink rose)

  schema "phoenix_kit_media_folders" do
    field :name, :string
    field :description, :string
    field :color, :string, default: "default"
    field :trashed_at, :utc_datetime
    # Folder hero-header customization. The cover (background) and logo (icon)
    # are media files living in the folder, excluded from its visible listing.
    # `header_size` is small/medium/large; the `header_show_*` flags toggle each
    # header element. New folders default to a small header (less vertical
    # space up front). Existing rows keep their stored size — the DB column
    # default (v134, "medium") only applies to raw inserts, which never happen
    # here; folders are always created via changeset, so this default wins.
    field :cover_file_uuid, UUIDv7
    field :logo_file_uuid, UUIDv7
    field :header_size, :string, default: "small"
    field :header_show_title, :boolean, default: true
    field :header_show_icon, :boolean, default: true
    field :header_show_creator, :boolean, default: true
    field :header_show_date, :boolean, default: true
    field :header_show_file_count, :boolean, default: true
    field :header_show_description, :boolean, default: true
    field :header_show_background, :boolean, default: true

    belongs_to :parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid

    has_many :children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid

    has_many :files, PhoenixKit.Modules.Storage.File,
      foreign_key: :folder_uuid,
      references: :uuid

    has_many :folder_links, PhoenixKit.Modules.Storage.FolderLink,
      foreign_key: :folder_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def colors, do: @folder_colors

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [
      :name,
      :description,
      :parent_uuid,
      :user_uuid,
      :color,
      :trashed_at,
      :cover_file_uuid,
      :logo_file_uuid,
      :header_size,
      :header_show_title,
      :header_show_icon,
      :header_show_creator,
      :header_show_date,
      :header_show_file_count,
      :header_show_description,
      :header_show_background
    ])
    |> validate_required([:name])
    |> validate_inclusion(:color, @folder_colors)
    |> validate_inclusion(:header_size, ~w(small medium large))
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> foreign_key_constraint(:parent_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:name, :parent_uuid],
      name: :phoenix_kit_media_folders_name_parent_idx
    )
  end
end
