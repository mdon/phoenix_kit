# PR #933 — Stacked bars, week-stepping `date_nav`, `chosen` state for `search_picker`, one label size for `select`

**Author:** mdon · **Reviewer:** Claude · **Verdict:** good; one bug fixed

## Findings

### BUG - MEDIUM — `date_nav` day picker ignored `target` (FIXED)

`target` was added as "`phx-target` for `event`", and the arrows/Today button honour it, but the picker `<form
phx-change={@pick_event}>` did not. Used inside a LiveComponent (`event` + `target`) the picker's change went to the
parent LiveView, not the component. The form now carries `phx-target={@target}` (nil renders nothing, so URL-mode
users are unchanged); doc updated; test added in `date_nav_test.exs`.

### NITPICK — `date_nav` with neither `path` nor `event`

Both default to nil now; the docs say "required unless `event` is set" but nothing enforces it, so the omission
surfaces as a `nil.(…)` call at render. Left as is — a guard would only trade one error for another.

### NITPICK — stacked-bar tooltip / opacity

Stacked segments draw at full opacity while single bars use 0.75; segment heights are rounded independently, so the
stack can differ from the bar height by a pixel fraction. Cosmetic.

## Checked and fine

- `y_max` below the tallest bar is ignored (documented, tested); zero/non-numeric parts dropped; a stacked datum with
  no usable parts renders as an empty plain bar.
- `search_picker` `chosen`: no hook mounted in the chosen state, `hero-x-mark` kept in the Tailwind safelist span,
  `chosen=""` falls back to the ordinary picker.
- `select` label: removing `block` is covered by a test. "Previous"/"Next" msgids already exist in `default.pot`.
