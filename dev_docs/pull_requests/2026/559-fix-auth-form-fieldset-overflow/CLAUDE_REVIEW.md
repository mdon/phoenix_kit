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

One genuine cleanup opportunity on a sibling page — see NITPICK (dead `@loading`
branch). Plus a cosmetic consistency nit.

> **Correction (post-review, after reading the backing LiveView).** An earlier
> draft of this review flagged `magic_link_registration_request.html.heex` as
> carrying the same root-cause-#2 double-swap and recommended dropping its
> `phx-disable-with`. That was wrong. Reading
> `magic_link_registration_request.ex:50-86` shows the `send_magic_link` handler
> is **synchronous**: it assigns `:loading, true` (line 54) but then calls
> `send_registration_link/1` inline and returns with `:loading, false` in every
> branch, with no re-render in between — so `@loading = true` never reaches the
> client. Therefore (a) the `if @loading` branch never renders, so the two
> content-swap mechanisms never both fire and there is **no** phantom-SVG bug on
> that page, and (b) `phx-disable-with` is the *only* in-flight feedback during
> the blocking email send — dropping it would be a regression, not a fix. The
> finding below is restated accordingly.

---

## NITPICK — `magic_link_registration_request.html.heex` has a dead `@loading` branch

`magic_link_registration_request.html.heex:75-82` renders a
`<%= if @loading do %>` spinner branch, but its LiveView handler
(`magic_link_registration_request.ex:50-86`) is synchronous: `assign(:loading, true)`
on line 54 is overwritten by `:loading, false` before the single `{:noreply, _}`
return, with no render in between. So the client never sees `@loading = true` and
the spinner branch is unreachable — the button always renders the `else` (default
"Send Magic Link →") state, and `phx-disable-with="Sending..."` does the actual
in-flight swap client-side.

Unlike `magic_link.html.heex` (which uses `start_async`, so its `@loading` branch
genuinely renders and the two swap mechanisms collided), here there is **no
double-swap and no overflow** — the form isn't in a `<fieldset>`, and `@loading`
never renders. So the PR correctly left this page alone. **Do not drop
`phx-disable-with` here** — it's the only in-flight feedback the page has.

Two honest options if this page is revisited: either delete the dead `@loading`
branch (cheapest; `phx-disable-with` stays as the sole feedback), or convert the
handler to `start_async` to match `magic_link.ex` and *then* the `@loading`
spinner becomes real and `phx-disable-with` can go. The latter is a behavior
change (non-blocking submit), out of scope for a one-liner.

> **Resolved in follow-up.** Done in two steps for the record: first the dead
> branch was removed (commit `34c494ad`); then, for consistency across both
> magic-link flows, the handler was converted to `start_async` mirroring
> `magic_link.ex` — `handle_event` now assigns `loading: true` + dispatches,
> `handle_async(:send_magic_link, …)` carries the distinct error messages and
> the `{:exit, _}` crash path, and the template re-renders the `@loading`
> spinner branch with `phx-disable-with` dropped (no double-swap since only the
> server diff swaps content now). Submit is non-blocking; `mix precommit` green.

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
