# PR #854: Update the etcher pin to 0.17.0

**Author**: @alexdont
**Reviewer**: Claude
**Status**: ✅ Merged (`46ddfcbc`), not yet released; review only, no fixes applied (no BUG findings)
**Date**: 2026-09-21

## Goal

Move Etcher to 0.17.0 as a floor, not a preference: 0.17 is where
`Etcher.Raster` bakes a dimension's heads, every kind's label (sized against
the `:canvas_width` / `:canvas_height` `AnnotationThumbnail` already passes)
and `style.fill`. On 0.16 a baked annotated thumbnail is a board of hollow,
unlabelled shapes. The editor gains the fixes #853 was exercised against.

## Verified

- The three places that must move together do: `{:etcher, "~> 0.17.0"}` in
  `mix.exs`, `etcher 0.17.0` in `mix.lock`, and `ETCHER_CDN` in
  `phoenix_kit.js` pointing at the `v0.17.0` tag — which is what
  `vendored_cdn_pins_test.exs` asserts.
- The only other source change is a comment in `annotation_thumbnail.ex`
  (the 0.16 caveat becomes "honoured from 0.17, which is the floor").
- Etcher 0.17.0's own dependency constraints (`fresco`, `jason`,
  `phoenix_html`, `phoenix_live_view`) are unchanged from 0.16.0, so the pin
  moves nothing else by requirement.

## Findings

### NITPICK: the lock also upgrades `phoenix_template` 1.0.4 → 1.1.0, unannounced

`mix.lock` moves `phoenix_template` a minor version alongside Etcher.
Nothing in Etcher 0.17.0 requires it (its constraints are the same as
0.16.0's), so it most likely rode in on a broader `mix deps.update` or
`deps.get` resolution. It affects only core's own dev/test/CI — a library's
lock does not reach its hosts — but a PR titled "Update the etcher pin"
should either say so or leave it out (`mix deps.update etcher` alone).

> **Left as is, deliberately.** It is now recorded here; the full suite
> passes on 1.1.0, and reverting the lock would be a downgrade for no
> behavioural reason.

### Pre-existing, noticed in passing

`ETCHER_CDN` loads `cdn.jsdelivr.net/gh/alexdont/etcher@v0.17.0/…` — a git
**tag**, which the repository owner can move, served without a Subresource
Integrity hash. The admin's browser then runs whatever that tag points at. A
commit-sha pin (`@<sha>`) or an `integrity=` on the lazy loader would make
the pin mean what `vendored_cdn_pins_test.exs` asserts it means. Same pattern
as the other vendored CDN pins, so not this PR's to fix.
