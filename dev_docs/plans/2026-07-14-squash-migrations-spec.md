# Migration-chain consolidation (squash) + verify-and-repair — SPECIFICATION

Status: **DRAFT for review** (spec only; implementation not started).
Written 2026-07-14 at v1.7.193/V148; **revised 2026-07-16 at v1.7.196/V150** (chain V01..V150,
150 modules, 25,405 lines). Branch: `squash-migrations` (rebased onto upstream 1.7.196).
Supersedes: `2026-06-15-squash-migrations-plan.md` (June plan; stale — written at v135/1.7.152,
before the 2026-07 prefix-safety overhaul and before the verify-and-repair requirement).
Companion: `2026-07-14-squash-inventory.md` (per-version classification of all 150 migrations:
seeds / backfills / drops / hazards).

Method: 10 parallel research agents over current code (mechanics, delta-since-June, full-chain
inventory ×4, floor/consumers, verification env, upstream strategy, repair design) + 3 external
LLM consultants (GLM-5.2, Kimi K2.7, Mistral Medium — independent, code-grounded reviews; all
converged on the floor rule, repair placement, and versioning below; GLM additionally contributed
the fresh-path clamp (D13) and the no-delta-re-execution rule (§6.1)).

`file:line` citations were verified at v1.7.193; between 1.7.193 → 1.7.196 only the `postgres.ex`
moduledoc grew (+13 lines before the code section — code-section refs shift by that amount) and
`v149.ex`/`v150.ex` were added. The review pass re-anchors load-bearing refs to HEAD.

---

## 0. Goal and non-goals

**Goal.** Collapse versioned migrations `V01..V{floor}` (today 150 modules, 25,405 lines) into ONE
baseline module `V{floor}`, keeping `V{floor+1}..V{current}` as individual deltas, without changing
the resulting schema byte-for-byte, and without breaking any existing install — including consumer
apps' accumulated wrapper migrations. Additionally ship an idempotent, additive-only
**verify-and-repair** capability that is safe to run against a live production database: it
verifies every expected object, creates only what is missing, and reports (never fixes) anything
divergent.

**Non-goals.** No schema changes; no data conversions beyond what the chain already does; no
change to the Oban-style version-tracking mechanism (COMMENT on `{prefix}.phoenix_kit`); no
per-module migration chains (verified: feature modules have NO chains of their own — all module
DDL lives in the core chain, see §3.3); no automatic destructive repair, ever.

---

## 1. Ratified decisions (summary)

| # | Decision | Choice | Rationale ref |
|---|---|---|---|
| D1 | Floor rule | `floor = min(confirmed migrated_version across all supported installs)`; **parameterized** in tooling, fixed only at execution time. Margin below the confirmed min is false safety (it protects against nothing an unsurveyed install wouldn't also break) — the binding input is survey completeness | §4 |
| D2 | Floor candidate today | **121** (hydroforce_prod, UNCONFIRMED as of pre-2026-06-15) — the single blocking input; if prod re-confirms ≥ 135, floor = 135 | §4 |
| D3 | Skip semantics | Unchanged Oban-style comment-gated skip; existing installs ≥ floor never run the baseline | §5.2 |
| D4 | Below-floor contract (existing installs) | `0 < migrated < floor` → hard `BelowFloorError` with actionable bridge-release message, in `up/1`, `down/1`, and generator tooling | §5.2 |
| D5 | Single source of truth | One tool-generated **ExpectedSchema manifest** (every object tagged `since: version`); baseline `V{floor}.up` applies its `since ≤ floor` slice; verify/repair consume the same manifest — no second schema description can drift | §5.1, §6.1 |
| D6 | Repair placement | `PhoenixKit.Migrations.Repair` (runtime, immediate queries) + `mix phoenix_kit.repair`; NOT inside migration context; **never re-executes delta modules** (V137-dedup / V144-conditional-drop class is not additive) | §6 |
| D7 | Backfills | **Zero historical backfills in the baseline**; fresh installs seed final state directly; repair backfills only columns it itself just added, from declared defaults | §5.4 |
| D8 | Version | **2.0.0** (breaking upgrade contract + Hex `~> 1.7` resolver never auto-pulls 2.0.0 — stragglers stay safe) | §7 |
| D9 | Rollout | Last 1.7.x = frozen **bridge release**; ONE atomic squash PR (baseline + deletions + guards + clamp); 1.7.x security-only ~90 days | §7 |
| D10 | Baseline construction | Generated from a real migrated scratch DB by **incremental catalog introspection** (per-version diffs → `since` tags), emitted in `Helpers.*` idioms, hand-reviewed, verified by normalized `pg_dump` + seed-row diffs; generator is a **repeatable tool**, not a one-off | §6.3, §8.3 |
| D11 | Re-squash cadence | Institutionalized: re-run tooling when above-floor delta > ~100 versions or annually (chain grows ~16 versions/month) | §7.3 |
| D12 | Verification env | Requires an operator-provided scratch DB (options ranked §8.1); NOTHING destructive ever touches the live DB | §8 |
| D13 | Fresh-DB clamp | `initial == 0` with `opts.version < floor` → **clamp**: run the baseline (single step), do NOT raise — this is what keeps consumer repos with accumulated `v1_to_vX` wrapper histories working on fresh `mix ecto.setup` | §5.2, §5.3 |

---

## 2. Background: how the machinery works today (verified 2026-07-14 @1.7.193; line refs per header note)

- Version state = table COMMENT on `{prefix}.phoenix_kit`, read via `obj_description`
  (`postgres.ex:1360-1397`); *table exists but no comment → assumed version 1* (`:1386-1387`);
  table absent → 0. Written by `record_version/2` (`:1673-1676`) and by **every** version module
  self-stamping (150/150 currently self-stamp, incl. `v149.ex`/`v150.ex`; the multi-step
  auto-stamp at `:1633-1635` is a redundant safety net — single-step runs must self-stamp, a trap
  for future modules and load-bearing for the D13 clamp path).
- `up/1` (`postgres.ex:1315-1330`): fresh (`0`) → `change(@initial_version..target)`; behind →
  `change((migrated+1)..target)` with a `uuid_generate_v7` re-ensure when starting ≥ V40 (`:1324`);
  at/ahead → **silent no-op** (`:1327-1328`) — this is what makes consumers' accumulated wrapper
  migrations harmless on the up path.
- Dispatch is dynamic: `Module.concat([__MODULE__, "V#{pad}"]) |> apply(dir, [opts])`
  (`:1614-1616`). A missing module in the live range raises `UndefinedFunctionError` mid-run —
  this is the crash the guards/clamp must pre-empt. There is NO completeness check that every
  version in `[@initial_version, @current_version]` has a module (release_check asserts only the
  max — §5.3).
- `down/1` (`:1333-1357`) rolls `current..(target+1)` downward — stale consumer wrappers'
  `down(version: X<floor)` would dispatch into deleted modules (§5.2 down-semantics).
- `@initial_version 1` / `@current_version 150`; `@uuid_fn_version 40` (`:1302-1306`); heal
  registry `version_checks/0` has exactly one entry `{83, …}` (`:1559-1573`).
- `ensure_current/2` (`migration.ex:308-324`) re-enters `up/1` on every test boot; a raised floor
  changes it from "always heals" to "heals iff fresh or ≥ floor" — the guard's message is the only
  operator signal (`test/test_helper.exs:49`, `prefix_migration_test.exs:66-67,191`).
- Consumer surface: installer emits an **unpinned** `add_phoenix_kit_tables.exs` (targets the
  installed lib's current version at run time); `phoenix_kit.update` emits
  `*_phoenix_kit_update_vXX_to_vYY.exs` with `@disable_ddl_transaction true`, from-version taken
  from the **live DB comment** (`update.ex:415-540`); `gen.migration` takes from-version from
  **filenames** (`gen.migration.ex:58-89`) — and has a pre-existing bug: it scans for
  `create_phoenix_kit_tables` but the installer writes `add_phoenix_kit_tables` (`:83`).
- 2026-07 prefix-safety overhaul (PR #628 + #631) is load-bearing for the baseline:
  `Helpers.validate_prefix!/1`, privilege-aware `Helpers.ensure_extension!/1,2` (immediate, never
  bare `CREATE EXTENSION`), schema-qualified `Helpers.ensure_uuid_v7_function/1,2` +
  `uuid_v7_call/1`, bare index names on CREATE, schema-anchored existence checks, name-based
  `pg_constraint` JOINs instead of regclass casts in immediate checks (the V146 trap: a regclass
  cast on a missing relation poisons the whole migration transaction with 25P02).
- **In-repo repair prior art** the design builds on: `UUIDRepair` (runtime additive repairer with
  dry-run, `uuid_repair.ex`), `heal_version_comment/2` (artifact-probe → stamp, `postgres.ex:
  1517-1573`), `mix phoenix_kit.doctor` (report-only checks, PgBouncer heuristic `doctor.ex:171`),
  V141's normalize-on-every-up, and `Helpers`' dual migration/runtime variants.

## 3. Key research facts that shaped the design

1. **Churn kills frozen baselines.** 40 of 135 legacy files (~30%) were modified since 2026-06-15
   (prefix overhaul, hardened-install fixes, 3 behavioral fixes); the chain gains ~16 new versions
   per month (V149+V150 landed within two days of this spec's first draft); **five**
   version-renumber events in fork history (latest: V149→V150 on 2026-07-15, `6201b2cb`, because
   upstream took V149). ⇒ the baseline must be **regenerable by tooling** (D10, D11), and the June
   draft artifacts are stale by construction.
2. **The chain is largely idempotent already** (50 files use `create_if_not_exists`, 27 use
   `ADD COLUMN IF NOT EXISTS`, 21 seed with `ON CONFLICT`), but NOT uniformly: early-era files
   (e.g. V10) crash on re-run; **V20's `Local Storage` bucket seed has no `ON CONFLICT` and no
   unique constraint** (re-run duplicates the row); V35 seeds a role with `DO UPDATE` (an upsert).
   ⇒ repair cannot be "re-run the old chain"; it needs the manifest (D5) with per-object guards.
3. **Feature modules have no own chains.** All `phoenix_kit_cat_*`, `location_*`, `warehouse_*`,
   crm/staff/projects/... DDL lives in core versions (inventory table in
   `2026-07-14-squash-inventory.md`; V149 — catalogue sourcing-info — continues the pattern). The
   baseline generator must include module tables — the June plan's implicit "core-auth only"
   framing is wrong.
4. **Only one live consumer is local** (`/www/app`, Andi/MebelKit, verified at comment `'147'`
   with 9 schema markers consistent — no drift). 41 accumulated phoenix_kit wrapper files there
   form the consumer-side regression surface (§5.3). docker1 installs (hydroforce DEV,
   decor_3d_print = 135 @ 2026-06-15; hydroforce_prod = 121, stale) are operator-confirmed only.
5. **Nobody has done this before in this ecosystem.** Upstream has zero squash intent (issues/PRs
   searched 2026-07-14); Oban (the pattern source) has never squashed — but Oban adds ~2
   versions/year vs our ~16/month, so its do-nothing strategy does not transfer. Django's squash
   semantics (bridge release, elidable data ops, delete-later) and Rails squasher (baseline from
   real DB state) provide the transferable rules used in D9/D10.
6. **Live verification environment exists but is read-only today**: direct PG 17.4 at
   172.18.0.13:5432 reachable (creds in `.git/squash_verify.pgpass`, host field stale), client
   psql/pg_dump 17.10 ≥ server — no dump mismatch; role has NO createdb; PgBouncer at
   `pgbouncer:6432` must never carry DDL. All destructive scenarios need an operator-provided DB
   (§8.1).

---

## 4. Floor decision

**Rule (D1):** `floor = min(confirmed migrated_version across all installs the maintainer commits
to seamless upgrades for)`. **No arbitrary safety margin below the minimum**: a margin of N
versions does not protect against an unsurveyed install sitting below the margin — floor 110 and
floor 121 strand a hypothetical v90 install identically. The only real protection for stragglers
is the guard + bridge stopover (D4/D9), which works at ANY floor; the only way to avoid stranding
someone silently is to survey every supported install. Keep a small margin only on concrete
suspicion of a specific unsurveyed install.

**Data (2026-07-16):**

| install | version | as of | status |
|---|---|---|---|
| Andi/MebelKit (local) | 147 | 2026-07-14 | verified live (comment + 9 markers) |
| hydroforce DEV | 135 | 2026-06-15 | stale, likely higher |
| decor_3d_print | 135 | 2026-06-15 | stale, likely higher |
| hydroforce_prod | 121 | pre-2026-06-15 | **UNCONFIRMED — the single blocking input** |

**Floor candidates math** (repo at V150, 25,405 lines across 150 files; per-floor deleted-line
figures unchanged since v01..v147 were not touched by 1.7.194-196):

| floor | files deleted | lines deleted | delta files remaining (of 150) |
|---|---|---|---|
| 110 (June) | 110 | 19,725 | 40 |
| **121** | 121 | 21,537 | 29 |
| **135** | 135 | 23,231 | 15 |
| 147 | 147 | 25,155 | 3 |

**Action:** ask the docker1 operator for
`SELECT obj_description(to_regclass('public.phoenix_kit')::oid, 'pg_class');` on hydroforce_prod
(and refresh DEV/decor numbers) immediately before implementation. Everything in this spec is
parameterized on `floor`; no other artifact depends on the choice.

---

## 5. Design

### 5.1 Baseline module `V{floor}` — thin shell over the ExpectedSchema manifest

`lib/phoenix_kit/migrations/postgres/v{floor}.ex` (replacing the existing delta of that number —
the module name MUST stay `V{floor}` so no new version number is consumed and in-flight upstream
v151+ PRs cannot collide).

```elixir
defmodule PhoenixKit.Migrations.ExpectedSchema do
  # TOOL-GENERATED (regenerated whenever a migration is added; §8.3), hand-reviewed.
  # Ordered object manifest — the ONLY schema description in the codebase.
  # Object.t :: %{id: String.t(), since: pos_integer(),          # version that introduced it
  #               class: :extension | :function | :table | :column | :index | :constraint
  #                      | :sequence | :seed | :oban | :comment,
  #               check: {:catalog, spec} | sql,   # parameterized, schema-anchored, non-raising
  #               create: sql | {:helper, mfa},    # additive-only statement
  #               expected: map(),                 # for verify-mode catalog comparison
  #               backfill: nil | :default | {:manual, sql_text}}
  def objects(prefix) :: [Object.t()]
end

defmodule PhoenixKit.Migrations.Postgres.V{floor} do
  use Ecto.Migration
  def up(opts)    # applies ExpectedSchema slice `since <= {floor}` via queued execute/flush,
                  # class-ordered: extensions < functions < tables < columns < indexes
                  # < constraints < seeds < comment; SELF-STAMPS '{floor}'
  def down(opts)  # teardown to version 0: generated reverse-order drops of the slice
                  # + Oban.Migration.down; never drops shared extensions/public functions
end
```

Requirements distilled from the chain inventory (complete lists in the companion doc):

- **Owns V01's responsibilities**: schema existence pre-check + `CREATE SCHEMA` only when missing
  and `create_schema: true`, else operator-facing raise (V01 semantics, `v01.ex:8-28`).
- **Extensions**: `Helpers.ensure_extension!/1` for citext + pgcrypto (+ pg_trgm when floor ≥ 111
  — all candidate floors qualify). Immediate execution BEFORE queued DDL flushes.
- **Functions**: `Helpers.ensure_uuid_v7_function/1` (schema-qualified; pgcrypto-schema-resolved)
  and `extract_primary_slug()` (`v52.ex:41`, `CREATE OR REPLACE`). All defaults/calls via
  `Helpers.uuid_v7_call/1`. Keep `@uuid_fn_version 40` and the `up/1` re-ensure line — both remain
  correct with floor ≥ 40.
- **Tables/columns/indexes/sequences**: final-state shapes only (post-drop, post-rename: e.g.
  `settings.value` nullable since V12, no `db_sync_*` artifacts — 43 versions drop/rename objects;
  the generator works from migrated end-states so elided objects can never leak in). Index names
  BARE on CREATE. Per-column `ADD COLUMN IF NOT EXISTS` entries for every column of every table
  (table-level `IF NOT EXISTS` alone cannot heal column drift in repair mode).
- **Constraints**: catalog-guarded (name-based `pg_constraint` JOIN with `nspname = $1` — never
  regclass in immediate checks); in repair mode FKs added `NOT VALID` + `VALIDATE` (§6).
- **Oban**: delegate `Oban.Migration.up(prefix: prefix, create_schema: false)` exactly as V27 does
  (`v27.ex:56`); never hand-create oban tables (repair delegates too). NB: baseline output for
  Oban objects therefore depends on the host's Oban version — pin it in the verify harness (§8.2
  S16, §9).
- **Seeds (final state, from inventory)**: roles (incl. V35's SupportAgent — as plain
  `ON CONFLICT (name) DO NOTHING` in baseline; the historical `DO UPDATE` upsert is
  upgrade-semantics, wrong for repair), settings with their FINAL keys/values/module tags (e.g.
  V03 seeds carry `module='system'` directly, folding V04's retro-tag; no
  `ai_text_processing_slots` — seeded by V32, deleted by V34), currencies, payment options,
  storage dimensions, admin role permissions (ordered after roles; conditional on Admin existing),
  publishing/legal/tickets/… settings. **Fix the V20 bucket seed**: guard `Local Storage` INSERT
  with `WHERE NOT EXISTS` (no unique constraint exists to hang `ON CONFLICT` on). Email templates
  stay **best-effort optional** (V15/V31 seed via app-level seeder with rescue) — repair treats
  them as re-seedable, not as missing-object errors.
- **Self-stamps** `COMMENT ... IS '{floor}'` at the end of `up` — single-step runs get no
  auto-stamp (`postgres.ex:1633-1635`), and the D13 clamp path IS a single-step run. On a fresh
  multi-step run (`change(floor..current)`) the range-end auto-stamp then overwrites `'{floor}'`
  with `'{current}'` — correct, but subtle enough to pin with a test (§8.2 S15).
- **No historical backfills** (D7): every below-floor backfill (V08 usernames, V40/56/61/63 uuid
  fills, V47/80 JSONB wraps, V88 versions derivation, V107/114 integrations rewrite, V120
  doc-categories, V135 skills parse, …) converts pre-floor data and is definitionally dead on a
  fresh DB. They live only in the git history of the deleted files (and in the bridge release).

### 5.2 Registry changes (`postgres.ex`)

- `@initial_version {floor}`; `@current_version` unchanged (max on disk).
- **`up/1` semantics** (new cond, replacing the current 3-way):
  1. `initial > 0 and initial < @initial_version` → raise `PhoenixKit.Migrations.BelowFloorError`
     naming the DB version, the floor, and the bridge release ("upgrade to phoenix_kit {bridge}
     and run mix phoenix_kit.update first").
  2. `initial == 0` → **clamp** (D13): `change(@initial_version..max(opts.version,
     @initial_version), :up, opts)` — a stale consumer wrapper pinning `version: 27` on a fresh DB
     runs the baseline only (stamps `'{floor}'` via self-stamp); later wrappers no-op below floor
     and continue above it; the final unpinned/current wrapper completes the chain. Without the
     clamp, every consumer repo with a pinned below-floor wrapper crashes on fresh
     `mix ecto.setup` (previously: descending-range `UndefinedFunctionError`).
  3. `initial < opts.version` → deltas as today (uuid re-ensure retained).
  4. else `:ok`.
- **`down/1` semantics**: `0 < current < @initial_version` → `BelowFloorError`. Target handling:
  `target == 0` → full teardown (baseline `down` runs last); `0 < target < @initial_version` →
  **clamp target to `@initial_version`** with a logged warning (roll back deltas only, keep the
  baseline) — a stale wrapper's `down(version: 45)` then rolls back to the floor instead of
  crashing into deleted modules. Rationale: rollback of a squashed range is semantically
  "rollback to the baseline"; going lower is only meaningful as full teardown (`version: 0`).
- Moduledoc: collapse V01..V{floor-1} narrative into one baseline entry; fix the stale V27-era
  "Migration Paths" examples; keep the `⚡ LATEST` marker discipline.
- `version_checks/0`: drop the `{83, …}` entry (dead below any candidate floor). The heal
  mechanism itself stays for future above-floor entries.
- `UUIDRepair` + its `phoenix_kit.update` caller: retire (floor ≥ 40 makes it unreachable);
  its job is subsumed by `mix phoenix_kit.repair`.

### 5.3 Consumer-app compatibility (the 41-wrapper surface)

Verified semantics that MUST survive (regression tests in §8.2):

- Fresh `ecto.setup` with accumulated wrappers: the unpinned install wrapper runs first → baseline
  + deltas → comment `'{current}'`; every later `up(version: Y)` wrapper hits the `:ok` no-op arm.
  **Works with no consumer-side changes.**
- Fresh setup where the earliest surviving wrapper pins a below-floor version (install wrapper
  deleted — real consumer repos have `v1_to_v27`-style chains): **works via the D13 clamp**
  (baseline → no-ops → deltas). Acceptance test = explicit multi-wrapper replay (§8.2 S5).
- `down` into below-floor range: clamped to floor with warning; `down(version: 0)` = full
  teardown; below-floor DB state raises `BelowFloorError` (§5.2).
- `mix phoenix_kit.update`: from-version comes from the live DB comment (≥ floor after guard) —
  mechanically unaffected; add a generation-time below-floor refusal with the bridge message
  (`update.ex:428-447` area) so operators are told at generate time, not migrate time.
- `mix phoenix_kit.gen.migration`: fix the from-version filename scan to also match
  `add_phoenix_kit_tables` (pre-existing bug, `gen.migration.ex:83`); emitted `down` pins
  clamp-safe versions.
- `mix phoenix_kit.release_check`: extend check 3 with `min(vNN on disk) == @initial_version`,
  **contiguity of `{floor}..{current}`** (today NOTHING catches an accidentally-deleted delta
  file — the crash surfaces at runtime on whatever install needs it), and "baseline module
  applies the ExpectedSchema floor slice" assertions. Plus a DB-free unit test asserting every
  `n in @initial_version..@current_version` resolves to a loadable module.
- Optional post-2.0 nicety (not in scope): `mix phoenix_kit.consolidate_wrappers` collapsing a
  consumer's accumulated wrapper files into one — the clamp makes it unnecessary for correctness.

### 5.4 What is deliberately NOT carried into 2.0.0

- Historical backfills and one-off data conversions below floor (bridge release carries them).
- `UUIDRepair` module + pre-migration invocation.
- The V83 heal entry.
- Dead `describe_version_changes` hardcodes (`common.ex:323-338`) and `migration.ex` moduledoc
  `version: 2` examples — refreshed as documentation cleanup.
- Phantom `PhoenixKit.Migrations.SQLite` / `.MyXQL` references in `migration.ex:326-333` (modules
  do not exist; cosmetic cleanup, flagged for upstream).

---

## 6. Verify-and-repair

### 6.1 Architecture (D5/D6): one manifest, three consumers, no delta re-execution

Chosen over (a) comment-gated-baseline-only — fails the maintainer requirement and the historical
record (≥5 chain versions exist solely to patch drift: V57, V61, V63, V70, V129; plus the
PgBouncer-dropped-DDL and lying-comment field incidents) — and over (c) an independent
hand-maintained expected-schema — a second copy of schema truth WILL diverge across ~16 new
versions/month. The manifest is tool-generated (D10) and shared: installer and doctor cannot
disagree.

```
lib/phoenix_kit/migrations/expected_schema.ex     # tool-generated manifest (§5.1), since-tagged
lib/phoenix_kit/migrations/postgres/v{floor}.ex   # thin: applies slice since <= floor (§5.1)
lib/phoenix_kit/migrations/repair.ex              # runtime executor: verify/repair modes
lib/mix/tasks/phoenix_kit.repair.ex               # UX
```

```elixir
PhoenixKit.Migrations.Repair.verify(opts)  :: {:ok, Report.t()} | {:error, term}
PhoenixKit.Migrations.Repair.repair(opts)  :: {:ok, Report.t()} | {:error, term}
# opts: prefix:, repo:, dry_run:, adopt:, unsafe_pooled:, validate_fks: (default true)
```

```
mix phoenix_kit.repair              # verify → apply additive repairs → re-verify → report
mix phoenix_kit.repair --dry-run    # report + planned SQL only
mix phoenix_kit.repair --prefix auth | --json | --adopt | --unsafe-pooled
# exit codes: 0 clean / 1 repairs applied-or-pending / 2 report-only divergences present
```

**Scope rule (supersedes any delta re-run idea): repair applies manifest objects with
`since <= comment` only.** Objects with `since > comment` are *pending migrations* — reported
("run mix phoenix_kit.update"), never pre-applied, because deltas may carry data migrations that
must run through the chain. Delta *modules* are never re-executed by repair: the chain contains
non-additive, host-state-dependent operations (V137's dedup `DELETE`, V144's conditional
`DROP TABLE`-when-empty, V141's constraint drop-and-readd) that are chain-legal but repair-illegal.
Everything repair applies comes from the manifest's additive `create` statements — destructive
delta operations are structurally absent from the manifest (they are data ops, not objects).

Execution: validate prefix → resolve repo (direct-connection probe; §6.3) → read comment → branch
per §6.4 → for each manifest object with `since <= comment`, class-ordered: run `check`
(parameterized, schema-anchored, non-raising); missing → apply `create` via autocommit
`repo.query!` (FKs `NOT VALID` + `VALIDATE`); present → compare catalogs vs `expected` →
`Oban.Migration.up(prefix:, create_schema: false)` → final verify → comment policy (§6.4) →
`Report`.

### 6.2 Additive-only safety rules (engine-enforced, not convention)

Never: `DROP` anything, `ALTER COLUMN TYPE`, `SET/DROP NOT NULL` on pre-existing columns, UPDATE/
DELETE user data, rename, touch objects outside `phoenix_kit*`/`oban_*` in the target schema.
The manifest generator restricts `create` fields to `CREATE …` / `ALTER … ADD …` /
`INSERT … ON CONFLICT DO NOTHING` (or `WHERE NOT EXISTS`) / `COMMENT`.
Detect-and-REPORT only: wrong type/length/default, unexpected NOT NULL, same-named index or
constraint with divergent definition (`pg_indexes.indexdef` / `pg_get_constraintdef` normalized),
FK whose `VALIDATE` failed (report orphan-count diagnostic; leave `NOT VALID` — new writes are
still enforced), unknown extra `phoenix_kit_*` objects (info-level; e.g. consumer-created bridge
tables — never drop), comment/schema disagreement.
Repair-mode backfill: ONLY the declared default expression of a column repair itself just added
(PG 11+ fast-default; V40-style batched loop only for volatile defaults on huge tables).
Seeds in repair mode: `DO NOTHING` semantics strictly (never clobber operator-tuned values).

Report struct (`--json`-able, severity-ordered): per finding `{severity, class, object, status ::
:missing | :divergent | :repaired | :would_repair | :report_only | :validate_failed | :pending,
expected, actual, action_sql | nil, detail}` + `versions: %{comment, floor, code}` + summary
counts.

### 6.3 Environment rules

- Immediate `repo.query!/3` per statement, statement-at-a-time autocommit, no wrapping transaction
  (the `@disable_ddl_transaction` rationale, `update.ex:482-495`), no queued `execute` → the
  entire flush-ordering bug family is structurally absent. **No regclass casts anywhere** (V146
  lesson); every probe parameterized + schema-anchored + non-raising.
- **PgBouncer**: statement-level autocommit is pooling-tolerant, but repair still detects pooled
  connections (doctor heuristic `doctor.ex:155-174` + `pg_backend_pid()` sampling), warns,
  requires `--unsafe-pooled`, and skips `VALIDATE CONSTRAINT` + advisory locking in pooled mode.
  Recommended and documented: direct connection only (Andi runtime goes through `pgbouncer:6432` —
  repair must be pointed at 172.18.0.13:5432).
- No `CREATE INDEX CONCURRENTLY` in v1 (failure leaves an INVALID index = a drop obligation that
  violates additive-only; revisit behind a flag later).
- `pg_try_advisory_lock` for the run on direct connections; document "not concurrently with
  migrations".

### 6.4 Version-comment policy

1. **Never lower the comment.**
2. `comment >= floor`: repair heals drift within the claimed version (`since <= comment` slice);
   comment untouched; pending deltas above comment REPORTED, never executed.
3. `0 < comment < floor`: hard error, bridge message (baseline `IF NOT EXISTS` semantics cannot
   converge a pre-floor schema: renames/derivations don't replay; repair is a completeness tool,
   NOT a migration bridge — non-additive intermediates like V58 timestamptz, V74 PK promotion,
   V114 key rewrite cannot be bridged additively).
4. Comment absent/0 but `phoenix_kit*` tables exist (half-installed or adopted DB): refuse by
   default; `--adopt` force-applies the full manifest then stamps `{floor}`/`{current}` **only
   if** the final verify pass is clean (zero `:missing`, zero error-severity divergences) — a
   half-converged DB must never acquire a clean version number. NB: the legacy mapping "table
   exists, no comment → version 1" (`postgres.ex:1386-1387`) routes genuine ancient installs into
   the below-floor guard — correct.
5. Lying-comment drift (the 2026-06 renumber incident): healed naturally by rule 2 (missing
   objects for versions ≤ comment get created); verify additionally cross-checks the newest
   version's marker objects and flags "comment ahead of schema" as a warning.

---

## 7. Versioning, rollout, upstream

### 7.1 Version: 2.0.0

Breaking change to the documented upgrade contract (below-floor upgrades removed) → semver MAJOR.
Decisive mechanical argument: Hex `~> 1.7` pins auto-resolve to 1.8.0 but never to 2.0.0 — a
below-floor install with a loose pin must not be *pulled into* the squash at deploy time; 2.0.0
makes the stopover an explicit opt-in. (All three external consultants independently endorsed
2.0.0 + bridge.)

### 7.2 Sequencing

1. Freeze **bridge** = last 1.7.x tag (full V01..V{current} chain, all backfills). Documented path
   for any below-floor install: pin bridge → `mix phoenix_kit.update` → confirm `≥ floor` → move
   to `~> 2.0`.
2. **ONE atomic PR** to upstream: baseline `V{floor}` + ExpectedSchema + delete
   `v01..v{floor-1}` + `@initial_version` bump + guards/clamp + repair engine + tooling/test/docs.
   Baseline-first / delete-later (Django two-phase) is mechanically impossible here: the
   dispatcher has no `replaces` metadata, and the baseline must define the same module name as the
   existing `v{floor}.ex` — two files, one module, compile-time redefinition. Django's deployment
   safety is delivered by the bridge in TIME instead.
3. Upstream window: was verified clean on 2026-07-14 (1 open PR, zero migration files touched) —
   **re-verify at PR time** (the chain gained V149-V150 within two days; expect motion). The
   squash PR consumes NO new version number (baseline replaces `V{floor}` in place) so v151+ PRs
   merge before/after with only trivial `@current_version`/moduledoc rebases. Ask the maintainer
   to hold migration-adding merges during the review window.
4. Post-2.0.0: 1.7.x gets security-only backports ~90 days.
5. CHANGELOG/@version: normally maintainer-owned; this task is maintainer-sanctioned (same
   arrangement as the June plan).

### 7.3 Re-squash institutionalized (D11)

At ~16 new versions/month a one-shot squash decays to today's state within a year. The tooling
(§8.3) is committed to the repo (hex-excluded) and parameterized on floor; policy: re-squash when
delta > ~100 versions or annually, new floor = then-current min deployed, same bridge/guard/atomic
pattern. Subsequent floor raises under the SAME contract are minor bumps of 2.x. The ExpectedSchema
manifest is regenerated on every migration-adding release regardless (it is the repair source of
truth), so re-squash reduces to "re-slice the manifest at a new floor + delete files".

---

## 8. Verification plan (adversarial; nothing destructive near the live DB)

### 8.1 Environment — operator request (ranked)

All options on the direct 5432 endpoint. On PG 13+ citext/pgcrypto/pg_trgm are *trusted*: a DB
owner can create them without superuser.

- **(a) BEST: CREATEDB** on 172.18.0.13 for the app role (or a dedicated `pk_squash_verify`
  role): unlimited throwaway DBs, full matrix incl. clean-`public` equivalence runs AND unlocks
  `mix test.setup` (integration suite + prefix oracle).
- **(b) Fallback: three pre-created DBs owned by the role**: `pk_squash_a`, `pk_squash_b`,
  `phoenix_kit_test`. Reset via `DROP SCHEMA public CASCADE; CREATE SCHEMA public`.
- **(c) Operator-side disposable Postgres 17 container** (no docker in this container): superuser
  matrix incl. the hardened low-privilege field-report scenario — the one thing (a)/(b) can't
  test.
- **Minimum viable: (b) with just `phoenix_kit_test`** — suite + prefix oracle + scratch schemas.

### 8.2 Scenario matrix

| # | Scenario | Oracle |
|---|---|---|
| S1 | Fresh-install equivalence: NEW (baseline+deltas) vs OLD chain (bridge tag) on two clean DBs | normalized `pg_dump --schema-only` diff == empty |
| S2 | **Seed-data equivalence** (schema-only dumps miss ROWS): dump seeded tables (roles, settings, currencies, payment options, dimensions, permissions), normalized (volatile uuids/timestamps) | diff == empty |
| S3 | Existing-install upgrade: DB migrated OLD to exactly `floor` (and to `floor+k`), then NEW code `up()` | runs only deltas; final comment = current; no data loss (row-count + checksum probes) |
| S4 | Below-floor guard: DB at `floor-1` + NEW code `up`/`down`/`update`-generation | **specific `BelowFloorError`** naming bridge (assert struct/message, not just "something raised") |
| S5 | Consumer wrapper replay: (i) Andi's real 41-file set; (ii) synthetic `[up(v:27), up(v:50), up(v:120), up(v:current)]` on fresh DBs — the D13 clamp acceptance | setup completes at current; below-floor wrappers baseline-then-no-op; `down(version: 45)` clamps to floor with warning |
| S6 | Baseline `down` to 0 + re-`up` idempotency; Oban teardown via `Oban.Migration.down`; shared extensions/public functions NOT dropped | clean teardown, identical re-create |
| S7 | Repair tamper matrix: from a migrated DB, drop {table, column, index, constraint, function, seed row, sequence} one at a time → `repair` | object restored; `pg_dump` diff vs reference empty; pre-existing EXTRA objects untouched |
| S8 | Repair idempotence: healthy DB → `repair` twice | empty plan both times; byte-identical dumps |
| S9 | Repair divergence reporting: wrong column type / extra NOT NULL / same-named-different index | `:report_only`, schema untouched, exit code 2 |
| S10 | Repair data preservation: seeded + user rows survive repair (incl. operator-modified settings values NOT clobbered) | row checksums unchanged |
| S11 | Prefixed install: S1+S7 into a named schema alongside a public install (dual-install cross-leak check; `prefix_migration_test.exs` must pass unchanged — incl. in-prefix uuid function, pinned defaults, empty-search_path execution) | markers in the right schema only |
| S12 | Pooled-connection refusal: repair via pgbouncer:6432 | warns + requires `--unsafe-pooled`; VALIDATE skipped |
| S13 | `--adopt` on half-installed DB (partial baseline) | converges + stamps only on clean verify; dirty → no stamp, report |
| S14 | DB-free gates: `mix compile --warnings-as-errors`, format, credo, `release_check` (extended: floor/contiguity/manifest-freshness), unit suite incl. range-completeness test | all green |
| S15 | Stamp semantics: single-step `up(version: floor)` on fresh DB → comment `'{floor}'` (self-stamp); multi-step fresh run → `'{current}'` (range-end overwrite) | comments exactly as specified |
| S16 | Oban forward-compat: baseline's Oban objects == `Oban.Migration.up` current output for the PINNED harness Oban version; document the pin | diff == empty |
| S17 | Repair `since`-scoping: DB at comment `floor+k` missing both a `since <= floor+k` object and nothing else → healed; manifest objects with `since > comment` | absent object healed; pending versions reported, NOT applied |

Manual (operator-side, can't run under suite superuser): the 2026-07-12 hardened-install recipe
(pre-created schema, app role without CREATE, PG15+ non-writable public) — re-verify baseline +
repair against it.

### 8.3 Tooling (rewrite of `dev_docs/squash/`, all findings from the env audit)

- `generate_baseline.exs` → **rewrite as manifest generator**: current version does not compile
  (`#{p}` interpolation at `:337`), its dollar-quote splitter is broken (`$$` toggles twice), and
  its preamble regresses the 2026-07 fixes (bare `CREATE EXTENSION`, unqualified
  `uuid_generate_v7`). New generator: scratch DB → run chain **version-by-version, recording
  per-version catalog diffs** (→ `since` tags) → emit ExpectedSchema entries in `Helpers.*` idioms
  → hand review. Commit the normalized reference dump as a snapshot (ash_postgres pattern).
  DB-free staleness detector: release_check asserts a hash over `v*.ex` matches the one recorded
  in ExpectedSchema (manifest regenerated ⟺ chain changed).
- `migration_runner.ex` → keep pattern, fix CRITICAL prefix bug (`Ecto.Migrator.up` without
  `:prefix` writes bookkeeping into live `public.schema_migrations`), derive floor/current from
  `Postgres.initial_version/0`/`current_version/0`.
- `dump_helper.ex` → keep skeleton; dollar-quote-aware statement splitting, word-boundary schema
  substitution, `diff -u` via `System.cmd`.
- `verify.exs` → keep scenario structure; fix Mode A; implement S5, S7–S13, S15–S17; ensure schema
  cleanup on scenario exceptions; below-floor assertions match the specific error (the old
  harness's any-raise-passes check is exactly how a missing guard would slip through).
- Update `.git/squash_verify.pgpass` host field `172.18.0.6` → `172.18.0.13` (creds verified
  valid).

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| hydroforce_prod below assumed floor | D1: floor fixed only after operator confirmation; guard + bridge protects any surprise install |
| Baseline diverges from real chain output | Generated from a migrated DB + S1/S2 diff oracles; regenerable per release (D10) |
| `IF NOT EXISTS` name-match blindness (same-named divergent object) | verify layer compares catalog definitions; divergences are report-only (S9) |
| ExpectedSchema staleness (migration added, manifest not regenerated) | release_check hash assertion (S14); regeneration is part of the add-a-migration workflow |
| Comment lies (renumber-drift class) | repair heals under 6.4(2)/(5); marker cross-check warns |
| PgBouncer silently drops DDL | repair = autocommit statements + pooled-connection detection + `--unsafe-pooled` gate (S12) |
| Stale consumer wrappers | up-path no-op preserved + D13 clamp (S5); down-path clamp/raise; gen.migration fixes |
| Oban version coupling (baseline delegates live) | pin Oban version in verify harness; S16 asserts equivalence; document host-Oban implications |
| Upstream lands v151+ mid-review | baseline consumes no new number; disjoint hunks; hold-window agreed with maintainer (5 renumber events say: expect contention, design already avoids it) |
| Below-floor test/CI DBs (long-lived) break on `ensure_current` | guard raises with actionable message; docs updated |
| Manifest executor is novel machinery | de-scoping lever: if review rejects it, fall back to imperative baseline + verify-probes-only (drops auto-repair to report-only); the contracts (§6.2/6.4) survive either way |
| Baseline `down/1` semantics surprise | explicit: `down` to 0 only; below-floor targets clamp-with-warning (S4/S5/S6) |

## 10. Open questions for the operator (block implementation, not review)

1. **hydroforce_prod current version** (+ refresh DEV/decor numbers) → fixes `floor` (D2).
2. **Scratch-DB option** (§8.1 a/b/c) — which will be provided? ("ещё одна база в контейнере" —
   recommend (a) CREATEDB or (b) three owned DBs).
3. Confirm 2.0.0 + bridge-release policy (~90-day security window on 1.7.x).
4. Repair v1 scope sign-off: FK `VALIDATE` on by default? `--adopt` in v1 or deferred?
5. Timing of the upstream hold-window ask.

## 11. Implementation phases (after spec sign-off — NOT part of this task)

1. **P0 — prerequisites**: floor confirmation; scratch DB; pgpass host fix.
2. **P1 — tooling**: rewrite generator (manifest emission + `since` tagging), runner/dump/verify
   harness (§8.3); prove S1/S2 oracles on the OLD chain alone (self-diff == empty).
3. **P2 — baseline**: generate ExpectedSchema at `{current}`; slice at `floor` → `V{floor}`;
   hand-review against inventory doc (seeds/drops/hazards); registry changes + guards/clamp
   (§5.2); consumer tooling fixes (§5.3).
4. **P3 — repair**: executor + mix task + report (§6); doctor wiring.
5. **P4 — verification**: full S1–S17 matrix; fix; re-run to green.
6. **P5 — release**: tests/CHANGELOG/version (maintainer-sanctioned); atomic upstream PR; bridge
   tag; docs (upgrade guide + re-squash runbook).

Estimated diff: −{19,725…23,231} lines of migrations, +1 thin baseline + ExpectedSchema manifest
(~2-4k combined), +repair engine (~1k), +tooling/tests. Net repo shrink ≈ 16-20k lines.
