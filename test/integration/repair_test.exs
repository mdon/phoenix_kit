defmodule PhoenixKit.Integration.RepairTest do
  @moduledoc """
  End-to-end `PhoenixKit.Migrations.Repair` scenarios against a real
  Postgres, using `PhoenixKit.Test.FixtureExpectedSchema` as the manifest
  and a dedicated schema (`"phoenix_kit_fixture_test"` — see `@prefix`
  below) so this suite never touches the real `public.phoenix_kit` chain
  the rest of the test suite depends on
  (`test/test_helper.exs`'s `ensure_current/2` boot). `@moduletag
  :integration` — auto-excluded in this repo's sandbox (no PostgreSQL, per
  `test/test_helper.exs`); genuinely runnable once a scratch DB is
  available (spec §8.1), not placeholder stubs.

  Covers spec §8.2's scenario matrix as follows:

    * S8 (idempotence) — `idempotence` describe block.
    * S7 (tamper → repair) — `tamper and repair` describe block.
    * S9 (divergence reporting) — `divergence reporting` describe block.
    * S17 (revision scoping) — `revision scoping` describe block — the
      single most important scenario to prove for real: a DB whose comment
      sits *between* `module_key`'s two revisions must verify clean against
      the OLD shape, not the newest.
    * S13 (`--adopt`) — `adopt` describe block. NOTE: `PhoenixKit.Migrations.Repair`
      hardcodes `floor: PhoenixKit.Migrations.Postgres.initial_version/0`
      (currently `1`, pre-squash) — against this fixture's own `since`
      numbering, `--adopt` therefore only ever converges the tiny
      `since <= 1` slice here. That is a property of testing the REAL
      engine (whose floor is real) against a SYNTHETIC manifest (whose
      `since` values are borrowed for realism, not tied to the real chain)
      — the test still validates the *mechanism* (apply the slice, gate the
      stamp on cleanliness) correctly; it is not a statement about how much
      of a REAL manifest `--adopt` would converge post-squash.
    * S20 (comment > current) — `comment above current` describe block.

  Incidentally exercised by every test above, though none of them assert on
  it directly: Oban delegation (`Oban.Migration.up(prefix: @prefix,
  create_schema: false)` — every `Repair.repair/1` call below also creates
  Oban's own tables inside `phoenix_kit_fixture_test`, cleaned up by the same
  `on_exit` `DROP SCHEMA ... CASCADE`) and the server-version preflight
  finding (`:unsupported_pg_version` — silent unless the scratch DB's major
  falls outside `Repair`'s declared supported range).

  NOT covered here (documented, not silently skipped):

    * S12 (pooled connection) — needs an actual PgBouncer instance in front
      of the target; `PhoenixKit.Migrations.Repair.EnvironmentTest`'s
      `classify_config/1` unit tests are this suite's only coverage today.
    * S18 (concurrent migration) — needs two genuinely concurrent
      transactions racing the raw-comment read/write; deterministic only
      with two separate connections coordinated around the advisory lock,
      which is more infrastructure than a single-process ExUnit test
      naturally provides. `PhoenixKit.Migrations.Repair.CommentPolicyTest`'s
      `concurrent_migration?/2` unit tests cover the DECISION; the
      DETECTION's plumbing (`PhoenixKit.Migrations.Repair`'s two
      `Probe.raw_comment/2` reads) is exercised implicitly by every test
      below (each one completes without a spurious `:concurrent_migration`
      abort), just never under an actual race.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Migrations.Repair.Executor
  alias PhoenixKit.Migrations.Repair.Report
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.Test.FixtureExpectedSchema
  alias PhoenixKit.Test.Repo

  @prefix "phoenix_kit_fixture_test"

  setup do
    Application.put_env(:phoenix_kit, :expected_schema_module, FixtureExpectedSchema)
    reset_schema()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :expected_schema_module)
      Repo.query("DROP SCHEMA IF EXISTS #{@prefix} CASCADE", [])
    end)

    :ok
  end

  describe "idempotence (S8)" do
    test "a healthy DB verifies clean twice, with identical finding summaries" do
      build_objects(142)
      stamp(142)

      {:ok, report1} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Report.exit_code(report1) == 0

      {:ok, report2} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Report.exit_code(report2) == 0
      assert Report.summary(report1) == Report.summary(report2)
    end
  end

  describe "tamper and repair (S7)" do
    test "a dropped column is detected, reported, and additively recreated" do
      build_objects(142)
      stamp(142)

      Repo.query!("ALTER TABLE #{@prefix}.phoenix_kit_fixture_widgets DROP COLUMN owner_uuid", [])

      {:ok, verify_report} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Report.exit_code(verify_report) == 1
      missing = Enum.find(Report.findings(verify_report), &(&1.kind == :missing))
      assert missing.object_id == "column:phoenix_kit_fixture_widgets.owner_uuid"

      {:ok, repair_report} = Repair.repair(prefix: @prefix, repo: Repo)
      repaired = Enum.find(Report.findings(repair_report), &(&1.kind == :repaired))
      assert repaired.object_id == "column:phoenix_kit_fixture_widgets.owner_uuid"

      {:ok, final} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Report.exit_code(final) == 0
    end

    test "a dropped FK constraint is recreated NOT VALID and then validated" do
      build_objects(142)
      stamp(142)

      Repo.query!(
        "ALTER TABLE #{@prefix}.phoenix_kit_fixture_widgets " <>
          "DROP CONSTRAINT phoenix_kit_fixture_widgets_owner_uuid_fkey",
        []
      )

      {:ok, repair_report} = Repair.repair(prefix: @prefix, repo: Repo)
      repaired = Enum.find(Report.findings(repair_report), &(&1.kind == :repaired))

      assert repaired.object_id ==
               "constraint:phoenix_kit_fixture_widgets.phoenix_kit_fixture_widgets_owner_uuid_fkey"

      {:ok, %{rows: [[valid]]}} =
        Repo.query(
          "SELECT convalidated FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace " <>
            "WHERE c.conname = 'phoenix_kit_fixture_widgets_owner_uuid_fkey' AND n.nspname = '#{@prefix}'",
          []
        )

      assert valid == true
    end
  end

  describe "divergence reporting (S9)" do
    test "a wrong column type is reported error-severity and never touched" do
      build_objects(142)
      stamp(142)

      Repo.query!(
        "ALTER TABLE #{@prefix}.phoenix_kit_fixture_owners ALTER COLUMN slug TYPE character varying(40)",
        []
      )

      {:ok, report} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Report.exit_code(report) == 2

      finding = Enum.find(Report.findings(report), &(&1.kind == :wrong_shape))
      assert finding.object_id == "column:phoenix_kit_fixture_owners.slug"
      assert finding.severity == :error

      # verify/1 is read-only — the wrong type is still there afterward.
      {:ok, %{rows: [[type]]}} =
        Repo.query(
          "SELECT format_type(atttypid, atttypmod) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid " <>
            "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE c.relname = 'phoenix_kit_fixture_owners' AND a.attname = 'slug' AND n.nspname = '#{@prefix}'",
          []
        )

      assert type == "character varying(40)"
    end
  end

  describe "revision scoping (S17)" do
    test "an old-shape column verifies clean at an old comment, then converges after the delta 'runs'" do
      build_objects(100)
      stamp(100)

      {:ok, report_old} = Repair.verify(prefix: @prefix, repo: Repo)

      refute Enum.any?(
               Report.findings(report_old),
               &(&1.object_id == "column:phoenix_kit_fixture_role_permissions.module_key")
             )

      # Built and stamped exactly the since<=100 slice — nothing missing,
      # nothing mismatched, nothing stale-low: genuinely clean, not just
      # "no errors".
      assert Report.exit_code(report_old) == 0

      # Simulate "the real delta module ran" (widening V142's own migration,
      # never repair's job) — then confirm the newer comment/shape also
      # verifies clean.
      Repo.query!(
        "ALTER TABLE #{@prefix}.phoenix_kit_fixture_role_permissions ALTER COLUMN module_key TYPE character varying(120)",
        []
      )

      stamp(142)
      {:ok, report_new} = Repair.verify(prefix: @prefix, repo: Repo)

      refute Enum.any?(
               Report.findings(report_new),
               &(&1.object_id == "column:phoenix_kit_fixture_role_permissions.module_key")
             )
    end
  end

  describe "adopt (S13)" do
    test "comment stripped from a healthy DB converges and stamps the floor" do
      build_objects(142)
      # No stamp() call — comment starts NULL (the half-installed/adopted case).

      {:ok, report} = Repair.verify(prefix: @prefix, repo: Repo)
      assert Enum.any?(Report.findings(report), &(&1.kind == :adopt_required))

      {:ok, adopted} = Repair.repair(prefix: @prefix, repo: Repo, adopt: true)
      assert adopted.comment_action == {:adopted, 1}
    end

    test "a missing since<=floor object is repaired additively before the clean gate is evaluated, and the stamp still lands" do
      build_objects(142)

      Repo.query!("ALTER TABLE #{@prefix}.phoenix_kit_fixture_widgets DROP COLUMN name", [])

      {:ok, report} = Repair.repair(prefix: @prefix, repo: Repo, adopt: true)

      repaired = Enum.find(Report.findings(report), &(&1.kind == :repaired))
      assert repaired.object_id == "column:phoenix_kit_fixture_widgets.name"
      # `widgets.name` is `not_null: true` with no default — the additive
      # rebuild correctly adds it NULLABLE instead (ShapeSql's documented
      # asymmetry), so this finding is `:repaired`/`:repairable`, never
      # `:wrong_shape`/`:error`, within THIS SAME pass (the object was
      # absent, not present-with-a-mismatch, when it was evaluated) — the
      # clean gate (`CommentPolicy.floor_verify_clean?/1`) sees no
      # error-severity finding and the stamp lands.
      assert report.comment_action == {:adopted, 1}
    end
  end

  describe "comment above current (S20)" do
    test "hard-errors instead of silently no-op'ing" do
      # No `build_objects/1` call — `classify/3` decides `:above_current`
      # from the raw comment alone, before the manifest is ever consulted;
      # only the meta table (from `reset_schema/0`) needs to exist.
      stamp(999)

      current = Postgres.current_version()

      assert Repair.verify(prefix: @prefix, repo: Repo) ==
               {:error, {:above_current, 999, current}}
    end
  end

  # ── Setup helpers ────────────────────────────────────────────────────

  defp reset_schema do
    Repo.query("DROP SCHEMA IF EXISTS #{@prefix} CASCADE", [])
    Repo.query!("CREATE SCHEMA #{@prefix}", [])
    # A minimal stand-in for the real `phoenix_kit` meta table — only
    # existence + a COMMENT are ever read (`Probe.raw_comment/2`); this
    # fixture's manifest does not model the meta table as an object at all
    # (same as the real one, spec §6.1: "the version-marker COMMENT is not
    # an object").
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit (id integer)", [])
  end

  defp build_objects(bound) do
    FixtureExpectedSchema.objects(@prefix)
    |> Scope.partition(bound)
    |> elem(0)
    |> Enum.map(&Scope.resolve(&1, bound))
    |> Enum.reject(&is_nil/1)
    |> Scope.execution_order()
    |> Enum.each(fn resolved ->
      case Executor.create(Repo, resolved, @prefix) do
        outcome when outcome in [:created, :already_present, :best_effort_skipped] ->
          :ok

        other ->
          flunk("test setup failed to create #{resolved.object.id}: #{inspect(other)}")
      end
    end)
  end

  defp stamp(version) do
    Repo.query!(~s(COMMENT ON TABLE #{@prefix}.phoenix_kit IS '#{version}'), [])
  end
end
