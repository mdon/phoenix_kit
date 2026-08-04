#!/usr/bin/env elixir
# verify.exs — scenario harness for the migration squash
# (spec: dev_docs/plans/2026-07-14-squash-migrations-spec.md, sections 8.2 + 8.3).
#
# Offline smoke gate (compiles everything, runs helper self-checks, no DB):
#
#     MIX_ENV=test mix run --no-start dev_docs/squash/verify.exs --check
#
# Scenario runs (need an operator scratch DB, spec section 8.1):
#
#     PGHOST=172.18.0.13 PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=... \
#     PK_SQUASH_FLOOR=121 \
#     MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b --scenario s1_self,s2_self
#
# Full env contract + scenario table: dev_docs/squash/README.md.

Code.require_file(Path.join(__DIR__, "repo_helper.ex"))
Code.require_file(Path.join(__DIR__, "dump_helper.ex"))
Code.require_file(Path.join(__DIR__, "migration_runner.ex"))

defmodule PhoenixKit.Squash.Verify do
  @moduledoc """
  Scenario harness implementing the spec's S1-S13/S15-S20 matrix (S14 is the
  DB-free gate suite — `mix precommit` / `mix phoenix_kit.release_check` — and
  deliberately not a verify.exs scenario).

  Every scenario emits one machine-readable line:

      RESULT <id> PASS | FAIL | ERROR | SKIP:<reason-slug>

  Scenarios whose prerequisites have not landed yet (P2 repair engine /
  manifest, P3 squashed registry / `BelowFloorError`, saved reference dumps)
  are present as SKIP stubs and light up as the phases land — the harness is
  runnable at every stage. Exit code: 0 when nothing FAILed/ERRORed
  (SKIPs are fine), 1 otherwise, 2 for configuration/usage errors.

  ## Modes

  * `--mode b` (default) — throwaway named schemas inside `PGDATABASE`;
    `public` is never touched. Safe against any scratch DB.
  * `--mode a` — sequential clean-DB runs in `public`; side-by-side
    comparisons are achieved by dump-then-reset-then-rerun, where reset is
    `DROP SCHEMA public CASCADE; CREATE SCHEMA public` (spec section 8.1
    option (b) recipe). Destructive by design, therefore gated:
    `PK_SQUASH_ALLOW_RESET` must equal the `PGDATABASE` name.

  ## Cleanup guarantee

  Scratch schemas a scenario creates are registered BEFORE creation and
  dropped in an `after` block — exceptions cannot leak them (the June 2026
  draft leaked schemas on every scenario crash). `--verbose` opts out of
  cleanup (retains schemas and dumps for inspection); the persistent
  below-floor handoff schema of `s4_seed` is exempt by design.
  """

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Squash.DumpHelper
  alias PhoenixKit.Squash.MigrationRunner
  alias PhoenixKit.Squash.RepoHelper

  @script_dir __DIR__

  # Committed :legacy_optional whitelist (spec sections 3.7 + 8.2 S1): objects
  # whose presence is bimodal between single-run and incrementally-upgraded
  # old-chain installs. Override with PK_SQUASH_WHITELIST (comma-separated;
  # set empty for strict mode). Any diff NOT covered by this list is a failure.
  #
  # - preferred_locale (+ its index): V28 adds them; V30's immediate-query
  #   guard misses V28's queued add on single-run installs, so fresh
  #   single-run chains RETAIN both while upgraded installs do not.
  # - V13's partial unique index on email_logs.aws_message_id: duplicated by
  #   V22's `_uidx`; the baseline keeps exactly one (V22's name), so V13's
  #   name is presence-optional.
  @legacy_optional_default [
    "phoenix_kit_users.preferred_locale",
    "phoenix_kit_users_preferred_locale_index",
    "phoenix_kit_email_logs_aws_message_id_index"
  ]

  @ref_header_prefix "-- pk-squash-ref"

  @usage """
  Usage: MIX_ENV=test mix run dev_docs/squash/verify.exs [options]

    --check              offline gate: compile, helper self-checks, config
                         validation, scenario runnability listing; no DB access
    --mode a|b           a = sequential clean-DB (public + CASCADE resets,
                         gated by PK_SQUASH_ALLOW_RESET=<PGDATABASE>)
                         b = throwaway named schemas (default)
    --scenario id1,id2   run only the listed scenario ids (--check lists them)
    --verbose            retain scratch schemas and all dumps (PK_SQUASH_OUT_DIR)
  """

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  def main(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [check: :boolean, mode: :string, scenario: :string, verbose: :boolean]
      )

    cond do
      invalid != [] -> halt_usage("unknown option(s): #{inspect(invalid)}")
      positional != [] -> halt_usage("unexpected argument(s): #{inspect(positional)}")
      Keyword.get(opts, :check, false) -> check(opts)
      true -> run(opts)
    end
  end

  @doc """
  Offline smoke gate: compiles this script plus the three helper modules,
  runs their DB-free self-checks, validates the configuration surface
  (mode/schema/whitelist/floor/scenario filter), lists every scenario with
  its current runnability, prints a one-line OK, and returns without any
  DB access.
  """
  def check(opts) do
    IO.puts("verify.exs --check (offline; no DB access)\n")

    RepoHelper.run_self_checks()
    IO.puts("  RepoHelper.run_self_checks: OK")
    DumpHelper.run_self_checks()
    IO.puts("  DumpHelper.run_self_checks: OK")
    MigrationRunner.check()
    IO.puts("  MigrationRunner.check: OK")

    ctx = build_ctx(opts, :check)
    selected = select_scenarios!(opts[:scenario])

    IO.puts(
      "  configuration: mode=#{ctx.mode} base=#{ctx.base} " <>
        "floor=#{MigrationRunner.floor()} current=#{MigrationRunner.current_version()} " <>
        "whitelist=#{length(ctx.whitelist)} selected=#{length(selected)}"
    )

    IO.puts("""

    Scenario runnability (S14 = DB-free gates: mix precommit / release_check,
    not a verify.exs scenario):
    """)

    Enum.each(scenarios(), fn s ->
      status =
        case unmet_requirement(ctx, s) do
          :ok -> "RUNNABLE"
          {:skip, slug, _human} -> "SKIP:#{slug}"
        end

      IO.puts(
        "  #{String.pad_trailing(s.id, 12)}#{String.pad_trailing(s.spec, 5)}" <>
          "#{String.pad_trailing(status, 36)}#{s.title}"
      )
    end)

    IO.puts(
      "\nOK verify.exs --check: modules compiled, helper self-checks passed, " <>
        "configuration valid; no DB was touched."
    )
  end

  def run(opts) do
    ctx = build_ctx(opts, :run)
    selected = select_scenarios!(opts[:scenario])

    IO.puts("""
    =======================================================
    PhoenixKit migration squash — scenario harness
    mode=#{ctx.mode} base=#{ctx.base} floor=#{MigrationRunner.floor()} \
    current=#{MigrationRunner.current_version()}
    scenarios: #{Enum.map_join(selected, ", ", & &1.id)}
    =======================================================
    """)

    ctx = attach_repo(ctx, selected)

    results = Enum.map(selected, fn s -> {s.id, run_scenario(ctx, s)} end)

    IO.puts("\n=======================================================")
    IO.puts("SUMMARY")
    IO.puts("=======================================================")

    Enum.each(results, fn {id, status} ->
      IO.puts("  #{String.pad_trailing(id, 12)} #{status_line(status)}")
    end)

    failed? =
      Enum.any?(results, fn {_id, status} ->
        match?({:fail, _}, status) or match?({:error, _}, status)
      end)

    IO.puts("")

    if failed? do
      IO.puts("One or more scenarios FAILED.")
      System.halt(1)
    else
      IO.puts("No failures (PASS/SKIP only).")
      System.halt(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario registry
  # ---------------------------------------------------------------------------

  # Requirements are checked before the body runs; the first unmet one becomes
  # the SKIP reason. Precursor scenarios (_self/_pre suffixes) prove the
  # oracles against the CURRENT compiled chain and need only a scratch DB.
  defp scenarios do
    [
      %{
        id: "s1_self",
        spec: "S1",
        title:
          "fresh-install self-oracle: current chain twice, normalized dumps byte-equal " <>
            "(strict; writes the S1 reference on pre-squash checkouts)",
        requires: [:db],
        run: &s1_self/1
      },
      %{
        id: "s1",
        spec: "S1",
        title: "fresh-install equivalence: NEW chain vs saved OLD-chain reference (whitelisted)",
        requires: [:squashed_registry, :ref_s1, :db],
        run: &s1_full/1
      },
      %{
        id: "s2_self",
        spec: "S2",
        title:
          "seed-data self-oracle: two fresh installs, normalized seed dumps identical " <>
            "(writes the S2 reference on pre-squash checkouts)",
        requires: [:db],
        run: &s2_self/1
      },
      %{
        id: "s2",
        spec: "S2",
        title: "seed-data equivalence: NEW chain vs saved OLD-chain seed reference",
        requires: [:squashed_registry, :ref_s2, :db],
        run: &s2_full/1
      },
      %{
        id: "s3",
        spec: "S3",
        title: "existing-install upgrade from floor and floor+k: deltas only, comment=current",
        requires: [:squashed_registry, :db],
        run: &s3_upgrade/1
      },
      %{
        id: "s4_seed",
        spec: "S4",
        title:
          "seed the persistent below-floor handoff schema at floor-1 " <>
            "(bridge checkout; hands off to s4 on the squash checkout)",
        requires: [:pre_squash_registry, :floor_override, :mode_b, :db],
        run: &s4_seed/1
      },
      %{
        id: "s4",
        spec: "S4",
        title: "below-floor guard: up() AND down() raise the specific BelowFloorError",
        requires: [:squashed_registry, :below_floor_error, :mode_b, :db],
        run: &s4_guard/1
      },
      %{
        id: "s5",
        spec: "S5",
        title: "consumer wrapper replay (Andi 41-file set / synthetic pins / interleaved)",
        requires: [:squashed_registry, :db],
        run: &s5_stub/1
      },
      %{
        id: "s6",
        spec: "S6",
        title: "baseline down to 0 + re-up; shared extensions survive; identical re-create",
        requires: [:squashed_registry, :db],
        run: &s6_down/1
      },
      %{
        id: "s7",
        spec: "S7",
        title: "repair tamper matrix: drop each object class, repair restores, extras untouched",
        requires: [:repair_engine, :manifest, :db],
        run: &s7_stub/1
      },
      %{
        id: "s8_pre",
        spec: "S8",
        title: "double up() idempotence: second run is a no-op, dumps byte-identical",
        requires: [:db],
        run: &s8_pre/1
      },
      %{
        id: "s8",
        spec: "S8",
        title: "repair idempotence: healthy DB twice, empty plan, byte-identical dumps",
        requires: [:repair_engine, :db],
        run: &s8_stub/1
      },
      %{
        id: "s9",
        spec: "S9",
        title:
          "divergence reporting: report-only, exit 2, no deparse false-positives " <>
            "(second-PG-major cell needs the operator container)",
        requires: [:repair_engine, :db],
        run: &s9_stub/1
      },
      %{
        id: "s10",
        spec: "S10",
        title: "data preservation: seeded + user rows + tuned settings survive repair",
        requires: [:repair_engine, :db],
        run: &s10_stub/1
      },
      %{
        id: "s11_pre",
        spec: "S11",
        title:
          "prefixed dual-install cross-leak: parity of coexisting installs via the dump " <>
            "differ (mode A adds the public-vs-named cell)",
        requires: [:db],
        run: &s11_pre/1
      },
      %{
        id: "s11",
        spec: "S11",
        title: "prefixed install parity on the NEW chain (repair-in-prefix cell lands with P2)",
        requires: [:squashed_registry, :db],
        run: &s11_full/1
      },
      %{
        id: "s12",
        spec: "S12",
        title: "pooled-connection detection / --unsafe-pooled degraded mode (needs Q6 endpoint)",
        requires: [:repair_engine, :db],
        run: &s12_stub/1
      },
      %{
        id: "s13",
        spec: "S13",
        title: "--adopt: healthy converges + stamps; half-installed / invariant-failing do not",
        requires: [:repair_engine, :manifest, :db],
        run: &s13_stub/1
      },
      %{
        id: "s15",
        spec: "S15",
        title: "stamp semantics: single-step fresh stamps '{floor}', multi-step '{current}'",
        requires: [:squashed_registry, :db],
        run: &s15_stamps/1
      },
      %{
        id: "s16",
        spec: "S16",
        title: "Oban delegation: repair/verify skip oban objects; no oban entries in Report",
        requires: [:repair_engine, :db],
        run: &s16_stub/1
      },
      %{
        id: "s17",
        spec: "S17",
        title: "repair since/revision scoping: comment-era shapes clean, pending reported",
        requires: [:repair_engine, :manifest, :db],
        run: &s17_stub/1
      },
      %{
        id: "s18",
        spec: "S18",
        title: "concurrency: chain up() mid-repair triggers the concurrent-migration abort",
        requires: [:repair_engine, :db],
        run: &s18_stub/1
      },
      %{
        id: "s19",
        spec: "S19",
        title: "data-dependent drift: V137-class index over duplicates yields :create_failed",
        requires: [:repair_engine, :db],
        run: &s19_stub/1
      },
      %{
        id: "s20",
        spec: "S20",
        title: "comment > current: repair hard-errors, doctor warns, up() no-op documented",
        requires: [:repair_engine, :db],
        run: &s20_stub/1
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Requirements
  # ---------------------------------------------------------------------------

  defp unmet_requirement(ctx, scenario) do
    Enum.find_value(scenario.requires, :ok, fn req ->
      case check_requirement(ctx, req) do
        :ok -> nil
        {:skip, _slug, _human} = skip -> skip
      end
    end)
  end

  defp check_requirement(ctx, :db) do
    if ctx.repo do
      :ok
    else
      {:skip, "needs-scratch-db",
       "PGHOST/PGUSER/PGPASSWORD/PGDATABASE not set — operator scratch DB pending (spec 8.1)"}
    end
  end

  defp check_requirement(_ctx, :squashed_registry) do
    if Postgres.initial_version() > 1 do
      :ok
    else
      {:skip, "needs-p3-squashed-registry",
       "compiled @initial_version is 1 (pre-squash checkout); lands with the P3 squash PR"}
    end
  end

  defp check_requirement(_ctx, :pre_squash_registry) do
    if Postgres.initial_version() == 1 do
      :ok
    else
      {:skip, "needs-pre-squash-checkout",
       "below-floor installs can only be built by the bridge (pre-squash) chain"}
    end
  end

  defp check_requirement(_ctx, :floor_override) do
    if MigrationRunner.floor() >= 2 do
      :ok
    else
      {:skip, "needs-pk-squash-floor",
       "set PK_SQUASH_FLOOR (>= 2) so floor-1 is a real version on the pre-squash checkout"}
    end
  end

  defp check_requirement(ctx, :mode_b) do
    if ctx.mode == :b do
      :ok
    else
      {:skip, "needs-mode-b",
       "the persistent below-floor handoff schema cannot coexist with mode A public " <>
         "resets (DROP SCHEMA public CASCADE also drops extension-dependent objects)"}
    end
  end

  defp check_requirement(_ctx, :below_floor_error) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.BelowFloorError) do
      :ok
    else
      {:skip, "needs-p3-below-floor-error",
       "PhoenixKit.Migrations.BelowFloorError is not defined (P3 deliverable)"}
    end
  end

  defp check_requirement(_ctx, :repair_engine) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.Repair) do
      :ok
    else
      {:skip, "needs-p2-repair-engine",
       "PhoenixKit.Migrations.Repair is not defined (P2 deliverable)"}
    end
  end

  defp check_requirement(_ctx, :manifest) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.ExpectedSchema) do
      :ok
    else
      {:skip, "needs-p2-manifest",
       "PhoenixKit.Migrations.ExpectedSchema is not defined (P2 deliverable)"}
    end
  end

  defp check_requirement(ctx, :ref_s1) do
    if File.exists?(s1_ref_path(ctx)) do
      :ok
    else
      {:skip, "missing-reference-s1",
       "no S1 reference at #{s1_ref_path(ctx)}; run --scenario s1_self on the bridge checkout"}
    end
  end

  defp check_requirement(ctx, :ref_s2) do
    if File.exists?(s2_ref_path(ctx)) do
      :ok
    else
      {:skip, "missing-reference-s2",
       "no S2 reference at #{s2_ref_path(ctx)}; run --scenario s2_self on the bridge checkout"}
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario runner (cleanup-guaranteed)
  # ---------------------------------------------------------------------------

  defp run_scenario(ctx, scenario) do
    IO.puts("\n--- #{scenario.id} (#{scenario.spec}) #{scenario.title} ---")

    status =
      case unmet_requirement(ctx, scenario) do
        {:skip, slug, human} ->
          IO.puts("  SKIPPED: #{human}")
          {:skip, slug}

        :ok ->
          {:ok, cleanup} = Agent.start_link(fn -> [] end)
          ctx = %{ctx | cleanup: cleanup}

          try do
            case scenario.run.(ctx) do
              :pass ->
                :pass

              {:fail, msg} ->
                IO.puts("  FAIL: #{msg}")
                {:fail, msg}

              {:skip, slug, human} ->
                IO.puts("  SKIPPED: #{human}")
                {:skip, slug}
            end
          rescue
            e ->
              IO.puts("  EXCEPTION:")
              IO.puts(Exception.format(:error, e, __STACKTRACE__))
              {:error, e}
          catch
            kind, value ->
              IO.puts("  NON-RAISE EXIT: #{inspect(kind)} #{inspect(value)}")
              {:error, {kind, value}}
          after
            drop_registered_schemas(ctx)
            Agent.stop(cleanup)
          end
      end

    IO.puts("RESULT #{scenario.id} #{status_line(status)}")
    status
  end

  defp status_line(:pass), do: "PASS"
  defp status_line({:fail, _}), do: "FAIL"
  defp status_line({:skip, slug}), do: "SKIP:#{slug}"
  defp status_line({:error, _}), do: "ERROR"

  # ---------------------------------------------------------------------------
  # S1/S2 precursors and full scenarios
  # ---------------------------------------------------------------------------

  defp s1_self(ctx) do
    to = MigrationRunner.current_version()

    a = fresh_target(ctx, "s1a")
    IO.puts("  installing chain v#{to} into #{a} (run 1)...")
    MigrationRunner.run_old_chain(ctx.repo, a)
    dump_a = DumpHelper.dump!(a)
    retain(ctx, "s1_self_a.sql", dump_a, :verbose)
    maybe_save_s1_reference(ctx, a, dump_a)

    b = fresh_target(ctx, "s1b")
    IO.puts("  installing chain v#{to} into #{b} (run 2)...")
    MigrationRunner.run_old_chain(ctx.repo, b)
    dump_b = DumpHelper.dump!(b)
    retain(ctx, "s1_self_b.sql", dump_b, :verbose)

    # Two identical single-run installs: strict comparison, no whitelist —
    # the bimodal artifacts are present on BOTH sides here.
    compare_dumps(ctx, "s1_self", dump_a, a, dump_b, b, [])
  end

  defp s1_full(ctx) do
    {meta, ref_dump} = load_ref!(s1_ref_path(ctx))
    ref_schema = Map.fetch!(meta, "schema")

    cond do
      Map.get(meta, "chain_version") != to_string(MigrationRunner.current_version()) ->
        {:skip, "reference-stale",
         "S1 reference was built at chain v#{meta["chain_version"]}, compiled chain is " <>
           "v#{MigrationRunner.current_version()}; regenerate via --scenario s1_self on " <>
           "the bridge checkout at the matching chain head"}

      ref_schema == "public" != (ctx.mode == :a) ->
        {:skip, "reference-mode-mismatch",
         "S1 reference came from schema #{ref_schema}; compare in the matching mode " <>
           "(public references in --mode a, named-schema references in --mode b) — " <>
           "cross-kind comparison false-diffs on shared-object references such as " <>
           "public.gen_random_bytes inside uuid_generate_v7's body"}

      true ->
        t = fresh_target(ctx, "s1_new")
        IO.puts("  installing NEW chain into #{t}...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t)
        raw = DumpHelper.dump!(t)
        retain(ctx, "s1_new.sql", raw, :verbose)
        compare_dumps(ctx, "s1", ref_dump, ref_schema, raw, t, ctx.whitelist)
    end
  end

  defp s2_self(ctx) do
    a = fresh_target(ctx, "s2a")
    IO.puts("  installing into #{a} (run 1)...")
    MigrationRunner.run_old_chain(ctx.repo, a)
    seeds_a = DumpHelper.dump_seed_data!(a)
    retain(ctx, "s2_self_a.txt", seeds_a, :verbose)
    warn_if_templates_absent(seeds_a)
    maybe_save_s2_reference(ctx, seeds_a)

    b = fresh_target(ctx, "s2b")
    IO.puts("  installing into #{b} (run 2)...")
    MigrationRunner.run_old_chain(ctx.repo, b)
    seeds_b = DumpHelper.dump_seed_data!(b)
    retain(ctx, "s2_self_b.txt", seeds_b, :verbose)

    compare_seed_texts(ctx, "s2_self", seeds_a, "run1", seeds_b, "run2")
  end

  defp s2_full(ctx) do
    {meta, ref_body} = load_ref!(s2_ref_path(ctx))

    if Map.get(meta, "chain_version") != to_string(MigrationRunner.current_version()) do
      {:skip, "reference-stale",
       "S2 reference was built at chain v#{meta["chain_version"]}, compiled chain is " <>
         "v#{MigrationRunner.current_version()}; regenerate via --scenario s2_self"}
    else
      t = fresh_target(ctx, "s2_new")
      IO.puts("  installing NEW chain into #{t}...")
      MigrationRunner.run_new_chain_fresh(ctx.repo, t)
      seeds = DumpHelper.dump_seed_data!(t)
      retain(ctx, "s2_new.txt", seeds, :verbose)
      warn_if_templates_absent(seeds)
      compare_seed_texts(ctx, "s2", ref_body, "reference", seeds, t)
    end
  end

  # ---------------------------------------------------------------------------
  # S3 — existing-install upgrade (post-squash)
  # ---------------------------------------------------------------------------

  defp s3_upgrade(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()

    ref = fresh_target(ctx, "s3_ref")
    IO.puts("  building single-run reference install in #{ref}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, ref)
    ref_dump = DumpHelper.dump!(ref)
    ref_seeds = DumpHelper.dump_seed_data!(ref)

    ks = Enum.uniq([0, min(3, current - floor)])

    results =
      Enum.map(ks, fn k ->
        from_version = floor + k
        t = fresh_target(ctx, "s3_from_#{from_version}")
        IO.puts("  installing #{t} to v#{from_version}, then upgrading via up()...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t, to_version: from_version)
        MigrationRunner.run_new_chain_existing(ctx.repo, t, from_version)
        v = MigrationRunner.migrated_version(ctx.repo, t)

        if v != current do
          {:fail, "upgrade from v#{from_version} landed at comment #{v}, expected #{current}"}
        else
          d = DumpHelper.dump!(t)
          seeds = DumpHelper.dump_seed_data!(t)

          first_failure([
            compare_dumps(ctx, "s3_from_#{from_version}", ref_dump, ref, d, t, ctx.whitelist),
            compare_seed_texts(ctx, "s3_from_#{from_version}", ref_seeds, "reference", seeds, t)
          ])
        end
      end)

    first_failure(results)
  end

  # ---------------------------------------------------------------------------
  # S4 — below-floor guard (bridge-seeded handoff schema + specific matcher)
  # ---------------------------------------------------------------------------

  defp s4_seed(ctx) do
    floor = MigrationRunner.floor()
    seed_version = floor - 1
    target = below_floor_schema(ctx)

    IO.puts("  (re)seeding persistent handoff schema #{target} at v#{seed_version}...")
    drop_schema!(ctx, target)
    MigrationRunner.run_old_chain(ctx.repo, target, to_version: seed_version)
    v = MigrationRunner.migrated_version(ctx.repo, target)

    if v == seed_version do
      IO.puts(
        "  handoff ready: #{target} is at v#{v} (below floor #{floor}) and is " <>
          "deliberately NOT dropped. Check out the squash branch and run " <>
          "--scenario s4 against the same database."
      )

      :pass
    else
      {:fail, "handoff schema landed at v#{v}, expected #{seed_version}"}
    end
  end

  defp s4_guard(ctx) do
    floor = MigrationRunner.floor()
    target = below_floor_schema(ctx)
    v = MigrationRunner.migrated_version(ctx.repo, target)

    cond do
      v == 0 ->
        {:skip, "handoff-schema-absent",
         "schema #{target} holds no install; run --scenario s4_seed on the bridge " <>
           "(pre-squash) checkout against the same database first"}

      v >= floor ->
        {:fail, "handoff schema #{target} is at v#{v}, not below floor #{floor}; reseed it"}

      true ->
        matcher = below_floor_matcher(v)

        r_up =
          MigrationRunner.assert_below_floor_error(ctx.repo, target, v,
            matcher: matcher,
            entry_point: :up
          )

        r_down =
          MigrationRunner.assert_below_floor_error(ctx.repo, target, v,
            matcher: matcher,
            entry_point: :down
          )

        case {r_up, r_down} do
          {:ok, :ok} ->
            IO.puts("  up() and down() both raised BelowFloorError with the expected fields")
            :pass

          {up, down} ->
            {:fail, "below-floor guard mismatch: up=#{inspect(up)} down=#{inspect(down)}"}
        end
    end
  end

  # Asserted field-by-field: db_version + floor; bridge_version is pinned only
  # indirectly via the bridge-named message (its expected VALUE is unknowable
  # until the bridge is tagged — add a field assert in s4_guard then). If P3
  # ships different field names this matcher fails loudly as
  # {:wrong_error, exception} — adjust it, never loosen it to any-raise-passes.
  defp below_floor_matcher(db_version) do
    error_mod = PhoenixKit.Migrations.BelowFloorError
    floor = MigrationRunner.floor()

    fn e ->
      is_struct(e, error_mod) and Map.get(e, :db_version) == db_version and
        Map.get(e, :floor) == floor and Exception.message(e) =~ ~r/bridge/i
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — consumer wrapper replay (stub: fixtures are a P3 deliverable)
  # ---------------------------------------------------------------------------

  defp s5_stub(_ctx) do
    {:skip, "pending-p3-fixtures",
     "wrapper-replay fixtures (Andi's real 41-file set, synthetic pinned chain " <>
       "[27,50,120,current], interleaved consumer migration, rollback round-trip) " <>
       "are built in P3 alongside the squash PR (spec S5 i-iv)"}
  end

  # ---------------------------------------------------------------------------
  # S6 — full down + re-up (post-squash)
  # ---------------------------------------------------------------------------

  defp s6_down(ctx) do
    t = fresh_target(ctx, "s6")
    IO.puts("  installing NEW chain into #{t}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t)
    d1 = DumpHelper.dump!(t)
    exts_before = installed_extensions(ctx)

    IO.puts("  rolling down to version 0...")
    MigrationRunner.run_old_chain_down(ctx.repo, t, to_version: 0)

    v = MigrationRunner.migrated_version(ctx.repo, t)
    leftover = pk_table_count(ctx, t)
    lost = exts_before -- installed_extensions(ctx)

    cond do
      v != 0 ->
        {:fail, "after down() migrated_version is #{v}, expected 0"}

      leftover > 0 ->
        {:fail, "#{leftover} phoenix_kit/oban tables left in #{t} after full down()"}

      lost != [] ->
        {:fail, "down() dropped shared extensions: #{Enum.join(lost, ", ")}"}

      true ->
        IO.puts("  teardown clean; re-installing...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t)
        d2 = DumpHelper.dump!(t)
        compare_dumps(ctx, "s6_reup", d1, t, d2, t, [])
    end
  end

  # ---------------------------------------------------------------------------
  # S8 precursor — double up() idempotence
  # ---------------------------------------------------------------------------

  defp s8_pre(ctx) do
    t = fresh_target(ctx, "s8pre")
    IO.puts("  installing into #{t}...")
    MigrationRunner.run_old_chain(ctx.repo, t)
    v1 = MigrationRunner.migrated_version(ctx.repo, t)
    d1 = DumpHelper.dump!(t)

    IO.puts("  running up() a second time (must be a silent no-op)...")
    MigrationRunner.run_old_chain(ctx.repo, t)
    v2 = MigrationRunner.migrated_version(ctx.repo, t)
    d2 = DumpHelper.dump!(t)

    if v1 != v2 do
      {:fail, "version moved #{v1} -> #{v2} on a double up()"}
    else
      compare_dumps(ctx, "s8_pre", d1, t, d2, t, [])
    end
  end

  # ---------------------------------------------------------------------------
  # S11 — prefixed dual-install cross-leak
  # ---------------------------------------------------------------------------
  #
  # Parity is asserted between two NAMED schemas (symmetric normalization —
  # comparing a public dump against a named-schema dump false-diffs on
  # shared-object references like public.gen_random_bytes). Mode A adds the
  # stronger cell: a public install coexists while the named installs run, so
  # unanchored existence checks would see public's objects and skip creating
  # the named ones (caught by parity), and any leak INTO public is caught by
  # the before/after snapshot.

  defp s11_pre(ctx), do: s11_body(ctx, "s11_pre", &MigrationRunner.run_old_chain/2)

  defp s11_full(ctx) do
    IO.puts("  note: the repair-in-prefix cell (S11 x S7) lands with the P2 repair engine")
    s11_body(ctx, "s11", fn repo, prefix -> MigrationRunner.run_new_chain_fresh(repo, prefix) end)
  end

  defp s11_body(ctx, id, install) do
    pub_before =
      case ctx.mode do
        :a ->
          reset_public!(ctx)
          IO.puts("  installing into public (mode A public-vs-named cell)...")
          install.(ctx.repo, "public")
          DumpHelper.dump!("public")

        :b ->
          IO.puts(
            "  mode B: public untouched; dual named-schema cell only " <>
              "(--mode a on a resettable scratch DB adds the public-vs-named cell)"
          )

          nil
      end

    n1 = named_target(ctx, "#{id}_a")
    IO.puts("  installing into #{n1}...")
    install.(ctx.repo, n1)
    d1 = DumpHelper.dump!(n1)

    n2 = named_target(ctx, "#{id}_b")
    IO.puts("  installing into #{n2} (while #{n1} exists)...")
    install.(ctx.repo, n2)
    d2 = DumpHelper.dump!(n2)
    d1_after = DumpHelper.dump!(n1)

    checks = [
      compare_dumps(ctx, "#{id}_parity", d1, n1, d2, n2, []),
      compare_dumps(ctx, "#{id}_first_intact", d1, n1, d1_after, n1, [])
    ]

    checks =
      if pub_before do
        pub_after = DumpHelper.dump!("public")

        checks ++
          [
            compare_dumps(
              ctx,
              "#{id}_public_intact",
              pub_before,
              "public",
              pub_after,
              "public",
              []
            )
          ]
      else
        checks
      end

    first_failure(checks)
  end

  # ---------------------------------------------------------------------------
  # S15 — stamp semantics (post-squash)
  # ---------------------------------------------------------------------------

  defp s15_stamps(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()

    t1 = fresh_target(ctx, "s15_single")
    IO.puts("  single-step fresh install: up(version: #{floor}) into #{t1}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t1, to_version: floor)
    v1 = MigrationRunner.migrated_version(ctx.repo, t1)

    r1 =
      if v1 == floor do
        IO.puts("  single-step run stamped '#{v1}'")
        :pass
      else
        {:fail, "single-step fresh install stamped '#{v1}', expected '#{floor}'"}
      end

    t2 = fresh_target(ctx, "s15_multi")
    IO.puts("  multi-step fresh install into #{t2}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t2)
    v2 = MigrationRunner.migrated_version(ctx.repo, t2)

    r2 =
      if v2 == current do
        IO.puts("  multi-step run stamped '#{v2}'")
        :pass
      else
        {:fail, "multi-step fresh install stamped '#{v2}', expected '#{current}'"}
      end

    first_failure([r1, r2])
  end

  # ---------------------------------------------------------------------------
  # P2 repair-engine scenario stubs
  # ---------------------------------------------------------------------------
  #
  # These bodies are reached only once PhoenixKit.Migrations.Repair (and,
  # where required, ExpectedSchema) load. They stay SKIP until the P2 phase
  # wires them to the final Repair API — implement against the real function
  # signatures then, never against guesses.

  defp s7_stub(_ctx), do: pending_p2("tamper matrix (drop one object class at a time, S7)")
  defp s8_stub(_ctx), do: pending_p2("repair idempotence on a healthy DB (S8)")
  defp s9_stub(_ctx), do: pending_p2("structural divergence reporting incl. second PG major (S9)")
  defp s10_stub(_ctx), do: pending_p2("data preservation under repair (S10)")
  defp s12_stub(_ctx), do: pending_p2("pooled detection + --unsafe-pooled degraded mode (S12)")
  defp s13_stub(_ctx), do: pending_p2("--adopt stamp/report/invariant gates (S13)")
  defp s16_stub(_ctx), do: pending_p2("Oban delegation - no oban entries in Report (S16)")
  defp s17_stub(_ctx), do: pending_p2("since/revision scoping incl. module_key@50 cell (S17)")
  defp s18_stub(_ctx), do: pending_p2("concurrent-migration abort via advisory lock (S18)")
  defp s19_stub(_ctx), do: pending_p2(":create_failed diagnostics on V137-class drift (S19)")
  defp s20_stub(_ctx), do: pending_p2("comment > @current_version hard error (S20)")

  defp pending_p2(note) do
    {:skip, "pending-p2-body",
     "repair-engine artifacts are loaded, but this scenario body is a P2 deliverable: " <> note}
  end

  # ---------------------------------------------------------------------------
  # Targets, cleanup, mode plumbing
  # ---------------------------------------------------------------------------

  # A fresh, empty migration target. Mode B: a named scratch schema (registered
  # for cleanup BEFORE creation, so exceptions cannot leak it). Mode A: public,
  # reset via the gated DROP SCHEMA public CASCADE recipe — sequential
  # comparisons must therefore capture their dumps BEFORE requesting the next
  # target.
  defp fresh_target(%{mode: :a} = ctx, _slot) do
    reset_public!(ctx)
    "public"
  end

  defp fresh_target(%{mode: :b} = ctx, slot), do: named_target(ctx, slot)

  # A named scratch schema in BOTH modes — for scenarios that need coexisting
  # installs (s11) regardless of mode.
  defp named_target(ctx, slot) do
    name = scratch_name(ctx, slot)
    register_schema(ctx, name)
    drop_schema!(ctx, name)
    name
  end

  defp scratch_name(ctx, slot) do
    name = "#{ctx.base}_#{slot}"
    validate_identifier!(name)
    name
  end

  defp below_floor_schema(ctx), do: scratch_name(ctx, "below_floor")

  defp register_schema(ctx, name) do
    Agent.update(ctx.cleanup, &[name | &1])
  end

  defp drop_registered_schemas(%{cleanup: nil}), do: :ok
  defp drop_registered_schemas(%{repo: nil}), do: :ok

  defp drop_registered_schemas(ctx) do
    schemas = ctx.cleanup |> Agent.get(& &1) |> Enum.uniq()

    cond do
      schemas == [] ->
        :ok

      ctx.verbose ->
        IO.puts("  retaining scratch schemas (--verbose): #{Enum.join(schemas, ", ")}")

      true ->
        Enum.each(schemas, fn name ->
          try do
            drop_schema!(ctx, name)
          rescue
            e ->
              IO.puts("  WARN: cleanup of schema #{name} failed: #{Exception.message(e)}")
          end
        end)
    end
  end

  defp drop_schema!(_ctx, "public") do
    raise "refusing DROP SCHEMA on public — mode A resets go through reset_public!/1"
  end

  defp drop_schema!(ctx, name) do
    refuse_live_schema!(ctx, name)
    validate_identifier!(name)
    RepoHelper.query!(ctx.repo, ~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
    :ok
  end

  # Spec section 8.1 option (b) reset recipe. Reached only behind the
  # PK_SQUASH_ALLOW_RESET gate (enforced before any scenario runs).
  # Tripwire ON TOP of the gate: a database whose public schema carries a
  # populated phoenix_kit_users table is a LIVE INSTALL, not a scratch DB —
  # refuse even with the gate set (no override; point PG* at a scratch DB).
  defp reset_public!(ctx) do
    refuse_live_install!(ctx)
    IO.puts("  resetting public (DROP SCHEMA public CASCADE)...")
    RepoHelper.query!(ctx.repo, "DROP SCHEMA public CASCADE")
    RepoHelper.query!(ctx.repo, "CREATE SCHEMA public")
    :ok
  end

  # Named-schema twin of refuse_live_install!: scratch schemas this harness
  # creates never contain user rows (migrations alone never insert users), so
  # a populated phoenix_kit_users in a schema we are about to drop means the
  # configured name collides with a LIVE prefixed install — refuse, no
  # override (pick a different base name).
  defp refuse_live_schema!(ctx, schema) do
    %{rows: [[reg]]} =
      RepoHelper.query!(ctx.repo, "SELECT to_regclass('#{schema}.phoenix_kit_users')::text")

    users =
      if reg do
        %{rows: [[n]]} =
          RepoHelper.query!(ctx.repo, "SELECT count(*) FROM \"#{schema}\".phoenix_kit_users")

        n
      else
        0
      end

    if users > 0 do
      raise """
      refusing DROP SCHEMA #{schema}: it contains #{users} row(s) in
      #{schema}.phoenix_kit_users — that is a LIVE prefixed PhoenixKit install,
      not a harness scratch schema. Change the scratch base name; there is
      deliberately no override.
      """
    end

    :ok
  end

  defp refuse_live_install!(ctx) do
    %{rows: [[reg]]} =
      RepoHelper.query!(ctx.repo, "SELECT to_regclass('public.phoenix_kit_users')::text")

    users =
      if reg do
        %{rows: [[n]]} =
          RepoHelper.query!(ctx.repo, "SELECT count(*) FROM public.phoenix_kit_users")

        n
      else
        0
      end

    if users > 0 do
      raise """
      refusing DROP SCHEMA public: this database has #{users} row(s) in
      public.phoenix_kit_users — it looks like a LIVE PhoenixKit install, not a
      scratch DB. There is deliberately no override; point PG* env at the
      operator-provided scratch database (spec section 8.1).
      """
    end

    :ok
  end

  defp attach_repo(ctx, selected) do
    needs_db? = Enum.any?(selected, &(:db in &1.requires))

    cond do
      not needs_db? ->
        ctx

      not db_env_present?() ->
        IO.puts(
          "NOTE: PG* env not set — every [DB] scenario will SKIP " <>
            "(operator scratch DB pending, spec 8.1)."
        )

        ctx

      true ->
        repo = RepoHelper.start!()
        enforce_mode_a_gate!(ctx)
        %{ctx | repo: repo}
    end
  end

  defp enforce_mode_a_gate!(%{mode: :a}) do
    database = RepoHelper.connection_env().database

    case System.get_env("PK_SQUASH_ALLOW_RESET") do
      ^database ->
        IO.puts(
          "MODE A: this run will repeatedly DROP SCHEMA public CASCADE in " <>
            "database #{database} (confirmed via PK_SQUASH_ALLOW_RESET)."
        )

        :ok

      other ->
        halt_usage("""
        Mode A resets the public schema of #{database} with DROP SCHEMA public CASCADE
        (spec 8.1 option (b) recipe). That destroys EVERYTHING in that schema,
        including extensions and their dependent objects.

        To confirm #{database} is a disposable scratch DB, set:

            PK_SQUASH_ALLOW_RESET=#{database}

        (currently: #{inspect(other)})
        """)
    end
  end

  defp enforce_mode_a_gate!(_ctx), do: :ok

  defp db_env_present? do
    RepoHelper.connection_env()
    true
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Comparison + retention helpers
  # ---------------------------------------------------------------------------

  defp compare_dumps(ctx, id, dump_a, schema_a, dump_b, schema_b, whitelist) do
    case DumpHelper.compare(dump_a, schema_a, dump_b, schema_b, legacy_optional: whitelist) do
      :equal ->
        IO.puts("  [#{id}] dumps identical after normalization")
        :pass

      {:equal_modulo_whitelist, %{only_a: only_a, only_b: only_b}} ->
        IO.puts("  [#{id}] dumps identical modulo the :legacy_optional whitelist:")
        Enum.each(only_a, &IO.puts("    only in #{schema_a}: #{&1}"))
        Enum.each(only_b, &IO.puts("    only in #{schema_b}: #{&1}"))
        :pass

      {:diff, text} ->
        retain(ctx, "#{id}_a.sql", dump_a, :always)
        retain(ctx, "#{id}_b.sql", dump_b, :always)
        retain(ctx, "#{id}.diff", text, :always)
        IO.puts("  [#{id}] dumps differ (unlisted divergence = FAILURE):")
        print_capped(text)
        {:fail, "[#{id}] normalized dumps differ (retained under #{ctx.out_dir})"}
    end
  end

  defp compare_seed_texts(ctx, id, text_a, label_a, text_b, label_b) do
    case DumpHelper.unified_diff(text_a, text_b, label_a, label_b) do
      :equal ->
        IO.puts("  [#{id}] seed dumps identical after normalization")
        :pass

      {:diff, diff} ->
        retain(ctx, "#{id}_seeds_a.txt", text_a, :always)
        retain(ctx, "#{id}_seeds_b.txt", text_b, :always)
        retain(ctx, "#{id}_seeds.diff", diff, :always)
        IO.puts("  [#{id}] seed dumps differ:")
        print_capped(diff)
        {:fail, "[#{id}] seed dumps differ (retained under #{ctx.out_dir})"}
    end
  end

  # S2 tolerance (spec 8.2): template rows must match when the seeder ran;
  # absence is acceptable only for release-mode installs. Under `mix run` the
  # seeder should have run — an empty section is suspicious, so warn loudly.
  defp warn_if_templates_absent(seed_text) do
    lines = String.split(seed_text, "\n")

    case Enum.split_while(lines, &(&1 != "-- table: phoenix_kit_email_templates")) do
      {_, []} ->
        if Enum.any?(lines, &String.starts_with?(&1, "-- table: phoenix_kit_email_templates")) do
          IO.puts("  WARN: phoenix_kit_email_templates table MISSING from the install")
        else
          IO.puts("  WARN: email-templates section absent from the seed dump")
        end

      {_, [_marker | rest]} ->
        rows =
          rest
          |> Enum.take_while(&(not String.starts_with?(&1, "-- table:")))
          |> Enum.reject(&(&1 == ""))

        # First row is the CSV header.
        if length(rows) <= 1 do
          IO.puts(
            "  WARN: system email templates absent (seeder skipped?) — acceptable " <>
              "only for release-mode installs (S2 tolerance)"
          )
        end
    end

    :ok
  end

  defp retain(ctx, name, content, when_) do
    if when_ == :always or ctx.verbose do
      File.mkdir_p!(ctx.out_dir)
      path = Path.join(ctx.out_dir, name)
      File.write!(path, content)
      IO.puts("  retained #{path}")
    end

    :ok
  end

  defp print_capped(text, max_lines \\ 200) do
    lines = String.split(text, "\n")
    Enum.each(Enum.take(lines, max_lines), &IO.puts/1)
    extra = length(lines) - max_lines
    if extra > 0, do: IO.puts("  ... (#{extra} more lines; see retained files)")
    :ok
  end

  defp first_failure(results), do: Enum.find(results, &(&1 != :pass)) || :pass

  # ---------------------------------------------------------------------------
  # Reference dumps (cross-checkout S1/S2 handoff)
  # ---------------------------------------------------------------------------

  defp s1_ref_path(ctx), do: Path.join(ctx.ref_dir, "s1_old_chain.sql")
  defp s2_ref_path(ctx), do: Path.join(ctx.ref_dir, "s2_old_chain_seeds.txt")

  defp maybe_save_s1_reference(ctx, schema, raw_dump) do
    if Postgres.initial_version() == 1 do
      save_ref(
        ctx,
        s1_ref_path(ctx),
        [kind: "s1", schema: schema, chain_version: MigrationRunner.current_version()],
        raw_dump
      )
    else
      IO.puts("  (squashed registry: not overwriting the OLD-chain S1 reference)")
    end
  end

  defp maybe_save_s2_reference(ctx, seed_text) do
    if Postgres.initial_version() == 1 do
      save_ref(
        ctx,
        s2_ref_path(ctx),
        [kind: "s2", chain_version: MigrationRunner.current_version()],
        seed_text
      )
    else
      IO.puts("  (squashed registry: not overwriting the OLD-chain S2 reference)")
    end
  end

  defp save_ref(ctx, path, kvs, body) do
    File.mkdir_p!(ctx.ref_dir)
    header = @ref_header_prefix <> " " <> Enum.map_join(kvs, " ", fn {k, v} -> "#{k}=#{v}" end)
    File.write!(path, header <> "\n" <> body)
    IO.puts("  wrote reference #{path}")
    :ok
  end

  defp load_ref!(path) do
    content = File.read!(path)

    case String.split(content, "\n", parts: 2) do
      [@ref_header_prefix <> rest, body] ->
        meta = ~r/(\w+)=(\S+)/ |> Regex.scan(rest) |> Map.new(fn [_, k, v] -> {k, v} end)
        {meta, body}

      _ ->
        raise "malformed reference file #{path}: first line must start with " <>
                "'#{@ref_header_prefix}' (references are tool-written; regenerate, " <>
                "never hand-edit)"
    end
  end

  # ---------------------------------------------------------------------------
  # Catalog probes
  # ---------------------------------------------------------------------------

  defp installed_extensions(ctx) do
    %{rows: rows} =
      RepoHelper.query!(ctx.repo, "SELECT extname FROM pg_extension ORDER BY extname")

    List.flatten(rows)
  end

  defp pk_table_count(ctx, schema) do
    %{rows: [[count]]} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT count(*)::int FROM information_schema.tables " <>
          "WHERE table_schema = $1 " <>
          "AND (table_name LIKE 'phoenix_kit%' OR table_name LIKE 'oban%')",
        [schema]
      )

    count
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  defp build_ctx(opts, phase) do
    mode =
      case Keyword.get(opts, :mode, "b") do
        "a" -> :a
        "b" -> :b
        other -> halt_usage("--mode must be 'a' or 'b', got #{inspect(other)}")
      end

    base = System.get_env("PK_SQUASH_SCHEMA", "pk_squash_test")
    validate_identifier!(base)

    if byte_size(base) > 40 do
      halt_usage(
        "PK_SQUASH_SCHEMA #{inspect(base)} too long (#{byte_size(base)} bytes); " <>
          "scratch suffixes must fit PostgreSQL's 63-byte identifier limit"
      )
    end

    %{
      phase: phase,
      mode: mode,
      verbose: Keyword.get(opts, :verbose, false),
      base: base,
      whitelist: whitelist_from_env(),
      ref_dir: System.get_env("PK_SQUASH_REF_DIR", Path.join(@script_dir, "reference")),
      out_dir: System.get_env("PK_SQUASH_OUT_DIR", Path.join(@script_dir, "out")),
      # :check phase never connects; :env marks "env present" for runnability
      # listing only. :run phase replaces this via attach_repo/2.
      repo: if(phase == :check and db_env_present?(), do: :env, else: nil),
      cleanup: nil
    }
  end

  defp whitelist_from_env do
    case System.get_env("PK_SQUASH_WHITELIST") do
      nil -> @legacy_optional_default
      "" -> []
      raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp select_scenarios!(nil), do: scenarios()

  defp select_scenarios!(filter) do
    ids =
      filter
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    known = MapSet.new(scenarios(), & &1.id)
    unknown = Enum.reject(ids, &MapSet.member?(known, &1))

    if unknown != [] do
      halt_usage(
        "unknown scenario id(s): #{Enum.join(unknown, ", ")}\n" <>
          "known ids: #{Enum.map_join(scenarios(), ", ", & &1.id)}"
      )
    end

    set = MapSet.new(ids)
    Enum.filter(scenarios(), &MapSet.member?(set, &1.id))
  end

  # Schema names are interpolated into DDL; enforce the same charset the
  # migration entry points enforce (Helpers.validate_prefix!/1).
  defp validate_identifier!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      halt_usage("invalid schema identifier #{inspect(name)}: must match [a-z_][a-z0-9_]*")
    end

    :ok
  end

  defp halt_usage(message) do
    IO.puts("ERROR: #{message}\n")
    IO.puts(@usage)
    System.halt(2)
  end
end

PhoenixKit.Squash.Verify.main(System.argv())
