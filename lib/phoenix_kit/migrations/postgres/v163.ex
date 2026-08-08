defmodule PhoenixKit.Migrations.Postgres.V163 do
  @moduledoc """
  V163: UUID primary-key integrity.

  Repairs any `phoenix_kit_*` table whose `uuid` column is the wrong type,
  nullable, or not the primary key — the state V40/V56/V74 are each supposed to
  make impossible, and which a production install reached anyway.

  ## The reported state

  On a database upgraded through the whole chain since V01,
  `phoenix_kit_email_events` had `uuid` as `character varying(255)`, nullable,
  no default, and the table had **no primary key at all**. 149 other tables were
  correct, so this was one table falling out of the conversion rather than a
  broken upgrade.

  ## Why the chain missed it, twice

  1. **V40's guard tests EXISTENCE, not TYPE.** An older release created that
     column as Ecto `:string`, so `unless column_exists?(table, :uuid, …)` was
     already true and V40 skipped the table wholesale — not just the `ADD
     COLUMN`, but the backfill, the `SET NOT NULL` and the unique index with it.
     The table *is* in V40's `@tables_to_migrate`; being listed did not help.

  2. **V56's type conversion shipped after some hosts had already passed V56.**
     `ensure_all_uuid_columns_native_type/2` — which converts exactly this
     varchar column — was added to V56 on 2026-03-02, seventeen days after V56
     itself (2026-02-13). A recorded version never re-runs, so every host that
     crossed V56 in that window kept the broken column permanently. V56's
     `NOT NULL` and index repairs also run off hardcoded table lists that
     `phoenix_kit_email_events` appears in none of.

  V74 then dropped the legacy bigint `id` but could not promote `uuid` to
  primary key — wrong type, nullable — and did not verify its own documented
  post-condition ("after V74, every PhoenixKit table has uuid as its PK").
  Nothing raised.

  ## Why this migration is catalog-driven

  Every previous attempt enumerated tables by hand, and this table was missing
  from every list. This one asks the catalog which tables are actually broken,
  so a table nobody remembered to list is repaired anyway — and so a table that
  is already correct is skipped without needing to be named.

  ## Large tables are deferred, not silently rewritten

  `ALTER COLUMN … TYPE uuid` rewrites the table under an `ACCESS EXCLUSIVE`
  lock, and `ADD PRIMARY KEY` builds a unique index under the same lock. Both
  are O(rows). On a big events table behind PgBouncer that is connection-pool
  exhaustion during `mix ecto.migrate`, not a pause — so above two million rows
  the rewrite is skipped and logged with the exact command to run in a
  maintenance window. Setting the default and backfilling
  are catalog-cheap or index-free and always run.

  This migration never raises on the happy path. A library does not own its
  hosts' deploy runbooks, and turning a latent problem (one audit table without
  a PK, on a version where no schema maps to it) into a failed deploy across a
  fleet is a worse outcome than the problem. `mix phoenix_kit.doctor` is the
  loud channel and reports precisely what was deferred.
  """

  use Ecto.Migration

  require Logger

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.UUIDIntegrity

  # Above this, the rewrite is deferred to a maintenance window. ~2M rows is a
  # few seconds of exclusive lock on ordinary hardware; an order of magnitude
  # more is not. Override with `up(%{uuid_rewrite_row_limit: n})`.
  @rewrite_row_limit 2_000_000

  # A repair that cannot get its lock quickly is deferred, not waited on.
  @lock_timeout_ms 5_000

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    limit = Map.get(opts, :uuid_rewrite_row_limit, @rewrite_row_limit)

    # Repaired tables need the generator to exist even if V40 never reached them.
    Helpers.ensure_uuid_v7_function(prefix)

    # Fail fast rather than queue behind a long-running reader. The generated
    # upgrade migration carries @disable_ddl_transaction, so this is autocommit:
    # without a timeout an ALTER blocked by an open transaction waits forever and
    # the deploy hangs rather than erroring.
    execute("SET lock_timeout = '#{@lock_timeout_ms}ms'")

    repo()
    |> UUIDIntegrity.broken_tables(prefix)
    |> Enum.each(&repair(&1, prefix, limit))

    execute("RESET lock_timeout")

    # ALWAYS recorded, even if a table above was skipped. The marker is the only
    # thing the chain consults, so failing to write it would make V163 re-run
    # forever — and, worse, a stale marker is how this codebase has previously
    # had migrations skipped permanently. Tables that did not get repaired are
    # logged and still reported by `mix phoenix_kit.doctor`; they are not lost.
    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '163'")
  end

  # Irreversible by design. Rolling back would mean re-breaking a primary key —
  # recreating the reported defect on a healthy table — and the prior state is
  # not recoverable anyway: which rows held NULL uuids before the backfill is
  # not recorded. Only the version marker moves.
  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '162'")
  end

  defp repair(%{name: name} = table, prefix, limit) do
    qualified = UUIDIntegrity.qualify(prefix, name)

    cond do
      not UUIDIntegrity.castable?(repo(), qualified, table) ->
        # Aborting the migration over one table's bad data would strand every
        # other repair in this run, so this table is skipped and named.
        Logger.error("""
        [PhoenixKit V163] #{name}: the uuid column holds values that are not \
        valid UUIDs, so it cannot be converted. Left unchanged. Inspect with:
          SELECT uuid FROM #{qualified} WHERE uuid IS NOT NULL
           AND uuid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' LIMIT 20;
        """)

      UUIDIntegrity.rewrite_needed?(table) and
          UUIDIntegrity.estimated_rows(repo(), prefix, name) > limit ->
        Logger.warning("""
        [PhoenixKit V163] #{name}: needs a uuid column rewrite but holds more \
        than #{limit} rows. Skipped, because ALTER COLUMN TYPE takes an ACCESS \
        EXCLUSIVE lock for the length of a full table rewrite. Run this in a \
        maintenance window:
          mix phoenix_kit.repair_uuid #{name}
        `mix phoenix_kit.doctor` will keep reporting it until you do.
        """)

      true ->
        run_isolated(qualified, prefix, table)
    end
  end

  # One table's failure must not take the rest of the run with it. Autocommit
  # means the statements already applied stay applied, and every prefix of the
  # sequence leaves the table further along than it started rather than
  # corrupted — so continuing is strictly better than aborting. The most likely
  # failure by far is `lock_not_available` from the timeout above, which means
  # "busy right now", not "broken".
  defp run_isolated(qualified, prefix, table) do
    qualified
    |> UUIDIntegrity.repair_statements(prefix, table)
    |> Enum.each(&execute/1)

    # `execute/1` only QUEUES a command; without this the statements are flushed
    # after `up/1` returns — outside the rescue below — and the isolation this
    # function exists for would silently never fire. `flush/0` runs everything
    # pending here, in scope, so a failure is caught and the next table proceeds.
    flush()
  rescue
    error ->
      Logger.error("""
      [PhoenixKit V163] #{table.name}: repair failed and was skipped — \
      #{Exception.message(error)}
      Other tables were not affected. Re-run with:
        mix phoenix_kit.repair_uuid #{table.name}
      """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
