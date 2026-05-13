defmodule PhoenixKit.Migrations.Postgres.V116 do
  @moduledoc """
  V116: Widen `phoenix_kit_annotations_kind_check` for callouts +
  add a `title` column to `phoenix_kit_annotations`.

  Etcher 0.2 ships two related additions:

    1. A callout / leader-line drawing tool — a small anchor point
       with a line connecting to a text label that displays inline on
       the image. Needs `kind = "callout"` to pass the V115 CHECK
       constraint, so this migration drops + re-adds the constraint
       with the wider value set.

    2. An optional `title` field on every annotation. When non-blank,
       the title renders inline on the shape (above the bounding box
       for rect/circle/polygon, at the leader endpoint for callout).
       Position-wise it can be relocated by the user via a drag
       handle in edit mode; the offset lives in `metadata.title_offset`.
       Title text itself is its own column so it stays queryable
       outside the JSONB blob.

  Both operations are idempotent (`IF NOT EXISTS` / `DO $$` guards)
  so re-running on a partially-applied schema is a no-op.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Widen the kind CHECK constraint.
    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_annotations_kind_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_annotations
          ADD CONSTRAINT phoenix_kit_annotations_kind_check
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout'));
      END IF;
    END $$
    """)

    # Optional inline title.
    execute("ALTER TABLE #{p}phoenix_kit_annotations ADD COLUMN IF NOT EXISTS title VARCHAR(200)")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '116'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_annotations DROP COLUMN IF EXISTS title")

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_annotations_kind_check'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_annotations
          ADD CONSTRAINT phoenix_kit_annotations_kind_check
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '115'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
