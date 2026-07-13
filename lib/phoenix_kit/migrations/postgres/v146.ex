defmodule PhoenixKit.Migrations.Postgres.V146 do
  @moduledoc """
  V146: `primary_supplier_uuid` on catalogue items.

  Backs `phoenix_kit_catalogue`'s per-item default supplier (upstream
  catalogue commit 2e47cdf): lets an item specify a supplier directly,
  independent of manufacturer — needed for generic/unbranded materials
  that have no brand to resolve a supplier through, and to break ties
  when a manufacturer has more than one linked supplier.

  - Nullable `primary_supplier_uuid` FK → `phoenix_kit_cat_suppliers(uuid)`
    with `ON DELETE SET NULL` — the pointer is an optional default; the
    item must survive its supplier (mirrors `category_uuid`'s nilify
    semantics, deliberately NOT `manufacturer_uuid`'s delete_all).
  - Partial index on `(primary_supplier_uuid) WHERE NOT NULL` for the
    "items defaulting to this supplier" reverse lookup.

  Idempotent + prefix-safe: bare index name on CREATE, all existence
  checks schema-anchored, FK constraint checked via `pg_constraint`
  anchored to the prefixed table (the V51 idiom).
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)
    p = prefix_str(prefix)

    # Flush queued commands so the immediate pg_constraint check below sees
    # phoenix_kit_cat_items — on a fresh chain V87's CREATE TABLE is still
    # queued at this point, and an immediate query touching a missing
    # relation would abort the whole migration transaction.
    flush()

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    ADD COLUMN IF NOT EXISTS primary_supplier_uuid UUID
    """)

    unless constraint_exists?(escaped_prefix, p) do
      execute("""
      ALTER TABLE #{p}phoenix_kit_cat_items
      ADD CONSTRAINT phoenix_kit_cat_items_primary_supplier_uuid_fkey
      FOREIGN KEY (primary_supplier_uuid)
      REFERENCES #{p}phoenix_kit_cat_suppliers(uuid)
      ON DELETE SET NULL
      """)
    end

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_primary_supplier_uuid_index
    ON #{p}phoenix_kit_cat_items (primary_supplier_uuid)
    WHERE primary_supplier_uuid IS NOT NULL
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '146'")
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_cat_items_primary_supplier_uuid_index")

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP CONSTRAINT IF EXISTS phoenix_kit_cat_items_primary_supplier_uuid_fkey
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_cat_items
    DROP COLUMN IF EXISTS primary_supplier_uuid
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '145'")
  end

  # Immediate check; anchored to the prefixed table so a public install's
  # constraint can't satisfy the check for a prefixed one. Deliberately a
  # name-based JOIN rather than the `'table'::regclass` idiom: a regclass
  # cast RAISES when the relation doesn't exist yet, which aborts the whole
  # migration transaction (and a rescue can't unpoison it).
  defp constraint_exists?(escaped_prefix, _p) do
    query = """
    SELECT EXISTS (
      SELECT FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE c.conname = 'phoenix_kit_cat_items_primary_supplier_uuid_fkey'
      AND t.relname = 'phoenix_kit_cat_items'
      AND n.nspname = $1
    )
    """

    case repo().query(query, [escaped_prefix], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
