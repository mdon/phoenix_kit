defmodule PhoenixKit.Migrations.Postgres.V157 do
  @moduledoc """
  V157: Widen `phoenix_kit_annotations_kind_check` for the new
  `"image"` kind.

  PR #660 exposed Etcher 0.9's `:image` tool in the media viewer's
  toolbar (`media_canvas_viewer.html.heex`) without widening the CHECK
  constraint (or the schema's `@kinds`) to match — the same regression
  V130's moduledoc warns about for `"marker"`. Without this, inserting
  an image annotation is rejected by the DB and silently fails to
  persist across a reload.

  Idempotent: each `ADD CONSTRAINT` is preceded by `DROP CONSTRAINT
  IF EXISTS` on the same prefixed table.

  ## down/1 is conditional, by necessity

  Rolling back re-adds the *narrower* CHECK, and Postgres validates
  every existing row when a CHECK is added. So the rollback is only
  possible while no `kind = 'image'` annotation exists — once a user has
  drawn one, the old constraint is not a truthful description of the
  data and there is no correct way for a schema migration to assert it.

  `down/1` therefore checks first and raises a message naming the row
  count and the two ways forward, rather than letting the `ALTER` fail
  with an opaque `23514` mid-rollback. The alternatives were both worse:
  deleting or rewriting user annotations is data loss a rollback has no
  business performing, and `NOT VALID` would leave a constraint that
  lies about the rows already in the table.
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
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker', 'image'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '157'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Runs before anything is queued, so no flush/1 is needed and no
    # half-applied DDL can be left behind when this raises.
    guard_no_image_annotations!(p)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '156'")
  end

  defp guard_no_image_annotations!(p) do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM #{p}phoenix_kit_annotations WHERE kind = 'image'")

    if count > 0 do
      raise """
      Cannot roll back V157: #{count} annotation(s) with kind = 'image' exist \
      in #{p}phoenix_kit_annotations.

      V157 widened phoenix_kit_annotations_kind_check to allow 'image'. Rolling \
      back re-adds the narrower CHECK, which Postgres validates against every \
      existing row — so these rows would make the ALTER fail regardless.

      To proceed, either:

        1. Remove or convert them first, e.g.
             DELETE FROM #{p}phoenix_kit_annotations WHERE kind = 'image';
           (or UPDATE ... SET kind = 'callout' to keep the geometry), then \
      re-run the rollback; or
        2. Stay on V157 — the widened CHECK is a superset of V156's and is \
      harmless to a host that no longer draws image annotations.
      """
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
