# PR #879 — MediaSelectorModal: group a scoped picker's files by folder, folder labels, full-screen size

- **Author:** timujinne
- **Merged:** 2026-09-28 (b7ec836b8)
- **Reviewer:** Claude
- **Released in:** 2.41.4

## Summary

Adds three opt-in `MediaSelectorModal` attrs, forwarded by `MediaGallery`:
`group_by_folder` (a scoped picker lists its files folder by folder, each run
opened by a heading tile in the same grid, with a "continued" marker when a
folder is cut by a page break), `folder_labels` (host names for the headings)
and `size: :full` (whole viewport, 60 files a page). Grouping is done in SQL —
`COALESCE(array_position(folder order, home folder), min link position)` — so
LIMIT/OFFSET paging stays correct, and per-group counts/offsets come from one
extra `GROUP BY` query. Defaults leave existing pickers unchanged. Solid,
well-tested PR.

## Findings

### BUG - MEDIUM — Paging had no stable order for same-second files (fixed)

`phoenix_kit_files.inserted_at` is `:utc_datetime` (second precision). Both
the flat order (`desc: inserted_at`) and the grouped order (group position,
then `desc: inserted_at`) left ties unbroken, and a batch upload ties by
construction. Postgres gives no stable order among ties across two separate
LIMIT/OFFSET queries, so page 2 could repeat a file from page 1 and never
show another. The flat case predates the PR, but grouping makes it far more
likely to bite (a folder's batch-uploaded images are exactly what straddles a
page break). The PR's own page-break test made three same-second files and
only checked that page 2 held one of them, so it could not catch a repeat.

**Fix:** `desc: f.uuid` as the final key in both orderings (UUIDv7 is
time-ordered, so newest-first is preserved). The page-break test now
collects page 1 and page 2 and asserts together they are exactly the three
files.

### NITPICK — The group-position fragment is written three times (not fixed)

`COALESCE(array_position(?, ?), ?)` appears in the ORDER BY, the SELECT and
the counts subquery. A shared `dynamic/2` would work for the ORDER BY but not
cleanly inside the tuple `select`, so the refactor would trade clarity for
little; left as is.

### NITPICK — `per_page` follows `size` only at first update (not fixed)

`assign_new(:per_page, fn -> default_per_page(assigns[:size]) end)` fixes the
page size the first time the component updates; a host that flips `size`
later keeps the old page size. No caller does that, and pinning page size for
the life of the component is the less surprising behaviour mid-pagination.

### Checked, no issue

- A file whose home folder is in the scope and is also linked into another
  scope folder groups under its home (COALESCE order) — covered by a test.
- A group position can't come back nil: `scope_files_by_folder/2` uses the
  same subtree, so every listed file is homed or linked inside it.
- Counts follow the search/type filters (the counts subquery reuses the
  filtered query).
- `folder_groups/1` returns nil (flat list) for a scope with no subfolders
  or a missing scope folder.
- Translations: `continued` added to all 8 locales; the heading count reuses
  the existing `%{count} file` plural entry.
