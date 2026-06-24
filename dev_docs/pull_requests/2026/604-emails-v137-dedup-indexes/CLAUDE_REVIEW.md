# PR #604: Add V137 email event dedup indexes + `aws_message_id` backfill

**Author**: @timujinne (Tymofii Shapovalov)
**Reviewer**: @CLAUDE
**Status**: ✅ Merged (post-merge review — no code changes)
**Commit**: `0f628114` (merge), reviewed against `4ed98f9c`
**Date**: 2026-06-24

## Goal

Migration V137 for the (external) `phoenix_kit_emails` module:

1. **Event dedup** — back the `Emails.Event` schema's declared unique
   constraints with real partial unique indexes (a schema↔DB mismatch: the
   constraints were declared but never enforced). One index per
   `(email_log_uuid, event_type)` for single-occurrence types, one per
   `(email_log_uuid, event_type, occurred_at)` for multi-occurrence
   (open/click). Pre-existing duplicates are removed first.
2. **`aws_message_id` backfill** — populate the indexed column from the legacy
   `headers` JSONB for old rows, conflict-safe.
3. **Performance indexes** — pg_trgm substring search (`to`/`subject`/
   `campaign_id`) for the admin list, per-template open/click analytics
   composites, and a partial index for the archiver's body-compression scan.
4. Bump `@current_version` → 137.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit/migrations/postgres/v137.ex` | New migration (8 indexes, dedup DELETEs, backfill) |
| `lib/phoenix_kit/migrations/postgres.ex` | `@current_version` 136 → 137 |

## Assessment

Solid, well-documented migration. Verified the load-bearing correctness claims
against the existing schema/migrations in core:

- **Registry wiring is correct.** The dispatcher resolves
  `Module.concat([__MODULE__, "V137"])` and `apply(:up/:down, [opts])`
  dynamically (`postgres.ex` `execute_migration_steps/4`), so bumping
  `@current_version` to 137 + the `V137` module existing is sufficient — no
  explicit map registration needed. ✅
- **`occurred_at` is `NOT NULL`** (V07: `add :occurred_at, :utc_datetime_usec,
  null: false, default: NOW()`). So the open/click dedup
  (`e.occurred_at = d.occurred_at`) and the partial unique index on
  `(email_log_uuid, event_type, occurred_at)` have **no NULL-distinctness
  pitfall** — `NULL = NULL` never silently skips rows, and the index can't admit
  duplicate `NULL`-timestamp rows. ✅
- **`aws_message_id` partial unique index exists**
  (`phoenix_kit_email_logs_aws_message_id_uidx`, V22, `WHERE aws_message_id IS
  NOT NULL`). The backfill's `DISTINCT ON (aws_id)` (one uuid per id) +
  `NOT EXISTS` guard (skip ids already present) make it genuinely conflict-safe
  against that index. ✅
- **Dedup keeps the earliest row.** `phoenix_kit_email_events` has no bigint `id`
  (dropped V74); `uuid` is the UUIDv7 PK and time-ordered, so the
  `e.uuid > d.uuid` self-join DELETE keeps `MIN(uuid)` per group. Single- vs
  multi-occurrence partitions are mutually exclusive (`NOT IN ('open','click')`
  vs `IN ('open','click')`). ✅
- **Idempotent / reversible.** All creates are `CREATE ... IF NOT EXISTS`; `down`
  is `DROP ... IF EXISTS` in reverse order and resets the version comment to
  `'136'`. The data-only backfill is intentionally not reversed (documented). ✅
- **pg_trgm available.** Enabled in V111 (`CREATE EXTENSION IF NOT EXISTS
  pg_trgm`), which runs before V137; the GIN trgm indexes follow V111's existing
  transactional pattern. ✅

No code changes were required. Three items recorded below — one operational
caveat, one cross-package verification the core repo can't perform, one nitpick.

## Findings

### IMPROVEMENT - MEDIUM (not fixed) — non-concurrent index builds hold a write lock on `phoenix_kit_email_logs`

The six `CREATE INDEX` statements run inside the migration transaction, taking a
`SHARE` lock that blocks writes (email logging + SES event ingestion) on
`phoenix_kit_email_logs` for the duration of each build. On a large email table
this is a write stall during deploy.

`CREATE INDEX CONCURRENTLY` is **not** an option here: Ecto migrations run inside
a transaction (concurrently can't), and this same migration runs the dedup
`DELETE`s + the backfill, which want transactional atomicity — splitting them out
into a separate `@disable_ddl_transaction true` migration would be required.

Left as-is: it matches the established convention (V111 builds its trgm GIN index
the same transactional way), and the atomic dedup is worth more than the lock
window for the typical table size. Recorded so operators with large
`phoenix_kit_email_logs` tables schedule the V137 upgrade during low write
traffic, or split the index builds into a follow-up `@disable_ddl_transaction`
migration if downtime is unacceptable.

### MEDIUM — verify index names match the external `Emails.Event` schema's `unique_constraint(name:)`

The `Emails.Event` schema lives in the **external `phoenix_kit_emails` package**,
not in core, so this can't be verified from this repo. For the schema's declared
unique constraints to surface as friendly changeset errors (rather than a raw
`Ecto.ConstraintError` / 500) on a racing insert, the changeset's
`unique_constraint(..., name: ...)` calls must reference exactly:

- `phoenix_kit_email_events_log_uuid_event_type_index`
- `phoenix_kit_email_events_log_uuid_type_occurred_index`

…or the insert path must use `on_conflict`/`ON CONFLICT` on the matching column
sets. The **dedup safety net works regardless** (a duplicate is rejected by the
unique index either way); only the error-handling UX depends on the name match.
The PR says the indexes "back the schema's declared unique constraints," so the
names were likely coordinated — but this warrants a one-line confirmation in the
emails package before relying on graceful conflict handling.

### NITPICK — single-occurrence index covers *all* non-open/click types, not just the enumerated nine

The moduledoc enumerates nine single-occurrence event types, but the unique index
predicate is `WHERE event_type NOT IN ('open', 'click')`. Any **future**
`event_type` therefore defaults to single-occurrence (one row per
`(email_log_uuid, event_type)`). That's a sensible default, but a new
*multi-occurrence* type added later would be silently constrained to a single row
until a follow-up migration adjusts the predicate. Worth a comment at the type
definition; no change needed now.

## Testing

- [x] `mix precommit` (compile --warnings-as-errors + credo --strict + dialyzer)
- [x] Migration correctness verified by reading against V07 (`occurred_at`
      NOT NULL), V22 (`aws_message_id` uidx), V74 (no bigint id), V111 (pg_trgm)
- [ ] No new test — pure DB migration in a repo that is not standalone-DB-testable
      (per CLAUDE.md / project memory); the author's PR test plan covers a live
      parent-app apply (all 8 indexes present, 0 remaining duplicates).

## Related

- `occurred_at` column: `lib/phoenix_kit/migrations/postgres/v07.ex:89`
- `aws_message_id` partial unique index: `lib/phoenix_kit/migrations/postgres/v22.ex:54-61`
- Email events `id` drop / `uuid` PK: `lib/phoenix_kit/migrations/postgres/v74.ex`
- pg_trgm enable: `lib/phoenix_kit/migrations/postgres/v111.ex:58`
- Migration dispatch: `lib/phoenix_kit/migrations/postgres.ex` (`execute_migration_steps/4`)
