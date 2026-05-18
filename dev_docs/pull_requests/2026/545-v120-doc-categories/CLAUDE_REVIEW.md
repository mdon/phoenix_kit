# PR #545 — V120: Document Creator Category → Type taxonomy

Reviewer: Claude (Opus 4.7) · State: MERGED · Base: `dev`

Reviewed `lib/phoenix_kit/migrations/postgres/v120.ex` against V117 (which
added the `category` columns) and V86/V94 (doc tables).

> **Update:** V120 is unreleased (no `@version`/CHANGELOG bump, no host app
> has run migration 120), so the scope-index and duplicate-category bugs were
> fixed in place in `v120.ex` rather than via a V121. See "Fixes applied"
> below. The preset-taxonomy question is left open for the module developer.

## Fixes applied to `v120.ex`

- **Scope index** — `up/0` now recreates
  `phoenix_kit_doc_template_presets_scope_index` on `(scope_type, scope_id)`
  after dropping `presets.category`; `down/0` restores the original V117
  3-column `(scope_type, scope_id, category)` index.
- **Duplicate categories** — the data migration now groups legacy values by
  `lower(category)`, so case variants collapse into one Category row.
- **Redundant index** — dropped the standalone `[:category_uuid]` index on
  `doc_types` (covered by the `[:category_uuid, :position]` composite).
- **Moduledoc** — documents that presets do not join the taxonomy and that
  their legacy `category` strings are discarded.

## Open — for the Document Creator module developer to decide

Presets get no `category_uuid` column, so their legacy `category` strings are
discarded with no migration path (see below). Decide whether presets should
participate in the new taxonomy; if so, that needs a follow-up migration
adding `phoenix_kit_doc_template_presets.category_uuid` plus repointing.

## BUG - MEDIUM — dropping `presets.category` silently destroys the V117 scope index — FIXED

V117 created:

```
CREATE INDEX phoenix_kit_doc_template_presets_scope_index
  ON phoenix_kit_doc_template_presets (scope_type, scope_id, category)
```

V120 does `ALTER TABLE phoenix_kit_doc_template_presets DROP COLUMN category`.
PostgreSQL drops an entire multicolumn index when *any* indexed column is
dropped — so this also removes the `(scope_type, scope_id)` index. Preset
lookups by scope (the common access path) lose their index with no
replacement. Neither `up/0` recreates an index on `(scope_type, scope_id)`,
nor does `down/0`, so even rolling V120 back leaves the index gone.

Fix: after dropping the column, recreate
`CREATE INDEX IF NOT EXISTS phoenix_kit_doc_template_presets_scope_index
ON ... (scope_type, scope_id)`.

## IMPROVEMENT - HIGH — preset `category` values are dropped without migration

The data migration only reads `phoenix_kit_doc_templates.category` to build
`Category` rows. `phoenix_kit_doc_template_presets.category` is dropped
outright. Any preset category string that is *not* also a template category
is lost permanently, and `down/0` cannot restore it (it re-adds the column
but only repopulates templates). If presets carry meaningful categories,
fold their distinct values into the `FOR legacy IN SELECT DISTINCT ...` loop
(union templates + presets) and repoint presets too. If presets intentionally
have no taxonomy, say so in the moduledoc.

## BUG - MEDIUM — case-variant legacy values produce duplicate categories — FIXED

`SELECT DISTINCT category` is case-sensitive, so `'financial'` and
`'Financial'` are two distinct rows. Both map through the CASE/capitalize
logic to `display_name = 'Financial'`, yielding **two** `phoenix_kit_doc_categories`
rows with identical `name` — and there is no unique constraint on `name` to
catch it. Templates then split across the duplicates.

Fix: dedupe on the normalized display name, e.g. group by the computed
`display_name` (or `lower(category)`) and repoint every legacy string that
maps to it to the single new uuid.

## NITPICK — redundant index on `doc_types.category_uuid` — FIXED

`index(:phoenix_kit_doc_types, [:category_uuid])` and
`index(:phoenix_kit_doc_types, [:category_uuid, :position])` both exist. The
composite index serves `category_uuid`-only lookups via its leftmost prefix,
including the FK cascade. Drop the standalone single-column index.

## NITPICK — no uniqueness on taxonomy names

`phoenix_kit_doc_categories.name` and `phoenix_kit_doc_types (category_uuid, name)`
have no unique index. Taxonomy tables usually want one; it would also have
caught the case-variant duplicate above. Consider adding (module-side
changeset validation alone won't stop concurrent inserts).

## Positives

- Idempotency is solid: `create_if_not_exists`, column-existence guards, data
  migration gated on the legacy `category` column still existing.
- `information_schema.columns` guards correctly include `table_schema` (the
  V119 multi-prefix pattern).
- `uuid_generate_v7()` used for PK defaults and data-migrated rows, per house
  convention.
- `down/0` drops `doc_types` before `doc_categories` (correct FK order);
  `category` re-added as unbounded `varchar` matching the V117 original.
- `phoenix_kit_doc_documents.template_uuid` confirmed to exist (V86) — the
  document repointing join is valid.
