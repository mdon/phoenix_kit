# Active role — one role at a time, and a switcher to change it

**Created:** 2026-09-13
**Status:** Plan approved 2026-09-13 (all four open decisions taken as
recommended: per-user, no "All roles", User always-on + configurable,
sign-in-default fallback). Stages 1–5 BUILT on `main` 2026-09-13 (stage 1
`273b4b1e`, stage 2 `2196be19`, stage 3 `0d012071`, stages 4–5 in the commit
after). Not published — awaiting review by other agents. Sibling follow-ups
(end of this file) not started.

**As built, departures from the plan below:**

- The impersonation authority reads the root's roles *in effect* through
  `ActiveRole.effective_role_names/1`, not a new active-scope gate on the
  endpoint — impersonating from inside an impersonated session is intended
  (the root decides), and a gate on the requesting scope would have broken it.
- The impersonation marker is `:pk_impersonated_tokens` (a list of tokens
  `impersonate/2` added), never cleared: removed tokens are deleted and cannot
  become active again, and a fresh login clears the session.
- `safe_destination/2` proves a path routable, not reachable, so the switch
  redirect passes `skip_admin: true` when the new role has no admin-area access.
- The switcher hides itself while impersonating using the `impersonated?` flag
  `MultiSession.list_accounts/1` now carries, not a new Scope field.
- `role_switcher_always_on_roles` is a comma-separated string (not JSON), so it
  rides the ordinary settings form; the page joins the checkbox list.
**Scope:** phoenix_kit (core). Sibling follow-ups listed at the end.

## Why

A host app (seller/buyer marketplace) asked for a header extension point to
render its own role switcher. Talking it through, the real gap is in core:
PhoenixKit has roles but no notion of *acting as* one. Today a user's access is
the **union of every role they hold** — `Scope.for_user/1` loads all role
names (`scope.ex:129`) and `Permissions.get_permissions_for_user/1` joins
across every assignment (`permissions.ex:754`). A user holding Admin, Seller
and Buyer is always all three at once; there is no way to "see how the seller
side works", and a host cannot build a seller UI that a seller-who-is-also-an-
admin experiences as a seller.

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
all (`auth.ex:2428`) — it rebuilds from the user row.

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

**Consequence (confirmed):** the role is per *user*, not per *browser*. Switching
to Seller on the laptop switches the phone too — its open LiveViews refresh
through ScopeNotifier and get evicted from admin pages. We think this is right
(one mental model, no "why am I still admin on my phone?"), but it is a choice.

Stored by **role uuid**, never name — role names are editable
(`role.ex` changeset does not block renames).

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

- `role_switcher_enabled` is on (default **off** → today's behaviour exactly,
  for every existing install);
- the user holds **two or more switchable roles**.

With zero or one switchable role there is nothing to choose; the scope is the
union, as today, and no switcher is shown.

**No "all roles" entry (confirmed).** Earlier in the discussion we floated an
"All roles" choice as the default. The maintainer's direction (roles as modes,
Admin by default) replaces it: while the feature is on, a multi-role user is
always exactly one switchable role. An Owner or Admin already sees everything
their role grants, so the union adds little and would reintroduce the
confusion the feature removes.

### Resolving the active role (pure, read-time)

`PhoenixKit.Users.ActiveRole.resolve(held, stored_uuid, settings)` — pure, no
DB, unit-testable:

1. Candidates = held roles that are switchable.
2. Fewer than two → `nil` (no narrowing).
3. `stored_uuid` names a candidate → that role.
4. Otherwise → the **sign-in default** (below).

Read-time validation is what makes it safe: a stored role the user no longer
holds (revoked, or made always-on in settings) is ignored, never trusted.
**Nothing is written on read** — no DB writes from plugs or mounts.

**The result can never exceed the user's real grants**: it is always a subset
of the roles they hold, so narrowing only ever narrows.

### Sign-in default

Setting `role_switcher_sign_in_role`:

- **`staff_first`** (default, per the maintainer): if the user holds Owner or
  Admin, sign-in **resets** the active role to the highest of them
  (Owner > Admin). Otherwise the stored role is kept.
- **`last_used`**: sign-in always keeps the stored role.

The reset is written once, in `PhoenixKitWeb.Users.Auth.log_in_user/3` — every
interactive sign-in goes through it (password, registration auto-login,
magic link, QR, OAuth, password-change re-login). **Remember-me restore does
not reset** — it continues a session, it is not a sign-in.

Fallback when nothing valid is stored (first sign-in, or the stored role was
revoked): Owner > Admin > first switchable custom role by name. **Confirmed**
for the revoked case too: a user in Seller mode whose Seller role is revoked lands in
Admin if they hold it. That is within their real grants, but it is a jump *up*
in the UI; the maintainer chose one rule for both over a least-privileged
fallback.

### How `for_user/1` narrows

- Load role **records** (uuid + name) in one query instead of names only:
  new `Roles.get_user_role_records/1`.
- New Scope fields:
  - `held_roles` — every role name the user really holds (display, switcher,
    and the safety rules below);
  - `active_role` — `%{uuid, name}` or `nil` when not narrowed.
- `cached_roles` = active + always-on names when narrowed, otherwise all (so
  `has_role?`, `owner?`, `can_access_admin_area?`, `system_role?`, the header
  badge, `activity.ex` `full_log_access?` all follow the active role with no
  change).
- `cached_permissions`: the existing Owner / Admin / other `cond`, applied to
  the **narrowed** role set, with permissions from new
  `Permissions.get_permissions_for_roles/1` (the same join, filtered to those
  role uuids). The Admin table-missing fallback is unchanged.
- Escape hatch: `Scope.for_user(user, narrow: false)` for code that genuinely
  needs the full union (none in core today; documented for siblings).

Query count per scope build stays the same as today (roles, permissions) plus
cached settings reads.

## Switching

`PUT /users/session/role` → `Users.Session.set_active_role/2`, a plain form
POST like the account switcher (the header lives in the layout, so a
`phx-click` would land in whatever page LiveView is mounted — the same reason
account switching is a controller). Added to **both** route blocks in
`integration.ex` (plain and localized, ~251 and ~1492).

`ActiveRole.switch(user, role_uuid, opts)` context function:

1. Feature on, user active.
2. Role is held **and** switchable → otherwise `{:error, :not_switchable}`.
3. Not impersonating → otherwise `{:error, :impersonating}` (below).
4. `Auth.merge_user_custom_fields(user, %{"active_role_uuid" => uuid},
   ensure_definitions: false)`; `active_role_uuid` added to
   `CustomFields.@internal_keys`.
5. `Activity.log` `session.role_switched`, metadata `from`/`to` role names.
   Actor = target, so no notification fans out.
6. `ScopeNotifier` broadcast for the user → every open LiveView of theirs, on
   every device, refreshes and is evicted by the existing
   `scope_refresh_decision/4` if it lost access.

Redirect: `Routes.safe_destination(conn, scope: new_scope, return_to: …)`,
with the scope read from the session after the switch. `safe_destination/2`
only proves a path *routable*, not reachable by the scope, so when the new
role has no admin-area access the call passes `skip_admin: true` — which
rejects admin-area candidates — instead of following `return_to` into an admin
page whose gate would bounce the user with "You must be an admin".

Eviction flash: the existing copy ("You must be an admin to access this page")
reads wrong after a deliberate switch. The refresh handler cannot tell a switch
from a revoke, so either the broadcast carries a reason
(`{:phoenix_kit_scope_roles_updated, uuid, :role_switched}`, keeping the
2-tuple handled) or the switched tab's redirect makes it moot and only *other*
tabs see the copy. Decide in stage 2; lean to the reason tuple.

## Safety rules: real roles vs. active role

The rule: **while narrowed, admin power must be unusable** — through the UI
*and* by a crafted request — **but rules that protect other users keep judging
by real roles.**

| Site | Judges by | Action |
|---|---|---|
| Every `Scope` gate (plugs, on_mount, tabs, sidebar, `can?`) | active | none — follows `for_user` |
| `maintenance_mode.ex:87`, `upload_controller.ex:194`, `file_controller.ex:156`, `referrals.ex:327` | active | none — they call `for_user` |
| Rank rules `auth.ex:3420` (delete/credentials/status/confirm), `roles.ex:1150` sync actor gate, last-Owner guards | real (`%User{}`, DB) | none. Only reachable from admin LiveViews that the narrowed scope already refuses to mount. Documented, not changed. |
| **Impersonation** `POST /users/session/impersonate/:uuid` (`multi_session.ex:498`) | real, **root** account | **Add** an active-scope gate: refuse when the requesting scope cannot reach the admin area. Otherwise a narrowed Admin can impersonate by crafting the POST. |
| `permissions.ex:1351` "cannot edit your own role" | `Scope.user_roles` (would become active) | **Change to `held_roles`**: a user must not edit *any* role they hold, including the ones they are not currently acting as. |
| `permissions.ex:1351` "only Owner edits Admin" | `Scope.owner?` (active) | none — stricter while narrowed is correct |
| `roles.ex:502`, `permissions_matrix.ex:82` grant ceiling = `accessible_modules` | active | none — stricter while narrowed |

### Impersonation

Switching while impersonating would rewrite the *target's* stored role, so it is
refused and the switcher hidden. The impersonated scope uses the target's own
stored role, which is what "see what they see" means. The session has **no
impersonation marker today** (an impersonated account is an ordinary
non-persisted stack entry), so stage 2 adds one (`:pk_impersonating_ref`, set by
`impersonate/2`, cleared by `remove_account`/`log_out_to_root`/`log_out_user`).

## Settings

On `/admin/settings/users`, a new **Roles** tab (the page already has
registration | sessions | redirects | defaults | fields). Keys go in
`Settings.get_defaults/0` **and** `@public_setting_keys` (the mount filters on
it; `settings_test.exs` fails otherwise).

| Key | Values | Default |
|---|---|---|
| `role_switcher_enabled` | `"true"`/`"false"` | `"false"` |
| `role_switcher_location` | `"menu"` / `"header"` | `"menu"` |
| `role_switcher_sign_in_role` | `"staff_first"` / `"last_used"` | `"staff_first"` |
| `role_switcher_always_on_roles` | role uuids | `[]` (User is always-on regardless) |

`location = header`: a compact control in the header's right cluster at `sm`
and up, and the menu section at phone width (`sm:hidden`) — one setting, no
separate mobile case.

The list setting cannot ride the string form path (`update_settings/2` writes
`value`, not `value_json`). Store as a JSON-encoded string in `value`, decoded
in one reader, with checkbox params joined in the page's save handler — or a
dedicated event like custom fields. Pick in stage 4. **Never** a `disabled`
checkbox for Owner/Admin/User rows (the hidden `false` fallback rewrites the
setting — AGENTS.md landmine); render them as static text.

## UI

One component, `PhoenixKitWeb.Components.Core.RoleSwitcher`, two variants:

- `:menu_section` — "Role" title + one form row per switchable held role, the
  active one highlighted with a check (the account-row markup in both
  dropdowns is the pattern). Rendered under Language in **both**
  `AdminNav.admin_user_dropdown/1` and `UserDashboardNav.user_dropdown/1`.
- `:header` — a compact dropdown (active role name + chevron), `hidden sm:flex`,
  placed in the right cluster of the admin header (`layout_wrapper.ex:1076`) and
  the dashboard header (`dashboard.html.heex:228`).

Renders nothing unless: feature on, `scope.active_role` set, not impersonating.
Every `<form>` gets a unique id (`missing_form_id` landmine). Strings through
gettext, all 8 locales, full extract/merge round-trip. Role names themselves are
DB strings and stay untranslated (as everywhere today).

Also: the multi-session account list's per-account `role_label`
(`multi_session.ex:173`, from `User.get_roles`) should show each account's
**active** role.

## Found along the way

- `refresh_scope_assigns/1` (`auth.ex:2428`) rebuilds the scope with
  `Scope.for_user/1` but never re-applies `MultiSession.scope_fields/1`, so after
  any role/permission change a connected LiveView loses the account list from
  its dropdown until reload. Switching roles makes this far more frequent. Fix
  in stage 2 (the socket has no session, so capture the fields at mount or
  re-derive from the token list).
- `AdminNav.admin_user_info/1` (`admin_nav.ex:514`) is never rendered. Not ours
  to remove here.

## Stages

Each stage: commit straight to `main`, `mix precommit` clean, the relevant
tests run against the sandbox DB. **No version bump, no publish** — the
maintainer is having other agents review first. CHANGELOG entries accumulate
under `## Unreleased`.

1. **Model, no UI.** `Roles.get_user_role_records/1`,
   `Permissions.get_permissions_for_roles/1`, pure `ActiveRole.resolve/3`, the
   four settings (off), `active_role_uuid` internal key, Scope `held_roles` /
   `active_role`, narrowing in `for_user/1`, `narrow: false` opt.
   Tests: resolver table (DB-less); integration — Admin+Seller in Seller mode
   fails `can_access_admin_area?`, `require_admin` 302s, admin LiveView mount
   redirects; feature off = union unchanged; revoked stored role falls back;
   always-on roles combine.
2. **Switching & safety.** `ActiveRole.switch/3`, controller + both route
   blocks, activity log, broadcast (+ reason), sign-in default in
   `log_in_user/3`, impersonation marker + refusal + active-scope gate on the
   impersonate endpoint, `can_edit_role_permissions` on `held_roles`, the
   refresh multi-session fix.
   Tests: switch to unheld / non-switchable role refused; CSRF; `return_to`
   open-redirect guard; crafted impersonate POST while narrowed refused;
   connected admin LiveView evicted after a switch from another conn; each
   sign-in flow applies the default; remember-me restore does not.
3. **Switcher UI.** Component, both dropdowns, both headers, account-list
   label, gettext round-trip.
4. **Settings tab.** Roles tab, the list setting, page round-trip test.
5. **Docs.** `dev_docs/guides/2026-09-13-active-role.md`; AGENTS.md
   Permissions bullet (landmine: *never hold the active role outside
   `for_user`*; `narrow: false`); CHANGELOG Unreleased.

## Sibling follow-ups (not in this run)

These read roles from the DB instead of the scope, so they ignore narrowing:

- **phoenix_kit_comments** `comments_component.ex:2018` `user_is_admin?` via
  `Roles.user_has_role_owner?/admin?` — moderate anyone's comment.
- **phoenix_kit_posts** `edit.ex:552`, `details.ex:172` — same, edit anyone's
  post.
- **phoenix_kit_projects** `grants.ex:373` `role_subjects` via
  `Roles.get_user_roles` — **role-based project grants**, an access decision.

Each should move to the scope (`Scope.owner?`/`system_role?`, `scope.cached_roles`)
behind a feature-detect, and must not narrow its core pin. Until they do, a
narrowed Admin keeps those three powers. Core should ship first.
