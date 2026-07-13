defmodule PhoenixKit.Migrations.Postgres.V115 do
  @moduledoc """
  V115: `phoenix_kit_annotations` — drawn-on-image annotations created via
  the Etcher overlay layer.

  Stores user-drawn shapes (rectangle, circle, polygon, freehand) tied to
  a `phoenix_kit_files` row, in image-pixel coordinates. The discussion
  thread for an annotation lives in `phoenix_kit_comments` anchored to
  the **file** (`resource_type = "file"`, `resource_uuid = file_uuid`)
  with `metadata.annotation_uuid` carrying the back-reference — no
  `comment_uuid` column on annotations is needed; the linkage is
  one-directional from the comment side, and annotation-rooted comments
  show up in the file's main thread alongside non-annotated ones.

  Cascade-on-delete on `file_uuid`: deleting a file removes its
  annotations (and the comments module's own cascade handles their
  discussion threads). `creator_uuid` is nullable + `ON DELETE SET NULL`
  so user removals don't take their annotations down with them.

  Indexes:

    * `(file_uuid)` — per-file listing in the MediaBrowser modal.
    * `(creator_uuid)` — author lookups, partial on NOT NULL.

  ## Geometry

  All shape coordinates live in image pixels:

    * rectangle: `{x, y, w, h}`
    * circle:    `{cx, cy, r}`
    * polygon:   `{points: [[x, y], ...]}`
    * freehand:  `{points: [[x, y], ...]}`

  Fresco's pan/zoom rescales them for free at render time.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_if_not_exists table(:phoenix_kit_annotations,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid,
        primary_key: true,
        default: fragment("#{prefix}.uuid_generate_v7()"),
        null: false
      )

      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :creator_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:kind, :string, size: 32, null: false)
      add(:geometry, :map, null: false)
      add(:style, :map)
      add(:metadata, :map)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_annotations, [:file_uuid], prefix: prefix))

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_annotations_creator_uuid_index
    ON #{p}phoenix_kit_annotations (creator_uuid)
    WHERE creator_uuid IS NOT NULL
    """)

    # DB-level guard on the kind enum — matches the four tools Etcher
    # ships in v0.1. Adding a new kind means a follow-up migration that
    # widens this constraint; the schema's validate_inclusion is the
    # user-facing check.
    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_annotations_kind_check'
        AND conrelid = '#{p}phoenix_kit_annotations'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_annotations
          ADD CONSTRAINT phoenix_kit_annotations_kind_check
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '115'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_annotations_creator_uuid_index")
    drop_if_exists(table(:phoenix_kit_annotations, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '114'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
