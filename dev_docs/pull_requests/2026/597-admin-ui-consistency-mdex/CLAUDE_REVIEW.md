# PR #597 — Admin UI consistency pass + centralize the MDEx dependency

**Author:** alexdont (Sasha Don) · **Base:** `main` · **State:** MERGED (`0d7c7065`)
**Reviewer:** Claude · **Date:** 2026-06-17

Mostly an admin-UI consistency pass (navbar title/subtitle pattern, manage-users
toolbar/mobile work, overflow fixes) plus moving `mdex` into core. Solid work —
verified the new layout/table attrs actually exist (no dead bindings) and the
`{@project_title}` interpolation fix is a real bug fix. Findings below.

---

## Resolution — addressed in commit `850d27ef` (v1.7.159)

| # | Finding | Disposition |
|---|---------|-------------|
| 1 | View-toggle broadcast (+ a custom-field-definition leak found while fixing) | **Fixed** |
| 2 | Untranslated Jobs / Languages headers | **Fixed** — `gettext` + et/ru |
| 3 | `load_user_view_mode(%{})` over-broad match | **Fixed** — `%User{}` |
| 4 | `~> 0.13` mdex pin | **Kept** — intentional loose-shared pin (matches `leaf "~> 0.3"`) |

**Finding 1 fix:** `update_user_custom_fields/3` gained `:broadcast` and
`:ensure_definitions` options (both default `true`, so existing callers are
unchanged); the view-mode write passes both `false`. While fixing the broadcast
I found the same call also ran `CustomFields.ensure_definitions_exist/1`, which
auto-registered `users_view_mode` as a user custom-field definition — surfacing
it in the Customize Columns modal (`get_custom_field_columns/0` lists every
enabled definition with no internal-key exclusion). `ensure_definitions: false`
stops that, and `validate_custom_fields/1` stores the raw map so the preference
still persists without a definition.

---

## IMPROVEMENT - MEDIUM

### 1. View-mode toggle broadcasts a global `user_updated`, reloading the users list for every connected admin

`set_view_mode` persists the grid/list preference via
`persist_user_view_mode/2` → `Auth.update_user_custom_fields/2`, which calls
`Events.broadcast_user_updated(updated_user)` (`lib/phoenix_kit/users/auth.ex:1607`).
The Users LV subscribes to user events (`Events.subscribe_to_users()`,
`users.ex:26`) and handles `{:user_updated, _user}` by calling
`load_users(socket)` (`users.ex:1229`).

Net effect: **each grid/list toggle re-queries the entire users list** — not
just for the admin who toggled, but for *every other admin* currently on
`/admin/users` (scroll-jump / flicker for them, an extra DB round-trip each). A
per-user view preference is not a profile change other sessions need to react
to.

- `lib/phoenix_kit_web/live/users/users.ex:638` (`persist_user_view_mode/2`)

**Suggest:** persist the preference without the `user_updated` broadcast (a
custom_fields-only update path that skips PubSub), or have the Users LV ignore
`:user_updated` events that only changed `custom_fields`. Either keeps the
toggle local.

---

## NITPICK

### 2. New page titles/subtitles on the Jobs + Languages pages aren't translated

The rest of the pass uses `gettext(...)`, but two pages use plain literals:

- `modules/jobs/index.html.heex` — `page_title="Jobs"`,
  `page_subtitle="View background job status and history"`
- `modules/languages.html.heex` — `page_title="Languages"`,
  `page_subtitle="Manage available languages for your application"`

The Languages title was previously the buggy literal `"{@project_title}
Languages"` — good that it's fixed — but it should land as
`gettext("Languages")` to match the rest of the admin's i18n.

### 3. `load_user_view_mode(%{} = user)` matches any map, not just `%User{}`

`lib/phoenix_kit_web/live/users/users.ex:626` matches `%{}` then calls
`Auth.get_user_field(%User{} = user, ...)`, which is guarded to `%User{}`. In
practice `phoenix_kit_current_user` is always a `%User{}` or `nil` (the `_`
clause covers `nil`), so it's safe today — but a non-`User` map would raise a
`FunctionClauseError` instead of falling through to the `"table"` default.
Tighten the head to `%PhoenixKit.Users.Auth.User{} = user`.

### 4. `{:mdex, "~> 0.13"}` is a wide pin for a pre-1.0 dependency

`~> 0.13` resolves to `>= 0.13.0 and < 1.0.0`, so a future breaking `0.14`/`0.x`
would silently resolve. For a 0.x library `~> 0.13.0` (`< 0.14.0`) is the
conventional safe pin. Low priority — it matches the existing `leaf "~> 0.3"`
house style — but the whole point of centralizing is that everyone shares one
resolved version, which a tight pin serves best. (`mix.exs`)

---

## Positive notes / verified

- **Real bug fix:** `page_title="{@project_title} …"` rendered the literal
  `{@project_title}` in the navbar — HEEx does not interpolate `{}` inside a
  quoted attribute string. Converting to `gettext(...)` / `{...}` expressions
  fixes a user-visible glitch on the dashboard and several settings pages.
- Verified `page_subtitle` is a declared `LayoutWrapper` attr and renders in the
  navbar (`layout_wrapper.ex:84,351`); `show_toggle`, `view_mode`, `view_event`,
  and the `:sort_bar` slot all exist on `table_default`. No dead bindings.
- `min-w-0` + `break-words` overflow fixes are the correct flexbox remedy.
- `persist_user_view_mode/2` re-reads a fresh user before merging custom_fields,
  so it won't clobber a concurrent change — good.
