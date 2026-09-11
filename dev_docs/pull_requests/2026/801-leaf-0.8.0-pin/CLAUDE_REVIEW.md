# PR #801 — Pin the Leaf CDN bundle to v0.8.0

**Author:** alexdont (`leaf-0.8.0-pin`) · **Merged:** 2026-09-11 · **Reviewed:** 2026-09-11

## Verdict

The two halves that matter moved correctly — **lock and CDN pin are in step at
0.8.0**. But the third change, the one the PR description leads with
("requirement widened to `~> 0.8`"), **does nothing**: the requirement it edited
already admitted 0.8.0, and still admits 0.9.0, 0.10.0 and everything else below
1.0.0. The enumeration reads as a curated support window and is not one. Fixed
here, with the guard test that would have caught it.

## Summary

Bumps `leaf` 0.7.0 → 0.8.0: `mix.lock`, the `LEAF_CDN` constant in
`priv/static/assets/phoenix_kit.js`, and an `or ~> 0.8` appended to the `mix.exs`
requirement. Same three-file shape as #799 (0.7.0), #776 (0.6.1) and #709 (the
lockstep pattern itself).

## Verified

- **Both halves moved together.** `mix.lock` → leaf 0.8.0 (`e58c5593…`, matches
  Hex); `LEAF_CDN` → `leaf@v0.8.0`. `curl -I` against
  `cdn.jsdelivr.net/gh/alexdont/leaf@v0.8.0/priv/static/assets/leaf.js` → 200.
- **0.8.0 is Hex's latest leaf** (`0.8.0, 0.7.0, 0.6.1, …`), so the pin is not
  reaching for an unpublished tag.
- **Guard tests green:** `leaf_bundle_pin_test.exs` and
  `vendored_cdn_pins_test.exs` (9 tests) pass before and after the fix below.
- **Nothing in core half-integrates 0.8.0's features.** The atomic-chip batch is
  client-side leaf.js behavior; `rg` finds no new message name, command or attr
  from 0.8.0 referenced in `lib/` or in `phoenix_kit.js`. No dangling contract.

## BUG - MEDIUM — the widened requirement is inert, and the ceiling is open

`mix.exs:189` (pre-fix):

```elixir
{:leaf, "~> 0.4.1 or ~> 0.5 or ~> 0.6 or ~> 0.7 or ~> 0.8"}
```

`~>` with no patch segment takes the **major** as the ceiling: `~> 0.5` is
`>= 0.5.0 and < 1.0.0`, not "the 0.5 line". So the second alternative already
swallows the entire 0.x range, and `or ~> 0.6 or ~> 0.7 or ~> 0.8` are all
no-ops. Verified against `Version.match?/2`:

| version | pre-#801 requirement | post-#801 requirement |
|---|---|---|
| 0.4.0 | false | false |
| 0.7.0 | true | true |
| **0.8.0** | **true** | true |
| **0.9.0** | **true** | **true** |
| **0.12.3** | **true** | **true** |
| 1.0.0 | false | false |

The two requirements are **the same set**. #801's `mix.exs` hunk changed nothing
a resolver can observe.

Two consequences, the second the one that bites:

1. **The comment above the dep is self-defeating.** It rejects `~> 0.3` because
   "that spanned 0.3 → 0.9, and for a 0.x package where each minor is
   effectively a major it claimed a support window core cannot back" — then
   declares `~> 0.4.1 or ~> 0.5`, which spans 0.4.1 → 0.9.x. The stated intent
   has never been implemented; every per-minor PR since #709 has been ceremony.

2. **The open ceiling defeats the CDN pin.** Core is not an ordinary consumer of
   leaf: `priv/static/assets/phoenix_kit.js` serves the *browser* half from an
   exact jsDelivr tag while Hex resolves the *Elixir* half. Core's own
   `mix.lock` keeps those together here, but a **host** resolves leaf itself —
   and with the ceiling at 1.0.0, the day leaf 0.9.0 ships, `mix deps.update` in
   any host floats the server half past the frozen `leaf@v0.8.0` bundle. That is
   precisely the silent cross-version editor `leaf_bundle_pin_test.exs` and
   `vendored_cdn_pins_test.exs` were written for — and neither can see it,
   because both only compare versions **this** project resolved.

### Fix applied

`mix.exs` — every alternative now carries a patch segment, so the union is
`>= 0.4.1 and < 0.9.0`, the window the comment always claimed:

```elixir
{:leaf, "~> 0.4.1 or ~> 0.5.0 or ~> 0.6.0 or ~> 0.7.0 or ~> 0.8.0"}
```

The comment was rewritten to state the `~>` semantics and why the ceiling is
load-bearing *here* specifically. `mix deps.get` re-resolves with **no lock
change** — 0.8.0 satisfies both forms — so this is a contract fix, not a bump.

`test/phoenix_kit_web/leaf_bundle_pin_test.exs` — new third test,
`"mix.exs does not admit a leaf minor the bundle cannot serve"`: derives the next
minor above the CDN pin (0.8.0 → 0.9.0) and asserts the requirement **rejects**
it. Confirmed non-tautological — reverting `mix.exs` to the merged text fails it
with the message above, then passes again restored. The existing
`"the pinned version is one mix.exs permits"` test could never have caught this:
it only checks the floor side, which was always right.

## Noticed, not fixed

### The same open ceiling applies to the other three CDN-pinned siblings

`mix.exs:223-225` declares `{:fresco, "~> 0.10"}`, `{:tessera, "~> 0.3"}`,
`{:etcher, "~> 0.9"}` — all `< 1.0.0` ceilings against exact jsDelivr tags for
resolved 0.11.0 / 0.3.5 / 0.13.1. `vendored_cdn_pins_test.exs`'s own moduledoc
records this failure mode happening in production twice, etcher's pin **three
minors** behind. Not fixed here: #801 is a leaf PR, and tightening three more
requirements is a resolution-affecting change for every host that deserves its
own PR and its own release note. The generalized guard belongs in
`vendored_cdn_pins_test.exs` (which already enumerates all four) rather than in
leaf's file — worth doing there in one pass.

### Correction to the #799 review

`dev_docs/pull_requests/2026/799-leaf-0.7.0-pin/CLAUDE_REVIEW.md` reports that
`phoenix_kit_publishing`'s `{:leaf, "~> 0.4.1 or ~> 0.5"}` "caps resolution below
0.6.0" and strands that package behind, and recommends a follow-up PR widening
it. **That is wrong, for the same `~>` reason this review is about**: `~> 0.5` is
`>= 0.5.0 and < 1.0.0`, so publishing already admits 0.8.0 — confirmed by its own
`mix.lock`, which sits at leaf **0.7.0**. There is no drift and no follow-up PR
to open. A correction pointer was added to that file so the recommendation is not
acted on. (After this PR's fix, core is the *narrower* of the two —
`< 0.9.0` ∩ `< 1.0.0` — which is the correct direction: core owns the CDN pin,
so core owns the ceiling.)

## Not changed

The lock, the `LEAF_CDN` value, and `vendored_cdn_pins_test.exs` — all correct as
merged.
