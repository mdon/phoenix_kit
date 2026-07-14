# PR #636: SMTP provider could not send at all (missing TLS options); Test Connection validated nothing

**Author**: @timujinne
**Reviewer**: Opus agents, two independent lenses (code + architecture/security), four rounds
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

> **On the reviewer**: GLM-5.2 — our usual reviewer — returned 529 for the whole of
> this work, so it was reviewed by two independent Opus agents instead. The final
> round is the one that mattered: it arrived late, after the branch had already been
> declared ready, and it found a **shipped crash** and a **leak introduced by the fix
> for the previous round** (both below). Every claim in it was re-verified against the
> dependency source and reproduced against the running dev app before being acted on —
> which is also how an earlier round's `depth` finding was refuted.
>
> The lesson worth keeping is the reviewer's own closing line: *"Green PRs did not
> catch these because neither had a test."* Both fixes therefore ship with the seams
> that make them testable, not just the patch.

## Goal

Two defects shipped together in v1.7.190, both in the email Integrations added by
PR #633:

1. **The universal `smtp` provider could not send at all.** It configured
   `tls: :always` with no TLS options. `gen_smtp` supplies none of its own, and
   OTP's `:ssl` now defaults to `verify: :verify_peer` with no CA store, so the
   handshake had nothing to verify against.
2. **"Test Connection" verified nothing** for the email providers. They declared
   no validation, so `PhoenixKit.Integrations` fell through to `:ok` and stamped
   the connection `"connected"` without a single byte leaving the box. An
   operator who pasted a wrong key saw a green check and then a failing send.

This PR fixes the transport, gives both providers a real check, and extracts the
transport so the check and the send cannot drift apart.

## Verified correct (no action needed)

- **The SES and Brevo-API send paths are untouched by the TLS fix.** Confirmed by
  a live send through each after the change.
- **Validation status is informational.** `get_credentials/1` still resolves a
  connection whose status is `"error"`, so a failing check cannot take a working
  integration offline. Checked live before tightening anything.
- **`aws_ses` is the only `:key_secret` provider**, so the tightened credential
  gate has no other blast radius.
- **Pre-existing full-suite failures are pre-existing.** Every failure in the
  suite on this branch also fails without it; the handful that vary run-to-run
  pass in isolation (sandbox contention — `Activity.log/1` raises
  `DBConnection.OwnershipError` on `main` too).

## BUG - CRITICAL (found and fixed): SMTP could not send, and `:if_available` hid it by sending in plaintext

`gen_smtp` supplies no TLS options and OTP's `:ssl` defaults to `verify_peer` with
no CA store. Verified against a real relay (`smtp-relay.brevo.com`):

- port 465 with `ssl: true` and nothing else → `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`
- any other port with `tls: :always` → STARTTLS fails with `:tls_failed`
- `tls: :if_available` **masks both** — gen_smtp silently falls back to
  **plaintext**, so the relay password goes out on the wire and it looks like it
  works

`PhoenixKit.Mailer.SmtpTransport` now builds the options properly: `verify_peer`,
the system CA store, SNI, and the `:https` hostname-check fun. Implicit TLS (465)
gets `ssl: true` + `sockopts:`; STARTTLS gets `tls: :always` + `tls_options:`.
`no_mx_lookups: true`, or gen_smtp connects to the relay's MX targets while SNI is
pinned to the configured name — a guaranteed certificate mismatch.

**`depth` is load-bearing, not decoration.** `smtp_socket.erl:50-56` defines
`?SSL_CONNECT_OPTIONS` with `{depth, 0}` and merges caller options over it
(`ssl_connect_options/2:314-315` → `proplist_merge` → `lists:ukeymerge`). Omit the
key and you inherit **depth 0** — "signed directly by a trusted root, zero
intermediates" — which fails every real chain. Live: omit → `:tls_failed` 4/4; any
value ≥ 1 → OK. A reviewer initially called it cargo-cult and has since conceded
the point; there is now a test guarding it against a future cleanup.

## BUG - HIGH (found and fixed): a failed connection check killed the operator's LiveView

The first cut of the deadline used `Task.async/1` + `Task.yield/2`, because
`:gen_smtp_client.open/1` runs in the **calling** process and, past the TCP
connect, waits on a hard-coded `?TIMEOUT` of 1_200_000 ms — the `timeout` option
bounds only `connect`, so a tarpit relay parks a LiveView for twenty minutes.

**`Task.async/1` links.** Both call sites are LiveView callbacks and a LiveView
process does not trap exits, so any crash inside the check killed the operator's
page — and the `{:exit, reason}` clause meant to turn that into an error message
could never run, because the caller was already dead. Measured, not assumed:

| check does | caller |
|---|---|
| `raise` | **DIES** |
| `exit(:boom)` | **DIES** |
| killed from outside | **DIES** |
| `exit(:normal)` | survives |
| succeeds / overruns the deadline | survives |

The SMTP check was safe only by accident (`open_smtp/1` both rescues and catches
`:exit`); the SES check was not (`send_quota_request/2` only rescues, and hackney
may exit under it).

`PhoenixKit.Integrations.Probe` now runs every check under `spawn_monitor/1` —
which is what LiveView's own `start_async` uses, for the same reason
(`phoenix_live_view/channel.ex:337` is a `:DOWN` handler, not a link). Three of
its seven tests drive the probe from a spawned, non-trapping caller and fail with
`{:caller_died, _}` if anyone swaps `Task.async` back in.

## BUG - CRITICAL (found and fixed): the retry cap did not cap retries — it crashed them

`retries: [max_attempts: 2]` looks like a cap. `ExAws.Config.build_base/2` merges
overrides with `Map.merge` (`config.ex:121`) — **shallow** — so the list *replaces*
the default `[max_attempts: 10, base_backoff_in_ms: 10, max_backoff_in_ms: 10_000]`
and takes both backoff keys with it. `ExAws.Request.backoff/2`
(`request.ex:223-229`) then evaluates `nil * :math.pow(2, attempt)` and raises. The
`rescue` below it swallowed the `ArithmeticError`, so the check performed **zero**
retries and reported an arithmetic error while the real cause scrolled past above it:

```
before:  HTTP ERROR: :nxdomain ... ATTEMPT: 1
         SES connection check failed: %ArithmeticError{}

after:   HTTP ERROR: :nxdomain ... ATTEMPT: 1
         HTTP ERROR: :nxdomain ... ATTEMPT: 2
         {:error, "Could not reach AWS SES"}   (278 ms)
```

Fires on transport errors and 5xx — exactly the blip the comment claimed to survive.
All three keys are mandatory.

## BUG - HIGH (found and fixed): the probe relocated the hang instead of removing it

The fix for "a crashing check kills the LiveView" replaced `Task.async/1` with
`spawn_monitor/1`. That removed the link — and the link was doing something.

`spawn_monitor` watches in **one direction only**. The deadline lives in the caller's
`receive/after`, so when the LiveView goes away mid-check — the operator hit refresh —
nothing is left alive to fire it. The check stays parked in gen_smtp's 20-minute
`?TIMEOUT` holding its socket, and, being unlinked, it is now unreachable rather than
merely slow. Every refresh leaks another process and file descriptor for up to twenty
minutes. Measured:

| caller dies mid-check | check |
|---|---|
| `spawn_monitor` (as shipped) | **still alive** — socket held 20 min |
| `spawn_link` + monitor + unlink | reaped with its caller |

The moduledoc justified the choice by asserting that LiveView "monitors rather than
links". **That was wrong**, and it was asserted from reading the `:DOWN` handler in
`channel.ex` without opening `async.ex`. LiveView does *both*: `Task.start_link/1`, a
monitor on top for result delivery, and the work wrapped in
`try/after Process.unlink/1` so the child unlinks before it dies. The link reaps the
child when the parent goes; the unlink stops the child taking the parent with it.
Handling one direction and not the other is worse than handling neither.

`Probe` now does the same, and unlinks *before* killing at the deadline (`:kill` is
untrappable, so the check cannot unlink itself and the link would carry `:killed`
straight back). The check also waits for a go-ahead, so it cannot finish — or die —
before the monitor is in place.

## BUG - HIGH (found and fixed): the check said yes when it should have said no

- **Blank region silently probed us-east-1.** `has_credentials?/1` for
  `:key_secret` only checked `access_key`, so a region-less SES connection reached
  the validator; ExAws defaults a missing region to us-east-1 and the check went
  **green** — while the send path builds `email..amazonaws.com` from the same
  blank region and raises inside Swoosh. The gate now requires every field the
  provider declares `required: true`, and the validator refuses a blank region
  outright. Live: `get_credentials` on such a connection now returns
  `{:error, :not_configured}` instead of crashing at send time.
- **Fail-open to `verify: :verify_none` when no CA store is found.** Latent in dev
  (this container has 150 CA certs) and fires exactly where nobody is looking:
  minimal production images. Sender *and* check would then trust any certificate,
  and the check would still show green. A relay that expects a password now
  **fails closed** (`:no_ca_store`); only a credential-less relay degrades.

## BUG - MEDIUM (found and fixed): the check said no when it should have said yes

- **`auth: :always` rejected relays that advertise no `AUTH` verb** (internal
  smarthosts authenticating by IP). Sending works there; the check went red, and
  the operator could not avoid it because `username`/`password` are required
  fields. gen_smtp throws `{:missing_requirement, _, :auth}` for exactly that
  case; it is now a pass. Relays that *do* advertise AUTH still fail closed on a
  bad password — `auth: :always` is required for that: with gen_smtp's default the
  AUTH exchange fails *tolerantly* (`gen_smtp_client.erl:605-613`), so a wrong
  password would still open a session and the check would lie.
- **SES `AccessDenied` was reported as "Invalid credentials".** The least-privilege
  policy AWS itself recommends (grant only `ses:SendEmail`) cannot read the send
  quota, so a correctly configured integration got a permanent red cross — which
  teaches operators to ignore the check. The XML `<Code>` is now decoded:
  signature/token errors → invalid credentials; throttling → "busy, try again";
  anything else surfaced verbatim.

  The first cut then passed `AccessDenied` with a "note" that went only to
  `Logger.info` — so the operator saw a bare **"Connection verified"**, and
  `AccessDenied` proves only that the signature is valid for *some* AWS principal: a
  key from the wrong account lands there too. That is this branch's own thesis
  reopened at the one door it had closed, and the final round was right to call it.
  A check can now pass **with something to say** (`{:ok, note}` alongside `:ok`): the
  connection is connected and sends exactly as before, but the caveat is stored in
  `validation_status` and rendered next to the badge — "Connection verified —
  credentials are valid, but not authorised for GetSendQuota; sending was not
  verified". Which is the whole truth, and what an operator needs to decide whether
  to care.
- **A valid key could be reported invalid.** Found live: after AWS rejects a bad
  signature, a *correct* request from the same key comes back
  `SignatureDoesNotMatch` for a moment — precisely what an operator produces by
  pasting a wrong key, fixing it, and pressing Test again. An "invalid credentials"
  verdict is now confirmed with a second attempt. The adversarial sequence went
  from intermittently red to 6/6 green.

## BUG - LOW (found and fixed): the check lost the operator's language

Gettext keeps the locale in the process dictionary, which a spawned process does
not inherit. Errors rendered *inside* the check came back in the default language
while errors rendered in the caller ("Region is required", "Invalid port") came
back translated, so the operator saw a mix. `Probe` now carries the locale across
explicitly. A reply landing in the instant the deadline fires is also flushed —
the caller is a LiveView and would log the stray as an unexpected message.

## The root cause of both late findings: the new logic was the untested logic

Neither the shipped crash nor the leak was caught by a green gate, and the reason is
the same in both cases — the code they lived in could not be tested as written. Fixed
at the root, not patched around:

- The **CA store is a parameter** of `SmtpTransport.config/2`. It was always a pure
  function of (credentials, CA store); the store was merely ambient. The fail-closed
  branch — the security-critical one, which fires only on images nobody is watching —
  is finally reachable from a test.
- **`request_send_quota/3` takes its requester**, so the confirm-retry (the behaviour
  that keeps a *valid* key from being called invalid) is tested without AWS.
- **`interpret_ses_error/1` is pure and public**, so the mapping from an AWS error
  body to an operator-facing verdict is tested against real SES codes.
- A **fake relay that greets and advertises no `AUTH` verb** proves the
  `{:missing_requirement, _, :auth}` carve-out, which had been asserted and never run.
- `Probe`'s tests now run in **both directions** — the asymmetry (five tests for
  "check dies, caller survives", none for "caller dies, check is reaped") is precisely
  why the leak survived the fix.

## Also fixed in the final round

- `send_quota_request/2` rescued but did not `catch :exit`; hackney reaches its pool
  through `GenServer.call`, which exits.
- The check no longer inherits gen_smtp's default `{retries, 1}`
  (`gen_smtp_client.erl:38`), which probed a temporarily-failing relay twice and could
  push a slow failure past our own deadline — the operator would be told "did not
  respond in time" instead of what actually went wrong. A real send still wants the
  retry; a check does not.
- `InvalidAccessKeyId`, `ExpiredToken` and `TokenRefreshRequired` are invalid
  credentials, not "AWS SES error: `<code>`", and now go through the confirm-retry.
- The confirm-retry waits a full second: SES throttles GetSendQuota at roughly one
  request per second and the retry doubles our rate against it, so a genuinely invalid
  key could come back as "AWS SES is busy".
- The tarpit test leaked its acceptor — `spawn_link` plus a `:normal` test exit does
  not propagate, so the acceptor, its listener and the accepted socket outlived every
  run for the life of the VM.

## Structure

The transport lives in `PhoenixKit.Mailer.SmtpTransport` — a pure function of the
credentials map, depending on nothing. `Mailer` and `Validators` both use it, so
*tested* and *sent* are literally the same options, and the
`Integrations → Validators → Mailer → Integrations` cycle is gone. The deadline
harness lives in `PhoenixKit.Integrations.Probe` for the same reason: as a module
rather than a private helper, its concurrency semantics can actually be tested — and
the round that caught the leak proves how much that mattered.

## Upgrade note (CHANGELOG)

Two of these fixes change the **send** path, not just the check:

- **SMTP sending now stops on images with no CA bundle** (`{:error, :no_ca_store}`)
  instead of proceeding with certificate verification disabled. Slim base images
  (distroless, scratch, some Alpine builds) are affected: install `ca-certificates`.
  A relay configured with no credentials still degrades rather than failing.
- **Configured relays are no longer MX-resolved** (`no_mx_lookups: true`). If you set
  `host` to a bare domain and relied on MX resolution, point it at the relay itself.

## Gate

`86 → 107 tests, 0 failures` in the affected suites. `--warnings-as-errors`,
`credo --strict`, `dialyzer` and `mix docs` clean. Dialyzer earned its keep three
times: twice on dead clauses whose types had narrowed during the rework, and once on
the one place the pass-with-note widening had not reached — `record_validation/2`'s
contract silently narrowed the result at the call site, which made the new clause
unreachable.

The full suite gains no failures: every failure in it also fails without this branch,
and the handful that differ run-to-run pass in isolation (pre-existing sandbox
contention — `Activity.log/1` raises `DBConnection.OwnershipError` on `main` too).

Live, against a real relay and a real SES account:

```
SES real          => :ok              SMTP real          => :ok
SES bad secret    => Invalid creds    SMTP bad password  => Invalid creds
SES blank region  => Region required  SMTP unreachable   => Could not reach
SEND via smtp integration  => {:ok, "2.0.0 OK: queued as <...>"}
SEND via SES (legacy path) => {:ok, %{id: "0110019f5fbc3ce7-..."}}
```

Timings, all far inside the 15s deadline: SES wrong key 1.7s (including the
confirm-retry), SES valid 1.1s, SMTP wrong password 0.6s, SMTP valid 0.3s.
