# Phase 1 Review — phoenix_kit #733

**PR:** "V175: validate the NOT VALID user FKs, and stop doctor from passing on a failed probe"
**Author:** Tymofii Shapovalov (timujinne)
**Opened:** 2026-08-18 09:13 UTC
**Stats:** 8 files changed, +1284/-26

## Files Changed

| File | Purpose |
|------|---------|
| `dev_docs/pull_requests/2026/a002-user-delete-orphans/FINDINGS.md` | Tymofii's A002 investigation doc (Russian, 337 lines) |
| `lib/mix/tasks/phoenix_kit.doctor.ex` | Doctor FK probe: fail-closed + 3-state output |
| `lib/phoenix_kit/migrations/expected_schema.ex` | chain_hash + @current_version → 175 |
| `lib/phoenix_kit/migrations/postgres.ex` | @current_version bump |
| `lib/phoenix_kit/migrations/postgres/v175.ex` | New V175 migration |
| `test/mix/tasks/phoenix_kit_doctor_orphaned_fk_test.exs` | New real-DB probe failure test |
| `test/mix/tasks/phoenix_kit_doctor_test.exs` | Updated classify/report unit tests |
| `test/phoenix_kit/migrations/v175_test.exs` | 4-scenario V175 migration test |

## Red Flag Check

- Build artifacts: none ✅
- Secrets: none ✅
- Suspicious deps: none ✅
- Unrelated changes: none ✅
- Bad files (swap/archive/crash): none ✅

## What It Does

**V175 migration:** For each FK in `UUIDFKColumns.fk_constraints/0`, if the constraint exists
and is NOT VALID and has zero orphaned rows — runs `VALIDATE CONSTRAINT`. If orphans exist,
warns with count and leaves the constraint alone. Purely additive; no rows deleted or nulled.
Idempotent (already-valid constraint = no-op).

**Doctor fix:** `check_orphaned_fk_refs` previously used `_ -> :absent` and `_ -> 0` as
catch-all fallbacks, so a failed DB probe would silently report PASS (fail-open). Now fail-closed:
probe failures surface as `{:probe_failed, reason}`. New `classify_fk_check/5` is a pure
multi-clause function — directly testable without a real repo. Output is now 3-state:
PASS / WARN (NOT VALID but no orphans, V175 will fix) / FAIL (orphans present).

**Tests:** V175 test covers 4 scenarios (orphan present → stays NOT VALID; 2 orphans → count
accurate; no orphans → validates; already valid → no-op). Doctor tests exercise `classify_fk_check/5`
and `report_orphaned_fk_refs/3` as pure functions, plus real-DB probe failure test.

**Author's test run:** 3765 tests + 43 doctests, 0 failures (4 pre-existing `Install.CommonTest`
failures unrelated to this PR).

## Verdict

✅ **Approve and merge**

No red flags. Well-researched (A002 doc shows 3 review rounds). The fail-open probe fix is
genuinely important — a diagnostic tool that could lie PASS on a failed check is a safety issue.
The V175 migration is safe on foreign schemas (same policy as V164: never deletes, never nulls).
