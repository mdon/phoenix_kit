# PR #798 Review — load_more: forward extra attributes to the button

**Author:** timujinne (Timujeen)
**Merged:** 2026-09-09, by fotkin (merge commit `1da0bf40`)
**Files:** `lib/phoenix_kit_web/components/core/pagination.ex`,
`test/phoenix_kit_web/components/core/load_more_test.exs`

## Summary

Adds a `:rest` global attr to `<.load_more>` and spreads it onto the
`<button>`. Lets a page rendering more than one `<.load_more>` list attach
`phx-value-*` to the button so a single shared `handle_event` clause can tell
which list fired it, instead of minting a distinct `on_load_more` event name
per list. One new render test pins `phx-value-field="title"` riding along
next to `phx-click`.

## Verification performed

- Read the full `load_more/1` body (`pagination.ex:369-411`): a single
  `<button>` render path — no other button/anchor in this component that
  would also need the passthrough.
- Confirmed `:rest` as a `:global` attr automatically excludes every
  already-declared attr name (`loaded`, `total`, `on_load_more`,
  `noun_plural`, `class`, `id`, `infinite`, `cursor`) per HEEx semantics, so
  `{@rest}` cannot clobber `id`/`class` on the container `<div>` (they're
  declared, and consumed elsewhere in the template — not spread onto the
  button in the first place).
- Checked for a collision risk on the button's own hardcoded attrs
  (`type="button"`, `phx-click`, `phx-disable-with`): none of those are
  declared attrs, so a caller passing e.g. `phx-click="x"` directly (instead
  of through `on_load_more`) would ride into `@rest` and duplicate that
  attribute on the tag. This is inherent to the `:global`-attrs pattern used
  throughout this component library (same shape as every other `attr :rest,
  :global` in `core/`), not a regression introduced here, and the
  documented, expected usage (`on_load_more` for the event, `phx-value-*`
  for extra payload) doesn't hit it. Not worth restricting via `:include`
  for a single-button component — noting it here rather than filing a fix.
- `mix precommit` — clean (format, `compile --warnings-as-errors`,
  `deps.unlock --check-unused`, `credo --strict`, dialyzer, JS tests).
- `mix test test/phoenix_kit_web/components/core/load_more_test.exs` — 6
  tests, 0 failures, including the new one.

## Findings

None requiring a fix.

## Verdict

**Approved, no changes required.**
