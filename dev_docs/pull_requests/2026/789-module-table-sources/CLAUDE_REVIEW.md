# Claude Review — PR #789

**Title:** Core: recognize catalogue-owned tables in storage/doctor, document module table ownership
**Author:** timujinne
**Merge commit:** fd652188
**Verdict:** Approve — one HIGH finding, fixed in this pass

## Summary

Adds JSONB-aware orphan-detection guards to
`PhoenixKit.Modules.Storage.orphaned_files_query/0` for three catalogue
tables (`phoenix_kit_cat_items`, `phoenix_kit_cat_categories`,
`phoenix_kit_cat_catalogues`) that store image references inside a JSONB
`data` column rather than dedicated FK columns, adds a `doctor.ex` comment
explaining why two of those tables are exempt from the NULL-uuid backfill
check, and documents the full 18-table catalogue inventory in
`dev_docs/guides/2026-09-05-module-table-extraction-guide.md`.

## Review scope

Read `storage.ex`'s `orphaned_files_query/0` and `existing_optional_tables/0`
in full, `doctor.ex`'s new comment, the full extraction guide, the related
PR #784 review, and `test/integration/storage_catalogue_orphan_test.exs`.
Cross-checked every added table/column name against
`phoenix_kit_catalogue`'s own migration source
(`phoenix_kit_catalogue/lib/phoenix_kit_catalogue/migrations.ex`) rather than
trusting the PR description.

## Findings

### IMPROVEMENT - HIGH — `phoenix_kit_cat_pdfs.file_uuid` was a real, unprotected file reference (fixed)

`lib/modules/storage/storage.ex` — unlike the three tables this PR added,
`phoenix_kit_cat_pdfs` references its source file via a plain `NOT NULL` FK
column with `ON DELETE RESTRICT`
(`phoenix_kit_catalogue/migrations.ex:493,817-818`) — the same shape as
`phoenix_kit_post_media.file_uuid`, which *is* in the orphan-check list. It
was missing.

Consequence, traced through the actual call chain: `file_orphaned?/1` would
wrongly return `true` for a PDF still referenced by the catalogue's
PDF-extraction feature → `DeleteOrphanedFileJob` calls
`Storage.delete_file_completely/1`, which deletes the physical file data
*first*, then calls `delete_file/1` (a bare `repo().delete/1` with no
`foreign_key_constraint` declared) — the FK-RESTRICT violation raises
`Ecto.ConstraintError` rather than returning `{:error, changeset}`, so the
Oban job crashes *after* the physical blob is already gone, leaving a
dangling `phoenix_kit_files` row and a broken PDF the catalogue module can't
re-open.

The PR's own new guide documents `phoenix_kit_cat_pdfs` as a real table with
a real FK, and the moduledoc/comments elsewhere explain why each JSONB table
either does or doesn't need a guard — but `cat_pdfs` got no orphan-check
entry and no comment explaining the omission. It reads like an oversight
rather than a deliberate exclusion.

**Applied:** added a `phoenix_kit_cat_pdfs` entry to `optional_checks`
mirroring the `phoenix_kit_post_media` pattern (`NOT EXISTS (SELECT 1 FROM
phoenix_kit_cat_pdfs cp WHERE cp.file_uuid = ?)`), with a comment explaining
the FK-RESTRICT crash it prevents, plus two new tests in
`test/integration/storage_catalogue_orphan_test.exs` mirroring the existing
suite's shape (a PDF's `file_uuid` protects its file; a PDF referencing a
different file does not).

## Verified correct (no issues)

- `doctor.ex`'s claim that `cat_items`/`cat_categories` never went through
  the V56 NULL-uuid backfill — confirmed against `v135.ex:1672-1699`: both
  carry `DEFAULT uuid_generate_v7() NOT NULL` since baseline creation. This
  hunk is comment-only, no `source_tables` list change, so no dead-code
  concern.
- The three added JSONB checks match catalogue's actual JSONB key names
  (`featured_image_uuid`, `media_order`, `ecommerce.file_uuid` /
  `ecommerce.image_uuid`) — cross-checked against the catalogue module's
  `product_card.ex` / `components.ex`.
- `test/integration/storage_catalogue_orphan_test.exs` exercises the real
  path (not vacuous): each test hits `Storage.file_orphaned?/1` against real
  inserted rows, including negative cases (a different file's UUID doesn't
  falsely protect one it shouldn't).
- No prefix-safety regression: the new fragments follow the exact same
  bare-table-name pattern as every pre-existing entry in the same list
  (`post_media`, `shop_products`, etc.) — not a new deviation introduced by
  this PR. (`existing_optional_tables/0`'s hardcoded `table_schema = 'public'`
  is pre-existing and untouched by this PR — out of scope here.)

## Verification

- `mix test test/integration/storage_catalogue_orphan_test.exs` — before fix:
  11 tests, 0 failures (didn't yet cover `cat_pdfs`). After fix: 13 tests, 0
  failures, run against the real Postgres test DB.
- `mix format` clean on both touched files.
