defmodule PhoenixKit.Annotations.Annotation do
  @moduledoc """
  Ecto schema for `phoenix_kit_annotations`.

  Stores user-drawn shapes (rectangle, circle, polygon, freehand) tied to
  a `PhoenixKit.Modules.Storage.File` via `file_uuid`. All geometry is
  in image-pixel coordinates; Fresco's coordinate adapter rescales for
  pan/zoom at render time.

  ## Comment thread linkage

  An annotation's discussion thread lives in `phoenix_kit_comments` via
  the established convention (`resource_type = "annotation"`,
  `resource_uuid = annotation.uuid`). There is no `comment_uuid` column
  on annotations — the relationship is one-directional from the comment
  side, and a thread is created lazily when the first comment is posted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(rectangle circle polygon freehand)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          file_uuid: UUIDv7.t(),
          creator_uuid: UUIDv7.t() | nil,
          kind: String.t(),
          geometry: map(),
          style: map() | nil,
          metadata: map() | nil,
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_annotations" do
    field :file_uuid, UUIDv7
    field :creator_uuid, UUIDv7
    field :kind, :string
    field :geometry, :map
    field :style, :map
    field :metadata, :map
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @cast_fields ~w(file_uuid creator_uuid kind geometry style metadata position)a
  @required_fields ~w(file_uuid kind geometry)a

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:file_uuid)
    |> foreign_key_constraint(:creator_uuid)
    |> check_constraint(:kind, name: :phoenix_kit_annotations_kind_check)
  end

  @doc "List of allowed kind strings."
  def kinds, do: @kinds
end
