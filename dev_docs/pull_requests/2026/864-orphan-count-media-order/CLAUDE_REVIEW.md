# PR #864 — Fix the orphan count taking seconds per media page load and folder click

**Author:** timujinne · **Merged:** 2026-09-23 (f8df2f79) · **Reviewer:** Claude · **Released in:** not yet released

## Summary

`orphaned_files_query/0` checked each file against every catalogue row with
`data->'media_order' @> to_jsonb(ARRAY[file_uuid])`. Postgres can't hash that
containment test, so it ran once per file and per row, unpacking each row's
`data` every time. On a live shop that took 8 s, on every media page load and
every folder click. The PR expands `media_order` with
`jsonb_array_elements_text` (guarded by `jsonb_typeof = 'array'`) and matches
by equality, which Postgres can hash-anti-join (0.15 s). The same change is
applied to catalogue items, categories and catalogues.

It also adds a spinner to the folder sidebar. While a folder click waits on
the server, the chevron or folder icon swaps to `loading-spinner`, keyed on
`.phx-click-loading`.

Verdict: correct. The answers are the same as before: only top-level string
elements match, which is also all `@>` matched, and a non-array
`media_order` still counts as "no reference" instead of raising. There are
tests for both the orphan query and the sidebar markup.

## Findings

No bugs.

### NITPICK — interaction with V202 (no action)

This landed on top of storage libraries phase 1 (V202). The library filter
(`where_library/2`) is added outside these fragments, so the two changes
compose without touching each other. The media page's orphan count is now
also narrowed to the library on screen.

### NITPICK — pre-existing, not introduced here

The fragments name catalogue tables unqualified (`phoenix_kit_cat_items`),
so on a named-schema (`prefix:`) install they resolve through
`search_path`. The `@>` version had the same problem. Worth a follow-up
together with the rest of `existing_optional_tables/0`.
