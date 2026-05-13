defmodule PhoenixKit.Migrations.Postgres.V117 do
  @moduledoc """
  V117: Widen `phoenix_kit_annotations_kind_check` to include `"text"`.

  Etcher 0.3 introduces a `text` shape kind — a freestanding label
  drawn as a click-drag bbox containing user-typed text (stored in
  the V116 `title` column). It's the canonical way to drop a floating
  label on an image, distinct from the inline title that rides along
  an existing shape.

  The migration drops and re-adds the kind CHECK with the wider value
  set; the inverse `down/1` restores the V116 set.
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
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '117'")
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
          CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout'));
      END IF;
    END $$
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '116'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
