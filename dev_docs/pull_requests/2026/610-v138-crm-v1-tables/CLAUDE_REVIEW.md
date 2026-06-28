# PR #610 — V138 CRM v1 tables (+ checkbox description slot, storage delete fix)

**Author:** Dmitri Don (`mdon/main`) · **Merge:** `dec1d701` · **Reviewer:** Claude

## Summary

Bundles three independent changes merged together:

1. **V138 migration** — five `phoenix_kit_crm_*` tables for the CRM module's first
   data model: `contacts`, `companies`, `company_memberships` (M:N edge with
   free-form role/department), `interactions`, and `interaction_parties`
   (resolvable "who was involved" with an as-of-then JSONB snapshot). Migration
   only — no schemas/contexts/UI yet.
2. **Checkbox description slot** — `Core.Checkbox` renders an optional
   `inner_block` as a muted description under the bold label, switching the label
   to `items-start` alignment when present.
3. **Storage delete fix** — `delete_folder_completely` no longer destroys a file
   that is *also* linked (via `FolderLink`) into a folder **outside** the deleted
   subtree; such files are re-homed instead of hard-deleted.

Verdict: **clean PR, no bugs found, safe to release.** All three pieces follow
existing project conventions. Findings below are minor (NITPICK / low-impact
IMPROVEMENT) and are documented, not fixed — none warrant a code change.

## Verification of claims

### V138 migration

Cross-checked against the V137 reference migration and the dispatch in
`postgres.ex`:

- **Dispatch wiring** — none needed. `Postgres.change/3` resolves version modules
  dynamically via `Module.concat([__MODULE__, "V#{pad}"])` (`postgres.ex:1482`).
  Bumping `@current_version` 137 → 138 (`postgres.ex:1187`) is the only wiring
  required; the new `V138` module is picked up automatically. ✓
- **Conventions match V137 exactly** — `prefix_str/1`, `Map.get(opts, :prefix,
  "public")`, self-managed `COMMENT ON TABLE … IS '138'` on up / `'137'` on down,
  `uuid_generate_v7()` PKs, `IF NOT EXISTS` everywhere (idempotent). ✓
- **FK / cascade choices are coherent** — `company_memberships`,
  `interactions.contact_uuid`, `interaction_parties.interaction_uuid` use
  `ON DELETE CASCADE`; user links use `ON DELETE SET NULL`; `staff_person_uuid`
  is a soft ref (no FK) so the optional staff module stays optional. ✓
- **Exclusive-arc CHECK** (`phoenix_kit_crm_party_exclusive_arc`) correctly
  permits both-NULL (unresolved party, `raw_name` only) or at most one of
  `contact_uuid` / `staff_person_uuid`. ✓
- **Partial unique index** `idx_crm_contacts_user_uuid … WHERE user_uuid IS NOT
  NULL` makes the user link 1:1 only among linked rows — matches the moduledoc's
  "optional, 1:1 only among linked rows" claim. ✓
- **`down/1`** drops in correct reverse-dependency order
  (parties → interactions → memberships → companies → contacts) with CASCADE. ✓

### Checkbox description slot

- `slot :inner_block` is declared (`checkbox.ex:28`), so `@inner_block` defaults to
  `[]` and the `@inner_block != []` emptiness check is valid. ✓
- `false`/`nil` entries in `class={[…]}` lists are dropped by Phoenix, so
  `@inner_block != [] && "mt-0.5"` and `class={@inner_block != [] && "font-medium"}`
  render no class when the slot is absent. ✓
- Backwards compatible: with no slot, output is the prior single-line label with
  `items-center` alignment. ✓

### Storage delete fix

Verified the bug premise against the cascade definitions in `v95.ex`:

- `phoenix_kit_media_folder_links.file_uuid` → file `ON DELETE CASCADE`
  (`v95.ex:86`). So the old `Enum.each(files, &delete_file_completely/1)` deleted a
  shared file's row, which **cascaded away its external `FolderLink`** — silently
  stripping the file from an unrelated folder. Bug confirmed. ✓
- `phoenix_kit_media_folder_links.folder_uuid` → folder `ON DELETE CASCADE`
  (`v95.ex:75`) — links to subtree folders vanish when those folders are deleted.
- `phoenix_kit_files.folder_uuid` → folder **`ON DELETE SET NULL`** (`v95.ex:112`),
  *not* cascade. So the fix's re-home approach is sound: promoted files point at an
  external folder and are never touched by the bottom-up folder deletes; confined
  files are explicitly deleted first.

The fix partitions subtree files with `Enum.split_with(…, &linked_outside_subtree?)`:
files with an external link are re-homed to the first such folder (consuming that
one link) and survive; files confined to the subtree are `delete_file_completely`'d.
Logic is correct for the multi-external-link case (remaining external links keep
pointing at the re-homed file) and for the home-outside-but-linked-in case (such
files aren't in the query set; their subtree link cascades away). Both new tests
(`scope_test.exs`) lock in exactly these two paths. ✓

## Findings

### NITPICK — N+1 queries on the folder-delete path (not fixed)

`linked_outside_subtree?/2` runs one query per subtree file inside `split_with`,
and `promote_out_of_subtree/2` re-runs `links_outside_subtree/2` for each promoted
file (a second identical query). For a large subtree this is O(files) round-trips.
**Not fixed:** this is a rare admin-initiated permanent-delete path, the code is
clear as written, and batching the link lookups into one `WHERE file_uuid IN (…)`
query would add complexity for negligible real-world benefit. Recorded so the
trade-off is on the record.

### IMPROVEMENT - LOW — `do_delete_folder_completely/1` is not wrapped in one transaction (pre-existing, not fixed)

Promotion, file deletion, and folder deletion run as separate statements (only the
per-file re-home update+link-delete is transactional). A mid-operation crash leaves
a partially-deleted subtree. This is **pre-existing** behavior (the original code
was equally non-transactional) and out of scope for this fix; noted for a future
hardening pass.

### NITPICK — CRM index naming diverges from project convention (not fixed)

V138 names indexes `idx_crm_contacts_user_uuid`, `idx_crm_companies_status`, etc.,
whereas the rest of the codebase uses `<table>_<col>_index` (e.g.
`phoenix_kit_email_logs_to_trgm_index` in V137). Purely cosmetic — index names are
schema-scoped so there is no collision risk across tenant prefixes. Left as-is to
avoid churning a freshly-merged migration.

### NITPICK — V137 has no entry in the `postgres.ex` aggregate moduledoc (pre-existing)

The convenience version log in `postgres.ex` jumps V138 → V136; V137's entry was
never added by its own PR (#604). Out of scope for this PR (its own `v137.ex`
`@moduledoc` is complete); flagged for a docs sweep.

## Gate

`mix precommit` (format + compile `--warnings-as-errors` + credo `--strict` +
dialyzer) — see release commit. No code changes were applied by this review.
