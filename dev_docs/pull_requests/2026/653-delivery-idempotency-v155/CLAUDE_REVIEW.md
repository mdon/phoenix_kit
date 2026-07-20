# PR #653 — V155: CRM contact id on newsletter deliveries + per-broadcast dedup indexes

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-20
**Verdict:** ✅ APPROVE — already merged; no bugs found.

---

## Summary

Adds V155, extending `phoenix_kit_newsletters_deliveries` /
`phoenix_kit_newsletters_broadcasts` for the CRM-sourced and role-targeted
newsletter recipient paths:

1. **`crm_contact_uuid`** — bare, nullable, no-FK soft reference on
   `phoenix_kit_newsletters_deliveries` (same soft-ref convention as V152's
   `crm_list_uuid`), backed by a plain (non-partial) index.
2. **Widened `..._recipient_check`** — same constraint name as V152's, replaced
   (not added) to additionally forbid a row claimed by both `user_uuid` *and*
   `crm_contact_uuid`. Deliberately **not** a strict XOR (see below).
3. **Three partial unique indexes** — `(broadcast_uuid, user_uuid)`,
   `(broadcast_uuid, crm_contact_uuid)`, `(broadcast_uuid, recipient_email)`, each
   `WHERE ... IS NOT NULL` — the first DB-level per-broadcast delivery dedup;
   previously `Broadcaster.process_batch/5`'s `insert_all` had no `ON CONFLICT` guard
   at all.
4. **`source_params JSONB NOT NULL DEFAULT '{}'`** on `..._broadcasts`, for the new
   `user_group` (core-role) recipient source: `%{"role_uuids" => [...],
   "role_names_snapshot" => [...]}`.

Note: the branch/commits are titled "V154" throughout (branch name
`feature/delivery-idempotency-v154`, individual commit subjects), but the version
was correctly renumbered to **V155** before merge to avoid colliding with PR #650's
V154 (OpenGraph tables), which landed on `main` first. `@current_version` is `155`,
consistent, no collision — confirmed by inspecting `postgres.ex` and the file name.

## Files Changed (3)

| File | Change |
|---|---|
| `lib/phoenix_kit/migrations/postgres.ex` | +25/−2 — moduledoc + `@current_version` bump |
| `lib/phoenix_kit/migrations/postgres/v155.ex` | +260 — new migration |
| `test/phoenix_kit/migrations/v155_test.exs` | +296 — new suite |

## Verification performed

- **Version-collision check** — this was the first thing worth checking, since the
  branch name and every individual commit message say "V154" while PR #650
  (reviewed and merged earlier the same day) also claims V154 for an unrelated
  OpenGraph feature. Confirmed no actual collision: the merge commit title and the
  shipped file are both V155, `@current_version` is `155`, and `git log` shows this
  PR's branch diverged before #650 merged then was renumbered prior to its own
  merge. Not a bug, but worth recording since a careless glance at the branch name
  would suggest otherwise.
- **Statement ordering for FK/constraint dependencies** — `up/1` adds
  `crm_contact_uuid` *before* the widened CHECK references it and *before* the
  dedup index on it; `down/1` reverses correctly — it restores the CHECK to its
  V152 form (dropping the `crm_contact_uuid` clause) *before* dropping the
  `crm_contact_uuid` column, which is required: Postgres refuses `DROP COLUMN` on a
  column still referenced by a CHECK constraint. Read both directions line by line;
  order is correct.
- **Cross-checked the "widened, not XOR'd" deviation against the actual production
  data shape it claims to justify** — the moduledoc says every existing CRM-sourced
  delivery has `user_uuid` and `crm_contact_uuid` both NULL (addressed by
  `recipient_email` alone), which is why a strict XOR would have been wrong. Verified
  this is at least internally consistent: `crm_contact_uuid` is new in this exact
  migration, so no pre-existing row can have it non-null; a strict XOR would indeed
  have rejected every historical crm_list delivery row on the next `ON CONFLICT`-free
  re-insert or any check-constraint validation pass. The reasoning holds.
- **Checked `list_uuid`/`user_uuid` nullability history** — the new test's
  `insert_broadcast!/0` inserts only `subject`, and several tests insert deliveries
  with only one of `user_uuid`/`recipient_email`/`crm_contact_uuid`. Traced back to
  V152 (`postgres/v152.ex:328,355`), which already dropped `NOT NULL` from both
  `broadcasts.list_uuid` and `deliveries.user_uuid` — confirming these inserts don't
  fail on unrelated legacy constraints the diff doesn't show.
- **Checked the "plain index is a strict superset of a partial one" claim** used to
  justify not making `crm_contact_uuid`'s index partial like its siblings — correct:
  a plain B-tree index covers NULL and non-NULL alike, so it's a superset of `WHERE
  crm_contact_uuid IS NOT NULL`; the trade-off (slightly larger index, no functional
  difference) is explicit in the moduledoc, not a bug.
- **Idempotency** — every `up_*` helper uses `IF NOT EXISTS`/`ADD COLUMN IF NOT
  EXISTS`, except `up_recipient_check`, which deliberately uses unconditional `DROP
  CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` (documented reasoning: re-running `up/1`
  must re-apply the new constraint definition even if a stale one exists, unlike a
  guarded-existence check that would skip it). Confirmed re-running is safe: the
  `DROP ... IF EXISTS` no-ops on first run, and the constraint name staying identical
  means no dangling duplicate-name conflict on repeat runs.
- **Prefix-safety** — index names stay bare on `CREATE` (`idx_newsletters_deliveries_crm_contact`,
  etc.), only the table name is `#{p}`-qualified; `DROP INDEX` correctly re-qualifies
  the index name with the prefix. No `regclass` casts, no unanchored
  `information_schema`/`pg_constraint` checks — consistent with the project's
  prefix-migration rules.
- **Test coverage matches the constraint's actual truth table** — the six
  `recipient_check` tests cover all four addressability/exclusivity combinations
  (neither → reject, email-only → accept, user-only → accept, contact+email →
  accept, contact-only-no-email → reject, user+contact → reject), not just the
  happy path.

No issues found — migration is idempotent, correctly ordered for
constraint/column/index dependencies, doesn't collide with the concurrently-shipped
V154 despite the misleading "V154" branch/commit naming, and its documented
deviation from the original XOR spec is justified against verifiable production
data shape.

## Gate

`mix precommit` run at HEAD (format + compile --warnings-as-errors + credo --strict +
dialyzer) — no fixes were required for this PR's changes.
