# PR #799 — Pin the Leaf CDN bundle to v0.7.0

**Author:** alexdont (`leaf-0.7.0-pin`) · **Merged:** 2026-09-10 · **Reviewed:** 2026-09-10

## Verdict

**Core-side change is clean, no fix needed.** One pre-existing cross-repo drift
noticed while verifying it (see below) — out of scope for this repo/PR, recorded
here rather than fixed silently.

## Summary

Bumps `leaf` from 0.6.1 to 0.7.0: widens `mix.exs`'s requirement to admit the
`~> 0.7` line, updates `mix.lock`, and moves `LEAF_CDN` in
`priv/static/assets/phoenix_kit.js` to `leaf@v0.7.0`. Same three-file shape as
PR #776 (0.6.1) and PR #709 (the lockstep pattern itself).

## Verified

- **Both halves moved together.** `mix.lock` → `leaf 0.7.0`
  (`c3b1618f…`); `LEAF_CDN` → `leaf@v0.7.0`. `deps/leaf/mix.exs` confirms
  `@version "0.7.0"`.
- **The requirement was widened, not just satisfied.** Unlike #776 (0.6.1 fit
  the existing `~> 0.6`), 0.7.0 needed a new `~> 0.7` alternative — added
  correctly at `mix.exs:188`, preserving the existing floor and every earlier
  line.
- **Guard tests pass.** `leaf_bundle_pin_test.exs` (pin vs lock) and
  `vendored_cdn_pins_test.exs` both green.
- **The CDN tag actually resolves** — `curl -I` against
  `cdn.jsdelivr.net/gh/alexdont/leaf@v0.7.0/priv/static/assets/leaf.js` returns
  200.
- **Nothing in core consumes the two 0.7.0 features yet** (wiki-link chips in
  hybrid source mode is pure client-side leaf.js behavior, no core call site;
  the `{:leaf_conflict, …}` / `Room.stop/1` / `idle_after` collab additions
  have zero references in `lib/` or `priv/static/assets/phoenix_kit.js`), so
  there's no dangling half-integration to check.

## Noticed, not fixed: `phoenix_kit_publishing`'s own leaf pin is now two lines behind

`phoenix_kit_publishing/mix.exs` declares its own direct
`{:leaf, "~> 0.4.1 or ~> 0.5"}` (it renders the post editor itself, per its own
comment there). That requirement caps resolution below 0.6.0. Core's comment at
`mix.exs:180-187` narrates the exact failure mode this reproduces — a resolver
that can reach a newer leaf while a dependent package's own requirement excludes
it "silently strand[s] that package a release behind rather than reporting a
conflict." That's precisely what's happening now: a host resolving both
packages gets leaf ~0.5.x for `phoenix_kit_publishing`'s editor while everything
else on the same host (core's comment composer) is free to resolve 0.7.0 — no
resolver error, just silent drift, because `~> 0.4.1 or ~> 0.5` and core's
`~> 0.4.1 or ~> 0.5 or ~> 0.6 or ~> 0.7` still overlap at the 0.5.x line.

This predates #799 — it's been true since core picked up `~> 0.6` — and #799
doesn't introduce or worsen the *mechanism*, just the gap (now three minors
instead of two). Not fixed here: it's a different repo/PR
(`phoenix_kit_publishing`), and `leaf_bundle_pin_test.exs` only holds core's own
lock and CDN pin together, not a sibling package's requirement. Worth a
follow-up PR against `phoenix_kit_publishing` widening its own range the same
way core's was widened.

## Not changed

Nothing else. No CHANGELOG entry existed for this commit prior to release —
added as part of shipping 2.22.16 (see CHANGELOG.md).
