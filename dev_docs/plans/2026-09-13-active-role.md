# Active role — one role at a time, and a switcher to change it

**Created:** 2026-09-13
**Status:** BUILT on `main` 2026-09-13 in four commits (below). **Not published,
no version bump** — waiting for review by other agents. Sibling follow-ups (end
of this file) not started.
**Scope:** phoenix_kit (core).
**Topic guide (read first):** `dev_docs/guides/2026-09-13-active-role.md`

This file has two halves:

1. **As built — implementation and review guide.** What exists on `main`,
   where it lives, how each path works, what is tested, what is not, and what
   a reviewer should look at hardest.
2. **Original plan.** The design record written before the build. It is kept
   because it carries the reasoning (why per-user, why inside `for_user/1`,
   why always-on roles). Where the build departed from it, the departure is
   listed in "Departures from the plan" and marked inline with
   **[as built: …]**.

Line numbers below are as of commit `45b53e56`.

---

# Part 1 — As built

## Reviewer quick start

1. Read the topic guide (5 minutes) for the behaviour.
2. Review the commits **in order** — each is a stage that passed the gate on
   its own:

   | Stage | Commit | Subject |
   |---|---|---|
   | 1 | `273b4b1e` | Add the active role model: users act as one role at a time |
   | 2 | `2196be19` | Add active role switching, the sign-in role and its safety rules |
   | 3 | `0d012071` | Add the role switcher UI to the account menus and headers |
   | 4–5 | `45b53e56` | Add the Roles settings tab, active-role docs and translations |

   `git diff 7909e5f3..45b53e56` is the whole feature
   (≈2,500 lines excluding `priv/gettext`, of which ≈880 are tests and ≈470
   docs).
3. Start with `lib/phoenix_kit/users/active_role.ex` (the rules, mostly pure)
   and `Scope.for_user/1` (the one place narrowing is applied). Everything else
   is plumbing around those two.
4. Run the suites (commands in "Tests").
5. Work through "Known gaps, risks and open questions" and "Review checklist".

## The one idea to hold while reviewing

**The active role is state on the user row, and it is applied inside
`Scope.for_user/1`.** Not in the session, not in socket assigns. The scope is
rebuilt from scratch with `for_user/1` in ~14 places in core and ~6 in sibling
packages (plugs, every LiveView mount, the role-change refresh, controllers,
background jobs). Putting the narrowing inside the builder means every one of
them narrows without being touched. Any change that keeps the active role
anywhere else is a **privilege-widening bug** — that is the main thing to guard
in review.

The stored value is never trusted: `ActiveRole.resolve/3` only returns a role
the user holds and that is switchable right now, so the narrowed scope is
always a subset of the user's real grants.

## Commits and files

### Stage 1 — `273b4b1e` — the model (no UI, off by default)

| File | Change |
|---|---|
| `lib/phoenix_kit/users/active_role.ex` | **New.** The rules: config, `switchable?/2`, `resolve/3`, `sign_in_role/3`, `effective_roles/3`, `narrow/2`, parsers. |
| `lib/phoenix_kit/users/auth/scope.ex` | New fields `held_roles`, `active_role`; `for_user/2` narrows; accessors `held_roles/1`, `active_role/1`, `narrowed?/1`; `to_map/1` includes both. |
| `lib/phoenix_kit/users/roles.ex` | New `get_user_role_records/1` (uuid + name, same query as `get_user_roles/1`). |
| `lib/phoenix_kit/users/permissions.ex` | New `get_permissions_for_roles/1` (the per-user join restricted to role uuids; fails closed to `[]`). |
| `lib/phoenix_kit/settings/settings.ex` | Four `role_switcher_*` defaults + `@public_setting_keys`. |
| `lib/phoenix_kit/settings/setting.ex` | `role_switcher_always_on_roles` in `@optional_settings` (empty default). |
| `lib/phoenix_kit/users/custom_fields.ex` | `active_role_uuid` in `@internal_keys` (never shown as an operator-editable custom field). |
| `test/phoenix_kit/users/active_role_test.exs` | **New.** Pure rule tests. |
| `test/integration/users/active_role_scope_test.exs` | **New.** `for_user/1` against real roles/permissions. |
| `test/integration/phoenix_kit_web/users/active_role_gate_test.exs` | **New.** Admin on_mount gate honours the active role. |
| `test/phoenix_kit/users/custom_fields_value_test.exs` | Pins the new internal key. |
| `CHANGELOG.md`, this file | Unreleased entry; plan. |

### Stage 2 — `2196be19` — switching, sign-in, safety

| File | Change |
|---|---|
| `lib/phoenix_kit/users/active_role.ex` | `switch/2`, `apply_sign_in_role/1`, activity log. |
| `lib/phoenix_kit/users/scope_notifier.ex` | `broadcast_active_role_changed/1` (3-tuple message). |
| `lib/phoenix_kit_web/users/session.ex` | `set_active_role/2` action, `session_user/1` helper, `redirect_after_role_switch/2`. |
| `lib/phoenix_kit_web/integration.ex` | `PUT /users/session/role` in **both** route blocks (plain + localized). |
| `lib/phoenix_kit_web/users/auth.ex` | Sign-in rule in `log_in_user/3`; refresh handles the 3-tuple and passes a reason to the eviction flash; refresh carries multi-session fields. |
| `lib/phoenix_kit_web/users/multi_session.ex` | Impersonation marker + `impersonating?/1`; actor's roles read in effect. |
| `lib/phoenix_kit/users/permissions.ex` | `can_edit_role_permissions?` "own role" rule on `held_roles`. |
| `.dialyzer_ignore.exs` | File-level `call_without_opaque` for `users/session.ex` (see risks). |
| `test/integration/phoenix_kit_web/users/active_role_switch_test.exs` | **New.** HTTP switch, impersonation, sign-in, LiveView eviction. |
| `test/phoenix_kit/users/active_role_test.exs` | + `can_edit_role_permissions?` while narrowed, `impersonating?/1`. |

### Stage 3 — `0d012071` — switcher UI

| File | Change |
|---|---|
| `lib/phoenix_kit_web/components/core/role_switcher.ex` | **New.** `role_switcher/1`, variants `:menu_section` / `:header`. |
| `lib/phoenix_kit_web/components/admin_nav.ex` | Menu section in `admin_user_dropdown/1`, under Language. |
| `lib/phoenix_kit_web/components/user_dashboard_nav.ex` | Menu section in `user_dropdown/1`, under Language. |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | Header variant in the admin header's right cluster. |
| `lib/phoenix_kit_web/components/layouts/dashboard.html.heex` | Header variant in the dashboard header. |
| `lib/phoenix_kit/users/active_role.ex` | `narrow/2` returns switchable roles too; `effective_role_names/1`; `location/0`. |
| `lib/phoenix_kit/users/auth/scope.ex` | New field + accessor `switchable_roles`. |
| `lib/phoenix_kit_web/users/multi_session.ex` | `list_accounts/1` adds `impersonated?`; account labels show the active role; `actor_roles` via `effective_role_names/1`. |
| `test/phoenix_kit_web/components/core/role_switcher_test.exs` | **New.** Component render tests. |
| `test/.../active_role_switch_test.exs`, `active_role_test.exs` | + `list_accounts` flag, `parse_location/1`, `switchable_roles/1`. |

### Stages 4–5 — `45b53e56` — settings tab, docs, translations

| File | Change |
|---|---|
| `lib/phoenix_kit_web/live/settings/users.ex` | Custom-role list, option labels, `normalize_settings_params/1`, `always_on_role?/2`. |
| `lib/phoenix_kit_web/live/settings/users.html.heex` | "Roles" tab + panel. |
| `test/integration/phoenix_kit_web/live/settings/role_switcher_settings_test.exs` | **New.** Tab renders, round-trip, untick-all. |
| `dev_docs/guides/2026-09-13-active-role.md` | **New.** Topic guide. |
| `AGENTS.md` | Topic-guide link; "Active role" entry under Permissions. |
| `priv/gettext/**` | 23 new msgids translated in de/es/et/fr/it/pl/ru (see "Translations"). |
| `CHANGELOG.md`, this file | Entries; status. |

## How it works

### Narrowing (every scope build)

`Scope.for_user/2` — `lib/phoenix_kit/users/auth/scope.ex:155`

1. `Roles.get_user_role_records/1` (`roles.ex:269`) → `[%{uuid, name}]` held,
   ordered by name. Replaces `User.get_roles/1`; same query count.
2. Unless `narrow: false`, `ActiveRole.narrow/2` (`active_role.ex:195`):
   - **Fewer than two held roles → `{nil, held, []}` with no settings read**
     (the common case costs nothing new).
   - Otherwise `config/0` (`active_role.ex:66`): reads `role_switcher_enabled`;
     only when on, also `role_switcher_sign_in_role` and
     `role_switcher_always_on_roles`. All `get_*_cached`.
   - `resolve/3` (`:136`) → active role or `nil`.
   - `effective_roles/3` (`:174`) → active + always-on held.
   - Switchable list (for the UI) only when narrowed.
3. `cached_roles` = effective names. The existing Owner / Admin / other `cond`
   now runs on the **effective** names, so an Owner acting as "Seller" gets
   neither the Owner branch nor all keys.
4. Permissions via `load_permissions/3` (`scope.ex:223`): not narrowed →
   `Permissions.get_permissions_for_user/1` (unchanged path); narrowed →
   `Permissions.get_permissions_for_roles/1` (`permissions.ex:859`) over the
   effective uuids. The Admin "table missing → all keys" fallback is unchanged.
5. Struct gets `held_roles` (all real names), `active_role`, `switchable_roles`.

The rules (`active_role.ex`):

- `switchable?/2` (`:110`): Owner, Admin → always; User → never; custom → unless
  its uuid is in `always_on`. **System roles are identified by name**
  (`Role.system_roles/0`), like the rest of the codebase.
- `resolve/3`: feature off or fewer than two switchable candidates → `nil`;
  stored uuid among candidates → it; otherwise Owner > Admin > first by name.
- `sign_in_role/3` (`:156`): `:staff_first` → the resolved default if it is Owner
  or Admin, else the stored role; `:last_used` → `resolve/3`.
- Stored value: `custom_fields["active_role_uuid"]`
  (`ActiveRole.stored_role_uuid/1`). Nothing is written on read.

### Switching

`PUT /users/session/role` (`integration.ex:254` and `:1496`) →
`Users.Session.set_active_role/2` (`session.ex:185`), on the
`[:browser, :phoenix_kit_auto_setup]` pipeline (CSRF from `:browser`).

1. `session_user/1` resolves the **active** account from the session token,
   through `Auth.ensure_active_user/1`. No user → login redirect.
2. `MultiSession.impersonating?/1` → refuse with a flash.
3. `ActiveRole.switch/2` (`active_role.ex:245`): refuse unless enabled, the
   role is a held switchable role, and there are ≥2 candidates. Same role as
   the one in effect → `{:ok, …}` without a write. Otherwise
   `Auth.merge_user_custom_fields/3` (atomic JSONB merge, `ensure_definitions:
   false`), `session.role_switched` activity row (`:323`, actor = target → no
   notification), `ScopeNotifier.broadcast_active_role_changed/1`.
4. Success → `redirect_after_role_switch/2` (`session.ex:232`): scope read
   from the session **after** the switch; `Routes.safe_destination/2` with
   `return_to` and `skip_admin: not can_access_admin_area?(scope)`.
   `safe_destination/2` only proves a path routable, so without `skip_admin` a
   switch to Seller from an admin page would follow `return_to` into that
   page's gate. Errors → the existing `redirect_back/2`.
5. A missing/non-string `role_uuid` hits the fallback clause → flash, no crash.

### Open LiveViews (every tab, every device)

`ScopeNotifier.broadcast_active_role_changed/1` (`scope_notifier.ex:42`) sends
`{:phoenix_kit_scope_roles_updated, user_uuid, :active_role_changed}` on the
user's existing scope topic.

`auth.ex:1401` — `handle_scope_refresh/2` now has a 2-tuple clause
(`:roles_updated`) and a 3-tuple clause (`:active_role_changed`), both into
`refresh_scope/3`, which is the old body with a `reason`. The existing
`scope_refresh_decision/4` decides `:evict_admin_area` / `:evict_module` /
`:stay`; `apply_scope_refresh_decision/4` picks the flash via
`eviction_message/2` (`auth.ex:1536`): a switch says "This page is not
available in the role you switched to." instead of "You must be an admin…".

A process subscribed to that topic **directly** (not through core's hook) must
handle the 3-tuple. A search of every repo in the workspace found none.

### Sign-in

`log_in_user/3` (`auth.ex:129`) calls `ActiveRole.apply_sign_in_role/1` first,
before the post-login destination is resolved against the user's scope. It
writes only when the sign-in role differs from the stored one, broadcasts on a
change, and never raises (rescue → the user unchanged). Every interactive
sign-in funnels through `log_in_user/3`: password, registration auto-login,
magic link, QR, OAuth, password-change re-login. Remember-me restore
(`ensure_user_token/1`) does not, by design.

### Impersonation

- **Marker:** `@impersonated_key :pk_impersonated_tokens`
  (`multi_session.ex:67`). `impersonate/2` → `mark_impersonated/1` (`:373`)
  prepends the now-active token. `impersonating?/1` (`:384`) = active token in
  that list. Never pruned (see risks).
- **Authority:** `actor_roles/1` (`:528`) =
  `ActiveRole.effective_role_names/1`, used by `staff?/1`,
  `authorize_impersonation/2`, `impersonable?/2`, `impersonable_uuids/2`. So the
  **root** account's roles **in effect** decide: an Admin acting as "Seller"
  cannot impersonate, even with a crafted POST, and the menus stop offering it.
  **Targets** are still judged by real roles (`Auth.User.get_roles/1`,
  `role_names/1`).
- The rule is still "the root decides, never the active account", so
  impersonating again from inside an impersonated session works as before.

### UI

`PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher/1`
(`role_switcher.ex:62`):

- Visible only when `Scope.active_role/1` is set, `Scope.switchable_roles/1`
  has ≥2 entries, and the session is not impersonating (`impersonated?` on the
  active entry of `scope.multi_session_accounts`, `:84`). Reads no DB.
  `ActiveRole.location/0` (a cached settings read) only when visible, unless
  the `location` attr is passed.
- `:menu_section`: divider, "Role" title, one row per switchable role. Active
  row = highlighted div with a check; others = `<.form method="put">` posting
  `role_uuid` + `return_to`, form id `"#{id}-#{role_uuid}"`. With location
  `:header` every element gets `sm:hidden`.
- `:header`: renders only with location `:header`; daisyUI dropdown,
  `hidden sm:block`, button shows the active role name.
- Placements: `admin_nav.ex:324` (`admin-role-switcher-menu`),
  `user_dashboard_nav.ex:180` (`dashboard-role-switcher-menu`),
  `layout_wrapper.ex:1103` (`admin-role-switcher-header`),
  `dashboard.html.heex:262` (`dashboard-role-switcher-header`).
- `MultiSession.list_accounts/1` (`:116`) adds `impersonated?`;
  `role_label/1` (`:184`) now labels the roles **in effect**.

### Settings page

`/admin/settings/users`, tab "Roles" (`users.html.heex:417`):

- `role_switcher_enabled` — `<.checkbox>`.
- `role_switcher_location`, `role_switcher_sign_in_role` — `<.select>` with
  labels from one gettext clause per value (`role_switcher_location_label/1`,
  `role_switcher_sign_in_label/1`).
- `role_switcher_always_on_roles` — one **plain** checkbox per custom role
  (`role_switcher_custom_roles/0`, `users.ex:382`: all roles minus
  Owner/Admin/User), plus an always-present hidden `""` so unticking all still
  submits the key. Plain inputs because `<.checkbox>`'s hidden `"false"`
  fallback would land in the list.
- `normalize_settings_params/1` (`users.ex:371`) joins the list into the
  comma-separated string in both `validate_settings` and `save_settings`.
  Saving goes through the existing `Settings.update_settings/2`.

### Public API added

| Function | Notes |
|---|---|
| `Scope.active_role/1`, `held_roles/1`, `narrowed?/1`, `switchable_roles/1` | nil-tolerant, like the rest of `Scope`. `held_roles/1` falls back to `cached_roles` for hand-built scopes. |
| `Scope.for_user(user, narrow: false)` | The full union. Not used in core. |
| `ActiveRole.switch/2`, `apply_sign_in_role/1`, `effective_role_names/1`, `location/0`, `config/0` | Context functions. |
| `ActiveRole.resolve/3`, `sign_in_role/3`, `effective_roles/3`, `switchable?/2`, `switchable_roles/2`, `parse_*` | Pure. |
| `Roles.get_user_role_records/1`, `Permissions.get_permissions_for_roles/1` | Queries. |
| `ScopeNotifier.broadcast_active_role_changed/1` | New message shape (3-tuple). |
| `MultiSession.impersonating?/1`; `list_accounts/1` gains `impersonated?` | |
| `RoleSwitcher.role_switcher/1` | Component. |
| Route `PUT /users/session/role` | `role_uuid`, optional `return_to`. |

### Settings

| Key | Values | Default | Public | Optional (empty allowed) |
|---|---|---|---|---|
| `role_switcher_enabled` | `"true"` / `"false"` | `"false"` | yes | no |
| `role_switcher_location` | `"menu"` / `"header"` | `"menu"` | yes | no |
| `role_switcher_sign_in_role` | `"staff_first"` / `"last_used"` | `"staff_first"` | yes | no |
| `role_switcher_always_on_roles` | comma-separated role uuids | `""` | yes | yes |

Unrecognised values parse to the defaults (`parse_location/1`,
`parse_sign_in_role/1`); unknown uuids in the always-on list are harmless.

### Safety matrix (as built)

Rule: **while narrowed, admin power is unusable** — UI and crafted requests —
**but rules protecting other users judge real roles.**

| Site | Judges by | As built |
|---|---|---|
| Every `Scope` predicate (plugs, on_mount hooks, sidebar, dashboard tabs, `can?/2`) | active | unchanged; follows `for_user/1` |
| `maintenance_mode.ex:87`, `upload_controller.ex:194`, `file_controller.ex:156`, `referrals.ex:327` | active | unchanged; they call `for_user/1` |
| `activity.ex` `full_log_access?`, header role badge (`admin_nav.ex` `current_role_badge`) | active | unchanged; read `cached_roles` |
| Impersonation authority (`multi_session.ex`) | root's roles **in effect** | **changed** (`actor_roles/1`) |
| Impersonation targets | real | unchanged |
| Switch while impersonating | — | **refused** (controller) + switcher hidden |
| `Permissions.can_edit_role_permissions?/2` "own role" (`permissions.ex:1380`) | **held** | **changed** to `held_roles/1` |
| Same, "only Owner edits Admin" | active | unchanged (stricter while narrowed) |
| Grant ceiling `accessible_modules` (`roles.ex:502`, `permissions_matrix.ex:82`) | active | unchanged (stricter while narrowed) |
| Rank rules on `%User{}` (`auth.ex` `validate_admin_authority_over`), `sync_user_roles` actor gate, last-Owner guards | real (DB) | unchanged — reachable only from admin LiveViews the narrowed scope cannot mount |
| Sibling packages reading `Roles.*` from the DB | real | **not changed** — see sibling follow-ups |

### Departures from the plan

1. **Impersonation:** no "active-scope gate on the endpoint". The actor's
   roles are read in effect instead. A gate on the *requesting* scope would
   have broken impersonating again from inside an impersonated session, which
   is intended (the root decides).
2. **Marker:** `:pk_impersonated_tokens` (list), not `:pk_impersonating_ref`,
   and never cleared.
3. **`switch/2`, not `switch/3`,** and the impersonation check lives in the
   controller: the context function has no session.
4. **Redirect:** `safe_destination/2` does not check reachability, so the
   switch redirect adds `skip_admin` when the new role cannot reach the admin
   area.
5. **Eviction reason:** decided — the 3-tuple message with
   `:active_role_changed` (the plan's example name was `:role_switched`).
6. **Always-on roles:** comma-separated string in `value`, not JSON.
7. **Switcher hidden while impersonating** via `list_accounts/1`'s
   `impersonated?`, not a new Scope field; `switchable_roles` **is** a new Scope
   field (the component needs uuids without a query).
8. **Header variant** is `hidden sm:block`, not `hidden sm:flex`.
9. **Settings tab:** Owner/Admin/User are not listed at all (the plan said
   "static text").
10. **Account labels and the impersonation authority** use
    `ActiveRole.effective_role_names/1` rather than building a full `Scope`
    (avoids a permissions query and a dialyzer opaque warning).
11. **Translations:** the extract also pulled in five never-extracted
    start-page strings whose fuzzy carry-overs were wrong; they were
    translated too.

## Tests

| File | Tests | Covers |
|---|---|---|
| `test/phoenix_kit/users/active_role_test.exs` | 30 | Pure: `switchable?`, `resolve` (off, <2 candidates, stored valid / not held / became always-on / User, default order), `sign_in_role` both modes, `effective_roles`, parsers, `stored_role_uuid`, Scope accessors, `can_edit_role_permissions?` while narrowed, `impersonating?/1`. DB-less. |
| `test/integration/users/active_role_scope_test.exs` | 9 | `for_user/1`: off = union; Admin default; Admin acting as Seller has no admin; permissions from active role only; revoked stored role; always-on roles; User never a mode; `narrow: false`; Owner acting as another role is not Owner / not superadmin. |
| `test/integration/phoenix_kit_web/users/active_role_gate_test.exs` | 2 | `live/2` on an admin page: acting as Admin mounts; acting as a custom role is redirected. |
| `test/integration/phoenix_kit_web/users/active_role_switch_test.exs` | 15 | PUT: switch + narrow; unreachable `return_to` replaced; reachable kept; off-site never followed; unheld role; User role; switcher off; missing param; while impersonating. Impersonation: marker + `list_accounts` flag; narrowed Admin cannot impersonate. Sign-in (password): staff_first Admin reset; non-staff keeps; last_used keeps. Open admin LiveView redirected with switch copy. |
| `test/phoenix_kit_web/components/core/role_switcher_test.exs` | 6 | Menu rows/forms/`_method`/ids; `sm:hidden` with header location; nothing when not narrowed; nothing when impersonating; header variant only with header location. |
| `test/integration/phoenix_kit_web/live/settings/role_switcher_settings_test.exs` | 3 | Tab controls; only custom roles offered; round-trip incl. list join; untick-all saves empty. |

Run just the feature (sandbox DB):

```bash
PGDATABASE=beamlab_test mix test \
  test/phoenix_kit/users/active_role_test.exs \
  test/integration/users/active_role_scope_test.exs \
  test/integration/phoenix_kit_web/users/active_role_gate_test.exs \
  test/integration/phoenix_kit_web/users/active_role_switch_test.exs \
  test/phoenix_kit_web/components/core/role_switcher_test.exs \
  test/integration/phoenix_kit_web/live/settings/role_switcher_settings_test.exs
```

Neighbours worth running with it: `session_multi_test.exs`,
`test/integration/users/multi_session_test.exs`, `auth_flows_test.exs`,
`test/phoenix_kit_web/users/auth_test.exs`, `permissions_test.exs`,
`users_settings_page_test.exs`, `settings_test.exs`, `setting_test.exs`.

Test-writing notes: the settings cache is not started in the suite, so settings
writes stay in the sandbox and these files run `async: true` (the settings
page files are `async: false` like their neighbour).

## Gates run

Every stage ended clean on compile (warnings as errors), format, credo
--strict and dialyzer, and ran the full `mix test` against `beamlab_test`.
Stages 1, 3 and 4–5 finished with a whole `mix precommit` at exit 0. Stage 2's
precommit failed only on dialyzer (`call_without_opaque` at `session.ex`);
after the `.dialyzer_ignore.exs` entry, `mix dialyzer` alone was re-run to
exit 0 — compile, credo and format had already passed in that same precommit
run, and every later stage's full precommit covers stage 2's code too.

| After | Full suite | Failures |
|---|---|---|
| Stage 1 | 4957 tests | 2 → 1 after fixing `@optional_settings` (mine) |
| Stage 2 | 4975 tests | 1 |
| Stage 3 | 4983 tests | 1 |
| Stages 4–5 | 4986 tests | 1 |

The one remaining failure is **pre-existing and unrelated**:
`MediaBrowserTest` "info sidebar collapse…" (`media_browser_test.exs:567`,
two `toggle_viewer_sidebar` buttons since #803). It fails identically on a
stashed tree.

Gettext: `mix gettext.extract` + `merge`, 23 new msgids hand-translated in
seven locales, `mix compile` (the `%{}` binding check), second merge
0 new / 0 removed / 0 fuzzy for all eight catalogues,
`mix gettext.extract --check-up-to-date` exit 0. Every locale has **42
pre-existing** untranslated entries (already empty in `HEAD`, from earlier
PRs) — left alone.

## Known gaps, risks and open questions

Review focus, roughly by importance.

1. **Sibling packages ignore the active role** where they read roles from the
   DB — comments (moderate anyone's comment), posts (edit anyone's post),
   projects (role-based project grants). A narrowed Admin keeps those powers
   until the siblings move to the scope. Details at the end of this file.
2. **Per-user, not per-browser — including sign-in.** With `staff_first`, an
   Admin signing in on device B resets their role to Admin and broadcasts, so
   device A, which was acting as Seller, silently becomes Admin again (its
   LiveViews refresh; nothing is evicted because access only widened). This
   follows from the two confirmed decisions, but it is the least obvious
   consequence — confirm it is wanted.
3. **`:pk_impersonated_tokens` is never pruned.** Each impersonation adds a
   raw token (32 bytes) to the session. Removing the account deletes the token
   from the DB but not from this list, so repeated impersonate/remove in one
   browser session grows the session cookie. Harmless for correctness (dead
   tokens never become active), but a cookie-size risk on a support desk that
   impersonates dozens of users without logging out. Candidate fix: drop the
   token in `remove_account/2` and `log_out_to_root/5`.
4. **Not every sign-in path is tested individually.** Only password sign-in has
   a test for the sign-in rule. Magic link, QR, OAuth and registration
   auto-login rely on all calling `log_in_user/3` (verified by reading, not
   tested). Remember-me restore not resetting the role is also untested.
5. **Untested branches:** the `require_admin` *plug* under narrowing (only the
   LiveView on_mount gate is tested); the `:evict_module` + switch-reason
   combination (a narrowed role that keeps the admin area but loses the current
   module); the header variant rendered inside the real layouts (only the
   component is rendered in tests).
6. **No browser verification.** Nothing was checked visually: dropdown spacing
   next to the Accounts section, the header control at `sm`/`md`/`lg`, dark
   themes, long role names (truncated with `max-w-40`), RTL. Worth a look
   through the git-dep trial flow before publishing.
7. **File-level dialyzer ignore** for `lib/phoenix_kit_web/users/session.ex`
   (`call_without_opaque`) — the repo's convention for the known `Scope`/`MapSet`
   false positive, but it will also hide any future real opaque issue in that
   file.
8. **System roles are matched by name** (`"Owner"`, `"Admin"`, `"User"`), as
   everywhere else in core. A host that renames a system role in the DB breaks
   `switchable?/2` along with the existing checks. Not new, but this feature
   leans on it.
9. **Fallback when the stored role is revoked** goes to Owner > Admin > first
   by name — a user in Seller mode whose Seller role is revoked lands in Admin
   if they hold it. Confirmed by the maintainer, noted for reviewers.
10. **Cost.** `for_user/1`: unchanged query count; +1 cached settings read for
    users with ≥2 roles (+2 more when the feature is on). `list_accounts/1`
    (only with multi-session on): each account's label now goes through
    `effective_role_names/1` (same roles query + cached settings reads).
    `impersonable_uuids/2`: one actor lookup per call, as before.
11. **`switch/2` is last-write-wins** across concurrent requests; the JSONB
    merge itself is atomic.
12. **The host's original request** (a header extension point for arbitrary
    widgets) was not built. If their "role" is a PhoenixKit role, the header
    switcher covers it; if it is a host concept, they still need that hook.

## Review checklist

- [ ] No code path stores or reads the active role outside
      `custom_fields["active_role_uuid"]` / `Scope.for_user/1`.
- [ ] `resolve/3` can only return a held, currently switchable role; nothing
      trusts the stored uuid directly.
- [ ] Feature off (`role_switcher_enabled` false) is byte-for-byte the old
      behaviour: `narrow/2` returns `{nil, held, []}` and permissions go
      through `get_permissions_for_user/1`.
- [ ] Owner acting as a custom role: not Owner, not `superadmin?`, no
      all-keys permission set.
- [ ] `PUT /users/session/role`: refuses unheld / non-switchable / User role /
      feature off / impersonating / missing param; CSRF via `:browser`;
      `return_to` cannot leave the site or land in an unreachable admin page.
- [ ] Impersonation: root's roles in effect for authority, real roles for
      targets; chained impersonation from an impersonated session still works.
- [ ] `can_edit_role_permissions?`: `held_roles` for "own role", active for
      "only Owner edits Admin".
- [ ] Refresh: 2-tuple behaviour unchanged; 3-tuple refreshes and evicts with
      the switch copy; multi-session fields survive a refresh.
- [ ] Sign-in rule applied before the destination is resolved; never raises;
      writes/broadcasts only on change.
- [ ] Component renders nothing unless narrowed, never while impersonating;
      every form id unique; `sm:hidden` / `hidden sm:block` pairing correct.
- [ ] Settings: all four keys public; always-on optional; untick-all saves
      empty; no `disabled` checkbox.
- [ ] Translations: the 23 new msgids read correctly per locale (formal
      de/es/fr/ru, informal it/pl), no fuzzy flags.
- [ ] Risks 2 and 3 above: accept, or fix before publishing.

---

# Part 2 — Original plan (design record)

## Why

A host app (seller/buyer marketplace) asked for a header extension point to
render its own role switcher. Talking it through, the real gap is in core:
PhoenixKit has roles but no notion of *acting as* one. Before this work a
user's access was the **union of every role they hold** — `Scope.for_user/1`
loaded all role names and `Permissions.get_permissions_for_user/1` joined
across every assignment. A user holding Admin, Seller and Buyer was always all
three at once; there was no way to "see how the seller side works", and a host
could not build a seller UI that a seller-who-is-also-an-admin experiences as a
seller.

What the maintainer wants (2026-09-13):

1. A **current role** in core. Switching to a role **really limits access** —
   an Admin who switches to Seller sees only the seller UI and has no admin
   access at all, not merely a different label.
2. A **built-in, settings-driven switcher**, so host apps get it by turning it
   on rather than building and integrating one.
3. The switcher lives in the **session widget** (under the language switcher),
   with a setting for where it appears; the header is an option, and on phones
   it always falls back into the menu.
4. **Default role on sign-in:** Admin if the user holds Admin; otherwise the
   role they last used (a seller who returns after a few days is still a
   seller, and can switch to buyer).

Decisions confirmed by the maintainer: per-user storage; no "All roles" entry;
User always-on plus operator-configurable always-on custom roles; revoked-role
fallback = the sign-in default.

## The central decision: where the active role lives

**Per user, persisted, and applied inside `Scope.for_user/1`.**

The inventory found the scope is rebuilt from scratch with `Scope.for_user/1`
at ~14 sites in core and ~6 in siblings — the plug, every LiveView mount, the
ScopeNotifier refresh, embedded mounts, login redirect resolution,
`Session.conn_scope`, OAuth, the maintenance plug, the upload and file
controllers, referrals, comments, dashboards, projects, publishing's
background translation. Any active role held *outside* `for_user` (a session
key, a socket assign) is silently dropped by every one of them, widening the
user back to all roles. The refresh handler in particular has no session at
all — it rebuilds from the user row.

So the active role is **state on the user row**, and `for_user/1` narrows from
it. Every existing rebuild then narrows for free, including siblings that never
heard of the feature. It also delivers requirement 4 directly: "last used" is
simply what is stored.

| Option | Verdict |
|---|---|
| Session key | Rejected. Dropped by ~20 rebuild sites, invisible to the refresh handler, wiped by `renew_session/1` at login, lost on remember-me restore. Every miss is a *privilege widening*. |
| Socket/conn assign | Rejected. Same, and does not survive a request. |
| **User row (`custom_fields["active_role_uuid"]`)** | **Chosen.** Read by `for_user/1`, which every path already calls with a freshly-loaded user. No migration (so no expected-schema restamp); `custom_fields` is already the per-user preference store (`preferred_locale`, notification prefs). |
| New `phoenix_kit_users.active_role_uuid` column | Viable (would give an FK with `ON DELETE SET NULL`), but costs V190 + a hand-declared manifest entry for nothing the read-time validation below doesn't already give. Revisit only if we need to query users by active role. |

**Consequence (confirmed):** the role is per *user*, not per *browser*.
Switching to Seller on the laptop switches the phone too — its open LiveViews
refresh through ScopeNotifier and get evicted from admin pages.

Stored by **role uuid**, never name — role names are editable (the `Role`
changeset does not block renames).

## Semantics

### Switchable vs. always-on roles

Not every role is a "mode". The baseline **User** role (and possibly some host
roles) should apply whatever mode you are in. So each role a user holds is one
of:

- **Switchable** — a mode. Exactly one is active at a time.
  **Owner and Admin are always switchable** (otherwise narrowing could never
  remove admin access — the whole point). Custom roles are switchable by
  default.
- **Always-on** — combined with whichever switchable role is active.
  **User is always-on.** An operator can mark custom roles always-on in
  settings (e.g. a "Newsletter subscriber" role that should not be a mode).

Narrowed scope = active switchable role **+** every always-on role held.

### When narrowing applies

Only when **all** of:

- `role_switcher_enabled` is on (default **off** → the old behaviour exactly,
  for every existing install);
- the user holds **two or more switchable roles**.

With zero or one switchable role there is nothing to choose; the scope is the
union, and no switcher is shown.

**No "all roles" entry (confirmed).** An "All roles" choice was floated early
on. The maintainer's direction (roles as modes, Admin by default) replaces it:
while the feature is on, a multi-role user is always exactly one switchable
role.

### Resolving the active role (pure, read-time)

`PhoenixKit.Users.ActiveRole.resolve(held, stored_uuid, config)` — pure, no DB:

1. Candidates = held roles that are switchable.
2. Fewer than two → `nil` (no narrowing).
3. `stored_uuid` names a candidate → that role.
4. Otherwise → Owner > Admin > first switchable role by name.

Read-time validation is what makes it safe: a stored role the user no longer
holds (revoked, or made always-on in settings) is ignored, never trusted.
**Nothing is written on read.** The result is always a subset of the roles the
user holds, so narrowing only ever narrows.

### Sign-in default

Setting `role_switcher_sign_in_role`:

- **`staff_first`** (default, per the maintainer): if the user holds Owner or
  Admin, sign-in **resets** the active role to the highest of them
  (Owner > Admin). Otherwise the stored role is kept.
- **`last_used`**: sign-in always keeps the stored role.

Applied once, in `PhoenixKitWeb.Users.Auth.log_in_user/3` — every interactive
sign-in goes through it. **Remember-me restore does not reset** — it continues
a session, it is not a sign-in.

Fallback when nothing valid is stored (first sign-in, or the stored role was
revoked): Owner > Admin > first switchable custom role by name. **Confirmed**
for the revoked case too, over a least-privileged fallback.

### How `for_user/1` narrows

- Load role **records** (uuid + name) in one query: `Roles.get_user_role_records/1`.
- New Scope fields `held_roles` and `active_role`
  **[as built: also `switchable_roles`]**.
- `cached_roles` = active + always-on names when narrowed, otherwise all, so
  `has_role?`, `owner?`, `can_access_admin_area?`, `system_role?`, the header
  badge and `full_log_access?` follow the active role with no change.
- `cached_permissions`: the existing Owner / Admin / other `cond`, applied to
  the **narrowed** role set, with permissions from
  `Permissions.get_permissions_for_roles/1`. The Admin table-missing fallback
  is unchanged.
- Escape hatch: `Scope.for_user(user, narrow: false)`.

## Switching

`PUT /users/session/role` → `Users.Session.set_active_role/2`, a plain form
POST like the account switcher (the switcher renders in the layout, so a
`phx-click` would land in whatever page LiveView is mounted). Added to **both**
route blocks in `integration.ex`.

`ActiveRole.switch(user, role_uuid, opts)` **[as built: `switch/2`; the
impersonation check is in the controller]**:

1. Feature on, user active.
2. Role is held **and** switchable → otherwise `{:error, :not_switchable}`.
3. Not impersonating → otherwise refused **[as built: controller flash]**.
4. `Auth.merge_user_custom_fields(user, %{"active_role_uuid" => uuid},
   ensure_definitions: false)`; `active_role_uuid` added to
   `CustomFields.@internal_keys`.
5. `Activity.log` `session.role_switched`, metadata `from`/`to` role names.
   Actor = target, so no notification fans out.
6. `ScopeNotifier` broadcast → every open LiveView of the user, on every
   device, refreshes and is evicted by `scope_refresh_decision/4` if it lost
   access.

Redirect: `Routes.safe_destination/2` with the scope read after the switch
**[as built: plus `skip_admin` when the new role has no admin-area access —
`safe_destination/2` proves routable, not reachable]**.

Eviction flash: "You must be an admin to access this page" reads wrong after a
deliberate switch, so the broadcast carries a reason
**[as built: `{:phoenix_kit_scope_roles_updated, uuid, :active_role_changed}`]**.

## Safety rules: real roles vs. active role (plan)

**[as built: see "Safety matrix (as built)" in Part 1, which supersedes this
table.]**

The rule: **while narrowed, admin power must be unusable** — through the UI
*and* by a crafted request — **but rules that protect other users keep judging
by real roles.**

| Site | Judges by | Planned action |
|---|---|---|
| Every `Scope` gate (plugs, on_mount, tabs, sidebar, `can?`) | active | none — follows `for_user` |
| Maintenance plug, upload/file controllers, referrals | active | none — they call `for_user` |
| Rank rules (delete/credentials/status/confirm), `sync_user_roles` actor gate, last-Owner guards | real | none — reachable only from admin LiveViews the narrowed scope refuses |
| Impersonation endpoint | real, root | ~~Add an active-scope gate~~ **[as built: actor roles read in effect]** |
| "cannot edit your own role" | would become active | change to `held_roles` |
| "only Owner edits Admin" | active | none — stricter while narrowed |
| Grant ceiling = `accessible_modules` | active | none — stricter while narrowed |

Impersonation: switching while impersonating would rewrite the *target's*
stored role, so it is refused and the switcher hidden. The session had no
impersonation marker, so one is added
**[as built: `:pk_impersonated_tokens`, never cleared — not
`:pk_impersonating_ref`]**.

## Settings (plan)

A new **Roles** tab on `/admin/settings/users`. Keys in
`Settings.get_defaults/0` **and** `@public_setting_keys`.

| Key | Values | Default |
|---|---|---|
| `role_switcher_enabled` | `"true"`/`"false"` | `"false"` |
| `role_switcher_location` | `"menu"` / `"header"` | `"menu"` |
| `role_switcher_sign_in_role` | `"staff_first"` / `"last_used"` | `"staff_first"` |
| `role_switcher_always_on_roles` | role uuids | empty (User is always-on regardless) |

`location = header`: a compact header control at `sm` and up, the menu section
at phone width.

The list cannot ride the string form path as a list
**[as built: comma-separated string in `value`, joined in the page's
validate/save handlers — not JSON]**. **Never** a `disabled` checkbox (the
hidden `false` fallback rewrites the setting)
**[as built: Owner/Admin/User are simply not listed]**.

## UI (plan)

One component, `PhoenixKitWeb.Components.Core.RoleSwitcher`, two variants:

- `:menu_section` — "Role" title + one form row per switchable held role, the
  active one highlighted with a check. Under Language in **both**
  `AdminNav.admin_user_dropdown/1` and `UserDashboardNav.user_dropdown/1`.
- `:header` — a compact dropdown in the admin and dashboard headers' right
  cluster **[as built: `hidden sm:block`]**.

Renders nothing unless narrowed and not impersonating. Unique form ids.
Strings through gettext in all locales. Role names are DB strings and stay
untranslated. The multi-session account list's per-account label shows each
account's **active** role.

## Found along the way

- `refresh_scope_assigns/1` rebuilt the scope without
  `MultiSession.scope_fields/1`, so after any role/permission change a
  connected LiveView lost the account list from its dropdown until reload.
  **[as built: fixed in stage 2 — `carry_multi_session_fields/2`.]**
- `AdminNav.admin_user_info/1` is never rendered. Not ours to remove here.

## Stages (plan)

Each stage: commit straight to `main`, `mix precommit` clean, the relevant
tests against the sandbox DB. **No version bump, no publish.** CHANGELOG
entries accumulate under `## Unreleased`.

1. **Model, no UI.**
2. **Switching & safety.** Planned tests not written as separate cases:
   CSRF, every sign-in flow, remember-me restore — see "Known gaps" item 4.
3. **Switcher UI.**
4. **Settings tab.**
5. **Docs.** Guide, AGENTS.md, CHANGELOG.

## Sibling follow-ups (not in this run)

These read roles from the DB instead of the scope, so they ignore narrowing:

- **phoenix_kit_comments** `web/comments_component.ex:2018` `user_is_admin?`
  via `Roles.user_has_role_owner?/admin?` — moderate anyone's comment.
- **phoenix_kit_posts** `web/edit.ex:552`, `web/details.ex:172` — same, edit
  anyone's post.
- **phoenix_kit_projects** `grants.ex:373` `role_subjects` via
  `Roles.get_user_roles` — **role-based project grants**, an access decision.

Lower risk, noted: `phoenix_kit_customer_support` `web/edit.ex:196` lists
support staff by role (targets, not the viewer); `phoenix_kit_billing` and
`phoenix_kit_ecommerce` `activity.ex` record `actor_role` from `cached_roles`
(now the active role — arguably correct).

Each should move to the scope (`Scope.owner?`/`system_role?`,
`scope.cached_roles`) behind a feature-detect, and must not narrow its core
pin. Until they do, a narrowed Admin keeps those three powers. Core should ship
first.
