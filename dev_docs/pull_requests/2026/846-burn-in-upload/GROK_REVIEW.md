# PR #846: Burn annotations into the picture, so the markup travels with it

**Author**: @alexdont
**Reviewer**: Grok
**Status**: ✅ Merged
**Commit**: `2dd5cce3` (review fixes follow on main)
**Date**: 2026-09-21

## Goal

A file's variants were the picture as uploaded, so a grid card, a list row,
and a copied image showed the photo without the arrows and measurements.
The browser now composes the live Etcher overlay when an editing session
ends and stores that rendering. `Etcher.Raster` stays the server path for
backfill.

## Verified

- The merge kept `tooltip_dock={:panel}` on the viewer's Etcher layer. The
  branch diff against its base removed it; the merge with main did not.
- `Etcher.Raster` 0.16 (the pin in `mix.exs`) draws a text or callout label
  from `metadata.title` and sizes it from the box. It does not read a
  top-level `"title"` key, and it ignores `canvas_width` / `canvas_height`.
  A dimension is drawn as a line only; the measurement text is not a
  primitive in this version.
- The viewer opens on `urls["small"]` and Tessera climbs `medium` → `large`
  → `original` (`build_viewer_canvas/3`, the sources list in the template).
  Grid cards use `MediaThumbnail.resolve_url/2` with `:card`, which preferred
  `small` ahead of `thumbnail`. List rows use `:small`, which prefers
  `thumbnail`.
- `store_prepared_variant/6` only drops a variant when the `source_key` it
  is given is no longer the original. Reading that key at the start of the
  request and passing it straight through does not detect an original that
  changed before the request.
- `ImageEditing` allows the owner, a system role, or the media module.
  `User.admin?/1` is a database role check and does not honour the active
  role. `FileController` documents why `can_access_admin_area?/1` is the
  wrong staff bypass.
- `ImageProcessor.sanitize/3` is the re-encode that caps pixels and
  ImageMagick resources. Nothing in the burn path called it; the new
  controller shelled out to `convert` on the raw upload.
- The route sits in the browser pipeline, so `protect_from_forgery` checks
  the `x-csrf-token` header the hook sends.

## Findings

### BUG - HIGH: the burn overwrote the rungs the editor paints (fixed)

The hook's default was `thumbnail,small,medium,large`. After the first
session, reopening the viewer loaded the burned `small` (then burned
`medium` and `large`) and drew the live shapes on top, so every annotation
appeared twice. On a picture over 4K the Tessera list omits `original`, so
the next burn composed onto the already-burned `large` and the ink stacked.

`small`, `medium`, `large`, and `original` are not writable. The burn is
stored as `thumbnail` (list rows) and `burned` (fit inside 800px). Cards
prefer `burned`, then the server bake, then the clean `small`. The server
rejects a request that names the ladder, so an old cached bundle cannot
write it either.

### BUG - HIGH: the label column never reached Raster (fixed)

The bake added `"title" => a.title` beside `metadata`. Raster 0.16 reads
`metadata.title` only, which is the projection the live viewer already
makes in `load_annotations_for/1`. Named text and callout shapes kept
baking as empty boxes.

`AnnotationThumbnail.raster_annotations/1` copies a non-blank column title
into `metadata.title`, and the column wins over a stale metadata copy.
`canvas_width` / `canvas_height` are the picture's real pixel size for a
Raster that scales reference-canvas label sizes; 0.16 ignores them and
sizes a label from its box.

A dimension's measurement is still not drawn by Raster 0.16. The client
burn includes it, because that path composites the SVG on screen.

### BUG - MEDIUM: the endpoint's idea of "who may edit" was the Admin role (fixed)

`User.admin?/1` misses a media-module holder, who can already annotate and
can already run an image edit, and it ignores the active role. The comment
called this "anyone who can reach the admin area", which is
`can_access_admin_area?/1` — a gate `FileController` explicitly refuses for
cross-user file access.

The burn now allows the owner, `Scope.system_role?/1`, or
`Scope.has_module_access?(scope, "media")`, matching `ImageEditing`.

### BUG - MEDIUM: the stale-original check compared the key to itself (fixed)

`original_key/1` loaded the current original and passed it as `source_key`.
`publish_variant/9` then asked whether that key was still current, which is
true unless the original changed during `convert`. A burn composed before
a crop or rotate was filed against the new picture.

The hook sends `source_version`, the `v` query on the original URL the
viewer was rendered with. A value that is not the original's version now
is `409 STALE`. The key from that same read is what `store_prepared_variant`
re-checks, so a change during the re-encode still rolls the write back.

When the original URL carries no version, or the client omits the field,
there is nothing to compare and the write proceeds. An authorized caller
can already replace these variants with any picture; the check is what
stops the honest stale composite. Media browser URLs are versioned, and
the hook sends the value.

### BUG - MEDIUM: the upload was trusted as far as `convert` (fixed)

`Plug.Upload.content_type` is the client's claim, and the `convert`
invocation had no resource limits and no pixel budget. A small file that
decodes to a huge bitmap would have been decoded in the request.

The bytes are checked for JPEG or PNG magic, then passed through
`ImageProcessor.sanitize/3` once (format allowlist, 40 megapixel cap,
ImageMagick memory/time limits, re-encode). Each slot is a resize of that
JPEG, not of the upload.

### BUG - MEDIUM: a second session-end during the upload was dropped (fixed)

`burnIfChanged` returned immediately while a burn was running. Closing the
viewer in that window set a flag, and the retry ran after the overlay had
been removed, so the later drawing was never captured.

The plan is taken while the overlay is still in the DOM (the close listener
is on the way in) and held as `_pending`. When the in-flight upload
finishes, that plan is what gets rendered. The viewer's own `<img>` is
still not swapped, so the live shapes are not drawn twice in the session
that made them.

### BUG - MEDIUM: the hook could compose someone else's canvas (fixed)

If the fresco canvas was not inside the annotation column, the hook fell
back to `document.querySelector` for both the canvas and the Tessera
source list. Another picture on the page would have been burned into this
file.

Both lookups stay inside `pk-annotation-actions-*`. The hook is mounted
for images only, including the detail page (`viewer_only`); a video or PDF
no longer listens for every Escape.

### IMPROVEMENT - MEDIUM: the first burn did not change the card that was showing `small` (fixed)

`_refresh` rewrites an `<img>` whose src already contains the variant that
was replaced. Cards were showing `small`, and `burned` is a new slot, so
the card would have kept the plain picture until the next full load.

A successful write broadcasts `{:phoenix_kit_file_thumbnail_updated, uuid}`.
The media browser refreshes that grid row and leaves an open viewer
mounted. `:card` resolution then picks `burned`.

### Left as they are

- **Copy Image on the viewer's `<img>` copies the plain bitmap.** The
  overlay is SVG, and the `<img>` is a clean rung on purpose. Burning that
  rung is what drew the shapes twice. Showing the burn in the viewer
  without a second drawing is the eye-toggle the PR deferred.
- **A link that points at `medium` or `original` stays the plain photo.**
  Featured images and preview cards build those URLs directly. The grid
  and the list row are the surfaces this burn updates.
- **The detail page's back button does not burn.** It is a `history.back()`
  click, not `close_viewer`. Turning Etcher off does burn. `pagehide`
  cannot `keepalive` a multi-megabyte body.
- **With server annotated thumbnails enabled, a list row still prefers
  `thumbnail_annotated`.** That slot is the 400px server bake. The client
  burn of the 150px `thumbnail` is the fallback when the bake is absent.
  Cards prefer `burned` either way, and the server job does not write
  `burned`, so it does not clobber the client rendering.
- **No HTTP round-trip test.** The policy (slots, caller, magic, version,
  the Raster projection, the card URL) is covered without Postgres. A
  stored object still wants ImageMagick and a database.

## Tests

- `AnnotationBurnControllerTest` — ladder slots refused, owner / media /
  system role, JPEG and PNG magic, source version.
- `AnnotationThumbnailRasterTest` — column title is what Raster draws.
- `MediaThumbnailTest` — cards prefer `burned`; list rows do not load it.
- `test/js/annotation_burn.test.cjs` — default slots, no document-wide
  canvas lookup, pending plan while a burn is in flight.
