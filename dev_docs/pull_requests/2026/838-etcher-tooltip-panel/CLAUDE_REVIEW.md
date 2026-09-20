# PR #838: Move the viewer's annotation tooltip into the style panel (etcher 0.16.0, fresco 0.12.2)

**Author**: @alexdont
**Reviewer**: @claude (Fable 5.1)
**Status**: ✅ Merged
**Commit**: `6bf010f1`
**Date**: 2026-09-20

## Goal

The media viewer passes `tooltip_dock={:panel}` so a shape's label/comment/
delete actions live in Etcher's style panel rather than over the photograph;
the etcher floor and both CDN pins move with it. Also fits a quarter-turned
photo's instant stand-in to the box it will occupy after the rotation.

## Verified

- The floor is `~> 0.16.0`, matching the first Etcher that declares
  `tooltip_dock`; CDN pin and `mix.lock` agree (etcher 0.16.0, fresco 0.12.2).
- The fresco requirement still admits 0.10/0.11 on purpose (the viewer stands
  down on older Fresco); only the CDN pin moved.
- `_hide` clears the swapped width/height.

## Findings

### BUG - HIGH — the quarter-turn fit never ran on an open from the grid (fixed)

`_show` measured `shown.parentNode.getBoundingClientRect()` *before*
`el.style.display = ""`. The stand-in rests at `display:none` (inline style in
`media_browser.html.heex`, and `_hide` puts it back), and a frame inside a
hidden element measures 0 × 0 — so the `fr.width && fr.height` guard skipped
the fit on exactly the open it was written for. It only worked when stepping
prev/next with the stand-in already visible. The test passed because its fake
frame always reported 800 × 400.

Fixed by revealing first and measuring second (one forced layout, no paint in
between), and clearing the box before measuring so an unmeasurable frame
falls back to the class-driven size instead of inheriting the last picture's.
The test's fake frame now answers 0 × 0 while the stand-in is hidden, as a
browser does; it fails against the merged code and passes against the fix.
Not browser-verified here — worth a glance at a rotated photo before relying on it.
