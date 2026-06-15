# Tech spec: anonymous (guest) user-menu dropdown in phoenix_kit

**For:** the agent maintaining the `phoenix_kit` package.
**From:** Langust. Verified against `phoenix_kit` **1.7.150** in `deps/phoenix_kit` on
2026-06-15.

**Status:** IMPLEMENTED in phoenix_kit **1.7.151** (2026-06-15). The guest dropdown was
added directly to `UserDashboardNav.user_dropdown/1`'s `else` branch (preferred single-
component shape). Same public call site; new optional attrs `:show_language_switcher`
(default `true`) and `:guest_links` (default all four) shipped as suggested. Guest links
are additionally gated by the `allow_registration` / `magic_link_login_enabled` settings.
Langust can now replace the header with the single widget and drop the standalone switcher.

## What's there now vs. what's needed

`PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1`
(`lib/phoenix_kit_web/components/user_dashboard_nav.ex`) renders a rich avatar dropdown
**only** for authenticated users (avatar trigger → email, Admin/Dashboard/Settings,
**Language switcher**, Log out). For anonymous visitors the `else` branch (lines 160–166)
renders a single **"Login"** button — no dropdown, no language switcher.

The earlier spec (`2026-06-15-phoenix-kit-anonymous-locale-spec.md`, item A) asked for the
switcher in the anonymous state; 1.7.150 shipped the standalone switcher + landing route
(great), but the **user widget's anonymous state is still just a bare Login button**.

**Needed:** a guest counterpart to `user_dropdown` — the same dropdown *shape*, but for
logged-out visitors:

- **Trigger:** a generic "anonymous / nobody" icon (e.g. `hero-user-circle` outline) where
  the avatar would be — visually signals "not signed in".
- **Dropdown contents (guest-relevant):**
  - **Log in** → `Routes.path("/users/log-in")`
  - **Sign up** → `Routes.path("/users/register")`
  - **Forgot password** → `Routes.path("/users/reset-password")`
  - (optional) **Magic link** → `Routes.path("/users/magic-link")`
  - a divider, then the **Language switcher** — same list/markup the authenticated branch
    already builds (reuse `get_user_languages/0` + the language `<a>` list, or delegate to
    `Core.LanguageSwitcher`), so guests can change language from the same place.

So both states (signed-in and guest) present **one consistent dropdown that always
includes the language switcher** — which lets consumers drop any separate standalone
switcher and rely solely on this widget everywhere, for everyone.

## Suggested shape

Make `user_dropdown/1` render the guest dropdown in its `else` branch (preferred — one
component, same call site), **or** add a sibling `guest_dropdown/1` that `user_dropdown/1`
delegates to when `@scope` is unauthenticated. Either way the public call stays:

```elixir
<PhoenixKitWeb.Components.UserDashboardNav.user_dropdown
  scope={@current_scope}        # nil / unauthenticated → guest dropdown
  current_path={@url_path}
  current_locale={@current_locale}
/>
```

Existing attrs (`scope`, `current_path`, `current_locale`) are sufficient. Optionally an
attr to choose which guest links appear (e.g. `guest_links: [:login, :register, :reset]`)
and one to hide the in-menu language list for consumers who keep a standalone switcher
(`show_language_switcher: true` default) — that toggle also resolves the
**duplicate-switcher** problem when a host renders both this widget and the standalone one.

## Constraints / notes

- **Language switcher must work for guests** here, on any page including locale-less ones
  (the 1.7.150 standalone switcher already does; reuse its URL logic so `/` → `/ru`, not
  `/ru/`).
- Reuse the existing dropdown styling (daisyUI `dropdown dropdown-end` + the same
  menu/scroll classes) so guest and signed-in widgets match.
- `current_locale` highlighting: the authenticated branch compares enabled (dialect) codes
  to `@current_locale`; keep the same logic in the guest branch.
- i18n: the guest link labels ("Log in", "Sign up", "Forgot password") should be
  `gettext`-wrapped in phoenix_kit's own gettext, like the rest of the menu.

## What Langust does once this ships

Replace the header so the **single** `user_dropdown` widget covers both states (guest
dropdown with switcher when logged out, avatar menu with switcher when logged in), and
**remove the standalone `language_switcher_dropdown`** from the header — eliminating the
current duplicate switcher while keeping a switcher available to everyone, everywhere.
