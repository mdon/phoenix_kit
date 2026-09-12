# PR #802 — Fix the open version ceilings on the other pinned-bundle deps

**Author:** alexdont (`dep-ceilings`) · **Merged:** 2026-09-12 · **Reviewed:** 2026-09-12

## Verdict

The ceiling half is correct and closes the "noticed, not fixed" item in the #801
review (`801-leaf-0.8.0-pin/CLAUDE_REVIEW.md`). The generalized test really
guards something. But the PR only looked at ceilings, and the **`:etcher` floor
it kept is wrong in a way core's own code can hit**. Fixed here.

## Summary

- `mix.exs`: `{:fresco, "~> 0.10"}` → `"~> 0.10.0 or ~> 0.11.0"`,
  `{:tessera, "~> 0.3"}` → `"~> 0.3.0"`, `{:etcher, "~> 0.9"}` →
  `"~> 0.9.0 or … or ~> 0.13.0"`, plus a comment pointing at `:leaf`'s rationale.
- `vendored_cdn_pins_test.exs`: a per-sibling test. The resolved version must
  satisfy the requirement, and the next minor above it must not.

## Verified

- **Resolution unchanged.** The lock still resolves fresco 0.11.0, tessera
  0.3.5, etcher 0.13.2 (the last after #803) and leaf 0.8.0. Each matches its
  CDN tag and Hex's latest release.
- **The new test catches the bug.** With the three pre-PR requirements
  temporarily restored in `mix.exs`, the fresco, tessera and etcher ceiling
  tests all fail (10 tests, 3 failures). They pass again once the PR's
  requirements are back.
- **No sibling package is squeezed.** No `phoenix_kit_*` package in the
  workspace declares fresco, tessera or etcher. Only stale forks under
  `decor3dprint/` carry the old requirements. Tessera 0.3.5's own
  `~> 0.10.0 or ~> 0.11.0` fresco constraint is the same window core now
  declares.

## BUG - MEDIUM — the `:etcher` floor admits versions core's code cannot run on

The PR kept every old minor in the enumeration, so the requirement was
`>= 0.9.0 and < 0.14.0`. But core consumes Etcher APIs well above 0.9:

| Core usage | Introduced |
|---|---|
| `connectors={:off}` on `<Etcher.layer>` (`media_canvas_viewer.html.heex`) | 0.12.2 |
| `etcher:tooltip-action` bridge in `phoenix_kit.js` | 0.13.0 |
| `panel_offset={%{top: 56}}` on both `<Etcher.layer>` embeds (#803) | 0.13.2 |

**Scenario:** a host's `mix.lock` holds etcher 0.12.1. It runs
`mix deps.update phoenix_kit`. The resolver only unlocks phoenix_kit, and 0.12.1
still satisfies the requirement, so etcher stays put. phoenix_kit then compiles
against 0.12.1 with an undeclared-attr warning buried in dep output. At runtime
`connectors` and `panel_offset` are silently ignored: connector anchors come
back on the lightbox (the bug 0.12.2 fixed), and the style panel collides with
the viewer chrome again. Meanwhile the lazy loader serves the **0.13.2**
browser bundle against a 0.12 server half. That is the cross-version drift this
whole pin discipline exists to prevent, just from below instead of above.

The PR description even names the floor side ("the floor even admits 0.10.x
hosts running under the 0.11 bundle") and leaves it open.

### Fix applied

`{:etcher, "~> 0.13.2"}` (`>= 0.13.2 and < 0.14.0`). A comment explains why
this floor is load-bearing and says to raise it whenever core starts consuming a
newer Etcher API. The lock does not move. The affected host now gets a resolver
conflict naming etcher, which is loud and fixable, instead of a degraded viewer.

### Why no test for the floor

The ceiling can be tested by checking a synthetic version against the
requirement. A floor can't be tested that way. The question is "does core's
code work on the oldest version the requirement admits", and answering it needs
that version installed. A test that hardcodes `refute Version.match?("0.13.1", …)`
would just restate the requirement. The rationale lives in the `mix.exs`
comment instead.

## Noticed, not fixed

- **The fresco and tessera floors** (`~> 0.10.0` under a 0.11.0 bundle,
  `~> 0.3.0` under 0.3.5) are left as merged. Core uses no Fresco 0.11
  server-side API, and 0.11.0's changes are client-side (middle-drag pan,
  drag-capture exemption). Tessera 0.3.1–0.3.5 are constraint and bugfix
  patches. The cross-version window is real but has no known failure, so
  there is no evidence to justify forcing a resolution change on hosts.
- **The leaf floor** (`~> 0.4.1` under the 0.8.0 bundle) is the same class of
  question and was a deliberate choice in #709 and #801. It is out of scope
  here. If a core call site starts depending on a leaf ≥ 0.5 API, apply the
  etcher treatment.
- **Duplicate leaf ceiling check.** The generalized test also runs for `:leaf`,
  so `leaf_bundle_pin_test.exs`'s "does not admit a leaf minor" test is now
  redundant. It is harmless and carries leaf-specific context, so it stays.

## NITPICK — fixed

The requirement lookup piped `Regex.run/2` into `fn [_, req] -> req end`. A
renamed or restructured dep line would have raised a bare `FunctionClauseError`.
It now `flunk`s naming the missing requirement, matching
`leaf_bundle_pin_test.exs`.
