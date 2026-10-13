# PR #931 — Fix dead user dashboard links and list module user tabs in the avatar menu

**Author:** timujinne · **Merged:** 2026-10-13 (6894079ba) · **Reviewer:** Claude · **Released in:** 2.62.2

## Summary

Stops registering the default "Dashboard" / "Settings" user tabs while `user_dashboard_enabled` is false (their routes are
compiled out, so the sidebar linked straight into a `NoRouteError`), and adds a `user_menu:` Tab option
(`true` or `fn scope -> boolean`) that lists a module's user tab in both avatar dropdowns after Settings
(`Registry.get_user_menu_tabs/1`, `UserDashboardNav.user_menu_tab_links/1`, `Tab.user_menu?/2`).

Verdict: sound. The option rides in `metadata[:user_menu]` (the struct is at the 31-field flat-map limit), a raising or
exiting gate answers `false`, a nil scope answers `[]` rather than skipping the permission filter, subtabs and external
tabs are left out, and the lookup reuses the sidebar's enabled/permission/visibility filtering. Tests cover the registry,
both dropdowns, the locale/prefix-aware link and the host opt-out.

## Findings

- **BUG - MEDIUM (fixed):** a user-menu tab registered with a relative path (never run through `Tab.resolve_path/2`) passed
  the filter, and `Routes.path/2` raises on a path that does not start with `/` — so one such tab would crash the
  dropdown, and with it every page that carries one. `get_user_menu_tabs/1` now drops tabs whose path is not absolute
  (`in_app_path?/1`); regression test added.
- **NITPICK (not changed):** `Registry.update_tab/2` ignores a `:user_menu` key (only `:metadata` is merged), so the flag
  can only be set at `Tab.new` time or via `metadata: %{user_menu: …}`. Harmless; nothing updates it today.
- **NITPICK (not changed):** the dropdown link does not skip the sidebar's `path_has_locale_prefix?` check, so a tab that
  hard-codes a locale segment would get a doubled one. Tab paths are locale-free by convention.
- **NITPICK (not changed):** `Tab.new` treats `user_menu: false` as "unset" (`put_user_menu/2`), so it does not override
  a `user_menu` already present in a passed `metadata`. Same outcome as the default.
