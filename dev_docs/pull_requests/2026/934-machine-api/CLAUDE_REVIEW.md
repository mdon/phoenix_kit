# Claude review — PR #934: machine API (admin + public REST, MCP, keys, confirmations, approvals, module tool callbacks)

**Author:** timujinne · **Merge:** `ec319db48` · **Reviewed:** 2026-10-15 · **Size:** 219 files, +50.5k (≈12k lib, ≈30k tests)

**Verdict:** sound. No CRITICAL or HIGH finding and no authentication or authorization bypass. The gates the guide
promises are the gates the code has: the verify-first check order (no probe oracle), effective rights = key scopes ∩
the owner's permissions re-read per request, atomic single-statement state transitions for confirmations / approvals /
idempotency, HMAC-bound confirmation codes, the `api_only` refusal on every web door, prefix-safe V219/V220 whose
manifest matches the SQL. What follows is MEDIUM or lower.

Reviewed in four read-only passes (auth + keys + body guard, executor + validator + registry, confirm + approvals +
idempotency + migrations, MCP + OpenAPI + REST + Settings LiveViews) plus a manual read of the non-`api/` core diff
(`Users.Auth`, `UserToken`, `MagicLink`, `OAuth`, `MultiSession`, `Routes`). Every item marked fixed below was
re-verified against the code before changing it; the rest are recorded, not fixed (reason given).

## Fixed in this follow-up

### IMPROVEMENT - MEDIUM: an approval ran after the admin API was switched off
`Approvals.execute/2` re-checked key, owner, scope, tool and input, but not `api_admin_enabled`; the switch was enforced
only on the request path (`Auth`, `BodyGuard`). An operator who turned the admin API off during an incident could still
see a queued approval run from the Settings page. `execute/2` now stops with `not_found` first. Test:
`approvals_decide_test.exs` "the admin API switched off since the request".

### IMPROVEMENT - MEDIUM: a re-request after the values changed returned the old, stale approval
`pending_row/4` deduped on key + tool + `input_hash` and ignored the fingerprint, so the repeat got the old pending row
with its outdated preview; the approver decided on a stale view and the approval ended `stale`, wasting a human
decision. `request` now closes the pending rows of the same key/tool/input whose fingerprint differs (`supersede/3`, in
the same advisory-locked transaction) so the repeat gets a fresh row. Test: `approvals_request_test.exs`.

### NITPICK→MEDIUM: `Approvals.finish/3` raised after the write
`repo().get!/2` after `write_final`: the `actor_key_uuid` FK is `ON DELETE CASCADE`, so a key (or its owner) deleted while
the handler ran took the row with it; the page then said "could not be processed" although the operation had run. It
now answers with the row it wrote. Test: "a key deleted while the handler runs does not make approve/3 raise".

### IMPROVEMENT - MEDIUM (defence in depth): `Keys.create_key/3` accepted any service user
`owner_allowed/2` (api_only clause) required only that the creator hold every permission of the service user. The guide
says a key goes to "a service user *they created*" and `ServiceUsers.list/1` shows exactly that set (all for an Owner),
but nothing enforced it below the page, so a future tool or module calling `create_key/3` with a uuid could mint a token
acting as another person's service user. It now also requires `created_by_uuid == creator` or an Owner scope; `rotate/3`
goes through the same function. Not reachable from today's UI. Tests: `keys_test.exs` (`service_user_with/2` in
`KeyTestSupport` now takes the creator).

### IMPROVEMENT - MEDIUM: Validator did the costly work before the cheap bounds checks
`string/3` ran `pattern` (a module-authored regex over the whole value) even when `maxLength` had already failed — a
2 MB value in a `maxLength: 64` field was scanned in full; `array/3` walked every element of a list already over
`maxItems`. Both now return the size error without the expensive step. Tests: `validator_scalars_test.exs`,
`validator_array_test.exs`.

### NITPICK: `catch :exit` gaps (project rule: soft-failure paths need `rescue` AND `catch :exit`)
- `ModuleRegistry.safe_enabled?/1` — now on the API request path through `all_api_tools` / `disabled_api_tool?`; a module
  `enabled?/0` reading settings on a dead pool exited out of `Registry.find`, giving the client a bare 500.
- `Keys.touch_last_used/2` — an authenticated request failed because a best-effort `last_used_at` write exited.

## Open — recorded, not changed

**BUG - MEDIUM: `api_disabled_tools` fails OPEN on a transient DB error.** `Config.fetch_list/1` (`config.ex:164`)
maps only a raise to `:unreadable`, but `Settings.get_setting_cached/2` swallows a cold-cache DB error and returns the
`""` default, which parses to "nothing hidden": every tool an admin hid is callable again until the cache refills. Scope
and permission checks still apply. Needs a Settings read that returns `{:ok, v} | :error`; a core Settings API change, so
not done here.

**IMPROVEMENT - MEDIUM: an owner who is no longer confirmed keeps working keys.** `Keys.active_owner/1` only calls
`Auth.ensure_active_user/1` (`is_active`), though its `@doc` says "gone, blocked or not confirmed" and AGENTS.md says
`require_email_confirmation` is honoured at every account gate. An admin who un-confirms a user as a soft suspension
locks them out of every page but not out of their bearer keys. Suggested: return `:owner_inactive` when `confirmed_at ==
nil`, `api_only` is false and the setting is on. Not applied: it changes who can use existing keys, so it wants a
maintainer decision (and a sweep of the fixtures that register unconfirmed owners).

**IMPROVEMENT - MEDIUM: `allowed_ips` and the failed-auth throttle trust a header on common deployments**
(`auth.ex:241` → `IpAddress.client_address/1`). Behind a loopback/private peer the LAST `X-Forwarded-For` entry wins; that
is safe only if a trusted proxy always appends. Docker `-p` publishing (peer = bridge gateway, nobody appends) and an
nginx that sets `X-Real-IP` but forwards the client's own XFF both let a holder of a leaked key send
`X-Forwarded-For: <allowed ip>`, and rotate the header to reset the pre-auth failure bucket. The guide only warns about
the shared-proxy-IP direction. At minimum document it (guide + the key form's hint); better, a host setting naming the
one trusted real-IP header.

**IMPROVEMENT - MEDIUM: nested objects are not closed**, contrary to `Executor`'s moduledoc ("every schema is closed").
`close_schema/2` closes the root only; `items: {type: object, properties: …}` accepts undeclared fields that reach the
handler. Closing recursively (objects that declare `properties`) is the right fix but changes the contract for sibling
module packages, so it needs a `ToolLint` rule / release note first. Until then correct the docstring or declare
`additionalProperties: false` in nested schemas.

**IMPROVEMENT - MEDIUM: the one-time token can reach a crash report.** `Settings.Api` keeps it in `socket.assigns.new_token`;
`Phoenix.LiveView.Channel.format_status(:terminate, …)` prints the full state, so an exception while the dialog is open can
put the token in the log (subject to Logger truncation). Wrap it in a struct with a redacting `Inspect` impl; the tests
assert only debug event-param logging.

**IMPROVEMENT - MEDIUM: credential check covers idempotency rows only.** An approved handler's result is stored in
`phoenix_kit_api_confirmations.result` for 30 days and returned on every `system.get_approval` poll with no
`Idempotency.credential_bearing?/1` check, so a tool answering with a `claim_url` / token is stored in the clear when
queued for approval. Redact in `finish/3`.

**IMPROVEMENT - MEDIUM: refusals after authentication cost nothing** (MCP 405/406/400 version/non-JSON-RPC, REST unknown
path/405): `Auth` does a key read, an owner lookup and a `touch_last_used`, then the response is sent with no limiter charge,
so a leaked key can loop `GET /mcp/admin` unthrottled. Charge `RateLimit.check_admin/2` on those branches.

**IMPROVEMENT - MEDIUM: pre-auth body read.** `BodyGuard` reads up to 2 MB and JSON-decodes it for the admin audience before
`Auth` sees whether a bearer token exists (the moduledoc measures ≈90 MB heap for a deeply nested 2 MB body). Skip the read
when no single well-formed `pk_` Authorization header is present.

**IMPROVEMENT - MEDIUM: Settings → API LiveViews query in `mount`** (`api.ex:81-115`, `api_approvals.ex:37-60`; Iron Law) and
`owner_labels/3` is an N+1 (`Auth.get_user/1` per distinct owner); every keystroke in the create-key form runs
`fresh_scope` + three lookups (no `phx-debounce`). Move loading to `handle_params`, batch the owner lookup, debounce the
text inputs.

**IMPROVEMENT - MEDIUM/LOW (smaller):** NUL-character guard covers write tools only, so an anonymous NUL in a public read
tool's string hits Postgres and answers 500 (`flow.ex nul_in/2`); `ToolLint` never checks that `handler` / `danger` /
`cost` `{module, function}` pairs exist (a typo is a runtime 500, or a permanently "dangerous" tool); an
unencodable handler result after a committed write releases the idempotency claim, so a retry re-runs the write
(`executor.ex:516`); public `initialize` / OpenAPI do an uncached `Settings.get_project_title/0`.

**NITPICK:** preview not size-checked though two comments say it is (`approvals.ex check_size`); `FlowConfig.save/2` not
all-or-nothing on a DB failure and reads defaults on a Settings error (fails open for `api_approval_pending_max`);
approval notice throttle claimed before the send; no retry on the 32-bit key-prefix collision; origin match ignores
scheme/port for the canonical host (dev `localhost`); `WWW-Authenticate` carries `error="invalid_token"` when no
credentials were sent (RFC 6750 §3.1); `Accept: application/json;q=0` accepted; one warning per Origin-bearing request when
the `:api_request_context` hook fails; origin list accepts non-punycode IDN hosts that can never match; OpenAPI omits the
rate-limit headers and 405; `find_tool` runs before `check_scope`, so a scopeless key distinguishes `module_disabled` from
`not_found` for real tool names (names ship in module code anyway); a handler key named `"effects"` is overwritten;
`Activity.log_many` raises on an improper list before its rescue.

**Design note (no change):** `Access.fresh_scope/1` is `narrow: false`, so an Owner acting under a limited active role that
holds `api` gets full Owner key management inside the page events. This matches the documented intent.

## Checked and found sound

Token format / parse / constant-time compare / dummy-hash on unknown prefix; revocation, expiry and cache generation
checks; rotate / `update_scopes` row locking and authorization on the re-read row; CIDR parsing (IPv4-mapped, family
mixing, prefix widths, 100-entry cap); credentials-in-URL refusal ordering; MCP Origin validation (null, userinfo, path,
fragment, duplicates, case, trailing dot, default ports, Host never trusted); JSON-RPC batch / notification / id handling;
confirmation codes (192-bit HMAC, `secure_compare`, atomic claim, no oracle); idempotency scoping and compare-and-set
takeover; approvals atomic transitions, advisory-locked pending cap, rights re-read per event; Oban workers / cron entries
agreeing across the four places; V219 / V220 prefix-safety rules and `expected_schema` agreement; the `api_only` guards
on session / email / magic-link / OAuth / `log_in_user` / multi-session / impersonation; `Routes` reserved `/mcp` segment.
