# PR #526 — Add selected-card indicator to SortableGrid styles

**Author:** @mdon
**Branch:** `feat/sortable-grid-handle-flash-selection` ← `dev`
**Merged:** 2026-05-09T10:39:55Z (`06758c8f`)
**Diff:** +7 / -0 (1 file, 1 commit)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/526

## Verdict

**APPROVE.** Tight, focused, low-risk change: a single CSS rule
appended to the runtime-injected SortableGrid stylesheet that paints
sortable cards whose internal checkbox is checked. The selector
choice (`:has()` against a checked `input[type="checkbox"]`) is the
right call given the constraint stated in the PR body — `<.table_default>`'s
card view has no per-item `selected={...}` attr, so the consumer can
neither pass selection state through nor brand a class onto the
specific card. CSS state-following-DOM is the cleanest available
shape.

Two NITPICK items below worth knowing about for follow-up; neither
is a blocker.

## What changed

| Layer | Change |
|---|---|
| `priv/static/assets/phoenix_kit.js` | One CSS rule added inside `injectStyles()` of the SortableGrid module. Selector: `.sortable-item.card:has(input[type="checkbox"]:checked)`. Styles: `background-color: oklch(var(--p) / 0.15) !important; box-shadow: inset 4px 0 0 0 oklch(var(--p));` |

The new rule sits between the existing wiggle keyframes and the
reorder-flash rules (`phoenix_kit.js:162-168`) — i.e. colocated with
the other sortable-card visuals it logically belongs with.

Companion change is consumer-side in `phoenix_kit_catalogue`'s
`item_table` (mirrors the table-row treatment); out of scope here.

## How it works

1. `<.table_default>` always emits `class="card card-sm bg-base-200 shadow-sm sortable-item"`
   on each card when `@on_reorder` is truthy
   (`lib/phoenix_kit_web/components/core/table_default.ex:236-239`).
   So `.sortable-item.card` is the stable join.
2. The checkbox is rendered by the consumer (e.g. catalogue) inside
   the card body; its `:checked` state reflects real DOM, which
   LiveView keeps in lockstep with server state via `phx-change` /
   `phx-click` round-trips.
3. `:has()` is supported in all modern evergreen browsers (Safari
   15.4+, Chrome 105+, Firefox 121+). Older browsers degrade to "no
   indicator" — graceful, no regression vs. pre-PR behavior.

## Findings

### NITPICK — `:has()` selector is broader than the PR body implies

The PR body says "the card's internal checkbox" but the selector
matches **any** descendant `input[type="checkbox"]:checked`
anywhere inside `.sortable-item.card`. For consumers who embed
unrelated form checkboxes inside a card body (e.g. a "favorite"
toggle, a per-card "publish" switch implemented as a checkbox, an
inline form), the card will paint as "selected" whenever any of
those is checked.

For the current consumer (`phoenix_kit_catalogue` bulk-select) the
card has only the one bulk-select checkbox, so this is benign today.
But the rule lives in shared `phoenix_kit.js` and applies to every
sortable card in every consumer.

**Why a nitpick, not a blocker:** no current consumer trips it; the
fix is ergonomic, not correctness.

**How to apply:** if a second consumer hits this, switch to an
opt-in attribute (`[data-pk-selectable]:has(...)` on the consumer's
selection-checkbox specifically) or require a wrapper class
(`.pk-selectable-card`). Both keep the "card view is opaque" guarantee
while narrowing intent.

### NITPICK — `!important` on `background-color` is mostly defensive

The injected `<style>` is appended to `<head>` at runtime via
`injectStyles()`, so it lands **after** the bundled Tailwind
stylesheet in source order. Combined with the rule's specificity
(`(0,3,0)` vs. `bg-base-200`'s `(0,1,0)`) the new rule already wins
without `!important`.

`!important` is only load-bearing if a future consumer sets a
higher-specificity background somewhere up the cascade (rare).
Harmless to keep — flagging only because the asymmetry with
`box-shadow` (no `!important`) is conspicuous, and someone reading
the line later might wonder why one and not both. Either drop the
`!important` or note the asymmetry inline.

### IMPROVEMENT - LOW — No automated coverage

`<.table_default>` test coverage is already a tracked TODO in
`CLAUDE.md` ("Component test coverage for `phoenix_kit_web/components/core/`"),
including specifically the card-view sortable wiring. This PR
neither adds nor regresses coverage relative to that baseline. Fold
the selected-card indicator into that future component-coverage
sweep; not a per-PR ask.

## Things I deliberately did **not** flag

- **Reduced motion:** The indicator is static; no animation, no
  `prefers-reduced-motion` concern.
- **Color contrast on dim themes:** A 15% primary tint over
  `bg-base-200` can be subtle, but the 4px primary left edge is the
  unambiguous signal — accessibility is carried by the border, not
  the tint. Consistent with the table-row treatment per the PR body.
- **`oklch(var(--p))` vs daisyUI 5 conventions:** Pre-existing
  pattern throughout the same `injectStyles()` block (see lines
  155, 178-179). Not something this PR introduced; if `--p` ever
  needs migration to daisyUI 5's newer custom-property names, that's
  a sweep across the whole `injectStyles()` body, not a fix for this
  PR.
- **Stale state during rapid client toggling:** `:has()` re-evaluates
  on DOM mutation, so selection state always tracks the live
  checkbox. No risk window.

## Summary

7-line CSS-only diff doing exactly what it says. The `:has()`
broadness is the only thing worth keeping in mind for future
consumers; everything else is fine as-is.
