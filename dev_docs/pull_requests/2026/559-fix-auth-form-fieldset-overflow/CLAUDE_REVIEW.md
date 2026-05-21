# PR #559 — Fix submit button overflow on auth form cards (fieldset min-width)

State: MERGED into `dev` (merge commit `f9d986a1`).
Author: @mdon
Diff: +26 / -8 across 6 files (all `lib/phoenix_kit_web/users/*.html.heex`).

## Scope recap

Two CSS/LiveView-render bugs on the auth forms, surfaced while testing the
projects-side AI Translate work:

1. **`<fieldset>` browser-default `min-width: min-content`** let the fieldset
   grow past its parent `<form>` when a child's intrinsic width exceeded the
   form width, so a `w-full` submit button overflowed the card (~100px past the
   right edge). Fixed by adding `min-w-0` to the fieldset on the six auth forms
   that lacked it (`confirmation`, `confirmation_instructions`, `forgot_password`,
   `login`, `magic_link`, `reset_password`). The other two (`registration`,
   `magic_link_registration`) already carried the fix.
2. **`phx-disable-with` ↔ `@loading` branch double-swap (magic_link only)** —
   both mechanisms swap button content on submit; the collision made LV's diff
   merger inject a stray `<svg data-phx-skip>` (~183px) from the success-alert
   icon into the button, wrapping the label onto three lines. Fixed by dropping
   `phx-disable-with` (the `@loading` branch already renders the spinner state)
   and adding `min-w-0 max-w-full` to the button.

I read the magic_link template + its LiveView (`magic_link.ex`), swept all eight
auth forms for the fieldset class and for the double-swap pattern, and inspected
the one sibling that shares the pattern.

## Verdict

**Approve with one follow-up.** Both fixes are correct, and `min-w-0` is the
right, standard remedy for the `<fieldset>` min-width quirk. The fieldset sweep
is genuinely comprehensive — all eight forms now carry `min-w-0` (verified).
Dropping `phx-disable-with` on magic_link is sound: the LiveView sets
`@loading = true` synchronously in `handle_event` before `start_async`
(`magic_link.ex:68-70`), so the `@loading` spinner branch + `disabled={@loading || @sent}`
fully reproduce the in-flight feedback `phx-disable-with` gave, with no JS-side
content swap to collide with.

One real gap: **the same root-cause-#2 antipattern survives on a sibling page
the PR didn't touch** — see IMPROVEMENT-MEDIUM. Plus a cosmetic consistency nit.

---

## IMPROVEMENT - MEDIUM — `magic_link_registration_request.html.heex` keeps the same `phx-disable-with` + `@loading` double-swap

`magic_link_registration_request.html.heex:69-83` has the *identical* second
root cause this PR diagnosed and fixed on `magic_link.html.heex`: a submit button
with **both** `phx-disable-with="Sending..."` (line 71) and an
`<%= if @loading do %>` spinner branch (line 75). It was not in the PR's six
changed files.

Why it didn't show up in the same sweep: that form isn't wrapped in a
`<fieldset>` (it's a plain `<form class="space-y-4">`), so root cause #1 — the
fieldset overflow — genuinely doesn't apply, and skipping it for `min-w-0` was
correct. But root cause #2 is structural to the button, not the fieldset: the
two content-swap mechanisms still fight on submit. There's an info-box icon
(`icon_info`, line 89) rendered as a sibling below the still-mounted form during
the `@loading` window, which is the same adjacency that fed the phantom SVG into
the magic_link button.

I have **not** visually reproduced it there (the success state replaces the whole
form via `if @email_sent`, a different DOM shape than magic_link's persistent
form + success alert, so the symptom may differ or not surface). But the
antipattern is the same one the PR exists to kill, and the fix is the same one
line: drop `phx-disable-with` and let the `@loading` branch own the swap
(`disabled={@loading}` is already present on line 72). Worth folding into a quick
follow-up so the bug class doesn't resurface the next time this page is touched.

The remaining four forms with `phx-disable-with` (`confirmation`,
`confirmation_instructions`, `login`, `reset_password`) and `user_form` have
**no** `@loading` branch, so there's no double-swap — leaving their button
content alone was the right call, no over-reach.

## NITPICK — fieldset class inconsistency (`w-full` on two, not the other six)

The two pre-existing forms carry `class="fieldset w-full min-w-0"`; the six this
PR fixed got `class="fieldset min-w-0"` (no `w-full`). In the flex-column form
container a fieldset stretches to full width anyway (`align-items: stretch`), so
`w-full` is redundant and the omission is harmless — but the divergence is the
kind of thing that makes the next reader wonder whether it's load-bearing.
Either drop `w-full` from the two or add it to the six; consistency over either
choice. Not blocking.

## Note (not a defect) — `phx-disable-with` removal loses zero feedback

Worth recording since it's the subtle part: removing `phx-disable-with` could
have regressed the in-flight UX if `@loading` were only set in an async
callback. It isn't — `handle_event("send_magic_link", ...)` assigns
`:loading, true` and re-renders *before* `start_async` runs (`magic_link.ex:61-70`),
and `handle_async` flips it back (`:82-105`). So the spinner appears on the
server's immediate first re-render. `start_async` (not `assign_async`) is the
right tool here: this is a fire-and-forward action, not a data load.

---

## Positives

- `min-w-0` is the correct, idiomatic fix for the `<fieldset>` `min-width: min-content`
  overflow — not a hack. Applied uniformly; all eight forms verified consistent.
- The double-swap diagnosis (two content-swap mechanisms confusing the diff
  merger into grafting a sibling SVG into the button) is precise and the chosen
  fix removes the *cause*, not just the symptom — `@loading` is the single
  source of truth for button content now.
- Excellent inline `<%!-- --%>` comments on both fixes; a future reader won't
  re-add `phx-disable-with` or strip `min-w-0` without understanding why.
- Correctly scoped: only touched the fieldset class on forms that have a
  fieldset, only touched button content on the one form with the conflict.
