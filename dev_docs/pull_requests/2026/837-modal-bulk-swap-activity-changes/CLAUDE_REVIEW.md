# PR #837: Fix a dismissed modal re-opening, stop the bulk bar moving rows, and say what changed in Activity

**Author**: @mdon (Max Don)
**Reviewer**: @claude (Fable 5.1)
**Status**: ✅ Merged
**Commit**: `7ecb0b29`
**Date**: 2026-09-20

## Goal

Three independent fixes: `PkDialog` pushes the server close from Escape's
`cancel` (Chromium never fires `close` for a server-opened dialog) and
restores a morphdom-stripped `open` before closing; `bulk_select_scope` gains
`swap` so the action bar replaces a toolbar instead of pushing rows down; the
Activity pages lead with a "What changed" diff read from a reserved
`"changes"` metadata key, folding legacy `_from`/`_to` pairs in.

## Verified

- `modal/1` still never renders `open`; `_sync` remains the only opener.
- The close-echo stamp (`_pkStackClosePushedAt`, 1 s window) suppresses the
  `close` that follows a `cancel` push, and self-heals when none arrives.
- `_syncSwap` publishes the count as an element *property* and asks every
  scope, so a sibling mid-patch cannot un-hide the toolbar; `destroyed()`
  restores it.
- Core's own legacy emitters (`avatar_*`, `roles_*`, `log_user_change/4`) all
  write true pairs, so the fold is right for every row core writes.
- `resolve_title/4`'s blank fallback recurses into the `nil` clause only — no loop.

## Findings

### BUG - MEDIUM — a stacked child's close could be pushed twice (fixed)

The PR made every dialog push its close from its own `cancel`. Chromium fires
`cancel` on every dialog of a grouped chain, so when the child's handler runs
before the parent's, the child pushes and stamps — and the parent's relay then
pushed the same `data-close-event` again. For a non-idempotent close (a
toggle) that is the double fire the stamp was introduced to prevent. The
parent now skips the push when the child carries a fresh stamp; it still
closes the element. Two tests in `dialog_open_attr.test.cjs` (fresh stamp →
no push, stale stamp → push).

### IMPROVEMENT - MEDIUM — four new msgids were in no catalogue (fixed)

"What changed", "Before", "After", "changed" were never extracted. The merge
fuzzy-matched "changed" onto the imperative **"Change"** in all seven locales
(de *Ändern*, ru *Изменить*) — and fuzzy entries are served. Translated by
hand, flags cleared; 0 fuzzy in the seven.

### IMPROVEMENT - MEDIUM — the list printed an English "changed" (fixed)

The detail page translates the `%{"changed" => true}` flag in the template,
but `Index.summarize_changes/2` went through `humanize_metadata_value/1`,
which has no Gettext backend. The index now translates it itself.

### NITPICK — a JS comment said the opposite of `modal/1` (fixed)

`_restoreOpenAttr`'s comment claimed "the server now renders `open`" — left
over from the attempt the PR itself reverted. It invited re-adding the broken
fix; rewritten to match.

### IMPROVEMENT - MEDIUM — the legacy fold reads a *range* as a *change* (not fixed)

`legacy_changes/1` lifts any `x_from` + `x_to` pair. A module that logs a
range — `valid_from` / `valid_to`, `price_from` / `price_to` — will see it
under "What changed" as "Valid: 1 Jan → 31 Dec". Nothing in core emits one,
and no generic rule tells a range from a diff; a stem denylist would be a
guess. The way out for a module is the reserved `"changes"` key plus any
other name for its range. On record rather than fixed.

### NITPICK — `summarize_plain/1`'s `_to` branch is now nearly dead (not fixed)

True pairs are lifted before it runs, so it only fires for an unpaired `_to`.
Harmless; left for whoever next touches the function.
