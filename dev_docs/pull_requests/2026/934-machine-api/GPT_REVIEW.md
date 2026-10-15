# GPT recheck — PR #934 and Claude's follow-up

**Reviewed:** 2026-10-15  
**PR merge:** `ec319db48`  
**Claude's fixes:** `e3b1b320a`

## Scope and verdict

Rechecked every source change in Claude's follow-up, its new tests and fixture changes,
and the open findings against their callers in Settings, Keys, Confirm, Approvals,
Executor, the transports and the API settings LiveView. This is a focused second review,
not a claim to have independently audited every line of the original 219-file PR.

Claude's applied fixes are sound. The approval switch check, superseding outdated
pending requests, handling a deleted key after execution, service-user ownership rule,
validator bounds checks and dead-pool catches should remain.

The blanket statement that there is no authentication/authorization bypass is too broad:
confirmation enforcement was missing from bearer authentication, and the hidden-tool
policy really could fail open. Neither requires a new product decision to implement the
already-documented gate. This follow-up fixes both, plus two credential exposures.
No critical or high finding was established in Claude's fix diff. The proxy issue below
has deployment-dependent security impact and remains a limitation of the shared IP helper.

## Fixed findings

### BUG - MEDIUM: hidden-tool policy failed open after a cold Settings read failed

`Config.fetch_disabled_tools/0` promised an unreadable result, but the underlying
`Settings.get_setting_cached/2` converted database exceptions into the empty default.
An enabled API could consequently expose a hidden tool again. A transient failure of
this particular read is enough; the rest of a request need not lose its database access.

Added `Settings.fetch_setting_cached/1`: `{:ok, nil}` means a successfully read missing
row; `:error` means the store could not be read. It shares the existing cache,
negative-cache sentinel, decryption rules and generation-protected fill. Failed reads
are never cached. Existing Settings getter behavior remains unchanged. Config now uses
this result and the registry's existing fail-closed branches finally receive it.

Tests exercise raises and exits, an explicitly empty warm cache, a missing row's
negative cache, and recovery after a failed read. They assert both registry listing and
lookup refuse tools on failure (`config_unreadable_test.exs`).

### BUG - MEDIUM: bearer authentication bypassed required email confirmation

`Keys.active_owner/1` checked activity only despite documenting confirmation too.
A human whose `confirmed_at` was cleared retained working cached bearer keys and could
still execute an approval. This violated the existing account-gate policy.

The shared owner check now refuses unconfirmed humans when `require_email_confirmation`
is enabled (default true). Confirmed humans and service users remain usable; turning
confirmation enforcement off permits unconfirmed humans. `verify/2`, `active?/1` and
`Confirm.live_actor/1` all use this check, including approval execution.

Tests clear confirmation after the key has been cached and assert all three paths
refuse it, then allow it when the setting is off. A separate test clears a service
user's confirmation and proves its key still works (`keys_verify_test.exs`). The shared
API fixture now creates confirmed humans, matching a person admitted to Settings → API.

### BUG - MEDIUM: one-time tokens were visible in LiveView termination state

The installed `Phoenix.LiveView.Channel.format_status(:terminate, ...)` returns the
channel state. A plain string in `socket.assigns.new_token` therefore reaches state
inspection in a crash report; filtering event parameters does not protect it.

Both create and rotate now store a `Keys.DisplayToken` with a redacting `Inspect`
implementation and an HTML-safe rendering implementation. The dialog still shows the
same token and dismissal clears it. A test inspects the actual channel termination
state with unlimited inspection limits, asserts neither token nor secret appears, and
also verifies the live dialog still renders it (`api_test.exs`). Rotation's existing
rendering, dismissal, replay and logging tests cover the second assignment path.

### BUG - MEDIUM: approval results and progress persisted replayable credentials

`Approvals.finish/3` stored handler results without the credential policy already used
for idempotency. Polling `system.get_approval` returned those credentials repeatedly.
The progress callback was another write path for the same problem.

Added `Idempotency.redact_credentials/1`, using the existing credential names and string
markers. Approval success/error results and progress now redact recognized credentials
before persistence. Finalization also redacts retained partial results. Status remains
`executed` after a successful operation: redaction does not invite the caller to repeat
its write. Polling sees the redacted answer. Existing historical rows are not rewritten.

Tests cover a real approved credential-producing handler, database and polling results,
and nested progress inspected while the handler is held, then retained after failure
(`approvals_decide_test.exs`). A unit test exercises every recognized field name,
case-insensitive names, nested arrays and credential URL/token markers
(`credential_redaction_test.exs`).

## Other open findings rechecked

- **BUG - MEDIUM, deployment dependent: forwarded IP trust.** Confirmed: a private or
  loopback peer causes the shared helper to trust the last XFF entry, then X-Real-IP.
  A directly reachable Docker port or a proxy that leaves the client's XFF intact can
  therefore allow a leaked key to bypass `allowed_ips` and evade the pre-auth failure
  bucket. The API guide now states the required header overwrite/append and network
  isolation, including the X-Real-IP-only nginx trap. The shared behavior is unchanged;
  an explicit trusted-proxy policy needs its own compatibility review across web login,
  website access, storage and API callers. Documentation does not eliminate this risk.
- **IMPROVEMENT - MEDIUM: nested schemas.** Confirmed. Corrected Executor's documentation
  to say it closes the root. Nested objects must declare `additionalProperties: false`
  themselves. Recursive closure is deferred because it would change module contracts;
  accepting an extra field is not by itself a demonstrated permission bypass.
- **IMPROVEMENT - MEDIUM: refusals after authentication.** Confirmed MCP method/path,
  Accept, RPC shape and protocol-header refusals can skip the limiter after verifying a
  key. REST unknown routes also bypass tool charging. Remains open; charge at the
  transport refusal boundary without double-charging executor refusals.
- **IMPROVEMENT - MEDIUM: pre-auth body cost.** Confirmed and already described in
  BodyGuard's own cost discussion. Remains open; a cheap token-shape gate cannot stop a
  caller supplying syntactically valid junk tokens, and proxy request/body limits are
  still needed. Any change must preserve disabled-side 404s and transport error shapes.
- **IMPROVEMENT - MEDIUM: Settings LiveView loading.** Confirmed synchronous loading in
  mount, per-owner label queries and form-change refresh work. Left for a focused
  performance/lifecycle change; this recheck establishes no authorization bypass there.
- Claude's smaller items remain open: NULs in read-tool input, callback lint coverage,
  encoding failure after a committed write releasing an idempotency claim, uncached
  public metadata, preview size checks, partial multi-setting saves, notification retry,
  prefix collision handling, Origin/Accept details and the remaining listed nitpicks.
  In particular, callers still need natural idempotency for writes whose response can
  be lost or fail encoding. This follow-up does not claim to fix these.

The API guide now records confirmation behavior, credential redaction for approvals,
and the concrete proxy deployment requirements. No version or CHANGELOG change and
no release are part of this review.

## Validation

- `mix precommit`: **exit 0**. Compile with warnings as errors, unused-dependency check,
  test-file compilation, formatting, strict Credo, Dialyzer and **370 JS tests** passed.
- `PGPOOL=12 mix test --max-cases 8`: completed in 875 seconds, **89 doctests,
  11,236 tests, one failure, 10 skipped (one excluded)**. The failure was PostgreSQL
  `40P01 deadlock_detected` in the setup of the existing auth-flow test
  "the public reset path charges the per-email bucket exactly once". It occurred while
  the exploratory and final suite processes overlapped on the same test database;
  the exploratory process was stopped. No other failure occurred. All new regressions
  and Claude's review tests passed in this full run.
- `PGPOOL=12 mix test --failed --max-cases 1`: **exit 0**, **one test, zero failures**.
  The deadlocked test passed in isolation. This was not a clean single-attempt full run;
  the failed-test retry is recorded separately rather than hidden.
- PostgreSQL was reachable and integration tests ran. The test role lacks `CREATEROLE`,
  accounting for the privileged-test exclusion; the suite's explicit skips remain.
- `git diff --check`: clean.

The initial focused run also caught a new test's mistaken assumption that service users
start unconfirmed. The test now explicitly clears `confirmed_at` and proves the intended
service-user exemption; it passed in the full run.
