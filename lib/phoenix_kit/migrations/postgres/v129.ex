defmodule PhoenixKit.Migrations.Postgres.V129 do
  @moduledoc """
  V129: Add the missing `subscription_type_uuid` column to subscriptions.

  `phoenix_kit_subscriptions` was created in V33 with an integer `plan_id`
  (renamed to `subscription_type_id` in V65). The UUID foreign key the
  `PhoenixKitBilling.Schemas.Subscription` schema actually uses —
  `subscription_type_uuid` — was only ever *renamed* (V65:
  `plan_uuid` → `subscription_type_uuid`), never **added**, and `plan_uuid`
  never existed. So on a fresh `ensure_current/2` build the column is absent
  and every subscription insert / Subscriptions LiveView query raises
  `undefined_column`.

  This migration adds it idempotently:

    * `subscription_type_uuid` UUID → FK
      `phoenix_kit_subscription_types(uuid) ON DELETE SET NULL`
    * a partial index for "subscriptions of type X" lookups.

  Nullable + `ON DELETE SET NULL` so deleting a subscription type un-links
  its subscriptions rather than cascading. Databases that already acquired
  the column (via a historic `plan_uuid` rename) are untouched — every step
  is guarded.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = schema_for(prefix)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_subscriptions'
          AND column_name = 'subscription_type_uuid'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_subscriptions ADD COLUMN subscription_type_uuid UUID;
      END IF;

      IF NOT EXISTS (
        SELECT FROM information_schema.table_constraints
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_subscriptions'
          AND constraint_name = 'phoenix_kit_subscriptions_subscription_type_uuid_fkey'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_subscriptions
          ADD CONSTRAINT phoenix_kit_subscriptions_subscription_type_uuid_fkey
          FOREIGN KEY (subscription_type_uuid)
          REFERENCES #{p}phoenix_kit_subscription_types(uuid)
          ON DELETE SET NULL;
      END IF;
    END $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM pg_indexes
        WHERE schemaname = '#{schema}'
          AND tablename = 'phoenix_kit_subscriptions'
          AND indexname = 'phoenix_kit_subscriptions_subscription_type_uuid_idx'
      ) THEN
        CREATE INDEX phoenix_kit_subscriptions_subscription_type_uuid_idx
          ON #{p}phoenix_kit_subscriptions (subscription_type_uuid)
          WHERE subscription_type_uuid IS NOT NULL;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '129'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("DROP INDEX IF EXISTS #{p}phoenix_kit_subscriptions_subscription_type_uuid_idx")

    execute("""
    ALTER TABLE #{p}phoenix_kit_subscriptions
      DROP CONSTRAINT IF EXISTS phoenix_kit_subscriptions_subscription_type_uuid_fkey
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_subscriptions DROP COLUMN IF EXISTS subscription_type_uuid"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '128'")
  end

  defp schema_for("public"), do: "public"
  defp schema_for(prefix), do: prefix

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
