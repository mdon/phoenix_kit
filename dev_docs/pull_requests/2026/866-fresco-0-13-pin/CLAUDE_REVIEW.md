# PR #866 — Update the fresco pin to 0.13.0 (with etcher 0.17.1 and tessera 0.3.8)

**Author:** alexdont · **Merged:** 2026-09-23 (cf61625d) · **Reviewer:** Claude · **Released in:** not yet released

## Summary

- fresco's requirement gains `~> 0.13.0` (0.10–0.12 are still allowed).
- The lock moves to fresco 0.13.0, etcher 0.17.1 and tessera 0.3.8. Those are
  the etcher and tessera releases whose own fresco requirement admits 0.13.
- The three CDN URLs in `phoenix_kit.js` point at the same tags.

fresco 0.13 converts wheel deltas that arrive in lines (many mice, and
Firefox) into pixels, and separates notch zoom from trackpad pan and pinch.
On 0.12, that hardware got about 0.9% zoom per notch.

Verdict: fine. `mix deps.get` resolves, and the gate passes on the merged
tree.

## Findings

### NITPICK — the browser runs the CDN version whatever the host resolved (pre-existing, no action)

The JavaScript comes from the version pinned in `phoenix_kit.js`, not from
the Hex version the host resolved. A host that pins fresco 0.12 or tessera
0.3.7 in its own `mix.exs` still runs 0.13.0 / 0.3.8 in the browser. That
was already true for every earlier pin, and nothing on the Elixir side
depends on 0.13, so the open range is correct (see memory: raise a floor
only when core uses a newer sibling API).
