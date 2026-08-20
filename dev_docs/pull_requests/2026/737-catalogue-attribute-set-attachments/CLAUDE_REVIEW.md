# Claude Review — PR #737 "Add V177: catalogue item-to-attribute-set attachments table"

**Merge commit:** f283691b96163713775a2c0154eee2084306aaef
**Author:** mdon
**Files:** `lib/phoenix_kit/migrations/postgres/v177.ex` (new), `lib/phoenix_kit/migrations/postgres.ex`, `lib/phoenix_kit/migrations/postgres/v176.ex`, `lib/phoenix_kit/migrations/expected_schema.ex`

## Summary of the change

Adds `phoenix_kit_cat_item_attribute_sets` — a composite-PK join table
(`item_uuid`, `set_uuid`) backing the catalogue's attribute-sets rework, plus a
reserved `data` JSONB column for future per-attachment state. Renumbered from
V176 to V177 after an upstream FK-validation migration took V176 first while
this branch was in review (documented in both moduledocs). `expected_schema.ex`
gets the table/columns/PK/FK/index hand-declared (introspected from a freshly
migrated `phoenix_kit_test`) and the chain hash restamped.

## Review

- **Prefix safety:** the existence check for the `item_uuid` FK uses a
  name-based `pg_constraint` + `pg_class` + `pg_namespace` JOIN, not a bare
  `'p.table'::regclass` cast — correct per the project's prefix-safe-migration
  rules (`AGENTS.md` → "Prefix-safe migrations"). Index name (`..._set_uuid_index`)
  is bare on `CREATE`, matching convention. The version-stamp
  `COMMENT ON TABLE #{p}phoenix_kit IS '177'` matches the exact pattern used by
  V175/V176.
- **Deliberate missing FK on `set_uuid`:** documented in the migration
  moduledoc and `postgres.ex`'s version log — `set_uuid` references
  `phoenix_kit_entities.uuid`, a different module's table, and this codebase's
  established pattern (per V175's `integration_uuid` precedent) is to keep
  cross-module references unconstrained and let each module own its own
  integrity/cleanup path rather than hard-FK across module boundaries. Verified
  this reasoning is consistent with the rest of the migration guide.
  Both directions are idempotent (`IF NOT EXISTS` / `IF EXISTS`) and `down/1`
  only drops the table and restamps — no data-destructive surprise beyond the
  expected table drop.
- **`expected_schema.ex` chain hash:** updated in the same commit as the new
  objects (`@chain_hash` changed), avoiding the "adding a migration blocks the
  next release" trap from prior incidents.

## Findings

None. No bugs, no correctness or prefix-safety issues found — this PR was
evidently already through a self-review round (the moduledoc explicitly
documents its own renumbering conflict and resolution).

## Verdict

Clean. Release-safe as-is.
