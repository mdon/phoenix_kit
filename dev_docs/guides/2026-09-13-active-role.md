# Active role and the role switcher

A user holding several roles acts as **one of them at a time**, and their
access is narrowed to that role. An Admin who also holds "Seller" can switch to
Seller, see the app exactly as a seller does, and has no admin access until they
switch back.

Design and decision record: `dev_docs/plans/2026-09-13-active-role.md`.

## Turning it on

`/admin/settings/users` → **Roles** tab. All four settings are public keys in
`Settings.get_defaults/0`:

| Setting | Values | Default | Meaning |
|---|---|---|---|
| `role_switcher_enabled` | `"true"` / `"false"` | `"false"` | Off = every user has the union of their roles, exactly as before the feature existed. |
| `role_switcher_location` | `"menu"` / `"header"` | `"menu"` | Where the switcher shows. `header` = a header control from `sm` up, the account menu below it. |
| `role_switcher_sign_in_role` | `"staff_first"` / `"last_used"` | `"staff_first"` | `staff_first`: an Owner/Admin starts every sign-in as that role; others continue as their last role. `last_used`: everyone continues as their last role. |
| `role_switcher_always_on_roles` | comma-separated role uuids | `""` | Custom roles that are never a mode; they apply whichever role is active. |

## Semantics

- **Switchable** roles are modes. Owner and Admin are always switchable (or
  narrowing could never remove admin access). Custom roles are switchable
  unless listed as always-on.
- **User** is always on.
- The scope is narrowed only when the switcher is on **and** the user holds
  **two or more** switchable roles. With zero or one there is nothing to
  choose, the scope is the union, and no switcher renders.
- Narrowed scope = active role + every always-on role held.
- No "All roles" entry: while narrowed, a multi-role user is always exactly one
  role.
- The active role is **per user**, not per browser: switching on the laptop
  switches the phone too (its LiveViews refresh and leave pages the new role
  cannot reach).
- A stored role the user no longer holds is ignored; they fall back to Owner >
  Admin > first switchable role by name. Nothing is written on read.

## For host apps and modules

Everything that goes through the scope already follows the active role —
`Scope.has_role?/2`, `owner?/1`, `can_access_admin_area?/1`,
`has_module_access?/2`, `can?/2`, dashboard tab `permission:` / `visible:`
filters, the admin gates.

```elixir
Scope.active_role(scope)       # %{uuid: "...", name: "Seller"} | nil
Scope.narrowed?(scope)         # acting as one role?
Scope.held_roles(scope)        # every role REALLY held: ["Admin", "Seller", "User"]
Scope.switchable_roles(scope)  # [%{uuid, name}] the switcher offers ([] unless narrowed)
Scope.for_user(user, narrow: false)  # the full union, ignoring the active role
```

Building a role-specific UI (e.g. a seller portal): gate it on a permission key
granted to that role, or on `Scope.has_role?(scope, "Seller")` in a tab's
`visible:` function. Both read the narrowed scope, so an Admin acting as Seller
sees the seller UI and an Admin acting as Admin does not (unless Admin also
holds the key).

Switching from your own UI: a form `PUT` to `Routes.path("/users/session/role")`
with `role_uuid` and an optional `return_to`, or render
`PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher/1`. From code:
`PhoenixKit.Users.ActiveRole.switch(user, role_uuid)`.

## Landmines

- ⚠️ **Never hold the active role anywhere but the user row.** It lives in
  `custom_fields["active_role_uuid"]` and is applied inside
  `Scope.for_user/1`. The scope is rebuilt from scratch with `for_user/1` in
  plugs, every LiveView mount, the role-change refresh, controllers and sibling
  packages; a role kept in the session or a socket assign is dropped by each of
  them, silently **widening** the user back to every role.
- ⚠️ **Access decisions read the scope; rules protecting against a user's real
  roles read `held_roles/1`.** Example: "you cannot edit a role you hold"
  (`Permissions.can_edit_role_permissions?/2`) uses `held_roles`, so acting as
  Seller does not make the user's Buyer role editable by them.
- ⚠️ **Code that reads roles straight from the database ignores the active
  role.** `Roles.user_has_role_owner?/1`, `Roles.get_user_roles/1`,
  `User.get_roles/1` return real roles. Use the scope for access decisions.
  Known sibling sites still to move: phoenix_kit_comments
  (`user_is_admin?`), phoenix_kit_posts (`user_is_admin?`),
  phoenix_kit_projects (`Grants.role_subjects`).
- **Impersonation** judges the root account's roles *in effect*: an Admin
  acting as a custom role cannot impersonate. Targets are judged by their real
  roles. Switching roles while impersonating is refused (it would rewrite the
  borrowed account's stored role), and the switcher is hidden.
- **Sign-in** applies the rule in `PhoenixKitWeb.Users.Auth.log_in_user/3`
  (every sign-in flow). Remember-me restore continues a session and does not
  reset the role.

## Events

- Activity: `session.role_switched`, metadata `from` / `to` role names (actor =
  target, so no notification).
- PubSub: `ScopeNotifier.broadcast_active_role_changed/1` sends
  `{:phoenix_kit_scope_roles_updated, user_uuid, :active_role_changed}` on the
  user's scope topic. Core's LiveView hook refreshes the scope exactly as for a
  role change, with switch-specific eviction copy. A process subscribing to
  that topic directly must handle the 3-tuple.

## Testing

The settings cache is not started in the test suite, so settings writes stay in
the sandbox transaction and tests can run `async: true`. Put a user into a role
without the HTTP switch:

```elixir
Settings.update_boolean_setting("role_switcher_enabled", true)
{:ok, user} =
  Auth.merge_user_custom_fields(user, %{"active_role_uuid" => role.uuid},
    ensure_definitions: false
  )
```

Reference suites: `test/phoenix_kit/users/active_role_test.exs` (pure rules),
`test/integration/users/active_role_scope_test.exs`,
`test/integration/phoenix_kit_web/users/active_role_{gate,switch}_test.exs`,
`test/phoenix_kit_web/components/core/role_switcher_test.exs`.
