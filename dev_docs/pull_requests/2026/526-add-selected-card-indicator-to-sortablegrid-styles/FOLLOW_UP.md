# FOLLOW_UP — PR #526 (Add selected-card indicator to SortableGrid styles)

Triaged 2026-05-12.

`CLAUDE_REVIEW.md` opens with `APPROVE` — single 7-line CSS rule in
`priv/static/assets/phoenix_kit.js`. Two NITPICKs and one
IMPROVEMENT-LOW; no BUG findings.

## Fixed (pre-existing)

- ~~NITPICK — `!important` on `background-color` is redundant given
  the rule's specificity vs `bg-base-200` and the late-injected
  source order.~~ Fixed post-merge in commit `3521fa2f`
  ("Remove redundant !important from selected-card indicator").
  Current rule at `phoenix_kit.js:170` no longer carries the
  `!important`.

## Skipped (with rationale)

- **NITPICK — `:has()` selector broader than PR body implies.** The
  rule matches any descendant `input[type="checkbox"]:checked` inside
  `.sortable-item.card`, not specifically the bulk-select checkbox.
  Benign for every current consumer (only `phoenix_kit_catalogue`
  uses the sortable card view, and it has exactly one checkbox per
  card — the bulk-select). The review explicitly calls this
  "ergonomic, not correctness" and says to switch to an opt-in
  data attribute only "if a second consumer hits this." No second
  consumer exists today; leave the rule as-is until one does.

- **IMPROVEMENT-LOW — No automated coverage.** Component test
  coverage for `phoenix_kit_web/components/core/` is already a
  tracked TODO in `phoenix_kit/AGENTS.md` (the `<.table_default>`
  card-view-sortable wiring is in scope there). The reviewer
  explicitly suggested folding this rule into that future
  component-coverage sweep rather than addressing per-PR. Defer.

## Files touched

| File | Change |
|---|---|
| `priv/static/assets/phoenix_kit.js` | One CSS rule added at line ~170. Already amended post-merge to drop the redundant `!important` (commit `3521fa2f`). |

## Verification

`grep -n 'sortable-item.card:has' priv/static/assets/phoenix_kit.js`
→ rule present at line 170. `!important` confirmed absent.

## Open

None.
