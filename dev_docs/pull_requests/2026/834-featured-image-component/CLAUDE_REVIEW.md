# PR #834: Add FeaturedImage component: one image pointer with a touch-friendly change/remove menu

**Author**: @timujinne
**Reviewer**: @claude (Fable 5.1)
**Status**: ✅ Merged
**Commit**: `700be706`
**Date**: 2026-09-20

## Goal

A controlled, write-free LiveComponent for an entity's "main image": thumbnail,
always-visible Change/Remove menu (`table_row_menu`, new `trigger_size`), and
the whole `MediaSelectorModal` protocol behind a portal. The host handles one
message, `{FeaturedImage, id, {:set_featured, uuid | nil}}`.

## Verified

- Modal protocol: `notify: {module, id}` → `send_update(media_selected:/media_selector_closed:)`
  matches `MediaSelectorModal.confirm_selection/1` and its close path.
- Service-message `update/2` clauses precede the general one; every one re-checks `readonly`.
- No queries in a `mount`; one `Storage.get_file/1` per uuid, memoized; the DB
  rescue covers raise paths the same way `MediaGallery.load_files` does.
- `trigger_size` uses whole literal class strings (Tailwind-scannable) and
  replaces rather than appends the size class. Default `"xs"` keeps every existing caller unchanged.
- Gettext: 0 fuzzy / 0 new untranslated in all locales.

## Findings

### BUG - MEDIUM — a system-managed file passed the display guard (fixed)

`classify/1` accepted any `file_type: "image"`, `status: "active"` row.
`Storage.get_file/1` does not filter `system_managed`, and an edited image's
hidden unedited original (`ImageEditing.backup/1`) is exactly such a row. The
picker never lists it, but the chosen uuid comes from the client, so a crafted
`media_selected` reached the host as a valid `:set_featured` — a pointer to a
file `FileController` refuses to serve (broken thumbnail), and a breach of the
"a new path must refuse system-managed files" rule in AGENTS.md.

**Fix:** `classify(%{system_managed: true}) -> :dangling`, first clause; the
rejection test enumerates a system-managed row; moduledoc updated.

### IMPROVEMENT - MEDIUM — thumbnail URL is unversioned (not fixed)

`thumb_url/2` calls `URLSigner.signed_url(uuid, variant)` without `version:`,
so the thumbnail is revalidated instead of cached `immutable`. Passing a
version needs the variant's instance — a second query per component, against
the component's one-query contract. Left as is; correct, just not cached for good.

### NITPICK — `preview_values/1` admits atoms

The moduledoc says "strings or numbers"; the guard also lets atoms through
(`nil`/`false` drop the attribute, others stringify). Harmless.

### NITPICK — `catch :exit` absent in `resolve/1`

A dead pool *exits* rather than raises (AGENTS.md soft-failure rule). Same
boundary as `MediaGallery`, which the comment cites; not widened here.
