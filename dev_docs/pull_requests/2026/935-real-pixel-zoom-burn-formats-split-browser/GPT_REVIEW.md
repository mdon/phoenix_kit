# GPT review — PR #935: zoom, burn formats and media browser split

**Reviewed:** 2026-10-15  
**Author:** alexdont  
**Merge:** `c49fa22ce`  
**Baseline including follow-up fixes:** `8290529b6`

## Scope

Reviewed the latest merged PR's burn controller and image processing changes,
the annotation capture/upload changes, zoom scaling, library minification and
the extracted media browser's component wiring. Rechecked the existing Claude
review and follow-up so its input-parser and per-picture budget fixes remain
intact. This is a focused review of #935, not an audit of earlier merges.

## Fixed findings

### BUG - MEDIUM: animation budgets ignored frames before the final crop

`composite_animation/5` checked the animation's frame count against the output
canvas only. ImageMagick first coalesces the original frames, then resizes them
to the picture box, and only afterwards crops or pads them to that canvas.
A 120×60 output could therefore admit three 8,000×8,000 intermediate frames
(192 million pixels), exceeding the 150 million animation budget. The earlier
follow-up's 100 million per-picture check permits each such frame individually.
The source canvas also had no per-image budget, including on the still fallback.

The animation budget now uses the largest pixel count of the source canvas,
resized picture and final canvas. The source also passes the existing per-image
budget before conversion, including for `still: true`. Existing ImageMagick
resource limits remain in place; this closes the preflight gap rather than
claiming requests previously had no resource ceiling.

Three regression tests cover oversized accumulated resized frames, oversized
accumulated source canvases and a source above the still-image budget. The source
fixtures alter only GIF's logical-screen header, keeping the encoded patches
small and avoiding allocation of the claimed canvases. Existing tests still
exercise animation, transparency, positioning and the frame-limit still fallback.

### IMPROVEMENT - MEDIUM: failed capture left live styles and selection altered

`burnCapturePlan` suspended selection/hover classes and inserted a stylesheet
disabling transitions before cloning and reading computed styles. An exception
in either operation skipped cleanup, leaving both the stylesheet and modified
live shape state behind. The earlier review recorded the stylesheet leak;
the selected/hovered classes were affected as well.

The clone/style-read section now restores classes and removes its stylesheet
in `finally`. Two behavior tests inject failures during cloning and computed
style reading and verify the original exception propagates while the live state
is restored. Both tests fail against the baseline JavaScript bundle.

## Remaining limitations

- Photo burns require ImageMagick's WebP encoder. The existing review's proposed
  PNG fallback or doctor check remains open; this follow-up does not change the
  chosen output format or deployment contract.
- Burn zoom remains an estimate when markup extends past the picture on both
  axes: `burn_scale/3` has the original and stored dimensions, but no stored ink
  bounds. Exact scaling would need additional burn geometry metadata.
- These checks do not constitute interactive browser verification of zoom and
  selection styling; the capture tests run with a small DOM stand-in.

## Validation

- `mix format` and `git diff --check` passed.
- Focused PostgreSQL-backed run: **30 tests, 0 failures**, covering composite
  animation, burn formats end to end, format/layout parsing and viewer libraries.
  Integration tests ran; only the unrelated `:requires_createrole` tag was excluded.
- Related media browser/viewer, burn replacement, image processor and annotation
  thumbnail tests: **254 tests, 0 failures**, including PostgreSQL integration tests.
- `node --test test/js/annotation_burn.test.cjs`: **32 tests, 0 failures**.
- `mix precommit` passed: compilation with warnings as errors, unused-lock check,
  compilation of the test tree, format check, strict Credo, Dialyzer and all
  **377 JavaScript tests**. Dialyzer used the repository's existing ignore file
  (284 suppressed warnings; four unnecessary suppressions reported).
