defmodule PhoenixKit.Migrations.Postgres.V143 do
  @moduledoc """
  V143: Manufacturing/Warehouse module tables consolidation.

  Consolidates tables previously created by `phoenix_kit_manufacturing`'s
  and `phoenix_kit_warehouse`'s own `migration_module/0` into core's
  migration chain — see PR body for the manual-migration note on non-empty
  legacy directory tables.

  Five objects, each idempotent (safe to re-run):

    * `phoenix_kit_machines` — machine reference-book records. V1 identity
      columns (`name`, `code`, `manufacturer`, `serial_number`,
      `description`, `location_note`, `status`, `data`, `metadata`) plus
      the V2 passport/soft-location columns (`model`, `manufacture_year`,
      `commissioned_on`, `warranty_until`, `to_last_on`,
      `to_interval_days`, `to_next_on`, `notes`, `location_uuid`,
      `space_uuid`), in their final (module V5-equivalent) shape.
    * `phoenix_kit_machine_type_assignments` — machine<->machine_type join.
      `machine_uuid` is a real FK to `phoenix_kit_machines`; `machine_type_uuid`
      is a soft reference to `phoenix_kit_entity_data.uuid` (no FK) — machine
      types now live in `phoenix_kit_entities`, a separate package this
      migration doesn't own. On a host upgrading from the published
      `phoenix_kit_manufacturing` 0.2.0 (module V1), this table already
      exists with a *live* FK on `machine_type_uuid` (pointing at the
      `phoenix_kit_machine_types` directory table below) — `CREATE TABLE IF
      NOT EXISTS` is a no-op there, so the FK is dropped by a separate,
      unconditional step.
    * `phoenix_kit_machine_operations` — machine<->operation join, same
      soft-reference shape on `operation_uuid`. Never published with a live
      FK on any known external host (0.2.0 predates this table entirely),
      but the drop is attempted unconditionally anyway, for symmetry with
      `machine_type_uuid` above.
    * `phoenix_kit_warehouse_transfers` (+ its `number` sequence) and
      `phoenix_kit_warehouse_min_stock` — fresh-install-only DDL. The
      published `phoenix_kit_warehouse` 0.1.0 shipped no migrations at all
      (no `phoenix_kit_warehouse_transfers`/`min_stock` on any external
      host), so there is no upgrade path to account for here, unlike the
      manufacturing tables above.

  `phoenix_kit_machine_types`, `phoenix_kit_operations`, and
  `phoenix_kit_defect_reasons` — the pre-V5 manufacturing directory tables —
  are **not** re-created by this migration; they are not one of the five
  objects it owns. If a host still has one of them (realistic only on an
  external `phoenix_kit_manufacturing` 0.2.0 install — our own dev database
  has never had them, since the module's local migration already carried it
  to V5), `up/1` drops it when empty and leaves it in place (with a
  `RAISE NOTICE`) when it still holds rows, so real directory data is never
  silently destroyed. See the core PR body for the manual data-migration
  note on such hosts.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    create_machines(p)
    create_machine_type_assignments(p, prefix)
    create_machine_operations(p, prefix)

    # FK drops above are unconditional and must run before these
    # conditional legacy-table drops: a non-empty `phoenix_kit_machine_types`
    # left in place still has to lose its inbound FK from
    # `machine_type_assignments`, and `DROP TABLE ... CASCADE` below is a
    # resilience net for a partially-applied prior run, not the primary
    # mechanism for removing those FKs.
    maybe_drop_if_empty(p, prefix, "phoenix_kit_machine_types")
    maybe_drop_if_empty(p, prefix, "phoenix_kit_operations")
    maybe_drop_if_empty(p, prefix, "phoenix_kit_defect_reasons")

    create_warehouse_transfers(p)
    create_warehouse_min_stock(p)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '143'")
  end

  @doc """
  Drops the five objects `up/1` owns, in FK-safe order (dependents before
  the tables they reference), and restores the version marker to `142`.

  **Upgrade-host caveat**: on a host that started from the published
  `phoenix_kit_manufacturing` 0.2.0 (module V1), `phoenix_kit_machine_type_assignments`
  pre-dates V143 — it was created by that module's own `migration_module/0`,
  not by this migration. `down/1` cannot tell the two provenances apart, so
  it drops that table unconditionally, which is a stricter rollback than
  "undo only what V143 did" on such a host. Does **not** touch
  `phoenix_kit_machine_types`, `phoenix_kit_operations`, or
  `phoenix_kit_defect_reasons` — those are never owned by V143 (see
  moduledoc), so rolling back leaves them exactly as `up/1` found them,
  dropped-if-they-were-empty or still in place otherwise.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_operations")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_type_assignments")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machines")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_min_stock")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_warehouse_transfers")
    execute("DROP SEQUENCE IF EXISTS #{p}phoenix_kit_warehouse_transfers_number_seq")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '142'")
  end

  # ── phoenix_kit_machines: V1 identity + V2 passport/soft-location ──

  defp create_machines(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machines (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      code VARCHAR(100),
      manufacturer VARCHAR(255),
      serial_number VARCHAR(255),
      description TEXT,
      location_note VARCHAR(500),
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      data JSONB NOT NULL DEFAULT '{}',
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machines_status
    ON #{p}phoenix_kit_machines (status)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS model VARCHAR(255)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS manufacture_year INTEGER
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS commissioned_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS warranty_until DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_last_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_interval_days INTEGER
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_next_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS notes TEXT
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS location_uuid UUID
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS space_uuid UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machines_location
    ON #{p}phoenix_kit_machines (location_uuid)
    """)
  end

  # ── phoenix_kit_machine_type_assignments: machine<->machine_type join ──
  # machine_type_uuid is a soft reference (no FK) — see moduledoc.

  defp create_machine_type_assignments(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_type_assignments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      machine_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_machines (uuid) ON DELETE CASCADE,
      machine_type_uuid UUID NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_type_assignments_unique
    ON #{p}phoenix_kit_machine_type_assignments (machine_uuid, machine_type_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machine_type_assignments_type
    ON #{p}phoenix_kit_machine_type_assignments (machine_type_uuid)
    """)

    drop_fk_constraint(p, prefix, "phoenix_kit_machine_type_assignments", "machine_type_uuid")
  end

  # ── phoenix_kit_machine_operations: machine<->operation join ──
  # operation_uuid is a soft reference (no FK) — see moduledoc.

  defp create_machine_operations(p, prefix) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_operations (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      machine_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_machines (uuid) ON DELETE CASCADE,
      operation_uuid UUID NOT NULL,
      time_norm_seconds INTEGER,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_operations_unique
    ON #{p}phoenix_kit_machine_operations (machine_uuid, operation_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machine_operations_operation
    ON #{p}phoenix_kit_machine_operations (operation_uuid)
    """)

    drop_fk_constraint(p, prefix, "phoenix_kit_machine_operations", "operation_uuid")
  end

  # ── legacy directory tables: conditional drop, never (re-)created ──
  #
  # Drops `table` only when it exists and is empty; a non-empty table is
  # left in place with a RAISE NOTICE, since destroying real directory data
  # without a chance to migrate it first is not acceptable. Plain PL/pgSQL
  # can't run DDL directly, hence the dynamic EXECUTE. CASCADE on the DROP
  # is a resilience net for a partially-applied prior run (e.g. a PgBouncer
  # mid-batch drop that skipped one of the `drop_fk_constraint` calls
  # above) — normally there is nothing left to cascade into, since those
  # calls already run unconditionally before this.
  defp maybe_drop_if_empty(p, prefix, table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = '#{prefix}' AND table_name = '#{table}'
      ) THEN
        IF (SELECT COUNT(*) FROM #{p}#{table}) = 0 THEN
          EXECUTE 'DROP TABLE #{p}#{table} CASCADE';
        ELSE
          RAISE NOTICE '#{table} is non-empty — left in place, see PR body for manual migration';
        END IF;
      END IF;
    END $$;
    """)
  end

  # ── phoenix_kit_warehouse_transfers + phoenix_kit_warehouse_min_stock ──
  # Fresh-install-only DDL — see moduledoc.

  defp create_warehouse_transfers(p) do
    execute("CREATE SEQUENCE IF NOT EXISTS #{p}phoenix_kit_warehouse_transfers_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_transfers (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{p}phoenix_kit_warehouse_transfers_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      source_location_uuid UUID,
      destination_location_uuid UUID,
      note TEXT,
      storage_folder_uuid UUID,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
      shipped_at TIMESTAMPTZ,
      received_at TIMESTAMPTZ,
      cancelled_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_number_index
    ON #{p}phoenix_kit_warehouse_transfers (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_status_index
    ON #{p}phoenix_kit_warehouse_transfers (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_inserted_at_index
    ON #{p}phoenix_kit_warehouse_transfers (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_deleted_at_index
    ON #{p}phoenix_kit_warehouse_transfers (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_source_location_uuid_index
    ON #{p}phoenix_kit_warehouse_transfers (source_location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_destination_location_uuid_index
    ON #{p}phoenix_kit_warehouse_transfers (destination_location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_shipped_at_index
    ON #{p}phoenix_kit_warehouse_transfers (shipped_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_received_at_index
    ON #{p}phoenix_kit_warehouse_transfers (received_at)
    """)
  end

  defp create_warehouse_min_stock(p) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_warehouse_min_stock (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      item_uuid UUID NOT NULL,
      min_quantity NUMERIC NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_min_stock_item_uuid_index
    ON #{p}phoenix_kit_warehouse_min_stock (item_uuid)
    """)
  end

  # ── FK-drop helpers, ported from PhoenixKitManufacturing.Migrations.Machines ──

  # Discovers the live FK constraint name for `table.column` via the
  # catalog rather than assuming a `..._fkey` naming convention. Returns
  # `nil` when no such constraint exists (fresh install, or already dropped
  # on a retry).
  @spec fk_constraint_name(String.t(), String.t(), String.t()) :: String.t() | nil
  defp fk_constraint_name(prefix, table, column) do
    query = """
    SELECT tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_schema = kcu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = $1
      AND tc.table_name = $2
      AND kcu.column_name = $3
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix || "public", table, column]) do
      {:ok, %{rows: [[name] | _]}} -> name
      _ -> nil
    end
  end

  defp drop_fk_constraint(p, prefix, table, column) do
    case fk_constraint_name(prefix, table, column) do
      nil -> :ok
      name -> execute("ALTER TABLE #{p}#{table} DROP CONSTRAINT IF EXISTS #{name}")
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
