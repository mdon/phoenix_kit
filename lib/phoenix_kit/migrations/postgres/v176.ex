defmodule PhoenixKit.Migrations.Postgres.V176 do
  @moduledoc """
  V176: `phoenix_kit_cat_item_attribute_sets` — the catalogue's item ↔
  attribute-set attachments (attribute-sets rework, replaces the single
  `phoenix_kit_cat_item_attribute_groups` assignment).

  A SET is a managed entities blueprint ("Ikea colors"); an item attaches
  any number of sets, ordered. `set_uuid` references
  `phoenix_kit_entities.uuid` WITHOUT an FK — deliberate, and load-bearing:
  the entities blueprint delete path consults the owning module's delete
  guard (`PhoenixKitEntities.Managed`), and the catalogue additionally
  cleans orphans off entities PubSub events. A hard FK would either
  cascade catalogue data on a blueprint delete or block entities' own
  lifecycle with a cross-module dependency — neither is this codebase's
  pattern for cross-module references (see V175's integration_uuid note).

  `data` (JSONB, default `{}`) is reserved per-attachment state. Known
  future keys (designed, not yet read by any code):

    * `"disabled_value_slugs"` — per-item value availability
    * `"selected_value_slug"`  — the item's current configuration

  Reserving the column now means those features land without another
  migration; readers must tolerate unknown keys.

  The old attribute tables (V103-era `cat_attribute_groups` /
  `cat_attributes` / `cat_attribute_values` / `cat_item_attribute_groups`)
  are NOT touched here — they go read-only during the dual-run and are
  dropped by a later version once the cutover completes.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_attribute_sets (
      item_uuid UUID NOT NULL,
      set_uuid UUID NOT NULL,
      position INTEGER NOT NULL DEFAULT 0,
      data JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
      updated_at TIMESTAMP(0) WITHOUT TIME ZONE NOT NULL,
      PRIMARY KEY (item_uuid, set_uuid)
    )
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = 'phoenix_kit_cat_item_attribute_sets_item_uuid_fkey'
          AND t.relname = 'phoenix_kit_cat_item_attribute_sets'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_item_attribute_sets
          ADD CONSTRAINT phoenix_kit_cat_item_attribute_sets_item_uuid_fkey
          FOREIGN KEY (item_uuid) REFERENCES #{p}phoenix_kit_cat_items(uuid)
          ON DELETE CASCADE;
      END IF;
    END $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_attribute_sets_set_uuid_index
      ON #{p}phoenix_kit_cat_item_attribute_sets (set_uuid)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '176'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_cat_item_attribute_sets")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '175'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
