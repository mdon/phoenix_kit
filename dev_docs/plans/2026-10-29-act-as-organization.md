# Acting for an organization

**Status:** scope only, not started. **Requested by:** Andi's project (2026-10-29).

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
  would need a `nil` branch. A placeholder address (below) changes one
  changeset instead.

## How this differs from the first proposal

The first proposal (discussed, not written up) was: replace the single
`users.organization_uuid` with a many-to-many membership, keep the person
signed in as themselves, and carry an "active company" in the scope.

| | First proposal | This plan |
|---|---|---|
| Person ↔ company link | `organization_uuid` replaced by a membership table (backfill, every reader changed, CRM changed) | `organization_uuid` ("works at") untouched; a NEW table says who may act for which organization |
| Who the session is | the person, with an active company in the scope | the organization's own account, entered by the person |
| Company-owned data | every core table and module must key on, and filter by, the active company | nothing changes: whatever an account owns today (files, libraries, orders, settings, notifications, roles) is the organization's, because the session IS the organization |
| "Who really did it" | the session user | the stack's root (the person); see "Attribution" |
| Size | core users/auth + CRM + every module that owns company data | core users/auth + the account menu; no module changes |

What this plan gives up: the person and the company are separate accounts. A
person acting for Acme sees Acme's inbox, Acme's files, Acme's roles, not their
own; switching back is one click.

## Design

### 1. Data model (V226)

- `phoenix_kit_users.managed_by_members` — `boolean NOT NULL DEFAULT false`.
  A check constraint allows `true` only with `account_type = 'organization'`.
- `phoenix_kit_users.contact_email` — `citext`, nullable, **not unique**. The
  real address of a managed organization (and optionally of any organization).
- `phoenix_kit_organization_managers` — `uuid` (v7), `organization_uuid` →
  users `ON DELETE CASCADE`, `user_uuid` → users `ON DELETE CASCADE`,
  `granted_by_uuid` → users `ON DELETE SET NULL`, timestamps;
  unique `(organization_uuid, user_uuid)`; index on `user_uuid` (the menu reads
  by person). New core table → `ModuleOwnedTables` core list.
- `phoenix_kit_users_tokens.acting_user_uuid` — nullable, → users
  `ON DELETE CASCADE`. Set only on a session token of a managed organization:
  the person who entered it.

Prefix-safe rules apply (`uuid_v7_call/1`, bare index names on CREATE, schema
anchors). New columns go into `ExpectedSchema` and the chain hash is restamped
(see `dev_docs/squash/README.md`).

### 2. The placeholder login email

A managed organization's `email` is generated, `org-<uuid>@organization.invalid`
(RFC 2606: `.invalid` never resolves). Same pattern as service users
(`PhoenixKit.API.ServiceUsers`, `api-<id>@service.invalid`). It keeps the
column `NOT NULL` and unique, so no email-resolving code changes. Nobody types
it; the UI shows `contact_email` (or nothing) instead.

### 3. A managed organization never signs in

Every door that refuses `api_only` refuses `managed_by_members` too:
`Auth.log_in_user/3` (web), `User.valid_password?/2`, magic link (request and
verify), OAuth (`found/1`, `attach_to_existing_user/2`), QR login, password
reset, `UserToken.verify_email_token_query/2`, `MultiSession.add_account/3`,
`add_authenticated_user/3` and `impersonable?/2` (see open decision 4).

**One exception, guarded in the query:** `UserToken.session_user_query/1`
accepts a managed organization's session token only when
`token.acting_user_uuid` names a person who is active, not `api_only`, and
still has a `phoenix_kit_organization_managers` row for that organization. So
removing a manager, or deactivating the person, ends their Acme session on the
next request, even if a revoke was missed. (Removal also deletes those tokens
outright: `Sessions.revoke_acting_sessions/2`.)

### 4. Entering an organization: the multi-session stack

`PhoenixKitWeb.Users.MultiSession` already lets a browser hold several
accounts' session tokens, with the root (the original login) deciding and one
token active, and `impersonate/2` already adds an account without its password
on the root's authority. Entering an organization is the same move with a
different authority check:

- `MultiSession.act_as_organization(conn, org_uuid)`: the **root** must hold a
  manager row for `org_uuid` (never the active account, or a person could act
  for Acme and, from inside Acme, enter something Acme manages). Mints a
  session token for the organization with `acting_user_uuid = root.uuid`,
  appends it to the stack, makes it active, logs `organization.acted_as`.
- **At most one organization token per stack.** Entering another organization
  replaces (and deletes) the previous one, so a person with seven companies
  never hits `@max_accounts` (5). Re-entering the same one is a `switch_to/2`.
- **Mirrored like an added account** (`persist_account/2`), not like an
  impersonation: it is the person's own choice, and the mirror is already bound
  to the root identity. A lost session resumes inside Acme.
- **Back to my account** = `switch_to/2` with the root's ref. Logging out of
  the organization = `log_out_active/1` (drops back to the root).
- **Works with `multi_session_enabled` off** (the default). The organization
  part of the stack needs no "add account" UI; only the gate in `scope_fields/1`
  and the routes must not require the setting. Verify `switch_to/2` and
  `log_out_active/1` paths have no hidden dependency on it.

Rejected alternative: storing the acting organization on the person's own
token (like `active_role_uuid`) and having the token loader return the
organization. That makes one token resolve to a user it does not belong to,
and every token-by-user path (the Sessions page, revoke, logout, `SessionRef`,
login alerts) would have to learn about it.

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
  and the **root** manages at least one organization. Independent of
  `multi_session_enabled`.
- Built as its own component (`Core.OrganizationSwitcher`, like
  `Core.RoleSwitcher`) so both navs share it.
- Each row is a form `POST /users/session/organizations/:uuid` (and the
  person's row a `PUT /users/session/active` with the root's ref): full
  page loads, same reasoning as `set_active_role/2` (the scope changes under
  every LiveView on the page).
- While acting, the header shows who you are ("Acme OÜ · via Dmitri Don"), so
  nobody forgets which company they are in.
- Data: one indexed query on `organization_managers` by the root's uuid, run
  only when the master switch is on; it rides on the scope next to
  `multi_session_accounts` (`scope.acting_organizations`). The scope already
  resolves the root for multi-session, reuse that read.

### 6. Roles while acting

The session is the organization, so `Scope.for_user/1` gives the
organization's roles, and the role switcher works per session as usual. A
managed organization never holds Owner or Admin: `Roles.assign_role/4` /
`sync_user_roles/3` refuse it (same place as the other `can_manage_role?/2`
rules), and converting an organization that holds one is refused.

### 7. Mail

- Mail meant for a managed organization goes to `contact_email`; with none,
  it is not sent. Notifications stay in-app (whoever acts for it sees them).
- **New safety net:** the mailer drops any recipient on `.invalid` (nothing in
  core does this today, service users are just never mailed). Covers both
  placeholders.

### 8. Attribution

Activity rows written while acting carry the organization as `actor_uuid`
(its own history reads naturally, and per-user queries keep working) and the
person in `metadata["acting_user_uuid"]`. Best done once, centrally: the scope
knows it is acting (`Scope.acting_user_uuid/1`), and `PhoenixKitWeb.Actor`
exposes it, so `Activity.log/3` callers need no change. Open decision 2.

### 9. Admin UI and creating organizations

- **Organization details page** (`Live.Users.UserDetails`): a "Managed by
  members" section — the managers list (add by person search, remove), and
  the contact email.
- **Convert an existing organization** to managed: its real email moves to
  `contact_email`, `email` becomes the placeholder, its own sessions and
  remember-me tokens are revoked. Converting back asks for a new unique
  login email.
- **New managed organization** (admin): name, contact email, first manager.
- **Self-serve "Add a company"** from the person's own account settings:
  creates the managed organization with the person as its first manager.
  Phase 2, behind a setting; Andi decides whether they need it.

## Phases

1. **Core model + doors** — V226, schema/changeset changes, placeholder email,
   every login door, the session-query guard, `.invalid` mail guard, Roles refusal.
2. **Switching** — `act_as_organization`, routes, the switcher component in
   both navs, the "acting as" header, attribution.
3. **Admin UI** — managers on the details page, convert, create.
4. **Self-serve** (optional) — "Add a company" in account settings.

Each phase is releasable on its own; nothing changes for an install until an
organization is marked managed.

## Tests

- Every login door refuses a managed organization (password, magic link,
  OAuth, QR, reset, confirm, add account), one test each.
- Session query: an organization token without `acting_user_uuid`, with a
  removed manager, with a deactivated person → nobody signed in.
- `act_as_organization` decides on the root: a person acting for A cannot
  enter B that only A manages; a non-manager is refused; the refusal is logged.
- One organization token per stack; entering a second replaces the first.
- Removing a manager signs out their organization session (with and without
  the explicit revoke, to prove the query guard).
- Managed organization cannot hold Owner/Admin.
- Mailer drops `.invalid` recipients.
- Forged-input LiveView tests for the managers UI (`render_submit` with a
  person/org the form never offered).
- Prefix migration test covers V226.

## Open decisions

1. **Self-serve creation** (phase 4): needed by Andi, or admin-created only?
2. **Attribution**: org as actor + person in metadata (proposed), or the
   person as actor with the org in metadata?
3. **`MultiSession.impersonated?/1`** is true for any active account that is not
   the root, so acting for an organization reads as "borrowed account" to
   callers that refuse one (the AI assistant spending limits). Keep that (safe)
   or teach it that an organization token with `acting_user_uuid = root` is
   the person's own?
4. **Impersonating a managed organization** (Owner/Admin support access): its
   token has no `acting_user_uuid`, so the session query would refuse it.
   Refuse in v1, or let an impersonation token carry the impersonator?
5. **CRM mirror** (`PhoenixKitCrm.Companies`) creates organization users from
   companies with a real email. Should it create managed ones (placeholder +
   contact email) when the company's email is already taken?
6. **Manager rights inside the organization**: v1 has one level (a manager
   acts with the organization's roles). Do Andi's companies need "can act, but
   only as role X"?
