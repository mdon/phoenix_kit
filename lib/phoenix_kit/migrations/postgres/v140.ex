defmodule PhoenixKit.Migrations.Postgres.V140 do
  @moduledoc """
  V140: Warehouse module tables.

  Creates the six `phoenix_kit_warehouse_*` tables that back the standalone
  `phoenix_kit_warehouse` package: `stock`, `inventory_documents`,
  `internal_orders`, `supplier_orders`, `goods_receipts`, `goods_issues`.

  These mirror the shape of the host-application tables the module was
  extracted from, minus every FK that pointed at a host-specific table:

  - `internal_orders` and `goods_issues` drop the `sub_order_uuid` FK — that
    relationship now lives exclusively in the generic `source_refs` JSONB
    column (`[%{"kind" => "sub_order", "uuid" => ...}, ...]`), resolved by a
    host-registered callback rather than a hard FK to an order table this
    package doesn't own. A GIN index on `source_refs` stands in for the index
    the dropped FK column used to provide, so the reverse lookup ("which
    documents reference this order?") stays off a sequential scan.
  - Intra-module FKs are kept: `supplier_orders.internal_order_uuid` →
    `internal_orders`, `goods_receipts.supplier_order_uuid` →
    `supplier_orders`, `goods_issues.internal_order_uuid` → `internal_orders`.
  - `performed_by_uuid` stays FK'd to `phoenix_kit_users` on every document
    table (core-to-core reference, unchanged from the originals).
  - `item_uuid`, `location_uuid`, `storage_folder_uuid`, and `supplier_uuid`
    are plain UUID columns. Their targets (`phoenix_kit_cat_items`,
    `phoenix_kit_locations`, `phoenix_kit_media_folders`,
    `phoenix_kit_cat_suppliers`) are all created by this same core migration
    set, so an FK would be physically possible. It is omitted because the
    delete semantics — restrict a location that still holds stock, versus
    cascade the documents away with it — are a product decision the warehouse
    package has not made yet. Until it does, referential integrity for these
    four columns is **not** enforced by the database, and a dangling
    `location_uuid` will not be rejected on insert.

  This migration ships the tables only — no application code reads or writes
  them yet, and no data is copied from the host's legacy tables (that is a
  separate, later host-side data migration, run only after the new package
  and its LiveViews are built and verified).
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # 1. Stock — per (item, location) balance.
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_stock (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      item_uuid UUID NOT NULL,
      location_uuid UUID NOT NULL,
      quantity NUMERIC NOT NULL DEFAULT 0,
      unit_value NUMERIC,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_stock_item_location_index
    ON #{p}phoenix_kit_warehouse_stock (item_uuid, location_uuid)
    """)

    # The composite index above only serves item_uuid-leading lookups; "what is
    # stored at this location" needs location_uuid on its own.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_stock_location_uuid_index
    ON #{p}phoenix_kit_warehouse_stock (location_uuid)
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'phoenix_kit_warehouse_stock_quantity_non_negative'
        AND conrelid = '#{p}phoenix_kit_warehouse_stock'::regclass
      ) THEN
        ALTER TABLE #{p}phoenix_kit_warehouse_stock
        ADD CONSTRAINT phoenix_kit_warehouse_stock_quantity_non_negative
        CHECK (quantity >= 0);
      END IF;
    END $$;
    """)

    # 2. Inventory documents (stocktakes) — standalone, no source_refs.
    execute(
      "CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_inventory_documents_number_seq"
    )

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_inventory_documents (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_inventory_documents_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      track_value BOOLEAN NOT NULL DEFAULT false,
      location_uuid UUID NOT NULL,
      storage_folder_uuid UUID,
      note TEXT,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      posted_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_number_index
    ON #{p}phoenix_kit_warehouse_inventory_documents (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_status_index
    ON #{p}phoenix_kit_warehouse_inventory_documents (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_inserted_at_index
    ON #{p}phoenix_kit_warehouse_inventory_documents (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_deleted_at_index
    ON #{p}phoenix_kit_warehouse_inventory_documents (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_inventory_documents_location_uuid_index
    ON #{p}phoenix_kit_warehouse_inventory_documents (location_uuid)
    """)

    # 3. Internal orders — no sub_order_uuid column; source_refs carries it.
    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_internal_orders_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_internal_orders (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_internal_orders_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      location_uuid UUID NOT NULL,
      note TEXT,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      posted_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_number_index
    ON #{p}phoenix_kit_warehouse_internal_orders (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_status_index
    ON #{p}phoenix_kit_warehouse_internal_orders (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_inserted_at_index
    ON #{p}phoenix_kit_warehouse_internal_orders (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_deleted_at_index
    ON #{p}phoenix_kit_warehouse_internal_orders (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_location_uuid_index
    ON #{p}phoenix_kit_warehouse_internal_orders (location_uuid)
    """)

    # Replaces the index the dropped sub_order_uuid FK used to provide: without
    # it, "which orders reference this source?" is a sequential scan.
    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_internal_orders_source_refs_index
    ON #{p}phoenix_kit_warehouse_internal_orders USING GIN (source_refs)
    """)

    create_supplier_orders(p)
    create_goods_receipts(p)
    create_goods_issues(p)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '140'")
  end

  @doc """
  Drops all six warehouse tables and their sequences, in FK-safe order
  (dependents before the tables they reference). Destroys any data written
  to them — safe only because, per this plan, nothing writes to them yet.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_goods_issues")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_goods_issues_number_seq")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_goods_receipts")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_goods_receipts_number_seq")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_supplier_orders")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_supplier_orders_number_seq")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_internal_orders")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_internal_orders_number_seq")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_inventory_documents")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_inventory_documents_number_seq")

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_stock")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '139'")
  end

  defp create_supplier_orders(p) do
    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_supplier_orders_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_supplier_orders (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_supplier_orders_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      supplier_uuid UUID,
      internal_order_uuid UUID REFERENCES #{p}phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL,
      location_uuid UUID NOT NULL,
      note TEXT,
      storage_folder_uuid UUID,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      posted_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_number_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_status_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_inserted_at_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_deleted_at_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_location_uuid_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_supplier_uuid_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (supplier_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_internal_order_uuid_index
    ON #{p}phoenix_kit_warehouse_supplier_orders (internal_order_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_supplier_orders_source_refs_index
    ON #{p}phoenix_kit_warehouse_supplier_orders USING GIN (source_refs)
    """)
  end

  defp create_goods_receipts(p) do
    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_goods_receipts_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_goods_receipts (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_goods_receipts_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      supplier_order_uuid UUID REFERENCES #{p}phoenix_kit_warehouse_supplier_orders(uuid) ON DELETE SET NULL,
      supplier_uuid UUID,
      location_uuid UUID NOT NULL,
      note TEXT,
      storage_folder_uuid UUID,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      posted_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_number_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_status_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_inserted_at_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_deleted_at_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_location_uuid_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_supplier_order_uuid_index
    ON #{p}phoenix_kit_warehouse_goods_receipts (supplier_order_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_receipts_source_refs_index
    ON #{p}phoenix_kit_warehouse_goods_receipts USING GIN (source_refs)
    """)
  end

  defp create_goods_issues(p) do
    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_goods_issues_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_goods_issues (
      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_goods_issues_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      internal_order_uuid UUID REFERENCES #{p}phoenix_kit_warehouse_internal_orders(uuid) ON DELETE SET NULL,
      location_uuid UUID NOT NULL,
      note TEXT,
      storage_folder_uuid UUID,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      posted_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_number_index
    ON #{p}phoenix_kit_warehouse_goods_issues (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_status_index
    ON #{p}phoenix_kit_warehouse_goods_issues (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_inserted_at_index
    ON #{p}phoenix_kit_warehouse_goods_issues (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_deleted_at_index
    ON #{p}phoenix_kit_warehouse_goods_issues (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_location_uuid_index
    ON #{p}phoenix_kit_warehouse_goods_issues (location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_internal_order_uuid_index
    ON #{p}phoenix_kit_warehouse_goods_issues (internal_order_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_goods_issues_source_refs_index
    ON #{p}phoenix_kit_warehouse_goods_issues USING GIN (source_refs)
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
