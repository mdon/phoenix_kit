# PR #637: V148 migration: phoenix_kit_crm_party_roles table

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, fix applied
**Date**: 2026-07-14

## Goal

Adds `phoenix_kit_crm_party_roles`, a polymorphic role-edge table for the
(external) `phoenix_kit_crm` module: marks an existing CRM company or
contact as `supplier`, `client`, or another commercial counterparty role.
One party can hold several roles (multiple rows). No FK on the polymorphic
`(roleable_type, roleable_uuid)` pair — integrity lives in the CRM module's
changesets, mirroring the `staff_person_uuid` soft-ref precedent from
V138's `interaction_parties`. `@current_version` bumped 147 → 148.

## Verified correct (no action needed)

- Bare index names on every `CREATE INDEX`/`CREATE UNIQUE INDEX` (prefix
  qualifies the table, not the index name) — correct per the
  index-name-on-CREATE rule.
- The guarded `CHECK` constraint uses the `DO $$ ... pg_constraint ...
  conrelid = '#{p}table'::regclass ... END $$` idiom entirely inside
  `execute/1`, not an immediate `repo().query/3` call. Traced
  `Ecto.Migration.Runner`: `execute/1` only *queues* commands (order
  preserved, reversed back to chronological on `flush/0`); since the
  preceding `CREATE TABLE IF NOT EXISTS` and this `DO` block are queued
  commands from the *same* `up/1` call, they always flush in the order
  written regardless of whether an explicit `flush()` ran first. This
  exactly mirrors V144's `create_warehouse_min_stock/1`, which uses the
  identical pattern (own table, own DO-block CHECK guard, no `flush()`)
  without incident — established, working precedent, not the V51/V146
  "immediate check racing an unflushed CREATE" bug class.
- `roleable_type` CHECK constraint is schema-anchored via the regclass cast
  (`p` already carries the schema), so a public install's constraint can't
  satisfy the check for a prefixed one.
- `down/1` drops the table (`CASCADE`, though nothing references it) and
  restores the `147` version comment — matches convention.

## Fixed

### BUG - HIGH: `uuid_generate_v7()` DEFAULT not schema-qualified

`up/1`'s `CREATE TABLE` used a bare `DEFAULT uuid_generate_v7()`. On a
prefixed (non-`public`) install, the function is created *inside the named
schema* by `Helpers.ensure_uuid_v7_function/1` — a bare call resolves via
the connection's `search_path`, which by default doesn't include a custom
prefix schema. Every insert relying on the default would fail with
`function uuid_generate_v7() does not exist` (or, on a host that also
carries a `public` install, silently resolve to *that* copy instead of the
prefixed one).

This is exactly the defect class the 2026-07-12 field report and the
`prefix_migration_test.exs` oracle exist to catch — but that test only
spot-checks two tables (`phoenix_kit_projects`, `phoenix_kit_users`), so a
new table with an unqualified default slips through. Every other
table-creation migration since (V138, V144) qualifies the call
(`#{prefix}.uuid_generate_v7()` / `#{p}uuid_generate_v7()`); V148 was the
outlier.

**Fix applied** — qualified the call with the prefix, matching V144's
style:

```diff
-      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
+      uuid UUID PRIMARY KEY DEFAULT #{p}uuid_generate_v7(),
```

## Noted, not fixed

### NITPICK: `phoenix_kit_crm_party_roles_roleable_idx` is redundant

`(roleable_type, roleable_uuid)` is a strict leading-column prefix of the
unique index on `(roleable_type, roleable_uuid, role)` — Postgres can
already satisfy `WHERE roleable_type = ? AND roleable_uuid = ?` lookups
from the unique index's leftmost columns, so the extra index only adds
write/storage overhead with no query benefit. Left in place: harmless at
this table's expected cardinality, and dropping it second-guesses a
plausible deliberate choice (a narrower index for a hot lookup path) rather
than a clear-cut bug.
