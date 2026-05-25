# Follow-up — PR #559 (auth form fieldset overflow fix)

## Fixed (pre-existing — verified, no new work needed)

- ~~**Core fix** — `min-w-0` on auth form fieldsets.~~ All 8 forms verified (`confirmation`, `confirmation_instructions`, `forgot_password`, `login`, `magic_link`, `magic_link_registration`, `registration`, `reset_password`) carry `min-w-0` on their fieldset.
- ~~**Core fix** — `phx-disable-with` removed from magic_link button.~~ `lib/phoenix_kit_web/users/magic_link.html.heex:45-56` now relies on the LV's `@loading` assign + `disabled={@loading || @sent}` + `min-w-0 max-w-full` for overflow protection. `handle_event` sets `loading: true` before the `start_async` (line 68 of `.ex`).
- ~~**NITPICK** — `magic_link_registration_request` had dead `@loading` branch.~~ Resolved in commits `34c494ad` + `84e7e2fb`; handler converted to `start_async` matching `magic_link.ex`. Both pages now consistent.

## Fixed (Batch 1 — 2026-05-25)

- ~~**NITPICK** — Fieldset class consistency (`w-full`).~~ Removed `w-full` from `registration.html.heex:28` and `magic_link_registration.html.heex:23` so the class shape now matches the other six forms (`class="fieldset min-w-0"`). Visually identical (parent stretches the form anyway), but the unified class string removes a future-grep gotcha.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/users/registration.html.heex` | Dropped `w-full` from fieldset class |
| `lib/phoenix_kit_web/users/magic_link_registration.html.heex` | Same |

## Verification

- `mix compile --warnings-as-errors` clean (via `phoenix_kit_parent`)
- Visual: the two registration forms render at the same width as before (parent `align-items: stretch` provides the full width)

## Open

None.
