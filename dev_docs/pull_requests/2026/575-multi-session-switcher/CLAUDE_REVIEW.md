# PR #575 — feat(auth): multi-session account switching (opt-in)

**Status:** MERGED into `main` (2026-06-01). Post-merge review.
**Scope:** +1368 / -20, 13 files. New `MultiSession` module + controller actions, plug/on_mount wiring, Scope fields, header switcher UI, OAuth add-account path, opt-in setting.

Overall this is solid, well-tested work: session-fixation protection (`renew_and_put_active_token`), open-redirect guards on every `return_to`, dedup/stack-limit invariants, CSRF-bearing `<.form>`s, and good unit + integration coverage. Findings below are refinements, not blockers.

---

## Resolution log (high-effort follow-up review, 2026-06-01)

A second high-effort review (7 finder angles over the multi-session fixes + the merged PR #577 PDF.js controller) surfaced 10 findings. Resolutions:

**Fixed:**
- **Logout token-leak regression** — moved stack draining into `Auth.log_out_user/1` (after the user lookup, so the admin disconnect broadcast still resolves) and removed the three call-site `delete_all_stack_tokens/1` calls. Fixes both the broadcast regression *and* the "fourth logout path forgets to drain" fragility.
- **Open-redirect guard duplicated 4×** — centralised into `PhoenixKit.Utils.Routes.local_path?/1` (also now rejects `/\\`), used by `session.ex`, `oauth.ex`, `login.ex`.
- **`scope_fields/1` redundant root query** — derives `allowed?` from the resolved stack instead of a separate `gate_allowed?/1` token lookup.
- **PDF controller (#577):** rejects symlinked targets via `File.lstat` (was `File.regular?/1`, which follows symlinks); adds `ETag` + `If-None-Match`/304; corrected the stale `.mjs`/`@content_types` comment.

**Deferred (architectural — flagged for the PR authors, not unilaterally redesigned):**
- **Two static servers for `/_pdfjs`** (controller fallback vs endpoint `Plug.Static`) can drift — the deeper fix is to make `mix phoenix_kit.install/update` always wire the route (or harden the mount), which is PR #577's design call.
- **PDF route hardcoded to one module/app** — generalising to a `static_asset_mounts/0`-style module callback is the same "lift to a registry" pattern the publishing note already tracks.
- **Transient switcher data on the auth `Scope` struct** (PR #575 design) — moving it to a dedicated assign touches `layout_wrapper` + `admin_nav` + `auth` and risks the switcher; larger refactor.
- **Partial:** PDF `lstat` closes final-component symlinks but not an intermediate symlinked *directory* (needs realpath resolution); near-zero realism for a package-vendored dir. `list_accounts/1`'s 2-queries-per-row + per-account role N+1 left as low-impact (≤5 accounts, behind an off-by-default flag).

---

## BUG - MEDIUM — Secondary tokens orphaned (left valid in DB) on single logout from root

`lib/phoenix_kit_web/users/session.ex` — `delete(conn, _params)` (non-`all` path)

The `?all=1` path and `get_logout/2` both call `MultiSession.delete_all_stack_tokens/1` before logging out, exactly to avoid leaving secondary tokens valid. The plain `delete/2` path does **not**:

```
delete(conn, _params) -> MultiSession.log_out_active(conn) -> {:full, conn} -> UserAuth.log_out_user(conn)
```

`log_out_user/1` (`auth.ex:154`) deletes only the **active** `:user_token`, then `renew_session/1` `clear_session()`s the stack out of the session. Any secondary tokens still in `:pk_session_accounts` are never `delete_user_session_token`'d — they remain valid in the DB until natural expiry, now unreferenced by any session.

**Reachable flow:** log in (root A) → add account B (active=B, stack=[A,B]) → switch back to A (active=A, stack=[A,B]) → click **"Log out"** (single). `active == root_token` → `{:full, conn}` → only A's token deleted; B's token leaks.

**Fix:** drain the stack in the `{:full, _}` branch too — either call `MultiSession.delete_all_stack_tokens(conn)` before `UserAuth.log_out_user/1` in the `{:full, conn}` clause, or have `log_out_active/1` delete the non-active stack tokens before returning `:full`. The two explicit-drain call sites confirm this is the intended invariant; this path just misses it.

---

## IMPROVEMENT - HIGH — `list_accounts/1` runs on every authenticated request/mount even when the feature is OFF

`lib/phoenix_kit_web/users/auth.ex` (plug ~L401 and on_mount ~L807)

Both scope-building sites populate the field unconditionally:

```elixir
scope = %{
  Scope.for_user(active_user)
  | multi_session_accounts: MultiSession.list_accounts(session),   # always runs
    multi_session_allowed?:  MultiSession.gate_allowed?(session)
}
```

`multi_session_enabled` defaults to `"false"`, so for essentially all installs this is pure waste on **every** authenticated HTTP request and **every** LiveView mount. Per account, `list_accounts/1` does:

- `Auth.get_user_by_session_token/1` (DB)
- `Auth.get_session_token_record/1` (DB)
- `role_label/1` → `Scope.for_user/1` again → `User.get_roles/1` + `Permissions.get_permissions_for_user/1` (DB; for Owner it even builds the full permission MapSet just to derive a label)

That's ~4 extra queries added to the hot auth path for a feature that is off by default, and on_mount runs twice (HTTP + WebSocket) per the LiveView lifecycle — so it's doubled there.

**Fix:** compute the gate first and only resolve accounts when it's open:

```elixir
allowed? = MultiSession.gate_allowed?(session)
accounts = if allowed?, do: MultiSession.list_accounts(session), else: []
scope = %{Scope.for_user(active_user) | multi_session_accounts: accounts, multi_session_allowed?: allowed?}
```

Bonus: `role_label/1` rebuilds the scope it was just handed for the active user — when this is reworked, the active account's already-built `Scope.for_user(active_user)` (and its `cached_roles`) can be reused instead of recomputed.

---

## IMPROVEMENT - MEDIUM — Settings copy says "Owner/Admin" but the gate allows any authenticated user

`lib/phoenix_kit_web/live/settings.html.heex` (Multiple Sessions block)

Commit `e3f8734f` ("multi-session for all authenticated users") changed `gate_allowed?/1` to require only an authenticated root user + the setting — no role check. The admin-facing copy still reads:

- *"Owner/Admin account switcher for testing under different roles"*
- *"…an Owner/Admin can add other accounts (with their password) and switch between them…"*

This now overstates the restriction — a plain User gets the switcher too (the integration tests assert exactly this). Update the copy to match the actual behavior (any signed-in user, gated only by this toggle), so an admin enabling it isn't surprised that non-admins also see it.

---

## NITPICK — `with_gate/3` sets 403 *and* a redirect

`lib/phoenix_kit_web/users/session.ex` — `with_gate/3` does `put_status(:forbidden) |> ... |> redirect(...)`. `redirect/2` sends with `conn.status || 302`, so the response is a 403 carrying a `Location` header the browser won't follow — the flash never renders. Works (tests assert `status == 403 or redirected_to =~ "/"`), but pick one: a clean `redirect(to: Routes.path("/"))` (302, flash shows) is friendlier than a dead-end 403. Low priority — this path is only hit when someone forges a request to a disabled feature.

---

## Notes / non-issues (verified OK)

- **Open-redirect guards** (`redirect_back/2` in both `session.ex` and `oauth.ex`): correctly reject `//host` and absolute URLs, accept only `^/` paths. Good.
- **Session fixation**: `renew_and_put_active_token/2` rotates the session id + drops CSRF on add/switch while preserving session data — correct, and the moduledoc explains why `configure_session(renew: true)` alone is insufficient.
- **CSRF**: switcher uses `<.form>` / `<.link method=...>`, both inject `_csrf_token`. Good.
- **OAuth add-account intent**: marker is consumed-and-cleared up front regardless of outcome, and the gate is re-checked at callback time (handles the setting being toggled off mid-flow). Good.
- **`delete(conn, %{"all" => _})`** matches any value of `all` (incl. `all=0`), but the only caller sends `?all=1`. Harmless.
- **Edge case (not blocking):** if the setting is toggled off while a user is active on a *secondary* account, the switcher UI disappears and the gate blocks switch/remove — the user is "stuck" as the secondary until they log out (logout is correctly ungated). Acceptable for an admin-controlled opt-in toggle; worth a mention if support questions arise.
