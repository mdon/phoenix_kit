# PR #833 — Etcher pin to 0.15.0

**Author:** alexdont (`etcher-0.15.0-pin`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

3 files: `mix.exs` raises the floor `~> 0.14.0` → `~> 0.15.0` with a comment
explaining why, `mix.lock` resolves `etcher` 0.14.1 → 0.15.0, and the jsDelivr
tag in `priv/static/assets/phoenix_kit.js` moves `v0.14.1` → `v0.15.0`.

## Verdict

Correct and complete. One cosmetic finding, fixed below.

- **The floor is genuinely a floor, not a preference**, and the comment's
  reason checks out against Etcher's own 0.15.0 changelog: a thickness used to
  mean document pixels and now means a weight against a 1000px reference
  canvas (`REFERENCE_CANVAS_PX`, applied through `_inkScale`). An older Etcher
  handed a host's saved `etcher_line_params` renders it at a different weight
  on every image, which is exactly the "compiles fine, draws wrong" case the
  floor discipline exists for.
- **The reinterpretation does not need a data migration, and the range still
  matches ours.** `WEIGHT_MIN`/`WEIGHT_MAX` are 1 and 40 in 0.15.0 — the
  sliders travel 0–100 but curve onto that same 1–40 weight — and
  `MediaCanvasViewer.sanitize_line_params/1` clamps `width` to `clamp_number(w,
  1, 40)`. So no saved value is silently clipped and no stored row is out of
  range; only what the number *means* changed, uniformly, for everyone.
- **Both halves of the pin move together.**
  `test/phoenix_kit_web/vendored_cdn_pins_test.exs` asserts the `gh/` tag names
  the version Hex resolved; it passes with 0.15.0.
- `fresco` stays inside etcher 0.15.0's own requirement (`~> 0.5.9 or … or
  ~> 0.12.0`) — core resolves 0.12.x. The lock diff is the single `etcher`
  line; nothing else drifted.
- The ceiling stays closed: `~> 0.15.0` admits 0.15.x only, which is the
  discipline a CDN-pinned sibling needs (a 0.16 would ship a tag the pin test
  would catch).

## NITPICK (fixed): the floor paragraph broke the block's wrap

Inserting the 0.15 reason left one line at 99 columns where the rest of that
comment block sits under 80 (`… An older Etcher compiles with an
undeclared-attr`). The formatter does not touch comment prose, so nothing
flagged it. Rewrapped.

## Interaction with #832

Nil, and in a useful direction: #832's reset is what a user reaches for after
0.15.0 reinterprets their saved thickness. Neither PR touches the other's
files except `phoenix_kit.js`, where #833 edits the CDN tag near line 5079 and
#832 adds a hook near line 5600.
