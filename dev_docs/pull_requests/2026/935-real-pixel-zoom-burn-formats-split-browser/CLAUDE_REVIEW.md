# Claude review — PR #935: real-pixel zoom, burned copies that keep transparency and animation, a split media browser, minified viewer libraries

**Author:** alexdont · **Merge:** `c49fa22ce` · **Reviewed:** 2026-10-15 · **Size:** 34 files, +4.7k / −3.8k (most of it the browser split)

**Verdict:** sound. No CRITICAL or HIGH finding. The burn pipeline holds up under a real ImageMagick: an animated GIF keeps
every frame with the markup on each one, a margin stays see-through, the signed offsets place the picture correctly, and
an old JPEG burn is replaced by the new format rather than left next to it. Two hardening gaps in the new
`layout_*` input are fixed below; the rest is recorded.

How it was checked: the controller / `ImageProcessor` / `ViewerLibraries` / viewer / JS diffs read in full; the
`media_browser` split verified by comparing the old `media_browser.html.heex` against the five new templates line by line
(only formatter reflow and `gettext(...)` call re-wrapping differ — no markup lost or added); the burn pipeline driven
for real (ImageMagick 6.9 with libwebp) through new tests, since the PR's own tests cover the format table and the layout
parser but not the pipeline itself.

## Fixed in this follow-up

### BUG - MEDIUM: a nested `canvas_w[a]=1` param crashed the burn request (500)
`layout_number/1` ran `to_string(value || "")` over whatever the client sent; a map (`canvas_w[a]=1`) raised
`Protocol.UndefinedError`, which the controller's `with` does not rescue. (A one-element list, `canvas_w[]=800`, slipped
through as the number 800.) Authenticated writers only, so a noisy 500 rather than a hole, but it is the one place a
client-shaped value reached a bare conversion. `layout_number/1` now takes binaries only; anything else is `nil`, so
`layout_from_params/1` answers `:error` and a GIF falls back to the still PNG. Tests: `annotation_burn_format_test.exs`
("a nested param…") and the end-to-end "a forged layout does not crash the request".

### BUG - MEDIUM (resource): the picture's box was unbounded relative to the canvas
`composite_animation/5` checked the pixel budget of the *canvas* only. The picture box (`w`×`h`) is the client's claim,
multiplied by `overlay_real_size / claimed_canvas` in `scale_layout/3`: a claimed 1×100 canvas with a 16 000 px picture and
a real 2 000 px overlay scaled to a 32 000 000 × 320 000 `-resize`. The `-limit` flags would end it in an ImageMagick
failure, but a request-derived number should not reach `convert` unchecked, and the failure surfaced as
"could not compose" rather than the budget refusal everything else uses. The picture box now goes through the same
`check_pixel_budget(w, h, @resize_max_pixels)`. Test: `composite_animation_test.exs` ("a picture box the client claims
far past any budget is refused").

### Test gap: the burn pipeline had no test of its own
New: `test/phoenix_kit/modules/storage/composite_animation_test.exs` (frames kept, markup on every frame, margin
see-through, negative offsets, scaled box, `still: true`, over-the-frame-limit → `:too_large`, budget refusal) and
`test/integration/phoenix_kit_web/burn_formats_test.exs` (the controller end to end: photo → WebP, GIF → a playing GIF with
the markup on each of its frames, GIF without a layout → a still PNG, a forged layout, and an existing JPEG burn replaced
by the WebP one with a single `burned` row left). These caught nothing wrong in the PR's logic — they lock it in.

## Recorded, not fixed

### IMPROVEMENT - MEDIUM: a photo burn now needs ImageMagick built with WebP
A photo used to burn as a JPEG, which every ImageMagick writes. It now burns as WebP (to keep the margin the markup opens
up past the picture's edges see-through), so on a host whose ImageMagick lacks libwebp every photo burn answers
`convert_failed`, where it worked before. WebP is already a variant format the storage module offers, so this is a
deployment assumption rather than a new one, but `phoenix_kit.doctor` does not check for the delegate. A fallback to PNG
on a failed WebP sanitize (or a doctor line) would close it; left for the author because the right default (silent PNG
fallback vs. a loud doctor warning) is a product call.

### IMPROVEMENT - MEDIUM: `burn_scale/3` is exact only when one axis has no spill
Documented in its comment: the spill past the picture is not recorded, so the scale is the larger of the two axis ratios
(a little low when both axes spill). The viewer's zoom percentage is then slightly off for a burn whose markup runs past
two edges. Recording the canvas origin/size on the instance would make it exact.

### NITPICK: `annotation_burn_format_test.exs` asserts source text
"the fingerprint is written before the file's change is announced" greps the controller's source for the two calls in
order, which breaks on any harmless refactor. A behaviour test would need the broadcast observed mid-request; the
ordering is documented in the controller comment, so it is left.

### NITPICK: the capture style tag is not removed on an exception
`burnCapturePlan` appends a `<style>` for `.pk-burn-still` and removes it a few statements later; an exception between
(none is expected from `getComputedStyle` / `cloneNode`) would leave one in `<head>`. A `try/finally` would make it
unconditional.

### Checked and fine
- **Browser split:** content-identical to the old template (see above); the `edit_target` module reference changed with the
  move and is the right one.
- **`ViewerLibraries` minify:** hash of the *source* in the file name (an unchanged library is not minified twice), the
  rename after write, esbuild missing / failing falls back to the readable copy, `Mix.env()` only evaluated at build time.
- **Replacement of an old-format burn:** `publish_variant` deletes the old row and the now-unreferenced object when the
  key changes; covered by the new integration test.
- **Floors in `mix.exs`** (`fresco ~> 0.14.0`, `tessera ~> 0.3.9`, `etcher ~> 0.22.0`) match the lock and their comments.
