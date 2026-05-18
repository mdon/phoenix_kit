defmodule PhoenixKit.Migrations.Postgres.V121 do
  @moduledoc """
  V121: Widen `phoenix_kit_annotations_kind_check` for the new
  `"line"` kind.

  Etcher gains a simple two-endpoint line annotation alongside
  `dimension` — same geometry (`{a: [x, y], b: [x, y]}`) but no
  arrowheads and no inline numeric label. Title + comment ride the
  same composer flow as `rectangle` / `circle` / `polygon`.

  Idempotent (`IF NOT EXISTS` guard).
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

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
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '121'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

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
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '120'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
