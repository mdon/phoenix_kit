# Acting for an organization

**Status:** scope only, not started. Design reviewed by Codex on 2026-10-29
(findings folded in; see [Review](#review-codex-2026-10-29)). All decisions
are made. **Requested by:** Andi's project (2026-10-29).

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
  and only on a session token of a managed organization (check constraint:
  both null or both set). `acting_session_uuid` is the person's own session
  token row (the root of the browser's stack); `organization_manager_uuid` is
  the grant that let them in. The person is that token row's `user_uuid`; no
  third column.
- **The cascades are the revocation guarantee.** Deleting the person's session
  (log out, "sign out other devices", password reset, an admin revoke) or the
  manager row (removal) deletes the organization token in the same statement.
  Nothing has to remember to do it. Re-granting creates a new manager row, so
  an old token cannot come back to life.
- Manager rows: the person must be `account_type = "person"`, not `api_only`,
  not the organization itself. Checked in the changeset and in the context.
- New core table → `ModuleOwnedTables` core list. Prefix-safe rules apply
  (`uuid_v7_call/1`, bare index names on CREATE, schema anchors on existence
  checks). The new columns and table go into the generated manifest and
  reference (`dev_docs/squash/README.md`, "Manifest & reference policy"), not
  only a chain-hash restamp.

### 2. The placeholder login email

A managed organization's `email` is generated, `org-<uuid>@organization.invalid`
(RFC 2606: `.invalid` never resolves). Same pattern as service users
(`PhoenixKit.API.ServiceUsers`, `api-<id>@service.invalid`). It keeps the
column `NOT NULL` and unique, so no email-resolving code changes. Nobody types
it; the UI shows `contact_email` (or the organization name) instead.

A managed organization is created with `confirmed_at` set: an admin made it
and there is no mailbox to confirm, so the confirmation gate
(`PhoenixKitWeb.Users.Auth.account_gate/1`) never stops it.

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

**Paths that do NOT go through the session query** and must refuse a managed
organization on their own:

- **Embedded LiveViews** rebuild the identity from `current_user_uuid`
  (`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`). In v1 a managed
  organization reconstructs as anonymous there.
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
twin for leaving, so entry, validation and revocation are not spread out:

- `MultiSession.act_as_organization(conn, org_uuid)`: the **root** decides,
  never the active account (otherwise a person could act for Acme and, from
  inside Acme, enter something Acme manages). The root must be an active,
  confirmed (when confirmation is required) `person` with a manager row for
  `org_uuid`, and the organization must be active and managed. Mints a session
  token for the organization with `acting_session_uuid` = the root token's row
  and `organization_manager_uuid` = the grant, appends it to the stack, makes
  it active, logs `organization.entered` (§8).
- **At most one organization token per stack, outside the account limit.**
  Entering another organization replaces (and deletes, and disconnects) the
  previous one. The organization token does not count toward `@max_accounts`
  (5), so a full stack of added accounts still lets the person enter a
  company, and seven companies never fill it.
- **Mirrored, in its own slot.** The persisted mirror cookie carries the
  organization token next to `accounts` (a new `organization` key), not in the
  list `write_persisted/4` trims to `@max_accounts - 1`. A lost session resumes
  inside Acme. Mirror recovery today forgets the whole mirror when
  `multi_session_enabled` is off (`restore_persisted_accounts/2`); it must keep
  the organization slot regardless of that setting.
- **Own routes, not the multi-session ones.** `POST
  /users/session/organizations/:uuid` (enter) and `DELETE
  /users/session/organization` (back to my account: switch to the root,
  delete the organization token, disconnect it). The existing
  `set_active_account/2` is behind the multi-session gate (`with_gate/3`), and
  enabling ordinary "add account" must not be the price of using companies.
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

### 5. The account menu (the switcher)

In the user dropdown (`PhoenixKitWeb.Components.AdminNav`, and the dashboard
nav while it still exists), a section above the role switcher:

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
  `Core.RoleSwitcher`) so both navs share it.
- Each row is a form to the routes in §4: full page loads, same reasoning as
  `set_active_role/2` (the scope changes under every LiveView on the page).
- While acting, the header shows who you are ("Acme OÜ · via Dmitri Don"), so
  nobody forgets which company they are in. Flashes on switching name the
  organization, never an email (the switch flash today prints `user.email`,
  which would be the placeholder).
- Data: one indexed query on `organization_managers` by the root's uuid, run
  only when the master switch is on; it rides on the scope next to
  `multi_session_accounts` (`scope.acting_organizations`). The scope already
  resolves the root for multi-session; reuse that read.

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

While acting, the account settings hide and server-reject the credential
sections (password, login email, OAuth links, sessions of the organization).
They would fail anyway (the forms ask for the active account's current
password, which a managed organization does not have); hiding them makes that
a rule rather than an accident.

### 7. Mail

- **One recipient helper** decides where mail for an account goes:
  `contact_email` for a managed organization (none = not sent), `email` for
  everyone else. Login lookups keep using `email`; only delivery uses the
  helper. The notification email channel
  (`PhoenixKit.Notifications.Channels.Email.deliver/2`) and the user-facing
  mailers go through it.
- Organization notifications are in-app (whoever acts for the organization
  sees them) and also mailed to `contact_email` when it is set.
- **Safety net in the mailer:** drop any `.invalid` recipient in `to`, `cc`
  and `bcc`, at delivery time (so queued Oban sends and integration delivery
  are covered). Nothing in core does this today; service users are simply
  never mailed. Covers both placeholders.

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

### 9. Admin UI and creating organizations

- **Creation is admin-only** (decided). A person never creates an organization
  from their own account settings.
- **Organization details page** (`Live.Users.UserDetails`): a "Managed by
  members" section — managers list (add by person search, remove), contact
  email.
- **Who may change managers or convert:** adding a manager hands over the
  organization, so it is decided like credential management, by role and rank
  (`Auth.can_manage_user_credentials?/2`), not by the `users` permission that
  opens the page. Checked in the context on every call, with fresh state, and
  in the event handler; forged-input tests for each event.
- **New managed organization:** name, contact email, first manager (required).
- **Convert an existing organization to managed:** its real email moves to
  `contact_email`, `email` becomes the placeholder, a first manager is
  required, and **everything that could sign it in is revoked**: sessions,
  remember-me and email-token contexts, OAuth identities, API keys, its
  password hash cleared.
- **Convert back:** asks for a new unique login email and goes through the
  normal set-password / confirmation path. All acting sessions are revoked
  first (otherwise, with the flag cleared, they would read as ordinary
  organization sessions), and nothing old (password, OAuth identity) comes back.
- **The last manager.** Removing, deactivating or deleting the last active
  manager of a managed organization is refused unless the admin explicitly
  leaves it without managers (a checkbox; the organization then stays
  reachable by nobody until a manager is added). Manager changes on one
  organization are serialized with a row lock on the organization
  (`FOR NO KEY UPDATE`, not `FOR UPDATE`: the row is referenced by foreign keys).
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
there as well.

The person's own Sessions page lists their acting sessions under the session
they came from ("Acme OÜ, from this browser"); revoking that session ends both.

## Phases

1. **Core model + doors** — V226, schema/changeset changes, placeholder email,
   every login door, the session-query guard, embedded-identity and API-key
   refusals, the permission ceiling, the recipient helper and `.invalid` guard.
2. **Switching** — `act_as_organization` and leaving, routes, the mirror slot,
   the switcher component in both navs, the "acting as" header, attribution,
   revocation with disconnects, the Sessions page entry.
3. **Admin UI** — managers on the details page, create, convert either way,
   the last-manager rule.
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
  can still enter); entering a second replaces and disconnects the first.
- Works with `multi_session_enabled` off: enter, leave, lost session resumes
  in the organization from the mirror.
- Revocation: each `Sessions` revoke path, password reset, person
  deactivation/deletion, manager removal, conversion and organization
  deactivation end the organization session **and** disconnect its socket.
- Embedded LiveView with a managed organization's uuid → anonymous.
- API: a managed organization cannot get a key or service user; an existing
  key row for one fails `Keys.verify/2`; conversion revokes keys.
- Ceiling: a managed organization never gets Owner/Admin/`"*"`/`api`, also
  when a role it holds is edited to include `"*"` afterwards.
- Activity rows written while acting carry the organization as actor and the
  person in metadata; a job enqueued while acting too.
- Mailer drops `.invalid` in `to`/`cc`/`bcc`; the recipient helper uses
  `contact_email` for a managed organization.
- Managers UI: forged-input tests (`render_submit` with a person, organization
  or role the form never offered); a `users` holder without credential
  authority cannot add a manager; last-manager rule.
- Prefix migration test covers V226; module-owned-tables test sees the new core table.

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
