# PR #848: Add a readonly attr to MediaBrowser for view-only embeds

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`598790eb`), not yet released; the BUG - MEDIUM below is fixed post-merge
**Date**: 2026-09-21

## Goal

A `readonly` attr (default `false`) makes `MediaBrowser` view-only for a
locked or soft-deleted record: every write affordance is hidden, every
mutating `handle_event` is refused server-side ahead of its real clause, a
broadcast upload is refused where it lands (`process_pending_upload/2`), and
the nested `MediaCanvasViewer` is wired read-only (`can_annotate`,
`persist_rotation`, `edit_target` and `details_path` all off). Navigation,
search, sorting, the viewer and downloads keep working.

## Verified

- **The server-side refusal really is complete.** Mechanically: `MediaBrowser`
  has 80 distinct `handle_event` names; 46 go through `log_readonly_blocked/2`.
  Each of the other 34 is navigation or display — `navigate_*`, `set_page`,
  `set_sort`, `set_view_mode` (the user's own preference), `search`, the
  `close_*`/`cancel_*` family, `download_file`/`download_selected`,
  `viewer_keydown` (Escape and the arrow keys only — no shortcut writes) and
  `restore_stacks` (re-expands stacks the page already knows). None writes.
- `FolderExplorer` is a function component whose events carry
  `phx-target={@myself}` of the consumer, so the sidebar's rename/create/drag
  events land in `MediaBrowser`'s guarded clauses, not an unguarded handler of
  its own.
- `MediaCanvasViewer` enforces its own gates server-side, not only in
  markup: `etcher:annotations-changed` and `etcher:shape-drawn` check
  `can_annotate`, `fresco:rotate` checks `persist_rotation`,
  `save_media_details` refuses when `details_path` and `edit_target` are both
  nil, `edit_image` checks `edit_target`. The comments thread
  (`annotation_reply`) is not gated — the PR states that as a deliberate
  limitation.
- Rebased onto together with the post-merge fixes to #847 (bulk folder
  events, selection cleanup) that touch the same `MediaBrowser` event
  handling: the combined tree's full suite passes.

## Findings

### BUG - MEDIUM: a readonly viewer still burns on close

The viewer's `AnnotationBurn` hook burns when an editing session ends —
Etcher switched off, **or the viewer closed** (`_onClosing` →
`burnIfChanged()`) — and it never checked what the viewer was allowed to
do. So in a readonly `MediaBrowser`, opening a file whose drawing has no
current burned copy and then closing the viewer composed the picture and
`POST`ed it to `/api/files/:uuid/burn`:

- for a user the endpoint admits (owner, Admin, "media"), a view-only
  session wrote `thumbnail`, `burned` and `burned_large` and
  `metadata["burn"]`;
- for one it refuses, the viewer showed "Could not update the burned
  image" for merely closing it.

A burn with no current copy is common: any file drawn on before burning
existed, and — since the #853 review fix — any image edited after its last
burn.

> **Fixed post-merge.** `burnIfChanged` returns before anything else unless
> the hook's `data-can-annotate` is `"true"`, which readonly sets to false.
> Pinned in `test/js/annotation_burn.test.cjs`.

### NITPICK: a client can write unlimited warnings

`log_readonly_blocked/2` logs at `:warning` for every refused event, and a
client can send them as fast as it likes. The attempt is worth knowing
about, so this is left as is; a rate limit or `:info` is an option if it
shows up in log volume.
