# PR #779 — Center described checkboxes against their first text line

**Author:** mdon (`mdon/main`) · **Merged:** 2026-09-02 (`40e64544`) · **Reviewed:** 2026-09-02

## Verdict

**The diagnosis and the geometry are both right, and the change is a strict
improvement over what it replaced.** One gap sits next to it: core still
contained a hand-rolled copy of exactly the markup this PR set out to fix, so
the misalignment survives on the notification-preferences form. Fixed here.
The new test was also loose enough to stay green through the regression it
guards; tightened.

---

## Verified — re-derived against the source

| change | verdict |
|---|---|
| `h-6` wrapper replaces `mt-0.5` | **correct.** The label is `text-sm leading-6`, so the first line box is exactly 24px. daisyUI 5's default `.checkbox` is `calc(var(--size-selector) * 6)` = 1.5rem = 24px — already flush with the line box, so `mt-0.5` was pure 2px error. The PR's claim that the nudge "was tuned for checkbox-sm" holds: at 20px (`checkbox-sm`) the 2px offset approximates centering; at 16px (`checkbox-xs`) and 24px (default) it does not. A `h-6` + `items-center` wrapper is size-independent. |
| `shrink-0` moved from caller to component | **correct, and a strict widening of the fix.** Previously only a caller that thought to pass `flex-shrink-0` was protected from a long description squashing the box; now every caller is. This is what makes the storage template's deletion safe rather than merely tidy. |
| storage template nudges dropped | **complete.** Scanned every `<.checkbox>` call site in core *and* in all 60 `phoenix_kit_*` sibling repos in the workspace: after this PR, zero callers pass a layout class through `class=`. The only surviving `class=` values are daisyUI modifiers (`roles.html.heex` ×4: `checkbox-sm`/`checkbox-xs` + `checkbox-primary`). Nothing was left compensating for a nudge that no longer exists. |
| interposing a `<span>` between `<label>` and `<input>` | **safe.** No `peer-*` / adjacent-sibling / general-sibling selector anywhere in `assets/` or `lib/` targets the checkbox, and no JS hook resolves the input by structural position (`priv/static/assets/phoenix_kit.js` and `assets/js` have no `label > input` or `closest('label')` lookup). Nothing depended on the input being a direct child. |
| host Tailwind picks up the new utilities | **yes.** `css_integration.ex` emits `@source "../../deps/phoenix_kit"` (whole package), so `h-6` / `shrink-0` are scanned out of `checkbox.ex` itself in a host build. |
| oversized boxes | `checkbox-lg` is 28px in a 24px wrapper — under `items-center` the 2px overflow is symmetric and nothing sets `overflow: hidden`, so it stays visually centered on the line. No core caller uses it anyway. |

The PR body's user-facing claim ("the checkbox and the text are kind of not
centered") reproduces: the default-size described checkboxes on
`/admin/settings/storage` were the ones carrying `mt-0.5`, i.e. the exact
combination where the nudge is 2px of pure error.

---

## IMPROVEMENT — MEDIUM · Core kept a hand-rolled copy of the bug

`lib/phoenix_kit_web/live/components/user_settings.ex:1299` — the
notification-preferences list did not go through `<.checkbox>` at all. It
hand-rolled the same structure, with the same class of nudge:

```heex
<label class="flex items-start gap-3 p-3 rounded-lg border ... cursor-pointer">
  <input type="hidden" name={"notification_prefs[#{type.key}]"} value="false" />
  <input type="checkbox" ... class="checkbox checkbox-primary checkbox-sm mt-1" />
  <div class="flex-1 min-w-0">
    <div class="font-medium text-sm">{type.label}</div>
    ...
```

`items-start` + a fixed `mt-1` (4px) on a 20px `checkbox-sm` inside a 20px
`text-sm` line box — 4px of pure error, the same defect this PR removed
everywhere else, and larger. It is also precisely what the component's own
moduledoc exists to prevent ("a hand-rolled checkbox + adjacent text is easy to
get wrong").

Converting is behaviour-preserving here, which is the reason it is safe to do
and the reason the `users.html.heex` / `user_details.html.heex` role checkboxes
are correctly left alone: those two carry a `DO NOT convert` comment because
the *submitted value* is the payload (`Map.values(params["roles"])`), so a
component hardcoding `"true"`/`"false"` would strip roles. The notification
form has no such constraint — it already submits `value="true"` plus a
hidden `"false"`, byte-for-byte what `<.checkbox>` emits.

**Fixed.** Converted to `<.checkbox>` with a `<:description :if={…}>`. The
`:if` matters: types with no description must leave the slot list empty so
`has_description?` stays false and the label falls back to `items-center`,
matching the old `if type.description && type.description != ""` guard. Card
chrome moves to `wrapper_class`; `cursor-pointer` drops out because the
component already sets it.

## NITPICK · The new test passes through the regression it guards

`assert with_description =~ "h-6"` matched the substring anywhere in the
document. A refactor that moved `h-6` onto the text span — un-fixing the
alignment — would have kept it green.

**Fixed.** Pinned to the wrapper element itself:

```elixir
assert with_description =~ ~s(<span class="flex items-center shrink-0 h-6">)
```

plus an assertion that the description-less label really is `items-center`,
which the `refute … =~ "h-6"` alone did not establish.

---

## On record — not fixed

**`wrapper_class` cannot reliably override the component's own layout
utilities.** The label hardcodes `gap-4 text-sm leading-6`; a caller passing
`gap-3` via `wrapper_class` loses, because Tailwind precedence is *stylesheet
order*, not HTML order, and `gap-3` is emitted before `gap-4`. This bit the
conversion above (the hand-rolled card used `gap-3`; it now renders `gap-4`, a
4px difference that is not worth a variant API). Pre-existing, unrelated to
this PR, and the right fix — variant props rather than class merging — is
over-engineering for a single 4px case. Noted so the next caller who tries it
knows why it silently does nothing.

---

## Testing

- [x] `test/phoenix_kit_web/components/core/checkbox_test.exs` — 7 tests, 0 failures
- [x] `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused, format-check, credo --strict, dialyzer, JS tests)
- [x] `mix test` (real PostgreSQL) — 43 doctests, 4350 tests, 0 failures
