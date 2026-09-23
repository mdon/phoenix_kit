# PR #865 — Fix the burn missing an emptied board, and refresh viewers sitting on a burned copy

**Author:** alexdont · **Merged:** 2026-09-23 (f853c528) · **Reviewer:** Claude · **Released in:** not yet released

## Summary

Three fixes in the annotation burn:

1. **An emptied board is now burned.** `_signature()` returns `null` before
   Etcher hydrates and `""` for an empty board. The check `if (!now) return`
   treated both as "nothing to do". So rubbing out the last shape never
   re-burned the image, and the stored copy kept the markup. It now checks
   `now == null`.
2. **One drawing is burned once.** Closing the editor ended the session, and
   the canvas swap that followed tore the layer down, which ended it a second
   time. That second end came before the first upload had answered, so the
   whole picture was composed and uploaded twice. A new `_inFlight`
   fingerprint stops the duplicate. It is cleared on success and on failure:
   the final `.then` runs after the `.catch`.
3. **Other viewers follow a new burn.** When a burn is stored, the
   `thumbnail_updated` path now also pokes an open viewer
   (`poke_viewer_burn/2` → `MediaCanvasViewer.update(%{burn_refreshed: …})`).
   The viewer takes the new burned canvas only in burn mode, and only if its
   stamp (the fingerprint, or else the URL's `v=`) differs, so an open editor
   is never interrupted and the same picture is never remounted.

Verdict: sound, well reasoned, and covered by the node tests in
`test/js/annotation_burn.test.cjs`.

## Findings

### NITPICK — a doc comment was left above the wrong function (fixed)

`poke_viewer_burn/2` was inserted between `refresh_processed_file/3` and
that function's own comment, so the refresh comment ran straight into the
poke's. **Fix:** moved `poke_viewer_burn/2` above the refresh comment.

### NITPICK — cost of the poke (no action)

Every connected browser that receives `thumbnail_updated` re-reads and
re-enriches the file, but only when its open viewer shows that exact file,
which the `with` checks first. That's one `get_file` plus `enrich_files`
per burn per matching viewer. Fine.
