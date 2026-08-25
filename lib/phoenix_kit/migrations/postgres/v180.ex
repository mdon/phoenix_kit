defmodule PhoenixKit.Migrations.Postgres.V180 do
  @moduledoc """
  V180: the manufacturer↔supplier graph becomes federated, and an item can no
  longer list the same supplier twice.

  ## Block 1 — `phoenix_kit_cat_manufacturer_suppliers` federates

  V179 did this for an item's manufacturer; the M:N graph was the last place
  still forced to point at the catalogue's own directory. It carried hard
  foreign keys onto **both** `phoenix_kit_cat_manufacturers` and
  `phoenix_kit_cat_suppliers`, so a CRM party's uuid physically could not be
  stored — which meant that with suppliers and manufacturers living in CRM the
  graph simply stopped being built, and warehouse's manufacturer-based supplier
  resolution (`supplier_orders.ex`) had nothing to read.

  Same shape as V179 and V149 before it: a uuid plus a `*_source`
  discriminator. The accepted values match
  `phoenix_kit_cat_item_supplier_info.supplier_source` — `'local'`,
  `'crm_company'`, `'crm_contact'` — because a supplier CAN be a contact there
  and a narrower CHECK here would make such a supplier unlinkable. Existing
  rows are all `'local'`, which is what the default backfills.

  ## What replaces the two FKs

  Application-level cleanup, deliberately. The dropped constraints carried
  `ON DELETE CASCADE`, so deleting a local supplier or manufacturer used to
  clear its links for free; `Catalogue.delete_supplier/2` and
  `delete_manufacturer/2` now delete them explicitly. A cascade cannot span an
  optional-module boundary — the CRM tables need not exist — so this is the
  same trade V179 made, and the same one `item_supplier_info.supplier_uuid` has
  lived with since V149.

  ## Block 2 — one CURRENT supplier row per item/supplier pair

  Riding along rather than spending a version number of its own (workspace
  `AGENTS.md`). Nothing stopped two OPEN rows for the same pair, i.e. one item
  listing the same supplier twice with two live prices and no rule about which
  one warehouse should believe.

  The index is **partial on `valid_to IS NULL`**, never the bare pair: several
  rows per pair are legitimate and expected, because that is exactly what a
  price revision produces — the old row is closed and a successor appended.
  Only one may be open.

  Existing duplicates are **closed, not deleted** — they are real price records
  — keeping the primary row, or the oldest when neither is primary, and
  clearing `is_primary` on the ones being closed so the V151
  `..._primary_uniq` index still holds. A loser is closed at
  `GREATEST(valid_from, CURRENT_DATE)` so a future-dated row cannot end before
  it begins, which would leave it failing its own changeset validation
  forever. Without this the `CREATE UNIQUE INDEX`
  would fail outright on any install carrying a duplicate.

  The lock, the dedupe UPDATE, and the index build all live inside one
  `DO $$` block (fixed post-publish, same shape as V170's
  `phoenix_kit_notifications_dedupe_unseen_idx`). A bare top-level
  `LOCK TABLE`, as this originally shipped, gets `25P01
  no_active_sql_transaction` — wrappers carry `@disable_ddl_transaction
  true`, so every top-level `execute/1` auto-commits on its own and `LOCK
  TABLE` has nothing to hold — and even accepted, the lock would release at
  its own commit before the statements it exists to protect. Recovery for an
  install that hit the crash: block 1 already committed and the version
  comment still reads `'179'`, so a plain re-run of `up/1` (or `mix
  ecto.migrate`) completes it — every block-1 statement is
  `IF NOT EXISTS`-guarded.

  ## Rollback

  `down/1` restores both foreign keys and will FAIL if any link references a
  CRM party by then — that uuid has no matching local row, which is the whole
  point of the columns. Repoint or delete those links first. The dedupe is not
  reversed: which rows were closed by this migration is not recorded, and
  re-opening them would recreate the ambiguity on purpose.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = schema_name(prefix)

    federate_manufacturer_supplier_links(prefix, p)
    enforce_one_current_supplier_per_pair(p, schema)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '180'")
  end

  defp federate_manufacturer_supplier_links(prefix, p) do
    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    ADD COLUMN IF NOT EXISTS manufacturer_source VARCHAR(20) NOT NULL DEFAULT 'local'
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    ADD COLUMN IF NOT EXISTS supplier_source VARCHAR(20) NOT NULL DEFAULT 'local'
    """)

    # Explicit SHORT names. Postgres truncates identifiers at 63 bytes, and
    # the conventional `<table>_<column>_check` for manufacturer_source is 64
    # — Postgres would silently truncate it, so the
    # IF NOT EXISTS guard below (and the DROP in down/1) would never match
    # their own constraint and the migration would stop being idempotent.
    add_source_check(prefix, p, "manufacturer_source", "mfr_source_check")
    add_source_check(prefix, p, "supplier_source", "sup_source_check")

    # These are what forced both sides of the graph to be local rows.
    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_fkey
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_manufacturer_suppliers_supplier_uuid_fkey
    """)
  end

  defp add_source_check(prefix, p, column, suffix) do
    constraint = "phoenix_kit_cat_manufacturer_suppliers_#{suffix}"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint}'
          AND t.relname = 'phoenix_kit_cat_manufacturer_suppliers'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
          ADD CONSTRAINT #{constraint}
          CHECK (#{column} IN ('local', 'crm_company', 'crm_contact'));
      END IF;
    END $$;
    """)
  end

  defp enforce_one_current_supplier_per_pair(p, schema) do
    # LOCK TABLE has no IF NOT EXISTS / IF EXISTS form and, unlike every other
    # statement here, cannot be wrapped for idempotency on its own — it must
    # be inside a transaction to mean anything at all. Wrappers carry
    # `@disable_ddl_transaction true` (core convention — see the moduledoc
    # note in v168.ex/v161.ex/v154.ex), so each top-level execute/1 auto-commits
    # on its own; a bare `LOCK TABLE` gets 25P01
    # (`no_active_sql_transaction`) and a bare lock followed by separate
    # statements would release it at its own commit anyway, before the
    # UPDATE and CREATE UNIQUE INDEX it exists to protect. A single DO $$
    # block opens its own implicit transaction, so the lock, the dedupe, and
    # the index build all happen atomically — same fix as V170's
    # `phoenix_kit_notifications_dedupe_unseen_idx`. The table guard exists
    # for the same reason V170's does: skip, don't abort, if it's somehow
    # absent.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_class t
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE t.relname = 'phoenix_kit_cat_item_supplier_info' AND n.nspname = '#{schema}'
      ) THEN
        -- Hold the table for the dedupe AND the index build. The UPDATE
        -- alone takes only row locks, so a concurrent writer could open a
        -- fresh duplicate in the gap before CREATE UNIQUE INDEX acquires its
        -- own lock — the build would then fail and roll back the whole
        -- migration. SHARE ROW EXCLUSIVE blocks writers while still allowing
        -- reads.
        LOCK TABLE #{p}phoenix_kit_cat_item_supplier_info IN SHARE ROW EXCLUSIVE MODE;

        -- Close the losers first, or CREATE UNIQUE INDEX fails on any
        -- install that already carries a duplicate. Primary wins; failing
        -- that the oldest, with uuid as the final tiebreak so the choice is
        -- TOTAL and two runs cannot disagree.
        WITH ranked AS (
          SELECT uuid,
                 row_number() OVER (
                   PARTITION BY item_uuid, supplier_uuid
                   ORDER BY is_primary DESC, inserted_at ASC, uuid ASC
                 ) AS rn
          FROM #{p}phoenix_kit_cat_item_supplier_info
          WHERE valid_to IS NULL
        )
        UPDATE #{p}phoenix_kit_cat_item_supplier_info AS i
        -- GREATEST, not a bare CURRENT_DATE: a future-dated row would
        -- otherwise close BEFORE it opens, and `validate_date_range/1` then
        -- refuses every later edit of a row the user cannot repair. GREATEST
        -- ignores a NULL valid_from, which is the common case.
        --
        -- Bare now(), NOT `now() AT TIME ZONE 'utc'`: this column is
        -- TIMESTAMPTZ (V149), so the core convention for the `timestamp
        -- without time zone` columns is wrong here — it yields a UTC wall
        -- clock that the assignment re-reads in the SESSION time zone,
        -- writing a value off by that offset (verified: +4h under
        -- America/New_York). V170's dedupe uses bare now() for the same
        -- reason.
        SET valid_to = GREATEST(valid_from, CURRENT_DATE),
            is_primary = FALSE,
            updated_at = now()
        FROM ranked AS r
        WHERE i.uuid = r.uuid AND r.rn > 1;

        -- Bare on CREATE — only DROP INDEX takes the schema qualifier.
        CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_current_pair_uniq
        ON #{p}phoenix_kit_cat_item_supplier_info (item_uuid, supplier_uuid)
        WHERE valid_to IS NULL;
      END IF;
    END
    $$
    """)
  end

  @doc """
  Rolls V180 back: drops the pair index, restores both foreign keys and drops
  the two source columns.

  Raises if any link references a CRM party — see the moduledoc. The dedupe is
  not reversed.
  """
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    DROP INDEX IF EXISTS #{p}phoenix_kit_cat_item_supplier_info_current_pair_uniq
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_cat_manufacturer_suppliers
        WHERE manufacturer_source <> 'local' OR supplier_source <> 'local'
      ) THEN
        RAISE EXCEPTION 'V180 down: manufacturer/supplier links reference a CRM party; remove them before rolling back';
      END IF;
    END $$;
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_manufacturer_suppliers_mfr_source_check
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_manufacturer_suppliers_sup_source_check
    """)

    restore_fk(prefix, p, "manufacturer", "phoenix_kit_cat_manufacturers")
    restore_fk(prefix, p, "supplier", "phoenix_kit_cat_suppliers")

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP COLUMN IF EXISTS supplier_source
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
    DROP COLUMN IF EXISTS manufacturer_source
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '179'")
  end

  defp restore_fk(prefix, p, side, foreign_table) do
    constraint = "phoenix_kit_cat_manufacturer_suppliers_#{side}_uuid_fkey"

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint}'
          AND t.relname = 'phoenix_kit_cat_manufacturer_suppliers'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers
          ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{side}_uuid)
          REFERENCES #{p}#{foreign_table}(uuid) ON DELETE CASCADE;
      END IF;
    END $$;
    """)
  end

  defp schema_name("public"), do: "public"
  defp schema_name(prefix), do: prefix

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
