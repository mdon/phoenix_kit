# CLAUDE_REVIEW.md — PR #755: Add doctor check for belongs_to relations with no database FK

- **Author:** timujinne
- **Merge commit:** 8a6abee1 (base 92f866d0, tip 2ae58f22 — 2 commits,
  including a post-review round already folded in before merge: `2ae58f22`
  "Fix check 13's zero-coverage PASS, wrong-target FKs, and query crashes")
- **Scope:** New `mix phoenix_kit.doctor` check #13,
  `check_schema_declared_relations_without_fk/1`. Check 12
  (`check_orphaned_fk_refs/1`, from #751) only ever examines a relationship
  that already has a declared DB foreign key constraint — its own moduledoc
  names that boundary explicitly. This check is the complement: it walks
  every `belongs_to` PhoenixKit's own Ecto schemas declare (via
  `:application.get_key(:phoenix_kit, :modules)`, `__schema__(:associations)`
  + `Ecto.Association.BelongsTo` filter), cross-references the (table,
  column, referenced-table) triple against `pg_constraint`, and reports the
  count with no matching FK — advisory (`:warn`, never `:fail`), since a
  federated/soft reference across an optional module boundary (V179/V180)
  legitimately can't carry a real FK. Found two real, still-open gaps on a
  live install: `phoenix_kit_activities.actor_uuid` and `.target_uuid`.

## Verification performed

- Read the full diff with surrounding context —
  `check_schema_declared_relations_without_fk/1`,
  `discover_schema_declared_relations_without_fk/2`,
  `belongs_to_owner_columns/1` — and the moduledoc renumbering (checks
  13–27) for off-by-one errors against the actual `run_check(...)` list
  order; confirmed they match exactly.
- Checked the two-query catalog scan: the FK-side query joins `pg_class` /
  `pg_namespace` / `pg_attribute` for single-column (`array_length(c.conkey,
  1) = 1`) FKs only, matched as a `(table, column, ref_table)` triple — not
  `(table, column)` alone, so a real FK on the right column pointing at the
  *wrong* table still counts as "missing its declared relation." Confirmed
  this triple-match is what the merged-in fixup commit (`2ae58f22`) added;
  the destructive test `discover_schema_declared_relations_without_fk/2 —
  I082, second step (destructive)` proves it live (adds a real FK to the
  wrong table, asserts the finding survives).
- Checked the coverage-accounting: `total_candidates` is every `belongs_to`
  owner_key that exists as a REAL column in this schema (via
  `information_schema.columns`), not just constraint membership — so an
  empty/wrong `--prefix` reports `{0, []}` (`:warn`, "coverage is zero, not
  the same as clean"), never a false `:pass`. Confirmed by the merged-in
  fixup and its dedicated tests (`a genuinely wrong schema name reports zero
  candidates, not an error` / `... is :warn naming zero coverage, never
  :pass`).
- Checked the `Code.ensure_loaded?/1` fix ahead of `function_exported?/3` in
  `discover_schema_declared_relations_without_fk/2`'s module filter — without
  it, an unloaded schema module reads `function_exported?` false even though
  it would load and export fine one line later, silently dropping it from
  candidates. Confirmed present.
- Checked SQL-interpolation style (`escaped_prefix = String.replace(prefix,
  "'", "\\'")`) against the rest of the file — same idiom used throughout
  (`grep` confirms 8+ existing call sites), not a new inconsistency; `prefix`
  is an operator-supplied `--prefix` CLI value on a local diagnostic task,
  not attacker input.
- Ran the full new/moved test suite: the non-destructive
  `discover_schema_declared_relations_without_fk/2` and
  `check_schema_declared_relations_without_fk/1` tests in
  `phoenix_kit_doctor_orphaned_fk_test.exs`, and the destructive
  proof-by-mutation tests (real `ALTER TABLE ... ADD CONSTRAINT`) split into
  the new `async: false`
  `phoenix_kit_doctor_orphaned_fk_destructive_test.exs` — confirmed the
  `async: false` split is warranted (moduledoc explains a real
  `ShareRowExclusiveLock` deadlock risk against other async tests writing to
  `phoenix_kit_users`) and structurally sound (ExUnit runs every `async:
  false` module only after all `async: true` ones finish).

## Findings

None new. The PR's own history already found and fixed the two real defects
a naive first pass would have (zero-coverage false `:pass`, wrong-target FK
silencing a real gap) in the pre-merge fixup commit `2ae58f22` — confirmed
those fixes are correctly in place and covered by dedicated regression
tests, not just claimed in the commit message.

One environment note, not a code defect: the destructive test
`an orphaned phoenix_kit_user_oauth_providers.user_uuid row is reported, not
read as clean` (`DISABLE TRIGGER ALL`) fails on this sandbox DB — no
superuser/CREATEDB available here, tracked separately in
[[project_sandbox_test_db_no_superuser]]. Pre-existing (same limitation
affects PR #751's tests, per that memory), not something #755 introduced or
should have avoided.

## Gate

`mix precommit` and `mix test` (4092 tests + 43 doctests) — clean except the
one environment-only failure above.
