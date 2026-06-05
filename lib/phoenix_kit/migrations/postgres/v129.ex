defmodule PhoenixKit.Migrations.Postgres.V129 do
  @moduledoc """
  V129: Widen `phoenix_kit_annotations_kind_check` for the new
  `"marker"` kind.

  The Media viewer exposes Etcher's marker (highlighter) tool. A
  marker persists like any other shape via `annotations-changed`, but
  it's pure marking — the viewer skips the annotation composer for it,
  so it carries no title/comment. Without widening the CHECK constraint
  (and the schema's `@kinds`) the insert is rejected and the marker
  silently fails to save across a reload.

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
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '129'")
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
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '128'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
