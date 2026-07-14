# PR #636: SMTP provider could not send at all (missing TLS options); Test Connection validated nothing

**Author**: @timujinne
**Reviewer**: Opus agents, two independent lenses (code + architecture/security), three rounds
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

> **On the reviewer**: GLM-5.2 — our usual reviewer — returned 529 for the whole
> of this work, so rounds 1–2 were reviewed by two independent Opus agents. The
> architecture reviewer then hit a hard billing limit mid-run, so **round 3's
> findings are the author's own**, verified the same way the others were: by
> experiment against the running dev app, and by reading `gen_smtp`, `ex_aws`,
> `swoosh` and `phoenix_live_view` rather than trusting recollection. Stating
> that plainly beats implying a review that did not happen.

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
  signature/token errors → invalid credentials; `AccessDenied` → pass with a note;
  throttling → "busy, try again"; anything else surfaced verbatim.
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

## Structure

The transport lives in `PhoenixKit.Mailer.SmtpTransport` — a pure function of the
credentials map, depending on nothing. `Mailer` and `Validators` both use it, so
*tested* and *sent* are literally the same options, and the
`Integrations → Validators → Mailer → Integrations` cycle is gone. The deadline
harness lives in `PhoenixKit.Integrations.Probe` for the same reason: as a module
rather than a private helper, its concurrency semantics can actually be tested.

## Gate

`93 tests / 0 failures` in the affected suites. `--warnings-as-errors`,
`credo --strict`, `dialyzer` and `mix docs` clean. Dialyzer twice caught dead
clauses whose types had narrowed during the rework.

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
