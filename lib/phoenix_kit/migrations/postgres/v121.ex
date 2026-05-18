defmodule PhoenixKit.Migrations.Postgres.V121 do
  @moduledoc """
  V121: Widen `phoenix_kit_annotations_kind_check` for the new
  `"line"` kind.

  Etcher gains a simple two-endpoint line annotation alongside
  `dimension` — same geometry (`{a: [x, y], b: [x, y]}`) but no
  arrowheads and no inline numeric label. Title + comment ride the
  same composer flow as `rectangle` / `circle` / `polygon`.

  Idempotent: each `ADD CONSTRAINT` is preceded by `DROP CONSTRAINT
  IF EXISTS` on the same prefixed table.
  """

  use Ecto.Migration

  # The DROP IF EXISTS immediately before each ADD makes the re-add
  # unconditional and safe. A `pg_constraint` existence guard would be
  # wrong here: `conname` is unique per namespace, not globally, so on a
  # multi-prefix install it would match another prefix's identically
  # named constraint and skip the add — leaving this prefix's table with
  # no kind check at all.
  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line'))
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
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '120'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
