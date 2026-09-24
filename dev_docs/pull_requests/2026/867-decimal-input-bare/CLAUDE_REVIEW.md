# PR #867 — DecimalInput: a bare mode — the control alone, for a host's own group

**Author:** timujinne · **Merged:** 2026-09-24 (59459742) · **Reviewer:** Claude · **Released in:** 2.38.1

## Summary

- `<.decimal_input bare …>` renders the `<input>` alone: no wrapper `<div>`,
  label, unit suffix, error list or `w-full`. It is for a host that places the
  control in a group of its own (a daisyUI `join` with a unit button, a table
  cell), where the wrapper would sit between `.join` and its `.join-item`.
- It keeps what makes it a decimal control: `type="text"`,
  `inputmode="decimal"`, `autocomplete="off"`, the zero-clearing handlers
  (chained with the host's own), and `input-error` when there are errors.
- The `<input>` moved into a private `control/1`, shared by all three layouts.
  Each layout has a single root (`layout/1` clauses), so no whitespace is left
  between sibling `:if` roots.
- Tests cover the bare output, field binding, errors, the handler chaining,
  and the classes the default layouts keep.

Verdict: good. The refactor keeps the default output the same, and a test
asserts that. One accessibility gap is fixed below.

## Findings

### IMPROVEMENT - MEDIUM — a `label` passed to a bare control was dropped without a trace (fixed)

In bare mode, `label` has nowhere to render, and the control was left with no
accessible name. The docs asked the host to pass `aria-label` instead, but a
host that switches an existing `<.decimal_input field={…} label="Quantity">`
to `bare` keeps the `label` and gets an unnamed control. The PR's own
field-binding test does exactly that.

Fix: in bare mode, a non-empty `label` becomes the control's `aria-label`.
An `aria-label` the host passes wins, and an empty or missing label adds
nothing. The moduledoc, the attr doc and the core-components guide now say
this. Three tests lock it in: the label names the control, the host's
`aria-label` wins (and there is exactly one), and an empty label adds no empty
name.

### NITPICK — bare errors are visible only as a colour (no action)

A bare control with errors gets `input-error` but no message and no
`aria-invalid`. Showing the message is the host's job by design, since the
host draws the group. The default layouts don't set `aria-invalid` either, so
adding it only in bare mode would make the two inconsistent. If it's wanted,
it belongs on `control/1` for every layout.
