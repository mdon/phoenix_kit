defmodule PhoenixKit.Migrations.Postgres.V118 do
  @moduledoc """
  V118: Widen `phoenix_kit_annotations_kind_check` for the new
  `"callout"` and `"text"` kinds + add a `title` column to
  `phoenix_kit_annotations`.

  Etcher 0.2 ships three related additions on the annotations table;
  they're folded into one migration because they all hang off the
  same row schema (kind CHECK + a single new column) — splitting
  would have meant two trips over the same constraint.

    1. **Callout** — leader-line annotation: a small anchor point
       with a line connecting to a labeled text bbox that displays
       inline on the image. Needs `kind = "callout"` to pass the
       V115 CHECK.

    2. **Text** — freestanding text label drawn as a click-drag bbox
       whose content lives in the V118 `title` column. Needs
       `kind = "text"` to pass the CHECK.

    3. **`title varchar(200)`** — optional short label that every
       kind can carry. Renders inline on the shape (above the
       bounding box for rect/circle/polygon, at the leader endpoint
       for callout, inside the bbox for text). Its own column so
       it stays queryable outside the JSONB blob.

  Both operations are idempotent (`IF NOT EXISTS` / `DO $$` guards)
  so re-running on a partially-applied schema is a no-op.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Widen the kind CHECK constraint to include callout + text.
    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    DO $$ BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_annotations_kind_check'
        AND conrelid = '#{p}phoenix_kit_annotations'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_annotations
          ADD CONSTRAINT phoenix_kit_annotations_kind_check
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text'));
      END IF;
    END $$
    """)

    # Optional inline title.
    execute("ALTER TABLE #{p}phoenix_kit_annotations ADD COLUMN IF NOT EXISTS title VARCHAR(200)")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '118'")
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
        AND conrelid = '#{p}phoenix_kit_annotations'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_annotations
          ADD CONSTRAINT phoenix_kit_annotations_kind_check
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '117'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
