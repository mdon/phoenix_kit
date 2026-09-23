defmodule PhoenixKit.Modules.Storage.FolderLink do
  @moduledoc """
  Schema for folder links (shortcuts).

  Allows a file to appear in multiple folders without moving it.
  The file's home folder is tracked via `folder_uuid` on the file itself;
  this junction table provides additional folder appearances.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_media_folder_links" do
    belongs_to :folder, PhoenixKit.Modules.Storage.Folder,
      foreign_key: :folder_uuid,
      references: :uuid

    belongs_to :file, PhoenixKit.Modules.Storage.File,
      foreign_key: :file_uuid,
      references: :uuid

    # The linked file's library (V202). `(file_uuid, library_uuid)` references
    # the file's own pair, so a link cannot name another library; the column
    # defaults to Media, which is every file's library until a second exists.
    field :library_uuid, UUIDv7, read_after_writes: true

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:folder_uuid, :file_uuid, :library_uuid])
    |> validate_required([:folder_uuid, :file_uuid])
    |> foreign_key_constraint(:folder_uuid)
    |> foreign_key_constraint(:file_uuid)
    |> foreign_key_constraint(:library_uuid,
      name: :phoenix_kit_media_folder_links_file_library_fkey,
      message: "is not the file's library"
    )
    |> unique_constraint([:folder_uuid, :file_uuid])
  end
end
