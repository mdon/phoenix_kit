# PR #632: V144 — consolidate manufacturing/warehouse module tables into core

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: 🔄 In Review (draft)
**Commit**: `dcd497dd` (V144 migration), `ad7080a4` (dispatcher wiring)
**Date**: 2026-07-13

## Goal

Move five tables — `phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
`phoenix_kit_machine_operations`, `phoenix_kit_warehouse_transfers` (+ its
`number` sequence), `phoenix_kit_warehouse_min_stock` — out of the
`phoenix_kit_manufacturing`/`phoenix_kit_warehouse` packages' own
`migration_module/0` callbacks and into core's single numbered migration
chain as `V144`, following the precedent already set by V140
(`phoenix_kit_warehouse`'s other six tables, PR #624) and locations
(V90/V122).

## Verdict

Clean. Every DDL statement was diffed by hand against its pre-consolidation
source and matches byte-for-byte (modulo the deliberate, documented
omissions below). No bugs found. One design decision worth recording
explicitly because it looks like an oversight at a glance but isn't
(index-naming inconsistency, see below).

## Verification of claims

### DDL fidelity vs. pre-consolidation sources

- **`phoenix_kit_machines`** — `v144.ex:110-187` (columns, types, defaults,
  both indexes) is an exact match for
  `phoenix_kit_manufacturing`'s `machines.ex` V1 (identity columns +
  `idx_machines_status`) and V2 (10 passport/soft-location `ADD COLUMN IF
  NOT EXISTS` statements + `idx_machines_location`), confirmed by reading
  the pre-removal source at commit `d202df9` in that repo. ✓
- **`phoenix_kit_machine_type_assignments`** — table/index DDL
  (`v144.ex:192-215`) matches the original except the `machine_type_uuid`
  column drops its `REFERENCES #{p}phoenix_kit_machine_types (uuid) ON
  DELETE CASCADE` clause (intentional — the target table is no longer
  created here, see below) and gains the unconditional
  `drop_fk_constraint/4` call for upgrade hosts. `phoenix_kit_machine_operations`
  (`v144.ex:220-244`) is the same shape one column over
  (`operation_uuid`). ✓
- **`phoenix_kit_warehouse_transfers`/`min_stock`** — `v144.ex:277-359`
  matches `phoenix_kit_warehouse`'s `v01.ex`/`v02.ex` (read from that
  repo's history at commit `d6d8751^`, the last commit before their
  removal) column-for-column, index-for-index. The only intentional
  deletions are the `COMMENT ON TABLE ...phoenix_kit_warehouse_stock IS
  '1'/'2'` lines — those tracked the *module's own* private version
  counter on a table this migration doesn't own (`phoenix_kit_warehouse_stock`
  is core's, created by V140); the plan correctly drops them since V144's
  only version marker is `phoenix_kit`, core's own. ✓
- **`fk_constraint_name/3` (`v144.ex:368-385`) / `drop_fk_constraint/4`
  (`v144.ex:387-392`)** — diffed against `machines.ex:902-925` at the same
  `d202df9` commit: identical, including the doc comment. Ported verbatim
  as the plan directed, not reimplemented. `prefix_str/1` (`v144.ex:394-395`)
  is **deliberately not** a verbatim port — the module's original
  (`machines.ex:951-952`) returns `""` for `nil`/`"public"` (bare,
  unqualified table names on the default schema); `v144.ex` instead
  matches V138/V140/V142's own `prefix_str/1` (`"public"` → `"public."`,
  always schema-qualified), per the plan's explicit style directive ("style
  strictly like V140/V142, not like the module pattern"). Confirmed
  identical to `v140.ex:414-415`, `v138.ex:202-203`, `v122.ex:219-220`. ✓

### Mandatory review-fix checklist (from the wave-C plan header)

- **#6 — eight indexes on `phoenix_kit_warehouse_transfers`.** Counted:
  `number_index` (unique) + `status`, `inserted_at`, `deleted_at`,
  `source_location_uuid`, `destination_location_uuid`, `shipped_at`,
  `received_at` — 1 unique + 7 plain = 8, `received_at` included.
  `v144.ex:304-341`. ✓
- **#7 — FK drops before conditional legacy-table drops, `CASCADE` in the
  dynamic `DROP TABLE`.** `up/1` (`v144.ex:55-77`) calls
  `create_machine_type_assignments`/`create_machine_operations` (each
  ending in `drop_fk_constraint`) *before* the three
  `maybe_drop_if_empty` calls — and the code's own comment
  (`v144.ex:63-68`) explains why the ordering matters. The dynamic
  `EXECUTE 'DROP TABLE #{p}#{table} CASCADE'` (`v144.ex:265`) is present.
  ✓
- **#8 — `down/1` upgrade-host caveat in the moduledoc, not just the PR
  body.** Present verbatim in `V144.down/1`'s own `@doc` (`v144.ex:79-93`).
  ✓
- **#9 — rollback terminology ("target exclusive").** Traced
  `PhoenixKit.Migrations.Postgres.down/1` (`postgres.ex:1285-1307`):
  `target_version = Map.get(opts, :version, 0)` and
  `change(current_version..(target_version + 1)//-1, :down, opts)` — for
  `version: 142`, that's `change(143..143, :down, opts)`, i.e. only V144's
  `down/1` runs and 142 itself is never re-executed. Confirms "target
  exclusive" is the accurate description used in this PR's body. ✓
- **Dispatcher wiring (recon fact, not a numbered fix but load-bearing)**
  — `Module.concat([__MODULE__, "V144"])`-style dispatch needs no separate
  version registry; `postgres.ex`'s only required edits are
  `@current_version 142 → 143` and the moduledoc version-list entry, both
  present (`ad7080a4`). ✓
- **`CHANGELOG.md` / `mix.exs` untouched.** `git diff
  c989b1a2..core-v143-module-tables -- CHANGELOG.md mix.exs` is empty. ✓

### Known bug classes checked and not present

- **Schema-qualified index names** (the 2026-07-11 bug class fixed in PR
  #628 — `CREATE INDEX <prefix>.<name> ON ...` is invalid; only the table
  may be schema-qualified). Every `CREATE INDEX` in `v144.ex` qualifies
  `ON #{p}<table>` and leaves the index name itself bare. ✓
- **Constraint-existence guard not scoped to schema** (the PR #624 /
  V140 bug — `pg_constraint.conname`/catalog lookups need to be
  schema-scoped, since names aren't globally unique). `fk_constraint_name/3`
  filters by `tc.table_schema = $1 AND tc.table_name = $2` and is a
  parameterized query, not raw interpolation — correctly scoped, and
  matches the pattern already fixed elsewhere in the repo. ✓
- **Prefix escaping.** `v144.ex` interpolates `prefix`/`p` into raw SQL
  without the dispatcher's `escaped_prefix`/`quoted_prefix` helpers.
  Checked whether this is a regression: V138, V140, and V142 all do the
  same (`escaped_prefix` is used only inside `postgres.ex`'s own
  `migrated_version/1`/`version_checks/0`, never by an individual `V*.ex`
  module) — consistent with established convention across the whole
  migrations directory, not something V144 introduces. Not flagged.

## Findings

None. (See "Verified as correct" below for one item that could plausibly
be *mis*-flagged as a bug on a shallow pass.)

## Verified as correct (no action)

- **Index-naming style differs between the two halves of this file, on
  purpose.** The manufacturing tables use `idx_<table>_<col>` (e.g.
  `idx_machines_status`); the warehouse tables use
  `phoenix_kit_warehouse_<table>_<col>_index`. This looks like the kind
  of inconsistency PR #610's review flagged as a NITPICK for the CRM
  tables — but here it's load-bearing, not cosmetic: a real
  `phoenix_kit_manufacturing` 0.2.0 host already has indexes named
  `idx_machines_status` etc. from the module's own V1. If V144 used a
  different name for the "same" index, `CREATE INDEX IF NOT EXISTS`
  would not recognize the existing one as already present (index identity
  is by name, not by definition) and an upgrade host would end up with
  two functionally-identical indexes. Preserving each side's original
  names is required for the `IF NOT EXISTS` idempotency claim to hold on
  upgrade, not just continuity for its own sake.
- **`create_machine_type_assignments`/`create_machine_operations` argument
  order** (`p` then `prefix`) is consistent with every other private
  helper in the file and with the ported originals — no accidental swap.
- **Down-order is FK-safe**: `machine_operations`, `machine_type_assignments`,
  `machines`, `warehouse_min_stock`, `warehouse_transfers` (+sequence) —
  both join tables (children) drop before `machines` (parent); the two
  warehouse tables have no FK relationship to the manufacturing ones or
  to each other, so their relative order doesn't matter functionally.

## Testing

- [x] `mix format --check-formatted`
- [x] `mix compile --warnings-as-errors`
- [x] `mix test test/phoenix_kit/migration_test.exs` — 6 tests, 0 failures
      (module-shape only, no DB required by design — see that file's own
      moduledoc for why).
- [ ] `mix test test/integration/prefix_migration_test.exs` — tagged
      `:integration`, auto-excluded: no PostgreSQL reachable in this
      environment (`pg_isready` refused on the default socket). This is
      the test that runs the *entire* versioned chain, now 143 versions
      deep, into a named schema — the closest thing to an automated
      fresh-host rehearsal for this exact change. Left for CI / a
      DB-backed environment; the orchestrator's separate live-Postgres
      rehearsal (wave-C tasks C10/C11, against a real and a scratch
      schema respectively) is the fuller manual complement to this gap.
- No code changes were made by this review — the migration was correct on
  first read.

## Related

- Migration: `lib/phoenix_kit/migrations/postgres/v144.ex`
- Dispatcher: `lib/phoenix_kit/migrations/postgres.ex`
- Pre-consolidation sources (for the byte-for-byte diff above):
  `phoenix_kit_manufacturing@d202df9:lib/phoenix_kit_manufacturing/migrations/machines.ex`,
  `phoenix_kit_warehouse@d6d8751^:lib/phoenix_kit_warehouse/migrations/postgres/{v01,v02}.ex`
- Schema-qualified-index precedent: PR #628
- Constraint-scoping precedent: PR #624 (`CLAUDE_REVIEW.md` in
  `dev_docs/pull_requests/2026/624-warehouse-v140-tables/`)
- Non-empty legacy-table manual migration runbook:
  `phoenix_kit_manufacturing`'s `dev_docs/LEGACY_DATA_MIGRATION.md`
  (companion PR)
