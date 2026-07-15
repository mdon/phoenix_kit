# PR #638: V149 migration: catalogue item-supplier sourcing info + CRM xref

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, no blocking issues — one design gap flagged for the
consuming module, not fixed here (see below)
**Date**: 2026-07-14

## Goal

Adds `phoenix_kit_cat_item_supplier_info` (junction: per-item, per-supplier
SKU / unit cost / currency / lead time / MOQ, with a soft `supplier_uuid`
ref) and a soft `crm_company_uuid` xref column on `phoenix_kit_cat_suppliers`.
Both are additive/idempotent. `@current_version` bumped 148 → 149. Ships
ahead of the `phoenix_kit_catalogue` consumer (issue #1 there) — checked
that module locally; it only consumes V146's `primary_supplier_uuid` so far,
nothing yet reads this table.

## Verified correct (no action needed)

- Bare index names on both `CREATE INDEX`, prefix only qualifies the table —
  correct per the index-name-on-CREATE rule.
- `item_uuid` FK to `phoenix_kit_cat_items` is inline in the `CREATE TABLE`
  (not a separate `ALTER TABLE ADD CONSTRAINT`), so no idempotency/anchoring
  concern — `CREATE TABLE IF NOT EXISTS` covers the whole statement.
- `phoenix_kit_cat_items` / `phoenix_kit_cat_suppliers` are created in V87
  via the `create_if_not_exists table(...)` DSL (not raw SQL), so no
  `flush()` was needed before this migration's FK reference — V87's queued
  commands are from an earlier, already-completed `up/1` call, not an
  immediate query racing an unflushed `CREATE` (the V51/V146 bug class).
- `crm_company_uuid` uses `ADD COLUMN IF NOT EXISTS` — idempotent, no
  immediate existence check required (unlike a constraint add).
- `down/1` drops the table with `CASCADE` (covers its own indexes) and the
  xref column, then restores the `148` version comment — correct order,
  matches convention.
- No FK on `supplier_uuid` is deliberate and documented (soft ref, resolves
  across two possible target tables) — consistent with the `staff_person_uuid`
  precedent in V138.
- `mix precommit` (format, compile, credo --strict, dialyzer) passes clean
  on this diff.

## Flagged, not fixed (design gap for the consuming module)

### IMPROVEMENT - HIGH: `supplier_uuid` has no discriminator — the two
possible targets can't be told apart

The moduledoc states `supplier_uuid` "resolves to a CRM party or a local
`cat_supplier`" — a genuinely polymorphic soft reference. But unlike the
codebase's two existing polymorphic-soft-ref precedents, there's no column
telling a reader which target table a given row points at:

- V138's `interaction_parties` uses **two** nullable columns
  (`contact_uuid`, `staff_person_uuid`) plus a CHECK making them mutually
  exclusive.
- V148's `phoenix_kit_crm_party_roles` (previous PR, same day) uses an
  explicit `roleable_type VARCHAR(20)` + `roleable_uuid UUID` pair.

V149's `phoenix_kit_cat_item_supplier_info.supplier_uuid` is a single UUID
column with neither pattern. A consumer resolving a row has no principled
way to know whether to look it up in `phoenix_kit_cat_suppliers` or in CRM
(and if CRM, company or contact) short of probing multiple tables. UUIDv7
collision risk across tables is negligible, so this isn't a data-integrity
bug — but it will force the first real consumer to either guess, probe
every candidate table on every read, or come back and add a type column
later (a breaking change once rows exist).

**Why not fixed here:** no consumer code reads this table yet (confirmed —
`phoenix_kit_catalogue` only wires `primary_supplier_uuid`), so there's no
call site to validate a schema change against, and guessing the shape of a
not-yet-written resolver risks a wrong-guess migration on top of a
wrong-guess migration. Recommend adding a `supplier_source` (or similarly
named) discriminator column before `phoenix_kit_catalogue`'s consumer lands,
mirroring V148's `roleable_type` pattern.

## Nitpick

- The catch-all JSONB column is named `metadata` here, but every other
  `phoenix_kit_cat_*` table (V87) uses `data` for the same role. Matches the
  CRM family's naming (V138/V148) instead — arguably intentional since this
  table is where CRM federation lands, but worth a beat of thought before
  the next `cat_*` table picks one or the other.
- `crm_company_uuid` gets no index, unlike the other soft-ref/lookup columns
  added in this same area (V138's `staff_person_uuid`, V146's
  `primary_supplier_uuid` both got a partial index for the reverse lookup).
  `phoenix_kit_cat_suppliers` is typically small, so this is unlikely to
  matter in practice — flagging for consistency, not performance.
