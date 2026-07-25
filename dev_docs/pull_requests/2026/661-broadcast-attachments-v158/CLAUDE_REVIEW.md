# PR #661 — V158: broadcast attachments column (accumulator)

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-25
**Verdict:** ✅ APPROVE — already merged; no bugs found. Three improvements applied post-merge.

---

## Summary

Opens V158 as the new accumulator (V157 shipped in 1.7.210) with a single
section: `attachments JSONB NOT NULL DEFAULT '[]'::jsonb` on
`phoenix_kit_newsletters_broadcasts`, an ordered list of Storage file uuids to
attach to every email of a broadcast, plus a
`phoenix_kit_newsletters_broadcasts_attachments_is_array` CHECK
(`jsonb_typeof(attachments) = 'array'`) as the DB-level shape backstop.

Soft references (no FK into `phoenix_kit_files`), matching this table's
`crm_list_uuid` (V152) / `source_params` (V155) precedent. Element-level
validation (uuid-ness, count cap) is deliberately left to the `Broadcast`
changeset in the `phoenix_kit_newsletters` package — companion PR to follow
there.

## Files changed (3)

| File | Change |
|---|---|
| `lib/phoenix_kit/migrations/postgres.ex` | +11/−2 — moduledoc V158 entry, `⚡ LATEST` moved off V157, `@current_version` → 158 |
| `lib/phoenix_kit/migrations/postgres/v158.ex` | +75 — new migration |
| `test/phoenix_kit/migrations/v158_test.exs` | +72 — new suite (shape pins, CHECK rejection, ordered round-trip, version marker) |

## Verification performed

- **Version wiring.** `@current_version` is `158`; `@initial_version` unchanged.
  There is no static registry to update — `execute_migration_steps/4` resolves
  modules dynamically (`Module.concat([__MODULE__, "V#{pad_idx}"])`,
  `postgres.ex:1721`), so the new file is picked up by existence alone. Grepped
  for a version→description map in `phoenix_kit.status` / `.update` /
  `.release_check` / `migration.ex` — none exists. `⚡ LATEST` occurs exactly
  once in the moduledoc, on V158.
- **The target table is core, not module-owned.** `phoenix_kit_newsletters_broadcasts`
  is created by V79 (`v79.ex:80`), so the `ALTER TABLE` is guaranteed a target on
  every install — this is not a case of core reaching into a feature package's
  table. `phoenix_kit_files` / `uuid` confirmed as the referent
  (`lib/modules/storage/schemas/file.ex:125`), so the moduledoc's claim is accurate.
- **The test's bare `INSERT (subject, attachments)` actually satisfies the table.**
  Traced every remaining NOT NULL column on `phoenix_kit_newsletters_broadcasts`:
  `uuid` (DEFAULT `uuid_generate_v7()`), `subject` (supplied), `status`,
  `total_recipients`/`sent_count`/`delivered_count`/`opened_count`/`bounced_count`,
  `inserted_at`/`updated_at` (all defaulted), `source_type` (V152, NOT NULL
  DEFAULT `'newsletters_list'`). The one that would have broken it —
  `list_uuid UUID NOT NULL` from V79 — was dropped by V156, so the insert is
  clean. Worth stating explicitly because the CHECK-rejection test asserts on the
  error *message*: had `list_uuid` still been NOT NULL, that test would have
  failed loudly rather than passing for the wrong reason.
- **Prefix safety.** Every statement targets a prefix-qualified table
  (`#{p}phoenix_kit_newsletters_broadcasts`); the constraint name is left bare on
  `ADD CONSTRAINT` (correct — a constraint lands in its table's namespace) and is
  only referenced via `DROP CONSTRAINT IF EXISTS` on an already-qualified table.
  No `information_schema` / `pg_constraint` / `pg_indexes` existence check is used
  at all, so none of the unanchored-check regressions AGENTS.md documents apply
  here, and there is no `regclass` cast to abort the transaction on a fresh chain.
  Constraint name is 55 chars — under Postgres' 63-char identifier limit, so no
  silent truncation to collide with a future `..._attachments_*` constraint.
- **Idempotency.** `ADD COLUMN IF NOT EXISTS`, then `DROP CONSTRAINT IF EXISTS`
  before an unconditional `ADD CONSTRAINT` — the same replace-in-place shape V155
  uses for `..._recipient_check`, and correct here for the same reason: a re-run
  must re-apply the definition, not skip it. Matters because `ensure_current/2`
  re-runs the chain on every test boot. `down/1` unwinds in reverse and both ends
  rewrite the `phoenix_kit` table comment (158 / 157).
- **Ordering claim.** The moduledoc rests on JSONB preserving array element
  order. That is correct — `jsonb` normalizes and deduplicates *object keys*
  only; array element order is preserved verbatim. The round-trip test pins it.
- **`RepoHelper` vs `Test.Repo` in the test.** V158Test aliases
  `PhoenixKit.RepoHelper` where V155/V156Test alias `PhoenixKit.Test.Repo`.
  Harmless: `RepoHelper.query!/3` (`repo_helper.ex:136`) delegates to
  `repo()`, which resolves to `PhoenixKit.Test.Repo` under `config/test.exs` —
  the same sandbox-owned connection. Not flagged as a finding.

## Findings

### IMPROVEMENT - MEDIUM — test's `column/2` lookup was not anchored to a schema (fixed)

`test/phoenix_kit/migrations/v158_test.exs` queried
`information_schema.columns WHERE table_name = $1 AND column_name = $2` with no
`table_schema` predicate. `test/integration/prefix_migration_test.exs` runs the
entire chain into a scratch schema (`pk_prefix_migration_test`) on this same
database, which creates a *second*
`phoenix_kit_newsletters_broadcasts.attachments`. It drops the schema both
up-front and in `on_exit`, so the two rows can only coexist after an interrupted
or crashed run — but when they do, `column/2`'s `case rows do [[...]] | [] end`
has no matching clause and the suite fails with a `CaseClauseError` that points
nowhere near the cause. This is the same class AGENTS.md calls out for migration
SQL ("Every existence check needs a schema anchor"), just on the test side.

**Fixed:** added `table_schema = 'public'` plus a comment naming the reason.

Every sibling migration test (`v112`, `v113`, `v125`, `v145`, `v152`, `v155`,
`v156`, `v107`) carries the same unanchored helper. Deliberately **not** swept —
out of this PR's scope; worth folding into a future test-hygiene pass.

### IMPROVEMENT - MEDIUM — CHECK coverage tested for one of five rejected shapes (fixed)

`jsonb_typeof` returns one of six values; the CHECK admits `'array'` and rejects
the other five, but the suite only exercised `object`. The shape most likely to
arrive from a real writer bug is a bare **scalar** — a caller storing a single
uuid without wrapping it in a list — and nothing pinned that the constraint
catches it.

**Fixed:** added a second rejection test inserting `'"019f...0001"'::jsonb`.

### IMPROVEMENT - MEDIUM — the CHECK does not constrain element type (not fixed, deliberately)

`jsonb_typeof(attachments) = 'array'` accepts `[1, {"a": 1}, null]` — anything
array-shaped. A stricter DB backstop is expressible (e.g. a
`jsonb_array_elements` + uuid-cast subquery in the CHECK, or a length cap).

**Not applied.** Tightening it would (a) duplicate a contract the moduledoc
explicitly assigns to the newsletters-side `Broadcast` changeset, (b) put a
per-row cast in a CHECK that fires on every write, and (c) break the precedent
V155 set for `source_params` and V152 set for `source_type`, both of which leave
content validation entirely to Ecto and take no DB CHECK on their contents. The
array-shape backstop is the right depth for this chain's conventions: it stops
the only failure that would crash *every* reader, and leaves the rest to the
writer. Recorded so the limitation is on the record rather than assumed away —
readers of this column must still tolerate a non-uuid element.

### NITPICK — moduledoc had no `## down/1` section (fixed)

V155 and V156 both close with an explicit rollback-semantics section; V158 had
none, which matters more than usual here because the writer ships in a separate
package on its own release cycle. **Fixed:** added a `## down/1` section stating
the loss is an editor selection (not delivery history, so unlike V155's
`crm_contact_uuid` it does not outlive the column) and repeating V155's
roll-back-both-together rule.

### NITPICK — the CHECK is added as validating, not `NOT VALID` (not fixed)

`ADD CONSTRAINT ... CHECK` takes an `ACCESS EXCLUSIVE` lock and scans the table.
Here every row was just backfilled to the constant `'[]'` by the preceding `ADD
COLUMN ... DEFAULT`, so the scan can only succeed — and `phoenix_kit_newsletters_broadcasts`
holds one row per broadcast (single digits to low hundreds in practice), so the
lock window is negligible. Noted only so the pattern isn't copied onto a
high-cardinality table later without the `NOT VALID` + `VALIDATE CONSTRAINT`
split.

## Not run

`mix test` was not run — per this repo's convention core is not
standalone-testable in this environment (no `psql`/PostgreSQL client present, so
`:integration` tests, which is all of `v158_test.exs`, are auto-excluded). The
gate is `mix precommit`; see below. The test edits are additive and mirror
assertions already proven by the author's run (160 tests, 0 failures).

## Gate

`mix precommit` (format + compile --warnings-as-errors + credo --strict +
dialyzer) — clean.
