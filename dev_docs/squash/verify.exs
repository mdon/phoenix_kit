#!/usr/bin/env elixir
#
# verify.exs — Migration squash verification harness
#
# Run:
#   MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b
#   MIX_ENV=test mix run dev_docs/squash/verify.exs --mode a
#
# [DB] — requires a live Postgres connection via PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.
#
# See dev_docs/squash/README.md for full environment variable documentation.

# ---------------------------------------------------------------------------
# Bootstrap: load helpers from this directory
# ---------------------------------------------------------------------------

root = Path.expand(".", __DIR__)
Code.require_file("#{root}/repo_helper.ex")
Code.require_file("#{root}/dump_helper.ex")
Code.require_file("#{root}/migration_runner.ex")

alias PhoenixKit.Squash.RepoHelper
alias PhoenixKit.Squash.DumpHelper
alias PhoenixKit.Squash.MigrationRunner

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

{opts, _args, _invalid} =
  OptionParser.parse(System.argv(), strict: [mode: :string, scenario: :string, verbose: :boolean])

mode = Keyword.get(opts, :mode, "b")
scenario_filter = Keyword.get(opts, :scenario)
verbose = Keyword.get(opts, :verbose, false)

IO.puts("""
=======================================================
PhoenixKit Migration Squash — Verification Harness
Mode: #{String.upcase(mode)}
=======================================================
""")

unless mode in ["a", "b"] do
  IO.puts("ERROR: --mode must be 'a' or 'b'. See README.md.")
  System.halt(1)
end

# ---------------------------------------------------------------------------
# DB connection
# ---------------------------------------------------------------------------

IO.puts("Connecting to database...")
repo = RepoHelper.start!()
IO.puts("Connected.\n")

# ---------------------------------------------------------------------------
# Schema names for this run
# ---------------------------------------------------------------------------

# Mode A: migrations run into "public". Two schemas for side-by-side comparison
# are achieved by running sequentially (drop+recreate between runs) — the
# normaliser makes the schema name irrelevant for comparison.
#
# Mode B: throw-away non-public schema.

base_schema = System.get_env("PK_SQUASH_SCHEMA", "pk_squash_test")

schema_old = "#{base_schema}_old"
schema_new = "#{base_schema}_new"

# In Mode A: we use "public" (clean DB assumed); no schema creation/drop.
# In Mode B: we manage the schemas ourselves.

use_public = mode == "a"

# ---------------------------------------------------------------------------
# Schema lifecycle helpers
# ---------------------------------------------------------------------------

create_schema = fn name ->
  unless use_public do
    RepoHelper.query!(repo, "DROP SCHEMA IF EXISTS #{name} CASCADE")
    RepoHelper.query!(repo, "CREATE SCHEMA #{name}")
    IO.puts("  Created schema: #{name}")
  end
end

drop_schema = fn name ->
  unless use_public do
    RepoHelper.query!(repo, "DROP SCHEMA IF EXISTS #{name} CASCADE")
    IO.puts("  Dropped schema: #{name}")
  end
end

# In Mode A with public schema, we need to drop PK objects before re-running.
# We do this by running the OLD down() migration fully.
clean_public = fn ->
  if use_public do
    IO.puts("  Cleaning public schema via down() migration...")

    try do
      MigrationRunner.run_old_chain_down(repo, "public", to_version: 0)
    rescue
      e -> IO.puts("  WARN: down() raised during cleanup: #{inspect(e)}")
    end
  end
end

# ---------------------------------------------------------------------------
# Scenario runner
# ---------------------------------------------------------------------------

results = []

run_scenario = fn name, fun ->
  if scenario_filter == nil or scenario_filter == name do
    IO.puts("""
    -------------------------------------------------------
    Scenario: #{name}
    -------------------------------------------------------
    """)

    try do
      result = fun.()
      IO.puts("")
      result
    rescue
      e ->
        IO.puts("EXCEPTION in scenario #{name}:")
        IO.puts(Exception.format(:error, e, __STACKTRACE__))
        {:error, name, e}
    end
  else
    IO.puts("Skipping scenario #{name} (filter: #{scenario_filter})")
    :skipped
  end
end

# ---------------------------------------------------------------------------
# SCENARIO 1: Fresh equivalence
#
# OLD:  V01..V135 -> schema_old
# NEW:  V110 baseline + V111..V135 -> schema_new
# Assert: normalised dumps are byte-identical
# [DB]
# ---------------------------------------------------------------------------

result1 =
  run_scenario.("1_fresh_equivalence", fn ->
    # ---- OLD chain ----
    IO.puts("Running OLD chain V01..V135 into #{schema_old}...")
    create_schema.(schema_old)

    MigrationRunner.run_old_chain(repo, schema_old,
      to_version: 135,
      create_schema: !use_public
    )

    IO.puts("  OLD chain complete.")

    # ---- NEW chain ----
    IO.puts("Running NEW chain (V110 baseline + V111..V135) into #{schema_new}...")
    create_schema.(schema_new)

    MigrationRunner.run_new_chain_fresh(repo, schema_new, create_schema: !use_public)

    IO.puts("  NEW chain complete.")

    # ---- Dump and compare ----
    IO.puts("Dumping #{schema_old}...")
    dump_old = DumpHelper.dump!(schema_old)
    IO.puts("Dumping #{schema_new}...")
    dump_new = DumpHelper.dump!(schema_new)

    if verbose do
      File.write!("#{__DIR__}/scenario1_old.sql", dump_old)
      File.write!("#{__DIR__}/scenario1_new.sql", dump_new)
      IO.puts("  Raw dumps saved to dev_docs/squash/scenario1_{old,new}.sql")
    end

    case DumpHelper.compare(dump_old, schema_old, dump_new, schema_new) do
      :equal ->
        IO.puts("PASS: Dumps are byte-identical after normalisation.")
        :pass

      {:diff, _a, _b} ->
        IO.puts("FAIL: Dumps differ.")
        DumpHelper.print_diff(dump_old, schema_old, dump_new, schema_new)
        :fail
    end
  end)

results = results ++ [{:scenario1, result1}]

# Cleanup scenario 1 schemas (keep them if verbose for inspection)
unless verbose do
  drop_schema.(schema_old)
  drop_schema.(schema_new)
end

# ---------------------------------------------------------------------------
# SCENARIO 2: Existing install
#
# Migrate OLD to V110 in schema_old.
# Apply NEW up() (must only run V111..V135, not the baseline).
# Result must be identical to reference dump at V135.
# [DB]
# ---------------------------------------------------------------------------

result2 =
  run_scenario.("2_existing_install", fn ->
    ref_schema = "#{base_schema}_ref"

    # Build a reference dump: OLD chain all the way to V135
    IO.puts("Building reference dump (OLD V01..V135 into #{ref_schema})...")
    create_schema.(ref_schema)

    MigrationRunner.run_old_chain(repo, ref_schema,
      to_version: 135,
      create_schema: !use_public
    )

    dump_ref = DumpHelper.dump!(ref_schema)

    # Now simulate existing install at V110
    schema_upgrade = "#{base_schema}_upgrade"
    IO.puts("Simulating existing install at V110 in #{schema_upgrade}...")
    create_schema.(schema_upgrade)

    MigrationRunner.run_old_chain(repo, schema_upgrade,
      to_version: 110,
      create_schema: !use_public
    )

    IO.puts("  Install at V110 complete.")
    IO.puts("Applying NEW up() (should only run V111..V135)...")

    MigrationRunner.run_new_chain_existing(repo, schema_upgrade, 110)

    IO.puts("  Upgrade complete.")

    dump_upgraded = DumpHelper.dump!(schema_upgrade)

    unless verbose do
      drop_schema.(ref_schema)
      drop_schema.(schema_upgrade)
    end

    case DumpHelper.compare(dump_ref, ref_schema, dump_upgraded, schema_upgrade) do
      :equal ->
        IO.puts("PASS: Upgraded install matches reference dump.")
        :pass

      {:diff, _a, _b} ->
        IO.puts("FAIL: Upgraded install differs from reference.")
        DumpHelper.print_diff(dump_ref, ref_schema, dump_upgraded, schema_upgrade)
        :fail
    end
  end)

results = results ++ [{:scenario2, result2}]

# ---------------------------------------------------------------------------
# SCENARIO 3: Below-floor guard
#
# An install at V109 (below floor 110) should produce a clear error when
# the new code's up() is called, not silently corrupt the schema.
# [DB]
# ---------------------------------------------------------------------------

result3 =
  run_scenario.("3_below_floor_guard", fn ->
    schema_old_v = "#{base_schema}_old_v109"
    IO.puts("Setting up install at V109 in #{schema_old_v}...")
    create_schema.(schema_old_v)

    MigrationRunner.run_old_chain(repo, schema_old_v,
      to_version: 109,
      create_schema: !use_public
    )

    IO.puts("  V109 install ready.")
    IO.puts("Calling NEW up() on V109 install (expect error or warning)...")

    guard_result = MigrationRunner.assert_below_floor_error(repo, schema_old_v, 109)

    unless verbose, do: drop_schema.(schema_old_v)

    case guard_result do
      :ok -> :pass
      :warn -> :warn
    end
  end)

results = results ++ [{:scenario3, result3}]

# ---------------------------------------------------------------------------
# SCENARIO 4: Down migration
#
# After a fresh install via NEW chain, run down() and verify all PK objects
# are gone (migrated_version returns 0).
# [DB]
# ---------------------------------------------------------------------------

result4 =
  run_scenario.("4_down_migration", fn ->
    schema_down = "#{base_schema}_down"
    IO.puts("Running NEW chain for down test into #{schema_down}...")
    create_schema.(schema_down)

    MigrationRunner.run_new_chain_fresh(repo, schema_down, create_schema: !use_public)

    IO.puts("  Fresh install complete.")
    IO.puts("Running down() to version 0...")

    try do
      MigrationRunner.run_old_chain_down(repo, schema_down, to_version: 0)
    rescue
      e ->
        IO.puts("WARN: down() raised: #{inspect(e)}")
    end

    # Verify: phoenix_kit table should not exist
    check_sql = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = '#{schema_down}'
        AND table_name = 'phoenix_kit'
    )
    """

    result = RepoHelper.query!(repo, check_sql)
    table_exists = result.rows == [[true]]

    unless verbose, do: drop_schema.(schema_down)

    if table_exists do
      IO.puts("FAIL: phoenix_kit table still exists after full down().")
      :fail
    else
      IO.puts("PASS: phoenix_kit table gone after full down().")
      :pass
    end
  end)

results = results ++ [{:scenario4, result4}]

# ---------------------------------------------------------------------------
# Clean up Mode A public schema if needed
# ---------------------------------------------------------------------------

clean_public.()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

IO.puts("""

=======================================================
SUMMARY
=======================================================
""")

all_pass =
  Enum.reduce(results, true, fn {name, result}, acc ->
    status =
      case result do
        :pass -> "PASS"
        :warn -> "WARN"
        :fail -> "FAIL"
        :skipped -> "SKIP"
        {:error, _, _} -> "ERROR"
        _ -> "?"
      end

    IO.puts("  #{status}  #{name}")
    acc and result in [:pass, :warn, :skipped]
  end)

IO.puts("")

if all_pass do
  IO.puts("All scenarios passed.")
  System.halt(0)
else
  IO.puts("One or more scenarios FAILED. Review output above.")
  System.halt(1)
end
