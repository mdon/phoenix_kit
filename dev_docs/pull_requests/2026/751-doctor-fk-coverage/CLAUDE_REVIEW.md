# CLAUDE_REVIEW.md — PR #751: Doctor's orphaned-FK check now covers every foreign key, not four of seventy

- **Author:** timujinne
- **Merge commit:** a18ebb90 (base 84258cb2, tip fbfaa2ad — several commits, including
  multiple post-review rounds already folded in before merge)
- **Scope:** `mix phoenix_kit.doctor`'s orphaned-FK check (`check_orphaned_fk_refs/1`)
  moved from a hardcoded 4-pair list to discovering every single-column FK constraint
  straight from `pg_constraint`. Adds coverage accounting to every report line
  ("checked N of M"), a per-probe timeout with two verified DBConnection/Postgrex
  timeout shapes both normalized to "time limit exceeded", a new `:existing_orphan`
  classification for orphans behind an already-VALID constraint (previously silently
  discarded by the generic catch-all), a `:warn` tier for probe-failure-only results
  (previously the same `:fail` red as confirmed data damage), and explicit multi-column
  FK exclusion (reported as "not supported by this check", never miscounted as clean or
  as a generic probe failure).

## Verification performed

- Read the full diff (`lib/mix/tasks/phoenix_kit.doctor.ex`, 500-line change) with
  surrounding context, not just the hunks — traced every `classify_fk_check/5` and
  `report_orphaned_fk_refs/4` clause for exhaustiveness against the tuple shapes
  `probe_fk/4` can actually produce.
- Checked the coverage-accounting arithmetic: `total = length(constraints) +
  length(skipped_multi)`; `covered = total - length(probe_failed)` where
  `probe_failed` already has the multi-column entries folded in. Confirmed `orphaned`
  and `not_validated` are both subsets of the successfully-probed set, so "no orphaned
  rows among the N successfully checked" in the probe-failure warn path is accurate.
- Checked `retry_suggestion/2`'s discrimination between a genuine probe failure
  (`elem(entry, 3) in [:orphan_count, :validation_state]`) and a composite-FK exclusion
  (`elem(entry, 3) == :multi_column`, which no re-run can ever resolve) — correct against
  all three `probe_failed` tuple shapes.
- Checked the raw SQL in `discover_fk_constraints/2` and `fk_probe_cost_context/4`:
  `escaped_prefix` is single-quote-escaped before interpolation (same pattern the file
  already used pre-PR); `table`/`fk_col`/`ref_table`/`ref_col` values interpolated into
  `probe_fk/4`'s query come from `pg_class`/`pg_attribute`, i.e. real existing catalog
  identifiers, not attacker input — no new injection surface versus the code this
  replaces. `fk_probe_cost_context/4`'s query is fully parameterized (`$1`/`$2`/`$3`).
  Confirmed the `indkey[0]` (0-based `int2vector`) vs. `conkey[1]` (1-based `smallint[]`)
  indexing distinction the comments call out is applied correctly in each query.
- Confirmed `harden`-style intent doesn't apply here — this is a read-only diagnostic,
  no migration/schema change.
- Ran the exposed pure functions directly and the full test suite:
  - `mix test test/mix/tasks/phoenix_kit_doctor_orphaned_fk_test.exs
    test/mix/tasks/phoenix_kit_doctor_test.exs` → 61 tests, 1 failure (see Findings).
  - Full `mix test` (against a real Postgres, `PGDATABASE=beamlab_test`) → 4065 tests +
    43 doctests, same 1 failure, otherwise green.
  - `mix precommit` (format, compile —warnings-as-errors, deps.unlock --check-unused,
    credo --strict, dialyzer, JS tests) → failed initially on `mix format
    --check-formatted`, fixed (see Findings), then green end-to-end.

## Findings

### NITPICK — merged code was not `mix format`-clean

`test/mix/tasks/phoenix_kit_doctor_test.exs` (the `classify_fk_check/5` "does not
clobber unrelated entries" test, around line 445) had a 3-line tuple-pattern match
that `mix format` collapses to 2 lines. This is enough to fail `mix precommit`'s first
gate (`mix format --check-formatted`) outright — the PR's own stated gate — on the
already-merged `main`.

**Fixed:** ran `mix format` on the file and committed the reformatted version as part
of this review. No behavioral change.

### Not a PR bug — one destructive test needs DB superuser, unavailable in this sandbox

`check_orphaned_fk_refs/1 — destructive: ... an orphaned phoenix_kit_user_oauth_providers.user_uuid
row is reported, not read as clean` fails here with:

```
** (Postgrex.Error) ERROR 42501 (insufficient_privilege) permission denied: "RI_ConstraintTrigger_c_686268" is a system trigger
```

The test needs `ALTER TABLE ... DISABLE TRIGGER ALL` (planting a real orphan behind an
already-VALID constraint, which is otherwise unreachable via ordinary SQL) and this
review's test database user is not a Postgres superuser. This is an environment
limitation of the shared sandbox DB, not a defect in the PR — the test's own comments
correctly document why the disable-trigger idiom is necessary and non-contrived. No
fix applied or needed.

### IMPROVEMENT - MEDIUM — CHANGELOG has no entry for this PR

The current unreleased version (`2.13.10`, bumped by PR #752, not yet published to
Hex) documents only the settings-secret-log-leak fix. PR #751's doctor coverage fix —
a real behavior change to a documented, user-facing `mix phoenix_kit.doctor` check —
has no CHANGELOG entry anywhere. Per this repo's convention (`CLAUDE.md`: "CHANGELOG
entries: write against the bumped `@version` heading... bullets from PR scopes"),
fixed as part of this review pass by adding a bullet under the existing `## 2.13.10`
heading (not a new version — the fix ships in the same unpublished release).

## Verdict

No functional bugs found in the FK-discovery, classification, or reporting logic —
this is a thorough, carefully-reasoned rewrite (visible from its own commit history:
multiple already-applied post-review rounds closing gaps like the `:existing_orphan`
catch-all discard, the composite-FK re-run suggestion, and the cross-schema boundary).
Two process-level gaps found and fixed: an unformatted test file that broke the
project's own precommit gate, and a missing CHANGELOG entry for the release it ships
in.
