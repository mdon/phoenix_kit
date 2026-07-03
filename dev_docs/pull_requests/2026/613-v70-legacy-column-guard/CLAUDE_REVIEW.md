# PR #613 — Fix V70 migration crash when legacy id columns are absent

**Author:** timujinne (`fix/v70-legacy-column-guard`) · **Merge:** `01f96c97` · **Reviewer:** Claude

## Summary

One file, +2 lines. `V70` re-backfills `email_log_uuid`/`matched_email_log_uuid`
by joining on the legacy integer FK columns (`email_log_id`,
`matched_email_log_id`). The `if` guards that gate each backfill step checked
`table_exists?` and `column_exists?` for the *uuid* columns but never checked
that the legacy *id* columns referenced inside the raw SQL (`e.email_log_id`,
`e.matched_email_log_id`) actually exist. On an install where those legacy
columns were already dropped (or never created), the guard passed and the
`execute/1` calls crashed on `undefined column`.

**Verdict: correct, minimal, safe to release.** No findings.

## Verification

- Confirmed both raw-SQL blocks (`rebackfill_email_log_uuid/2`,
  `rebackfill_matched_email_log_uuid/2`) reference `e.email_log_id` /
  `e.matched_email_log_id` directly in the `UPDATE ... WHERE` and `DO $$` blocks
  — the added `column_exists?` checks guard exactly the columns the SQL uses. ✓
- `column_exists?/3` (existing helper, unchanged) is a straightforward
  `information_schema.columns` existence check scoped by table/column/schema —
  consistent with the pre-existing `table_exists?/2` pattern used elsewhere in
  the same `if`. ✓
- The migration remains idempotent: skipping the block entirely when the legacy
  column is absent is correct — there's nothing to backfill from if the source
  column doesn't exist, and `down/1` has no structural changes to reverse either
  way. ✓
- No other guard sites in the file reference an unchecked column. ✓

## Gate

Covered by the combined `mix precommit` run for this release batch (PRs
#613–#616) — see the workspace `AGENTS.md`-mandated gate; result recorded in
the release commit/notes.
