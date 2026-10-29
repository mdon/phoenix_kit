# Acting for an organization

**Status:** scope only, not started. Design reviewed by Codex on 2026-10-29
and by Grok on 2026-10-29 (findings folded in; see
[Review (Codex)](#review-codex-2026-10-29) and
[Review (Grok)](#review-grok-2026-10-29)). One question is open
([Open questions](#open-questions)).
**Requested by:** Andi's project (2026-10-29).

## Problem

Some people own several companies and use one email address for all of them.
Today an organization is a `User` row (`account_type: "organization"`) with its
own login email, and `phoenix_kit_users.email` is unique (`phoenix_kit_users_email_index`).
So a person who wants five companies needs five mailboxes, or five
plus-addresses (`me+acme@…`), and five passwords.

## Decision

**One email = one login stays.** Instead, an organization can be a
**managed** account: it has no login of its own, and the people allowed to act
for it enter it from their own session, through the account menu.

Rejected:

- **A setting that allows duplicate emails, login by username.** Username
  login already works (`Auth.get_user_by_email_or_username_and_password/3`), but
  everything else that resolves an email does not: magic link, forgot password,
  email confirmation, OAuth matching, email change, organization invitations,
  the rate limits keyed on email, and ~30 `get_user_by_email` call sites in core
  plus `phoenix_kit_crm` and host apps, each assuming one result. The unique
  index cannot follow a runtime setting either: it would be dropped for every
  install, uniqueness would become a racy app-level check, and switching the
  setting back off cannot restore the index once duplicates exist.
- **A nullable email.** `email` is `NOT NULL` since V1 and typed `String.t()`;
  every reader (mailers, display names, admin search, the CRM mirror, hosts)
  would need a `nil` branch. A placeholder address (§2) changes one changeset
  instead.
- **One membership table replacing `users.organization_uuid`, with the person
  staying signed in as themselves and an "active company" in the scope** (the
  first proposal). See the next section.
- **The acting organization stored on the person's own token** (like
  `active_role_uuid`), with the token loader returning the organization. One
  token would then resolve to a user it does not belong to, and every
  token-by-user path (the Sessions page, revoke, logout, `SessionRef`, login
  alerts) would have to learn about it.

## How this differs from the first proposal

| | First proposal | This plan |
|---|---|---|
| Person ↔ company link | `organization_uuid` replaced by a membership table (backfill, every reader changed, CRM changed) | `organization_uuid` ("works at") untouched; a NEW table says who may act for which organization |
| Who the session is | the person, with an active company in the scope | the organization's own account, entered by the person |
| Company-owned data | every core table and module must key on, and filter by, the active company | whatever an account owns today (files, libraries, orders, settings, notifications, roles) is the organization's, because the session IS the organization |
| "Who really did it" | the session user | the organization, with the person in the activity metadata (§8) |
| Size | core users/auth + CRM + every module that owns company data | core users/auth + the account menu + mail recipient + CRM mirror option; no module data changes |

What this plan gives up: the person and the company are separate accounts. A
person acting for Acme sees Acme's inbox, Acme's files, Acme's roles, not their
own; switching back is one click.

"No module data changes" is about ownership, not a promise that nothing
outside `lib/phoenix_kit/users` is touched: the mailer, the embedded-LiveView
identity, the API key paths and the CRM mirror all change (below).

**v1 limitations** that follow from "the session is the organization" (decision
3, the ceiling, and one `contact_email`):

- Authorship is the organization everywhere a human sees it (comments, files,
  orders, presence, mentions). The person is only in activity metadata, and
  the activity UI has to show it (§8).
- In-app notifications are the organization's, visible only while acting.
  Email goes to one `contact_email`. Managers share one preference matrix on
  the org row. There is no fan-out to each manager's personal inbox.
- `MultiSession.impersonated?/1` is true while acting, so the AI assistant,
  header widgets that refuse a borrowed account, and `Executor.execute_as`
  stay off. The ceiling also keeps `api` out: no machine API as the
  organization.
- Public org signup (`registration_account_type: "organization"`) still
  creates unmanaged orgs with their own mailbox. Managed is an admin-created
  alternative, not a replacement.

## Design

### 1. Data model (V226)

```
phoenix_kit_users                      (existing table)
  organization_uuid         existing, untouched: "works at" (one)
  managed_by_members        NEW boolean NOT NULL DEFAULT false
  contact_email             NEW citext, nullable, NOT unique

phoenix_kit_organization_managers      NEW table: who may act for which organization
  uuid                      uuid v7, PK
  organization_uuid         → phoenix_kit_users ON DELETE CASCADE
  user_uuid                 → phoenix_kit_users ON DELETE CASCADE   (the person)
  granted_by_uuid           → phoenix_kit_users ON DELETE SET NULL
  inserted_at, updated_at
  UNIQUE (organization_uuid, user_uuid); INDEX (user_uuid)

phoenix_kit_users_tokens               (existing table)
  acting_session_uuid       NEW → phoenix_kit_users_tokens(uuid) ON DELETE CASCADE
  organization_manager_uuid NEW → phoenix_kit_organization_managers(uuid) ON DELETE CASCADE
```

- `managed_by_members = true` is allowed only with `account_type =
  'organization'` (check constraint).
- `acting_session_uuid` and `organization_manager_uuid` are set **together**,
  and only on a `"session"` token of a managed organization (check constraint:
  both null, or both set **and** `context = 'session'`).
  `acting_session_uuid` is the person's own session token row (the root of the
  browser's stack); `organization_manager_uuid` is the grant that let them in.
  The person is that token row's `user_uuid`; no third column. The minting
  path is the only writer: if these columns are set on a **person's** token,
  `session_user_query/1` would look for a manager row whose organization is
  that person, find none, and the person would read as anonymous.
- **Indexes on the new token columns.** Postgres does not index the
  referencing side of a foreign key. `ON DELETE CASCADE` from a person
  session (or a manager row) seq-scans `phoenix_kit_users_tokens` without
  indexes on `acting_session_uuid` and `organization_manager_uuid`.
- **The cascades are the revocation guarantee.** Deleting the person's session
  (log out, "sign out other devices", password reset, an admin revoke) or the
  manager row (removal) deletes the organization token in the same statement.
  Nothing has to remember to do it. Re-granting creates a new manager row, so
  an old token cannot come back to life.
- Manager rows: the person must be `account_type = "person"`, not `api_only`,
  not the organization itself. Checked in the changeset and in the context.
  A person who has manager rows cannot change `account_type` to
  `"organization"` or become `api_only` while those rows exist (the insert
  check is not enough).
- New core table → `ModuleOwnedTables` core list. New schema uses
  `PhoenixKit.SchemaPrefix`. Prefix-safe rules apply (`uuid_v7_call/1`, bare
  index names on CREATE, schema anchors on existence checks). The new columns
  and table go into the generated manifest and reference
  (`dev_docs/squash/README.md`, "Manifest & reference policy"), not only a
  chain-hash restamp. V226 is the next free version (V225 is
  `phoenix_kit_files.short_code`).

### 2. The placeholder login email

A managed organization's `email` is generated, `org-<uuid>@organization.invalid`
(RFC 2606: `.invalid` never resolves). Same pattern as service users
(`PhoenixKit.API.ServiceUsers`, `api-<id>@service.invalid`). It keeps the
column `NOT NULL` and unique, so no email-resolving code changes. Nobody types
it; the UI shows `contact_email` (or the organization name) instead.

**Never authenticate via `contact_email`.** Login, magic link, OAuth matching
(`found/1`, `attach_to_existing_user/2`) and `get_user_by_email` stay on
`users.email`. `contact_email` is delivery and display only. Public
registration of `@organization.invalid` and `@service.invalid` is refused
(defense in depth; service users already use the second).

`contact_email` is validated like an email (format, max 160) and is not
`.invalid`. It is not unique: several orgs, and a person's login, may share
one inbox.

A managed organization is created with `confirmed_at` set **and** referral
satisfied (`Referrals.mark_satisfied/2`). `account_gate/1` also runs
`Referrals.access_satisfied?/1`; a new managed org is none of marked
satisfied, grandfathered, `*`/`Owner` (the ceiling forbids those), or invited
(placeholder email). With `referral_codes_required` on, acting as Acme would
park the browser on `/users/referral`, which the org cannot complete. Same
treatment as confirmation: an admin made it, there is no person to enter a
code.

**`hashed_password` stays `NOT NULL`.** It has been `NOT NULL` since V1.
Convert-to-managed and create set a random unknown hash, the service-user
pattern (`ServiceUsers` `random_password_hash/0`). They never write `NULL`.
`valid_password?/2` still refuses. Convert-back sets a new password; it never
restores the old one.

Create goes through a **dedicated insert**, not `Auth.admin_create_user/2` /
`register_user/2`: those call `Roles.ensure_first_user_is_owner/1` and send
confirmation mail. The dedicated path: placeholder email, random password
hash, `confirmed_at`, referral satisfied, default `User` role, no welcome or
confirmation mail. Extra roles are assigned afterwards on the details page,
inside the ceiling.

### 3. A managed organization never signs in

Every door that refuses `api_only` refuses `managed_by_members` too:
`Auth.log_in_user/3` (web), `User.valid_password?/2`, magic link (request and
verify), OAuth (`found/1`, `attach_to_existing_user/2`), QR login (approval
**and** completion, `QrLoginComplete`), password reset (the token lookup **and**
the reset mutation, which works on an already-loaded struct:
`PhoenixKitWeb.Users.ResetPassword`), `UserToken.verify_email_token_query/2` and the
email-change verifier next to it, `MultiSession.add_account/3`,
`add_authenticated_user/3`, `impersonable?/2`. Guard the mutations, not only
the first lookup.

**The one way in is a session token minted by §4**, and
`UserToken.session_user_query/1` accepts a managed organization's token only
when all of these hold, in the query itself:

- `acting_session_uuid` names a `"session"` token row that has not expired;
- that row's user is an active `person`, not `api_only`;
- `organization_manager_uuid` names a manager row whose `organization_uuid` is
  this token's user and whose `user_uuid` is that person.

An unmanaged account's token is unaffected. A managed organization's token
without both columns (one minted before a conversion, or by a door nobody
guarded) reads as "nobody is signed in". Raw-token and token-uuid lookups
share `session_user_query/1`, so this one guard covers ordinary requests,
remember-me recovery, the mirrored multi-session accounts, socket reconnects
and `SessionRef`.

**Paths that do NOT go through the session query** and must handle a managed
organization on their own:

- **Embedded LiveViews** rebuild the identity from `current_user_uuid`
  (`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`). For a
  **managed organization** uuid they load the organization only when the
  LiveView session's own `user_token` (the cookie session is merged into every
  LiveView session) resolves through `session_user_query/1` to that same
  organization; otherwise anonymous. That keeps the admin home dashboard
  (`Live.Dashboard` passes `current_user_uuid` into `phoenix_kit_dashboards`)
  and comment composers working while acting (Grok: anonymous blanks them),
  and still refuses an embed whose grant has ended (Codex: a uuid alone
  reconnects without consulting the grant, e.g. an embed in a host's
  controller-rendered page, which has no parent LiveView to re-check it).
  Every other uuid keeps today's behaviour. One extra token lookup, only for
  managed organizations.
- **API keys** (`PhoenixKit.API.Keys.verify/2` loads the key's owner directly).
  A managed organization owns no keys and no service users in v1: refused in
  `Keys.create_key/3` (including a key for itself, which `owner_allowed/2`
  allows today for one's own account) and `ServiceUsers` creation, refused at
  `Keys.verify/2` too (fail closed if a row exists anyway), and conversion to
  managed revokes the organization's existing keys. The permission ceiling (§6)
  also keeps the `api` key out of a managed organization's scope, so Settings
  -> API and `API.Access.fresh_scope/1` never open for it.

### 4. Entering an organization: the multi-session stack

`PhoenixKitWeb.Users.MultiSession` already lets a browser hold several
accounts' session tokens, with the root (the original login) deciding and one
token active, and `impersonate/2` already adds an account without its password
on the root's authority. Entering an organization is the same move with a
different authority check. All of it lives in one context function and its
twin for leaving, so entry, validation and revocation are not spread out.

The organization token is a **first-class exception** in every stack helper,
not only in `act_as_organization` / leave:

- `MultiSession.act_as_organization(conn, org_uuid)`: the **root** decides,
  never the active account (otherwise a person could act for Acme and, from
  inside Acme, enter something Acme manages). The root must be an active,
  confirmed (when confirmation is required) `person` with a manager row for
  `org_uuid`, and the organization must be active and managed. Mints a session
  token for the organization with `acting_session_uuid` = the root token's row
  and `organization_manager_uuid` = the grant, appends it to the stack, makes
  it active, logs `organization.entered` (§8). Rate-limited per root user
  (authenticated enumeration of org uuids).
- **At most one organization token per stack, outside the account limit.**
  Entering another organization replaces (and deletes, and disconnects) the
  previous one. Entering the same one is a no-op. The organization token does
  not count toward `@max_accounts` (5): `add_account/3` /
  `add_authenticated_user/3` measure `length(stack)` **excluding** it, so a
  full stack of added accounts still lets the person enter a company, and
  seven companies never fill it.
- **`list_accounts/1` omits the organization token.** Otherwise the existing
  multi-session switcher renders `org-<uuid>@organization.invalid` as an
  account. The org switcher (§5) is the only UI for it.
- **Switching away leaves.** `switch_to/2`, `remove_account/2` and
  `log_out_active/1` delete and disconnect the organization token when the
  browser leaves it (same as the dedicated leave route). A live org token
  must not sit unused in the stack: `impersonated?/1` would go false on the
  root while the grant was still valid.
- **Add-account and impersonation are refused while an organization token is
  in the stack.** Otherwise an Owner acting as Acme can impersonate Bob into
  `[owner, acme, bob]`. Root still decides, so the authority check alone does
  not prevent it.
- **Mirrored, in its own slot.** The persisted mirror cookie carries the
  organization token next to `accounts` (a new `organization` key), not in the
  list `write_persisted/4` trims to `@max_accounts - 1`. Today's helpers
  would drop that slot: `write_persisted(conn, root, [], _)` forgets the whole
  cookie, and `active` is stored only when `active in kept`. They must write
  an org-only mirror, accept the org token as `active`, and keep old cookies
  without the key decoding. A lost session resumes inside Acme when
  remember-me was used (the mirror never outlives the remembered identity).
  Mirror recovery today forgets the whole mirror when `multi_session_enabled`
  is off (`restore_persisted_accounts/2`); it must keep the organization slot
  regardless of that setting, and still drop the extra accounts.
- **Own routes, not the multi-session ones.** `POST
  /users/session/organizations/:uuid` (enter) and `DELETE
  /users/session/organization` (back to my account: switch to the root,
  delete the organization token, disconnect it). Wired in **both** scopes in
  `PhoenixKitWeb.Integration` (bare and `/:locale`), next to
  `/users/session/role`. The existing `set_active_account/2` is behind the
  multi-session gate (`with_gate/3`), and enabling ordinary "add account" must
  not be the price of using companies.
- **Landing.** Enter redirects to `Routes.post_auth_path/1` (tail `/admin`):
  staying on the current URL would open the person's profile, settings or
  files as the organization. Leave redirects to a path the **root** can open
  (`post_auth_path` if the current URL is not one, otherwise stay).
- **Log out while acting.** `log_out_active/1` already means "drop the
  non-root active token, stay as root", so the menu's Log out would leave
  Acme and keep Dmitri signed in, with the flash "Logged out. Now signed in
  as …". The account menu offers **Back to my account** (the DELETE above)
  and **Log out**, which full-logs-out the person (the existing "log out all"
  path, `UserAuth.log_out_user/1`, already drains the stack).
- **Reads as a borrowed account** (decided). `MultiSession.impersonated?/1`
  stays true while acting: callers that refuse a borrowed account, such as the
  AI assistant spending an account's limits, refuse an organization session too.
- **Support impersonation of a managed organization is refused in v1**
  (decided). `impersonable?/2` answers false for it; an impersonation token
  would carry no manager grant and the session query would refuse it anyway.
  A later support mode needs its own authorization and provenance, not an
  impersonator uuid standing in for a grant.
- **No login alert.** Entering is not a sign-in (the person already signed in,
  and their own login alert covered that); it is an activity row instead.
- **Master switch off.** `enable_organization_accounts` today only hides UI;
  existing unmanaged org logins still work. Same here: the switcher hides and
  **new enters are refused**; live acting sessions continue until they leave
  or the grant ends. `session_user_query/1` does not read the setting.

### 5. The account menu (the switcher)

In the user dropdown (`PhoenixKitWeb.Components.AdminNav` used from
`layout_wrapper`, and `UserDashboardNav` while it still exists), a section
above the role switcher:

```
Acting as
  ● Dmitri Don          (my account)
    Acme OÜ
    Beta Holdings
    Gamma Trade
```

- Shown when organization accounts are on (`Auth.organization_accounts_enabled?/0`)
  and the **root** manages at least one active managed organization.
  Independent of `multi_session_enabled`.
- Built as its own component (`Core.OrganizationSwitcher`, like
  `Core.RoleSwitcher`) so both navs share it. The header role switcher in
  `layout_wrapper` (when `role_switcher_location` is `"header"`) stays as it
  is; the org switcher lives in the dropdown.
- Each row is a form to the routes in §4: full page loads, same reasoning as
  `set_active_role/2` (the scope changes under every LiveView on the page).
- While acting, the dropdown identity shows who you are ("Acme OÜ · via
  Dmitri Don"), so nobody forgets which company they are in. That string is
  `User.display_name/1` (already prefers `organization_name`) plus the
  person's display name. Flashes on switching name the organization, never an
  email (the switch flash today prints `user.email`, which would be the
  placeholder).
- **One display helper for an address a human should see:** `contact_email`
  for a managed organization, `email` otherwise. Used by the nav
  (`Scope.user_email/1` in `AdminNav`, `UserDashboardNav`, dashboard
  presence), the admin users list and search, admin sessions
  (`list_user_sessions/1` selects `user.email`), mentions search, and mail
  template variables. Login lookups stay on `users.email`.
- Data: one indexed query on `organization_managers` by the root's uuid, run
  only when the master switch is on; it rides on the scope next to
  `multi_session_accounts` (`scope.acting_organizations`). The scope already
  resolves the root for multi-session; reuse that read.
- Strings go into `default.pot` and the nine `.po` files (switcher, flashes,
  admin managers UI).

### 6. What an organization may do (the permission ceiling)

The session is the organization, so `Scope.for_user/1` gives the
organization's roles and the role switcher works per session as usual. One
manager level (decided): a manager acts with the organization's full
authority; there is no "may act, but only as role X" in v1.

A managed organization's authority has a ceiling, **applied when the scope is
built** (`Scope.for_user/1`), not only when a role is assigned, because a
role's permissions can be edited after the organization got it:

- never Owner or Admin, never the `"*"` superadmin key, never `api`;
- the role inserts refuse them too, at the common insertion point
  (`Roles.assign_role_internal/4`, which `assign_role/4`, `sync_user_roles/3`,
  promotion and the bootstrap/backfill paths all reach), with fresh state;
- converting an organization that holds one of them is refused until it is
  removed.

A new managed organization gets the default new-user role (`User`). Extra
roles (shop, CRM, media, a custom "Company admin") are assigned on the
details page, inside the ceiling.

While acting, the account settings hide and server-reject the credential
sections (password, login email, OAuth links, sessions of the organization).
The hide and the reject live in `PhoenixKitWeb.Live.Components.UserSettings`
(the LiveComponent hosts embed), not only `ProfileSettings`. They would fail
anyway (the forms ask for the active account's current password, which a
managed organization does not have); hiding them makes that a rule rather
than an accident.

**`can_manage_user_credentials?/2` is true for self** (rule 1: "your own
account is always yours"), and while acting the actor *is* the organization.
So manager changes and conversion must **not** use it as is: they use the
same role-and-rank rule **without** the self clause (Owner or Admin by role,
never the organization itself). Otherwise any context call reached while
acting would pass the check for the organization's own row. (Reaching
`/admin/users/view/<org>` additionally needs the `users` permission, which a
managed organization holds only if an admin gave one of its roles that key.)
Convert either way stays admin-only in every case: a manager must not give
the organization a real login and cut the other managers out.

Whether managers may add and remove managers themselves while acting is
**open** (question A below); the v1 default is admin-only.

`TimeZoneAlert.observe/2` and any auto-save of `user_timezone` are skipped
while `Scope.acting_user_uuid/1` is set. The detector would otherwise write
`custom_fields` and notify the organization from the person's browser.

### 7. Mail

- **One recipient helper** decides where mail for an account goes:
  `contact_email` for a managed organization (none = not sent), `email` for
  everyone else. Login lookups keep using `email`; only delivery uses the
  helper. Every sender goes through it: `UserNotifier.deliver_*`, the
  notification email channel (`PhoenixKit.Notifications.Channels.Email.deliver/2`),
  `DigestWorker`, and any newsletter path that today reads `user.email`.
  Template variables (`user_email`) use the helper too, so a body never
  prints the placeholder.
- Organization notifications are in-app (whoever acts for the organization
  sees them) and also mailed to `contact_email` when it is set. There is no
  fan-out to each manager's personal inbox in v1.
- **Safety net in the mailer:** drop any `.invalid` recipient in `to`, `cc`
  and `bcc`, at delivery time (so queued Oban sends and integration delivery
  are covered). Nothing in core does this today; service users are simply
  never mailed. Covers both placeholders.
- No welcome or confirmation mail on managed create (there is no mailbox to
  confirm; `contact_email` is not asked to confirm an account it does not
  own).

### 8. Attribution

**Decided:** the organization is the activity actor, the person is in
`metadata["acting_user_uuid"]`.

This is not free: `PhoenixKitWeb.Actor.opts/1` passes only `actor_uuid`, and
`Activity.log/3` never sees the scope, so the person cannot be inferred
there. And it must never be inferred from the organization uuid (several
people manage one organization). So:

- the scope carries the acting person (`Scope.acting_user_uuid/1`, filled from
  the token's `acting_session_uuid` → user, by the same loader as everything else);
- `Actor.opts/1` adds `acting_user_uuid:` when the source is acting, and
  `Activity.log/1,3` writes it into the metadata;
- direct writers that build `actor_uuid` themselves (e.g. `ActiveRole` on a
  switch) are audited and passed it explicitly;
- an Oban job enqueued while acting carries it in its args if it logs.

The activity UI today prints `entry.actor.email` (`activity_list`,
`activity/index`, `activity/show`). It shows `User.display_name/1` of the
organization and, when `metadata["acting_user_uuid"]` is set, the person's
display name next to it ("Acme OÜ · via Dmitri Don").

### 9. Admin UI and creating organizations

- **Creation is admin-only** (decided). A person never creates an organization
  from their own account settings. Public org signup still creates unmanaged
  orgs with their own mailbox.
- **Organization details page** (`Live.Users.UserDetails`): a "Managed by
  members" section — managers list (add by person search, remove), contact
  email. Person search excludes `api_only`, organizations, and inactive
  users. The users list search includes `contact_email` and
  `organization_name` (`maybe_filter_by_search` today is email / username /
  first / last) and shows a managed badge; the email column uses the display
  helper (§5).
- **Member vs manager stay two relationships.** `organization_uuid` is "works
  at", at most one. A manager of five companies cannot "work at" all five.
  Adding a manager does not write `organization_uuid`. Organization
  invitations still create members, not managers, unless the admin UI offers
  both.
- **Who may change managers or convert:** adding a manager hands over the
  organization, so it is decided like credential management, by role and rank
  (`Auth.can_manage_user_credentials?/2`), not by the `users` permission that
  opens the page, and without the self clause (§6). **Convert is admin-only
  even when the actor is the organization.** Managers managing managers:
  open, question A (v1 default: admin-only). Checked in the context on every
  call, with fresh state, and in the event handler; forged-input tests for
  each event.
- **New managed organization:** name, contact email, first manager (required),
  dedicated insert (§2). Default role `User`.
- **Convert an existing organization to managed:** its login email moves to
  `contact_email` only when `contact_email` is empty (otherwise
  `contact_email` is kept and the login email is abandoned), `email` becomes
  the placeholder, a first manager is required, and **everything that could
  sign it in is revoked**: sessions, remember-me and email-token contexts,
  OAuth identities, `google_email`, API keys. The password hash is replaced
  with a random unknown hash (`hashed_password` is `NOT NULL`).
- **Convert back:** asks for a new unique login email and goes through the
  normal set-password / confirmation path. All acting sessions are revoked
  first (otherwise, with the flag cleared, they would read as ordinary
  organization sessions), and nothing old (password, OAuth identity) comes back.
- **The last manager.** Removing, deactivating or deleting the last *active*
  manager of a managed organization is refused unless the admin explicitly
  leaves it without managers (a checkbox; the organization then stays
  reachable by nobody until a manager is added). That includes **deactivating
  or deleting the person** who is the last manager (`ON DELETE CASCADE` on
  `user_uuid` would otherwise skip the checkbox, same shape as last-Owner).
  Manager changes on one organization are serialized with a row lock on the
  organization (`FOR NO KEY UPDATE`, not `FOR UPDATE`: the row is referenced
  by foreign keys).
- **CRM mirror** (decided): `PhoenixKitCrm.Companies` gets an explicit
  "create as managed organization" option, chosen by the admin with a first
  manager. Never an automatic fallback when the company's email is taken:
  email equality never grants management. For a managed organization the
  mirror maps the company's email to `contact_email` in creation, diff and
  reverse mirroring (`PhoenixKitCrm.Mirror`). A separate CRM release, after core.

### 10. Ending sessions and open pages

Deleting a token ends a session for the next request; a connected LiveView
keeps its assigns until it re-mounts (`Sessions.disconnect_tokens/1` moduledoc).
So every path that ends organization access deletes **and** disconnects:

- manager removal, conversion either way, organization deactivation or
  deletion, person deactivation;
- every revoke of the person's own sessions: the database cascade deletes the
  dependent organization tokens, but cannot broadcast, so the revoke paths in
  `Sessions` (`revoke_user_session/2`, `revoke_other_user_sessions/2`,
  `revoke_session/2`, `revoke_user_sessions/2`, `revoke_user_sessions_in_role/2`)
  and the password-reset path collect the dependent organization tokens
  **before** deleting, then disconnect them after commit. One shared helper,
  so a new revoke path cannot forget it.

A person deleted outright cascades too; collect the dependent tokens first
there as well. Deleting or deactivating the last manager's person goes
through the last-manager rule (§9) first.

The person's own Sessions page lists their acting sessions under the session
they came from ("Acme OÜ, from this browser"); revoking that session ends both.
The admin sessions list uses the display helper (§5), not the placeholder.

## Phases

1. **Core model + doors** — V226, schema/changeset changes, placeholder email,
   dedicated create path, every login door, the session-query guard, embedded
   identity, API-key refusals, the permission ceiling, the recipient helper
   and `.invalid` guard, referral satisfied, display helper.
2. **Switching** — `act_as_organization` and leaving, routes in both scopes,
   every stack helper treating the org token as an exception, the mirror slot
   (org-only and old cookies), the switcher component in both navs, the
   "acting as" header, attribution (including the activity UI), revocation
   with disconnects, the Sessions page entry, enter/leave landing, log-out
   copy.
3. **Admin UI** — managers on the details page, create, convert either way,
   the last-manager rule (including person deactivate/delete), users-list
   search and badge, i18n.
4. **CRM** — the managed-organization mirror option (`phoenix_kit_crm`).

Each phase is releasable on its own; nothing changes for an install until an
organization is marked managed.

## Tests

- Every login door refuses a managed organization, one test each: password,
  magic link (request, verify), OAuth (sign-in, attach), QR (approve,
  complete), password reset (lookup, mutation), email confirm, email change,
  add account, impersonation.
- Session query: a managed organization's token with no grant columns; with a
  removed manager; with an expired or deleted person session; with a
  deactivated, `api_only` or non-person person; with a grant for another
  organization → nobody signed in. An unmanaged account's token still works.
- Removal then re-grant: the old token stays dead.
- `act_as_organization` decides on the root: a person acting for A cannot
  enter B that only A manages; a non-manager, an inactive organization and an
  unmanaged organization are refused; refusals are logged.
- One organization token per stack, outside the account limit (a full stack
  of 5 people can still enter); entering a second replaces and disconnects the
  first; entering the same one is a no-op.
- `list_accounts/1` omits the organization token.
- `switch_to/2`, log out of the active account, and `remove_account/2` all
  leave (delete + disconnect). Log out all ends person + org.
- Add-account and impersonation while acting are refused.
- Works with `multi_session_enabled` off: enter, leave, lost session resumes
  in the organization from the mirror. Org-only mirror is kept;
  `accounts: []` does not forget the cookie; old cookies without the org key
  still decode.
- Routes exist at both `/users/session/organizations/:uuid` and
  `/:locale/users/session/organizations/:uuid`.
- Enter lands on `post_auth_path`; leave from an org-only URL lands on a path
  the root can open.
- Master switch off: new enter is refused; an already-acting session still
  resolves.
- Enter is rate-limited per root user.
- Revocation: each `Sessions` revoke path, password reset, person
  deactivation/deletion, manager removal, conversion and organization
  deactivation end the organization session **and** disconnect its socket.
- Embedded LiveView with a managed organization's uuid: loads it when the
  session's token resolves to that organization; anonymous when the grant has
  ended or the token is another account's. Any other uuid: unchanged.
- API: a managed organization cannot get a key or service user; an existing
  key row for one fails `Keys.verify/2`; conversion revokes keys.
- Ceiling: a managed organization never gets Owner/Admin/`"*"`/`api`, also
  when a role it holds is edited to include `"*"` afterwards. Dedicated
  create does not call `ensure_first_user_is_owner/1`.
- Invite-only: acting as a new managed org is admitted (`mark_satisfied`).
- `hashed_password` is a random hash after create and after convert-to-managed,
  never `NULL`. Public registration of `@organization.invalid` is refused.
- Never authenticate via `contact_email` (magic link, OAuth).
- Activity rows written while acting carry the organization as actor and the
  person in metadata; a job enqueued while acting too. The activity UI shows
  the organization name and the acting person, not the placeholder.
- Mailer drops `.invalid` in `to`/`cc`/`bcc`; the recipient helper uses
  `contact_email` for a managed organization; `UserNotifier` template
  variables do too. No confirmation mail on managed create.
- Display helper: nav, admin users list/search (`contact_email`,
  `organization_name`), admin sessions, presence — no placeholder.
- `UserSettings` email/password/OAuth event while acting is rejected.
  Convert and manager changes while acting are rejected even though "self"
  passes `can_manage_user_credentials?/2` (unless question A is answered yes).
- `TimeZoneAlert` does not write the organization.
- Last-manager rule: manager-row remove, **and** deactivating or deleting the
  person who is the last manager. A person with manager rows cannot become
  `account_type: "organization"`.
- Managers UI: forged-input tests (`render_submit` with a person, organization
  or role the form never offered); a `users` holder without credential
  authority cannot add a manager.
- Prefix migration test covers V226; module-owned-tables test sees the new
  core table; both new token columns are indexed.

## Decisions (2026-10-29)

1. **Creation:** admin-created only; no self-serve "Add a company".
2. **Attribution:** the organization is the actor, the person is in
   `metadata["acting_user_uuid"]`.
3. **`MultiSession.impersonated?/1`** stays true while acting for an
   organization (the safe default): it reads as a borrowed account.
4. **Support impersonation of a managed organization:** refused in v1.
5. **CRM mirror:** an explicit, admin-chosen "managed organization" option
   with a first manager; never an automatic fallback on an email collision.
6. **Manager rights:** one level, the organization's full authority.
Design defaults proposed in the Grok review (not maintainer decisions;
adopted because they follow from the decisions above or from existing
behaviour, change them if wanted):

- **Invite-only:** a managed organization is born referral-satisfied
  (`Referrals.mark_satisfied/2`), same as `confirmed_at`.
- **Enter/leave landing:** enter → `Routes.post_auth_path/1`; leave → a path
  the root can open.
- **Master switch off:** refuse new enters; live acting sessions continue
  until they leave or the grant ends (today the switch only hides UI too).
- **Embedded identity:** load the organization only when the session's token
  resolves to it (§3; a middle ground between the two reviews).
- **Convert `contact_email`:** login email moves to `contact_email` only
  when `contact_email` is empty; otherwise `contact_email` is kept.
- **Default role** for a new managed organization: `User`; extra roles on
  the details page, inside the ceiling.
- **Person-delete / deactivate of the last manager:** same checkbox as
  manager-row remove (last-Owner shape).

## Open questions

A. **May managers add and remove managers themselves, while acting?** Grok
   proposed yes (an owner of five companies adds their accountant without a
   site admin). That is new scope: a "Managers" section the organization can
   reach (its account settings, since `/admin/users/view` needs `users`), and
   any manager could also remove the others. v1 default until answered:
   admin-only.

## Review (Codex, 2026-10-29)

Codex reviewed the first version of this plan against the code (read-only).
Verdict: the approach is sound; the authentication lifecycle needed
tightening. What changed because of it:

- The acting token is bound to the person's **session row** and the **manager
  row** by cascading foreign keys, instead of a bare `acting_user_uuid`. Before,
  signing the person out (other devices, password reset, admin revoke) left
  their organization session alive, and removal followed by re-grant revived
  an old token.
- Revocation now also **disconnects** sockets (§10); deleting rows alone left
  connected LiveViews serving the organization.
- **API keys** and **embedded LiveViews** bypass the session query; both now
  refuse a managed organization on their own (§3).
- **Conversion** in either direction revokes every credential (§9); converting
  back used to turn acting sessions into ordinary ones.
- **Manager changes** need credential-level authority, not the `users` page
  permission (§9).
- The **permission ceiling** is applied when the scope is built and also
  covers `"*"` and `api` (§6); blocking Owner/Admin roles at `assign_role/4`
  alone missed the `"*"` key and the internal insertion paths.
- Corrected claims: working with `multi_session_enabled` off needs its own
  routes and a mirror slot (§4); attribution needs the scope to carry the
  person and `Actor.opts/1` to pass it, it is not free (§8); the schema change
  needs the generated manifest, not only a restamp (§1).
- Added: confirmation of new managed organizations (§2), credential sections
  hidden while acting (§6), one mail recipient helper (§7), acting sessions on
  the person's Sessions page (§10), the last-manager rule (§9), the full-stack
  case (§4), and Codex's recommendations for decisions 4–6.

## Review (Grok, 2026-10-29)

Grok reviewed the Codex-folded plan against the current code (read-only).
Verdict: the approach still holds; the org token has to be a real exception
in `MultiSession` and every `user.email` display, and two auth gates the
plan did not name will fire on the first invite-only install and the first
manager who opens their own user page.

What changed because of it:

- **`hashed_password` is `NOT NULL` since V1.** Convert-to-managed and create
  set a random unknown hash (the service-user pattern); they never write
  `NULL`. Dedicated create, not `admin_create_user/2` (`ensure_first_user_is_owner/1`
  and confirmation mail).
- **Invite-only.** `account_gate/1` also runs `Referrals.access_satisfied?/1`.
  A new managed org would park on `/users/referral`. Born `mark_satisfied`,
  same as `confirmed_at`.
- **`can_manage_user_credentials?/2` is true for self.** Manager changes and
  convert use the rule without the self clause; convert is admin-only.
  Grok's proposal that managers manage managers is open question A.
- **Last manager vs person lifecycle.** Deactivating or deleting the person
  who is the last manager went through user status/delete and skipped the
  checkbox (`ON DELETE CASCADE` on `user_uuid`). Same rule as manager-row
  remove. A person with manager rows cannot become
  `account_type: "organization"` or `api_only`.
- **The org token vs every stack helper, not only enter/leave.**
  `list_accounts/1` omits it; `length(stack)` excludes it; `switch_to` /
  `remove_account` / `log_out_active` leave; add-account and impersonation
  are refused while it is in the stack; log-out copy vs "Back to my
  account"; enter/leave landing.
- **Mirror helpers as they are written.** `write_persisted(conn, root, [], _)`
  forgets the cookie; `active` is stored only when `active in kept`. Org-only
  slot, org as `active`, old cookies still decode.
- **Routes in both scopes** in `PhoenixKitWeb.Integration` (bare and
  `/:locale`). Enter rate-limited per root user. Master switch off refuses
  new enters and leaves live sessions alone.
- **Indexes** on `acting_session_uuid` and `organization_manager_uuid`. Pair
  CHECK also requires `context = 'session'`.
- **Never authenticate via `contact_email`.** Display helper for every human
  `user.email` (nav, activity UI, admin list/search, sessions, presence,
  mail templates). Activity UI shows organization name + acting person.
- **Embedded LiveViews:** Grok proposed loading the org user from the uuid
  (anonymous blanks `phoenix_kit_dashboards` home and comment composers),
  reversing Codex. Adopted as a middle ground instead: load it only when the
  session's own token resolves to that organization (§3). A bare uuid is
  not enough: a host can embed from a controller-rendered page, where no
  parent LiveView re-checks the session on reconnect.
- **Mail:** every `UserNotifier.deliver_*`, digest, newsletters, template
  variables; no welcome/confirmation on create; block public `@*.invalid`
  registration.
- **Member vs manager stay two relationships**; adding a manager does not
  write `organization_uuid`. Public unmanaged org signup stays.
- **`UserSettings` LiveComponent** hides and server-rejects credentials
  (hosts embed it). `TimeZoneAlert` skipped while acting.
- **v1 limitations** written down: authorship is the org, notifications are
  org-centric, AI / machine API off while acting.
- Grok's proposals recorded as design defaults, not decisions; managers
  managing managers is open question A.
