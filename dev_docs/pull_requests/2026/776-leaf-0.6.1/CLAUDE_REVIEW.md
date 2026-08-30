# PR #776 — Update the Leaf pin to 0.6.1

**Author:** alexdont (`update-leaf-v061`) · **Merged:** 2026-08-30 · **Reviewed:** 2026-08-30

## Verdict

**Clean. No findings.**

A two-line pin bump where the two lines are exactly the two that have to move
together, and the repo already has tests that fail if they ever do not.

### Verified

- **Both halves moved.** `mix.lock` → `leaf 0.6.1` (hash
  `bd98537a…`), and `LEAF_CDN` in `priv/static/assets/phoenix_kit.js:4091` →
  `leaf@v0.6.1`. Confirmed `deps/leaf/mix.exs` is `@version "0.6.1"`.
- **The requirement admits it.** `mix.exs:183` —
  `{:leaf, "~> 0.4.1 or ~> 0.5 or ~> 0.6"}`. No resolver change needed, and the
  comment above it (the phoenix_kit_publishing co-resolution note) still holds.
- **Nothing else carries the pin.** Core has no `assets/` source tree —
  `priv/static/assets/phoenix_kit.js` is the artifact itself, so there is no
  second copy of the constant left stale. The usual "two lists drifted apart"
  failure has no place to hide here.
- **Both guard tests pass.** `leaf_bundle_pin_test.exs` (bundle pin vs lock) and
  `vendored_cdn_pins_test.exs` (CDN URL shape) are green.
