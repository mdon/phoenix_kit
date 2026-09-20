# PR #836: Show a placeholder when a preview card has no media

**Author**: @mdon (Max Don)
**Reviewer**: @claude (Fable 5.1)
**Status**: ✅ Merged
**Commit**: `18926293`
**Date**: 2026-09-20

## Goal

A `preview_card` with no images and no files collapsed to a bare field list;
it now draws a `h-40` "No images" placeholder so the card keeps its shape.

## Verified

- `:if={@slide_count == 0}` is the exact complement of the track's condition; both tests cover each side.
- `"No images"` was already a msgid (MediaBrowser), translated in every locale — no new string.

## Findings

### NITPICK — POT references were stale (fixed)

`mix gettext.extract --check-up-to-date` failed after the merge: the new
`preview_card.ex` reference was missing. Re-ran extract/merge; reference
comments only, 0 fuzzy.

### NITPICK — wording

The placeholder says "No images" when the card has no *files* either. Fine for
the catalogue popup that motivated it; noted only.
