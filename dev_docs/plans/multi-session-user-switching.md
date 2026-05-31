# Multi-Session User Switching — Design Spec

**Status:** Approved design (pre-implementation)
**Date:** 2026-05-31
**Scope:** PhoenixKit core (`lib/phoenix_kit/users/`, `lib/phoenix_kit_web/`)

## Goal

Let an Owner/Admin be logged into **several real user accounts at once** and switch
the active account from a dropdown in the header. Purpose: testing the app under
different roles/permissions without juggling browsers or incognito windows.

This is **genuine multi-account** (each account is a real authenticated login,
added with email + password) — **not** impersonation. No privilege escalation: you
can only add an account whose credentials you know, exactly like a normal login.

## Decisions (locked)

| Decision | Choice |
|---|---|
| How accounts are added | Real login — email + password per account |
| Session model | One cookie holding a **stack of session tokens** |
| Access gate | Root (first) account must be Owner/Admin **and** `multi_session_enabled` setting on |
| Kill switch | `multi_session_enabled` in `phoenix_kit_settings` (default `"true"`) + UI toggle on a Settings page |
| Logout semantics | Two actions: **Log out** (active account only) + **Log out all** (whole stack) |
| Audit | Log `session.account_added` / `session.switched` to Activity feed (`mode: "auto"`) |

### Rejected alternatives
- **Impersonation (no password):** privilege escalation; needs heavier audit + intrusive
  "you are impersonating" banner. Out of scope.
- **Multiple browser sessions:** cannot switch from a single header UI.

## Session model

Plug session keys:

- `:user_token` — raw token of the **active** account. Semantics unchanged, so every
  existing plug / `on_mount` / `Scope` resolution path keeps working with zero edits.
- `:live_socket_id` — derived from the active token (unchanged).
- `:pk_session_accounts` — **new** key: ordered list of raw session tokens in the stack,
  including the active one. `stack[0]` is the **root** account (the original login).

**Switching** = copy the selected stack token into `:user_token` and recompute
`:live_socket_id`. User/scope resolution is never touched.

Each token in the stack is a real, independently-valid row in
`phoenix_kit_users_tokens` (context `"session"`). The cookie is signed/encrypted by
Phoenix; storing up to ~5 base64 tokens stays well under the 4 KB cookie limit.

## Hard constraint: cookie mutation requires a controller

LiveView **cannot write the Plug session cookie**. Therefore all mutating operations
(add / switch / remove / logout) are **HTTP controller actions** that redirect/reload.
The header dropdown items are `<.link>` / small `<form>` posts to these routes — the
LiveView only *renders* the account list.

## Context module — `PhoenixKit.Users.MultiSession` (new)

`lib/phoenix_kit/users/multi_session.ex`

Pure session/stack logic, conn-aware where it must write the session. Functions:

- `add_account(conn, email_or_username, password)` —
  validates via `Auth.get_user_by_email_or_username_and_password/3`; on success creates
  a session token (`Auth.generate_user_session_token/1`), pushes it onto the stack,
  makes it active. Enforces stack cap (default **5**). Returns `{:ok, conn}` or
  `{:error, :invalid_credentials | :stack_full | :gate_denied}`.
- `switch_to(conn, token_ref)` — activates a token already present in the stack;
  rejects refs not in the stack.
- `remove_account(conn, token_ref)` — removes the token from the stack **and** deletes
  it from the DB (`Auth.delete_user_session_token/1`); if the removed token was active,
  the **root** account becomes active.
- `list_accounts(session)` — returns `[%{token_ref, user, active?, root?, roles}]` for
  rendering. Resolves each token to its user (N ≤ 5 light queries; computed only for
  gated owner/admin sessions and memoized in an assign).
- `clear_stack(conn)` — used by "Log out all"; deletes all stack tokens from the DB and
  clears the stack key.
- `gate_allowed?(session)` — true iff `stack[0]` resolves to an Owner/Admin
  (`Scope.owner?/1` or `Scope.admin?/1`) **and** `Settings.get_boolean_setting("multi_session_enabled", true)`.

`token_ref` is an opaque, non-secret handle for the dropdown (e.g. the account's
`user_uuid` or stack index) — the raw token is never exposed in markup/URLs; the
controller maps the ref back to the stack token server-side.

## Routes

Added to the authenticated scope in `integration.ex` (alongside the existing
`/users/log-out`), `pipe_through` including `:phoenix_kit_require_authenticated`:

- `POST   /users/session/accounts`        → `Users.Session.add_account` (form: email + password)
- `PUT    /users/session/active`          → `Users.Session.switch_account` (param: `token_ref`)
- `DELETE /users/session/accounts/:ref`   → `Users.Session.remove_account`

Existing logout is extended:
- `DELETE /users/log-out`        → log out **active** account (pop from stack, fall back to root). If stack would become empty, behaves like today (full logout → `/`).
- `DELETE /users/log-out?all=1`  → "Log out all": `clear_stack/1` then full logout.

Controller actions live in `PhoenixKitWeb.Users.Session`. Each action re-checks
`gate_allowed?/1` server-side and returns 403/flash if denied — the gate is enforced at
the controller, not only hidden in the UI.

## Gate behaviour

- The switcher renders only when `gate_allowed?/1` is true.
- The gate is evaluated against the **root** account, so even when the active account is
  a low-privilege User, the dropdown stays visible and the user can switch back.
- Added accounts may be **any role** (that is the point: test under different rights).

## UI — extend `AdminNav.admin_user_dropdown/1`

`lib/phoenix_kit_web/components/admin_nav.ex` (existing daisyUI `dropdown dropdown-end`).

A new section, rendered only when gated, between the user-info header and the
Settings/Logout block:

- **Account list:** each stack account as a row — avatar/email + role badge + a check on
  the active one. Each non-active row is a `<form method="put" action=".../active">` with
  `token_ref`. Active row is inert.
- **`+ Add account`** — opens a `<.modal>` with an email + password form posting to
  `POST .../accounts`. Validation errors surface via flash after redirect (controller
  round-trip, since cookie write is required).
- **`×`** on each non-active row → `DELETE .../accounts/:ref`.
- Footer: **Log out** (active) and **Log out all**.

The active account is already shown via the header avatar/email, so no separate intrusive
banner is added. Match existing daisyUI markup and `Routes.locale_aware_path` link helpers.

The same section is also added to the fallback navbar
(`layouts/root.html.heex`) and the user-dashboard nav only if trivially shareable;
otherwise the admin header is the canonical surface (single source via the component).

## Settings

- New setting key `multi_session_enabled` (string `"true"`/`"false"`, default `"true"`),
  read with `Settings.get_boolean_setting("multi_session_enabled", true)`, written with
  `Settings.update_boolean_setting/2`.
- A toggle on the relevant admin Settings LiveView (owner-visible) so it can be turned off
  from the UI without a redeploy.

## Audit (Activity feed)

Guarded with `Code.ensure_loaded?(PhoenixKit.Activity)`:

- `session.account_added` — `actor_uuid` = root account, `target_uuid` = added account,
  `module: "users"`, `mode: "auto"`, metadata `%{email, role}`.
- `session.switched` — `actor_uuid` = root account, `target_uuid` = newly-active account,
  `mode: "auto"`.

No notifications are generated (admins use the audit trail; `target` may equal a tester
account but these are not user-facing events — keep `mode: "auto"`).

## Security notes

- Every stack token is a genuine valid session token; cookie is signed by Phoenix.
- No escalation: adding requires the account's password.
- Controller actions enforce the gate independently of UI visibility.
- `remove_account` and "Log out all" delete tokens from the DB (no orphaned sessions).
- `token_ref` is opaque; raw tokens never appear in markup or URLs.

## Testing

**Unit (`test/phoenix_kit/users/multi_session_test.exs`, no DB where possible):**
- stack push/switch/remove/cap logic, `token_ref` mapping, gate denial when root is a plain User.

**Integration (`PhoenixKit.DataCase`, real Repo):**
- Owner logs in → add User-role account → assert stack size 2 → switch → assert resolved
  `Scope` reflects the User account → switch back to root → remove the User account →
  assert its DB token deleted.
- "Log out all" deletes every stack token from `phoenix_kit_users_tokens`.

**Controller tests:**
- Add/switch/remove rejected with 403/flash when `multi_session_enabled = "false"`.
- Add/switch rejected when root account is not Owner/Admin.
- Invalid credentials on add → flash error, stack unchanged.

## Out of scope (YAGNI)

- Impersonation without password.
- Persisting the stack across browser restart via remember-me (stack lives in the session cookie only).
- Per-role configurability of who may use the switcher (gate is fixed at Owner/Admin).
- Cross-device session sync.

## Reference call sites

- Auth/session: `lib/phoenix_kit_web/users/auth.ex` (`log_in_user/3:85`, `log_out_user/1:153`,
  `put_token_in_session/2:1647`), `lib/phoenix_kit_web/users/session.ex`.
- Token model: `lib/phoenix_kit/users/auth/user_token.ex` (`build_session_token/2:97`).
- Scope/roles: `lib/phoenix_kit/users/auth/scope.ex` (`owner?/1`, `admin?/1`, `for_user/1:90`).
- Header dropdown: `lib/phoenix_kit_web/components/admin_nav.ex:186` (`admin_user_dropdown/1`).
- Routes: `lib/phoenix_kit_web/integration.ex:233` (auth scope).
- Settings: `lib/phoenix_kit/settings/settings.ex` (`get_boolean_setting/2:892`,
  `update_boolean_setting/2:1203`).
