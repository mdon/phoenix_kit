# PR #533 Review — V112: phoenix_kit_projects schema evolution

**Branch:** `mdon/dev` → `dev`
**Merge commit:** `76f3f060`
**Reviewer:** Claude (Opus 4.7 1M)
**Date:** 2026-05-11
**Scope:** 4 files, +415 / −38

Skills consulted: `elixir:using-elixir-skills`, `elixir:ecto-thinking`.

---

## Follow-up status (2026-05-11, post-review)

Working-tree fixes landed on top of `dev` after review (not yet committed):

| # | Item | Status | Where |
|---|------|--------|-------|
| BUG-1 | Visible-index predicate doc/code mismatch | **Fixed** (docs → match code) | `postgres.ex` moduledoc |
| BUG-2 | `down/1` rollback unsafe on duplicate names | **Fixed** (reorder: indexes restored first) | `v112.ex` `down/1` |
| IMP-3 | No `v112_test.exs` | **Fixed** (new file, mirrors V107Test) | `test/phoenix_kit/migrations/v112_test.exs` |
| IMP-4 | `v106_test.exs` testing post-V112 state | **Fixed** (moved post-V112 assertions to V112Test, kept V106-specific down/1 pre-check) | `v106_test.exs` |
| IMP-7 | `schema_for/1` inconsistency between `up/1` and `down/1` | **Fixed** | `v112.ex` `up/1` |
| IMP-5 | `position` has no scope-aware index | **Deferred** — not urgent at current scale; flag for next index sweep | — |
| IMP-6 | `backfill_archived_at` lacks `status` column guard | **Skipped** — V101 always creates `status`; can't-happen scenario | — |
| NIT-8 | `scheduled_start_date` name now lies | **Skipped** — author explicitly accepted the lie-vs-churn tradeoff in V112 moduledoc | — |
| NIT-9 | `multilang_form` `w-full` is silent visual change | **Outstanding** — needs `rg '<\.translatable_field' lib/` audit; out of scope for this PR | — |
| NIT-10 | SQL string-interpolation of `schema` into `information_schema` | **Project-wide convention** — not introduced by V112, no action | — |

Verification: `mix precommit` clean on the four touched files (format, compile-warnings-as-errors, credo --strict 7292 mods/funs no issues, dialyzer no new entries).

The new `v112_test.exs` pins the visible-index predicate shape with `assert indexdef =~ "WHERE (archived_at IS NULL)"` AND `refute indexdef =~ "is_template"` — closing the docs-drift loop that produced BUG-1.

---

## Summary

V112 is a five-step schema evolution on `phoenix_kit_projects*` (archived_at, translations JSONB, drop name-uniqueness, retype scheduled_start_date, position) plus the migrator `@current_version` bump that actually makes V112 apply. The migration shape is reasonable — DO-block guards for idempotence, `down/1` reverses each step, partial index on the visible set. Touched files compile clean, credo passes, dialyzer not asserted but no surface red flags.

Findings below are ordered by severity. The two BUG items + the two MEDIUM improvements have been addressed in the working tree (see Follow-up status table above).

---

## BUG-1 — MEDIUM: Visible-index predicate mismatch between docs and code  ✅ FIXED (docs)

The PR description AND the migrator moduledoc in `lib/phoenix_kit/migrations/postgres.ex:536` both promise:

> Visible-set partial index keeps the list query fast (`WHERE archived_at IS NULL AND is_template = false`).

The actual index emitted by `create_visible_index/2` (`lib/phoenix_kit/migrations/postgres/v112.ex:209-211`) is:

```sql
CREATE INDEX phoenix_kit_projects_visible_idx
  ON #{p}phoenix_kit_projects (inserted_at DESC)
  WHERE archived_at IS NULL;
```

No `is_template = false` clause. So either:

1. **The docs are stale** — the index is intentionally broader (covers visible projects *and* templates) and the moduledoc / PR description should be corrected. This is the path of least resistance.
2. **The code is incomplete** — the visible/template dashboards are split (per the moduledoc on `position`: "the LV sorts within `is_template = false` for the project list, `is_template = true` for the template list"), so a single broader index serves neither query as efficiently as two scope-specific partials. If that's the intended design, the predicate should be tightened (and arguably a sibling `phoenix_kit_templates_visible_idx` added for `WHERE archived_at IS NULL AND is_template = true`).

Either way: docs and code currently disagree, and the discrepancy hides a real design question (one shared partial vs. two scoped partials). Pick a direction in a follow-up.

**Suggested fix (path 1):** update both occurrences of the predicate claim in `postgres.ex:536` and the PR description.
**Suggested fix (path 2):** see "Position has no scope-aware index" below — solve both at once with `(is_template, position, inserted_at DESC) WHERE archived_at IS NULL` or two partial indexes.

---

## BUG-2 — MEDIUM: `down/1` will fail on rollback if post-V112 duplicate names exist  ✅ FIXED

**Resolution:** `down/1` now restores the V105/V101 unique indexes FIRST, before any `DROP COLUMN`. A duplicate-name conflict at rollback now aborts cleanly with all V112 columns intact — the operator can dedupe and re-run rather than face a half-rolled schema. Comment in the migration explains the ordering invariant.

`down/1` restores the V105/V101 unique indexes with plain `CREATE UNIQUE INDEX IF NOT EXISTS` (`v112.ex:146-161`). The whole point of V112's drop is that users can now create duplicate names. So:

1. V112 applies, users create two projects named "Onboarding" (one of V112's stated goals).
2. Operator runs `down(112)` to roll back.
3. `CREATE UNIQUE INDEX … ON phoenix_kit_projects (lower(name)) WHERE is_template = false` aborts with `could not create unique index … contains duplicate values`.
4. The migration leaves the schema half-rolled (positions and translations columns already dropped, but archived_at still present because the unique-index CREATE was after archived_at's DROP in the down order).

The PR's framing — "rollback is a throw-away-post-V112-work operation" — implicitly accepts this, but the failure mode is worse than a data loss: it's a *partial rollback* that needs manual schema repair.

**Suggested fix:** before each `CREATE UNIQUE INDEX` in `down/1`, dedupe the conflicting rows (e.g. `DELETE FROM phoenix_kit_projects p1 USING phoenix_kit_projects p2 WHERE p1.uuid > p2.uuid AND lower(p1.name) = lower(p2.name) AND p1.is_template = p2.is_template`) — or accept the failure mode and document it explicitly with a `RAISE NOTICE` so the operator sees what happened. At minimum, reorder `down/1` so all `DROP COLUMN`s happen *after* the `CREATE UNIQUE INDEX`es succeed.

---

## IMP-3 — MEDIUM: No `v112_test.exs`  ✅ FIXED

**Resolution:** New `test/phoenix_kit/migrations/v112_test.exs` mirrors V107Test's shape. Pins each of the five V112 additions (archived_at column + nullability + type, visible-index existence AND predicate shape, translations JSONB on all three tables, scheduled_start_date retype, position on both tables) plus the four index-drop assertions and duplicate-name behavior tests.

`test/phoenix_kit/migrations/` ships `v106_test.exs` and `v107_test.exs` but no V112 test. The PR description points at the V106Test rewrites as evidence the new schema state is asserted, but that's testing *V106's deltas survived V112*, not *V112's own additions*. V112 adds five distinct things; none are pinned by a dedicated test:

- `archived_at` column exists, type `timestamp(0)`, nullable
- `translations` JSONB on all three tables, NOT NULL DEFAULT '{}'
- `scheduled_start_date` is now `timestamp(0)`, not `date`
- `position` column exists with NOT NULL DEFAULT 0
- Visible partial index exists with the right predicate (would have caught the discrepancy in BUG #1 above)
- Backfill: a pre-existing `status='archived'` row gets `archived_at` populated

Add `test/phoenix_kit/migrations/v112_test.exs` mirroring the V106Test shape. The visible-index assertion alone would have caught the predicate mismatch at PR time.

---

## IMP-4 — MEDIUM: V106Test file now tests post-V112 reality under V106's name  ✅ FIXED

**Resolution:** Removed the "schema state (verified at boot)" describe block from `v106_test.exs` (those assertions moved to `v112_test.exs` where they belong). V106Test's moduledoc updated to reflect that it now covers only V106's down/1 cross-mode duplicate pre-check — the file/contents now match.

`v106_test.exs` has been rewritten so every "schema state (verified at boot)" assertion now pins V112's drops rather than V106's adds. The intent is documented in the comments, but the filename and `describe` blocks are now misleading — a reader looking for "what did V106 introduce?" finds tests that prove V106's indexes *don't exist*.

Two cleaner options:

1. **Rename + restructure**: move the post-V112 schema-state suite to `projects_name_uniqueness_test.exs` (or fold it into a new `v112_test.exs`), and either drop `v106_test.exs` entirely or shrink it to the "V106's `up/1` was idempotent at the time" assertions that don't depend on V112.
2. **Test V106 in isolation**: run `V106.up` against a clean DB in setup, assert V106-era state, tear down. Then V112's effects belong in `v112_test.exs`. This is what `v106_test.exs`'s name promises.

Right now the file's contract ("tests V106") and contents ("asserts V112 removed V106's indexes") don't match. Future maintainers will be confused.

---

## IMP-5 — LOW: `phoenix_kit_projects.position` has no scope-aware index  ⏸ DEFERRED

Not urgent at current scale; flag for the next index sweep.

`position` is shared between projects (`is_template = false`) and templates (`is_template = true`) via application convention only. The two LV views sort by `position` scoped by `is_template`. A query of the form

```sql
SELECT … FROM phoenix_kit_projects WHERE is_template = false AND archived_at IS NULL ORDER BY position
```

doesn't have a supporting index. Once these tables grow, that's a sort on the heap. Worth either:

- A composite `(is_template, position)` index, or
- Tightening the visible partial index from BUG #1 to `(is_template, position, inserted_at DESC) WHERE archived_at IS NULL` — covers the dashboard sort and the visible filter in one shot.

Not urgent for current scale; flag for the next index sweep.

---

## IMP-6 — LOW: `backfill_archived_at/1` doesn't guard against missing `status` column  ⏭ SKIPPED

V101 always creates the `status` column on `phoenix_kit_projects` (verified: `lib/phoenix_kit/migrations/postgres/v101.ex:54-72`), so the missing-column scenario can't happen in normal migration flow. Per project guideline "don't validate scenarios that can't happen," the guard would be over-engineering. If a future migration ever drops `status` before V112, revisit.

`backfill_archived_at/1` (`v112.ex:181-188`) issues an unconditional `UPDATE … WHERE status = 'archived'`. Every other DDL helper in this file wraps with a `DO $$ … IF EXISTS / IF NOT EXISTS` guard for idempotence. The backfill is the lone exception — if a deployment somehow lacks the `status` column (e.g. partial migration history, hand-rolled schema), the UPDATE crashes with `column "status" does not exist` and the whole migration aborts mid-way.

Add the same guard pattern:

```sql
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM information_schema.columns
    WHERE table_schema = '#{schema}'
      AND table_name = 'phoenix_kit_projects'
      AND column_name = 'status'
  ) THEN
    UPDATE … WHERE status = 'archived' AND archived_at IS NULL;
  END IF;
END $$;
```

---

## IMP-7 — LOW: Inconsistent `schema` derivation between `up/1` and `down/1`  ✅ FIXED

`up/1` now calls `schema = schema_for(prefix)`, matching `down/1`.

`up/1` inlines `schema = if prefix == "public", do: "public", else: prefix` (`v112.ex:110`).
`down/1` calls `schema_for(prefix)` (`v112.ex:132`).

Both produce the same value. Pick one — `schema_for/1` already exists and is the cleaner shape. Replace the inline conditional with `schema = schema_for(prefix)`.

---

## NIT-8 — NITPICK: `scheduled_start_date` column name now lies about its type  ⏭ SKIPPED

Author explicitly accepted the lie-vs-churn tradeoff in the V112 moduledoc ("Lying name + honest type beats a churn pass"). No action.

The moduledoc self-acknowledges: "Lying name + honest type beats a churn pass; future cleanup can rename when a larger refactor is on the table." Fine — but worth a `# TODO` inline near the column to surface the debt to the next reader. Right now the rationale is buried in the V112 moduledoc; six months from now nobody reads that file unless the migration changes.

---

## NIT-9 — NITPICK: `multilang_form.ex` `w-full` is a silent visual change for every consumer  ⏳ OUTSTANDING

Quick `rg '<\.translatable_field' lib/` audit of existing call sites still owed. Out of scope for the V112 review-followup commits; flag for the maintainer.

`<.translatable_field>` now bakes `w-full` into the base class for both `input` and `textarea` (`multilang_form.ex:817-819`). Justified for the projects-module form that triggered this PR, but every other existing consumer of `<.translatable_field>` will silently grow to `width: 100%` of its parent. Likely fine — the wrapper change to `flex flex-col` constrains the layout — but the PR doesn't enumerate the call sites. Quick `rg '<\.translatable_field' lib/ ` to confirm no other consumer relied on intrinsic width would close this loop.

---

## NIT-10 — NITPICK: SQL string interpolation of `schema` into `information_schema` queries  ⏭ SKIPPED (project-wide)

Pattern like `WHERE table_schema = '#{schema}'` (`v112.ex:172`, repeated in five helpers) is safe only because `prefix` comes from migrator config, not user input. Same pattern is used elsewhere in `lib/phoenix_kit/migrations/postgres/`, so this isn't introduced by V112. Worth noting as a project-wide convention rather than a V112 issue: if `prefix` ever becomes user-controllable (e.g. a multi-tenant setup that names schemas from request input), every migration file becomes an injection vector.

No action required for this PR.

---

## Things done well

- **Idempotent everywhere it matters.** All DDL is wrapped in `DO $$ IF [NOT] EXISTS … $$` blocks. Re-running V112 on a post-V112 DB is a no-op.
- **Backfill ordering.** `backfill_archived_at` runs *before* `create_visible_index`, so the partial index is built against correct data — not against a state where every row qualifies as visible and then gets re-filtered.
- **Comment-density on the non-obvious bits.** The moduledoc explains *why* `status` is kept (future workflow concept), *why* `scheduled_start_date` isn't renamed (churn cost), and *why* `down/1` restores the dropped indexes (round-trip invariant). This is the right level of comment density for a migration file.
- **Translations storage shape.** Primary in dedicated columns, non-primary in JSONB. Matches the existing `<.translatable_field>` settings-translations pattern — no new convention to learn.
- **Migrator version bump is in the same PR as the V112 file.** PR description correctly notes the prior state ("V112 was dead code, capped at V111") and the bump that fixes it. Avoiding a "code shipped, version forgot to bump" decoupling.

---

## Follow-up actually landed

Working-tree diff (not yet committed) covers four files:

```
 lib/phoenix_kit/migrations/postgres.ex      |   7 +-
 lib/phoenix_kit/migrations/postgres/v112.ex |  44 ++++++-----
 test/phoenix_kit/migrations/v106_test.exs   | 110 +++-------------------------
 test/phoenix_kit/migrations/v112_test.exs   | 220 +++++++++++++++++++++++++++  (new)
```

- BUG-1 → docs in `postgres.ex` aligned to actual emitted predicate.
- BUG-2 → `down/1` reordered: `CREATE UNIQUE INDEX` calls now happen before any `DROP COLUMN`, so a duplicate-name conflict aborts cleanly with all V112 columns intact.
- IMP-3 → `v112_test.exs` pins every V112 addition, including a regression test against the BUG-1 docs-drift (asserts the predicate is exactly `archived_at IS NULL`, refutes any `is_template` mention).
- IMP-4 → `v106_test.exs` moduledoc + body now scoped to V106's down/1 pre-check (post-V112 schema assertions migrated to V112Test).
- IMP-7 → `up/1` uses `schema_for(prefix)` for consistency with `down/1`.

Skipped or deferred items (IMP-5, IMP-6, NIT-8, NIT-10) annotated inline above with rationale. NIT-9 (multilang_form `w-full` audit) remains open and is the only worthwhile follow-up item left.
