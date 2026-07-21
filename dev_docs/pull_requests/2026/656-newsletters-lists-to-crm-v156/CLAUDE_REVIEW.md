# PR #656 — V156: Migrate legacy newsletters lists into CRM, drop the legacy tables

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-21
**Verdict:** ✅ APPROVE — already merged; no bugs found.

---

## Summary

Adds V156, which one-time-migrates `phoenix_kit_newsletters_lists` /
`..._list_members` into the CRM's `phoenix_kit_crm_lists` /
`..._crm_list_members` (spec §4.5), re-points
`phoenix_kit_newsletters_broadcasts` off `list_uuid` onto
`source_type = 'crm_list'` / `crm_list_uuid`, then drops the legacy tables and
column entirely. Ships in this repo's own PR; the moduledoc carries an explicit
warning that a coordinated newsletters-module release must land alongside it
(an older newsletters release still reads the dropped tables directly).

Four data steps (lists → contacts → link → memberships → recount), each
idempotent via `table_exists?/3` short-circuiting section 1+2 entirely on a
second `up/1` run, then schema changes (drop FK/column/tables) and a
structure-only `down/1`.

## Files Changed (4)

| File | Change |
|---|---|
| `lib/phoenix_kit/migrations/postgres.ex` | +33/−2 — moduledoc entry + `@current_version` bump to 156 |
| `lib/phoenix_kit/migrations/postgres/v156.ex` | +479 — new migration |
| `test/phoenix_kit/migrations/v152_test.exs` | updated pin: `list_uuid` now asserted absent (removed by V156) instead of nullable |
| `test/phoenix_kit/migrations/v156_test.exs` | +685 — new suite |

Already went through one review-fix round pre-merge (`a712997d` — fail-closed
status CASE on the list copy so an out-of-vocabulary legacy status can't abort
the CRM CHECK mid-INSERT; the email-collision carve-out in
`create_contacts_for_migrating_users/1` so a same-email contact linked to a
*different* user doesn't suppress creation and silently drop that user's
memberships; tests for both). Reviewed the post-fix state.

## Verification performed

- **Idempotency on re-run.** `up_migrate_lists_and_members/3` and
  `up_repoint_broadcasts/1`'s call site are both gated on
  `table_exists?(opts, prefix, "phoenix_kit_newsletters_lists")`; the DDL
  drops (FK, column, tables) all use `IF EXISTS`. A second `up/1` invocation
  after the first is a clean no-op rather than an `undefined_table` error —
  matters because `ensure_current/2` (this project's test-boot migrator, per
  `AGENTS.md`) can re-run the chain.
- **Contact creation/linking correctness under the email-collision carve-out.**
  Traced all three cases by hand against
  `create_contacts_for_migrating_users/1` + `link_contacts_to_existing_users/1`:
  (a) no existing contact by email → new contact created, then linked to the
  migrating user; (b) an unlinked same-email contact already exists → creation
  skipped, that contact gets linked (picked deterministically via
  `ORDER BY inserted_at, uuid LIMIT 1` so a naive join can't try to set the
  same `user_uuid` on two rows and trip the `idx_crm_contacts_user_uuid`
  partial unique index); (c) a same-email contact exists but is linked to a
  *different* user → creation is NOT skipped (the carve-out), a fresh contact
  is created for the migrating user and gets linked in the same pass since it's
  the only unlinked row at that email. In all three cases every migrating
  user ends up with exactly one contact carrying their `user_uuid`, so the
  later membership INSERT's `JOIN ... c ON c.user_uuid = m.user_uuid` can't
  silently drop a user's memberships. Matches
  `v156_test.exs`'s four contact-semantics tests line for line.
- **Membership FK guarantees the join always finds a contact.**
  `phoenix_kit_newsletters_list_members.user_uuid` carries
  `ON DELETE CASCADE` to `phoenix_kit_users` (V79), so no membership row can
  reference a deleted user — `create_contacts_for_migrating_users/1`'s
  `DISTINCT user_uuid FROM ...list_members` source set is therefore always
  resolvable, and the membership INSERT's inner joins can't skip a row for a
  missing contact.
- **`source_params` NULL-safety on the broadcast re-point.** The orphan-guard
  UPDATE does `b.source_params || jsonb_build_object(...)` — jsonb `||`
  returns SQL NULL if either side is NULL. Checked: V155 added
  `source_params JSONB NOT NULL DEFAULT '{}'`, so this can't silently null out
  the column. (Flagging the pattern here because the same NULL-propagation
  gotcha *is* live in the sibling PR #657 — see that review.)
- **Statement ordering for the DROP.** `up_drop_broadcast_list_fk/1` runs
  before `up_drop_list_tables/1` — required, since `fk_newsletters_broadcasts_list`
  is `ON DELETE RESTRICT` and would otherwise block the table drop entirely.
  `down/1` reverses correctly: tables recreated before the FK referencing them
  is restored.
- **`@current_version` / doc sync.** `postgres.ex` moduledoc's V156 entry is
  accurate against the actual migration; `⚡ LATEST` marker moved correctly
  (only one occurrence, on V156); `@current_version` bumped to 156.
  Module resolution is dynamic (`Module.concat([__MODULE__, "V156"])` off the
  version number), so no separate registry list needed updating.
- **No other core code references the dropped tables** — confirmed via `rg`
  across `lib/`; the only remaining `phoenix_kit_newsletters_lists`/
  `..._list_members` string literals are in `postgres.ex`'s own moduledoc
  history and V-series migration files that created them. The newsletters
  package itself is external per the moduledoc's coordinated-release warning.

No bugs found. Migration is unusually well-documented (moduledoc walks every
design decision with its rationale) and the test suite
(`v156_test.exs`, 685 lines) independently exercises every branch discussed
above, including the two edge cases the pre-merge review round added.
