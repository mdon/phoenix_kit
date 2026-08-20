defmodule PhoenixKit.Migrations.Postgres.V179 do
  @moduledoc """
  V179: an item's manufacturer becomes a federated reference — `{source, uuid}`
  — instead of a hard foreign key into the catalogue's local directory.

  ## Why

  CRM owns party identity, and a manufacturer that is a real company is a CRM
  party. `phoenix_kit_cat_items.manufacturer_uuid` was a FOREIGN KEY onto
  `phoenix_kit_cat_manufacturers`, so a party's uuid physically could not be
  stored in it: the catalogue could only ever point at a local row. That is the
  same shape `phoenix_kit_cat_item_supplier_info` already uses for suppliers
  (soft uuid + `supplier_source` + a name snapshot), and this brings
  manufacturers into line with it.

  Three changes:

    * `manufacturer_source` — `'local'` (a `phoenix_kit_cat_manufacturers` row)
      or `'crm_company'` (a CRM party). Existing rows are all `'local'`, which
      is what the default backfills.
    * `manufacturer_name_snapshot` — a TOMBSTONE, not a cache. It is read only
      when the reference resolves to nothing (party deleted, CRM uninstalled,
      dangling uuid) so a product page can still say what it used to be. It is
      never the display source: the resolver is.
    * the FK is DROPPED.

  ## What replaces the FK

  Nothing, deliberately. `ON DELETE SET NULL` cannot span an optional-module
  boundary — the CRM tables need not exist — so integrity moves to the
  application, exactly as it already has for `item_supplier_info.supplier_uuid`
  and the warehouse document columns. `mix phoenix_kit_catalogue.audit_supplier_refs`
  is the precedent for auditing soft references; manufacturers now want the
  same treatment.

  ## Rollback

  `down/1` re-creates the FK, and it will FAIL if any item points at a CRM
  party by then — that uuid has no matching local row, which is the whole
  point of the column. Repoint those items first (unlink the manufacturer in
  the catalogue UI) and the rollback succeeds. Better to fail loudly here than
  to silently drop the offending references.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    ADD COLUMN IF NOT EXISTS manufacturer_source VARCHAR(20) NOT NULL DEFAULT 'local'
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    ADD COLUMN IF NOT EXISTS manufacturer_name_snapshot VARCHAR(255)
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = 'phoenix_kit_cat_items_manufacturer_source_check'
          AND t.relname = 'phoenix_kit_cat_items'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD CONSTRAINT phoenix_kit_cat_items_manufacturer_source_check
          CHECK (manufacturer_source IN ('local', 'crm_company'));
      END IF;
    END $$;
    """)

    # The FK is what forced every item's manufacturer to be a local row.
    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_manufacturer_uuid_fkey
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '179'")
  end

  @doc """
  Rolls V179 back: restores the foreign key and drops the two columns.

  Raises if any item currently references a CRM party as its manufacturer —
  see the moduledoc. Nothing is silently discarded.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_cat_items
        WHERE manufacturer_source <> 'local' AND manufacturer_uuid IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'V179 down: items reference a CRM manufacturer; unlink them before rolling back';
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_manufacturer_source_check
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = 'phoenix_kit_cat_items_manufacturer_uuid_fkey'
          AND t.relname = 'phoenix_kit_cat_items'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_items
          ADD CONSTRAINT phoenix_kit_cat_items_manufacturer_uuid_fkey
          FOREIGN KEY (manufacturer_uuid)
          REFERENCES #{p}phoenix_kit_cat_manufacturers(uuid) ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP COLUMN IF EXISTS manufacturer_name_snapshot
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP COLUMN IF EXISTS manufacturer_source
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '178'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
