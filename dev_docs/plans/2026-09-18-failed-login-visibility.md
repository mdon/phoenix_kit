# Failed sign-in attempts — record them, and show them to the two people who care

**Created:** 2026-09-18
**Status:** SCOPE ONLY — nothing built. Written after an audit of what core
does with a wrong password today.
**Scope:** phoenix_kit (core).
**Related:** `PhoenixKit.Users.LoginAlerts` and its moduledoc (the new-device
alert this builds beside), `dev_docs/guides/2026-07-28-login-and-registration.md`.

Line numbers below are as of commit `d71a4062`.

---

## What happens today

Nothing is persisted. A wrong password produces a flash and a redirect.

| Path | What it does with a failure |
|---|---|
| `Auth.get_user_by_email_or_username_and_password/3` (`auth.ex:210`) | returns `{:error, :invalid_credentials}`; writes nothing |
| `Session.create/2` (`session.ex:110`) | `put_flash` + `redirect`; writes nothing |
| `Activity` | no `user.login_failed` action exists |
| Database | no login-attempts table exists |

The only trace is the rate limiter, and it is weaker than it looks:

- Counters live in **ETS** via Hammer (`rate_limiter.ex:1-6`) — in-memory,
  node-local, gone on restart, not queryable.
- It counts **every** attempt, not just failures: `check_login_rate_limit/2`
  runs *before* credentials are checked. (Side effect: five *successful*
  logins in a minute lock the account out. The comment at `auth.ex:175`
  claiming the counter is incremented on the failure branch is misleading —
  it was already incremented on both.)
- Only a bucket **overflow** emits anything, one `Logger.warning` from
  `log_rate_limit_violation/4` (`rate_limiter.ex:702`). Attempts 1–5 leave no
  trace at all.
- On a multi-node deploy the ETS backend is node-local, so the effective
  limit is 5 × nodes per email.

**Neither the targeted account holder nor the site owner can see any of it.**
The Active Sessions list and the new-device email both describe only
*successful* sign-ins.

### The case that motivates this

An attacker guesses correctly on attempt 400. The only thing core sends is the
new-device email, which reads exactly like "I signed in from my new laptop."
The 399 failures that preceded it are the one signal that distinguishes the
two, and we discard them. A patient attacker (4/minute, or spread across IPs)
never trips the limiter either, so they generate zero log lines.

---

## Design

### Why not the activity feed

`phoenix_kit_activities` is the obvious reuse — it already has the admin UI,
retention, prune worker and notification hook. It is the wrong shape here:

- **Volume.** Entries are insert-only, so a brute-force run writes one row per
  attempt. Debouncing would need read-then-update, which is racy under exactly
  the concurrency an attack produces.
- **Purpose.** The feed is a business audit trail (`user.registered`,
  `role.assigned`). Attack telemetry has a different retention, a different
  reader and a different volume profile.

### The table

Aggregated **at write time**, so the row count is bounded by
(accounts × IP networks × hours) rather than by attacker effort.

```
phoenix_kit_login_attempts
  uuid             uuid        pk, default uuid_generate_v7()
  user_uuid        uuid        null, FK -> phoenix_kit_users(uuid) ON DELETE CASCADE
  ip_address       text        not null   -- full address, for display
  ip_network       text        not null   -- IpAddress.network/1, the grouping key
  user_agent_hash  text        null
  browser          text        null
  os               text        null
  outcome          text        not null   -- invalid_credentials | rate_limited | inactive
  attempt_count    integer     not null default 1
  bucket_start     timestamptz not null   -- date_trunc('hour', now())
  first_at         timestamptz not null
  last_at          timestamptz not null

  unique (user_uuid, ip_network, outcome, bucket_start)
```

Write is a single `INSERT … ON CONFLICT (…) DO UPDATE SET attempt_count =
attempt_count + 1, last_at = EXCLUDED.last_at`. One statement, no read, no
lock contention, attack-proof.

`user_uuid` is `NULL` when the attempted identifier matched no account.

### What is NOT stored, and why

**The attempted identifier, when it matches no account.** Storing it would
mean core holds email addresses of people who have no relationship with the
install, harvested from attacker-supplied input — a GDPR liability created by
a security feature. It is also unbounded attacker-controlled text.

A no-match attempt still records its IP network and a count, which is the part
anyone acts on ("this IP is spraying us"). Knowing *which* non-existent
addresses were guessed is not actionable.

When the identifier **does** match an account, `user_uuid` is the reference —
we already hold that address.

### Where the write hooks in

`Session.create/2` (`session.ex:110`), not `Auth`. The conn is in scope there,
which is what supplies the user agent and the client IP
(`IpAddress.extract_from_conn/1`, already called at `session.ex:81`), and it
keeps `Auth` free of Plug. `Auth` would also have to distinguish "no such
user" from "wrong password" to set `user_uuid`, which it currently collapses
into one return value on purpose.

**This covers the password form only.** Magic link, QR login and OAuth have
their own failure modes and are out of scope for a first pass — noted here so
the omission is deliberate rather than forgotten.

### Non-negotiables

- **Must never block sign-in.** Same discipline as `LoginAlerts.check/2`
  (`login_alerts.ex:88-95`): `rescue` **and** `catch :exit` — an unreachable
  DB raises on an unowned checkout but *exits* on a dead pool.
- **Must not become an account-existence oracle.** The write path runs on
  both branches and the response is unchanged; only what is stored differs.
  The generic flash copy at `session.ex:113` stays exactly as is.
- `use PhoenixKit.SchemaPrefix` immediately after `use Ecto.Schema` —
  enforced by `test/phoenix_kit/schema_prefix_test.exs`.
- Prefix-safe migration per `dev_docs/guides/2026-07-27-prefix-safe-migrations.md`:
  bare index names on CREATE, schema-anchored existence checks,
  `Helpers.uuid_v7_call/1` for the default.
- The new migration (**V197**; latest is V196) restamps the expected-schema
  manifest — see `project_expected_schema_manifest_blocks_release` — which
  blocks a release until done.

---

## Phases

### Phase 1 — record

Migration V197, `PhoenixKit.Users.LoginAttempts` context, the write hook, and
retention.

- Setting `login_attempt_logging_enabled`, **default `true`**. Unlike
  `new_login_alert_enabled` (default `false`, because it sends mail), this only
  writes a bounded row and is useless if off by default.
- Setting `login_attempt_retention_days`, default `90`, matching
  `activity_retention_days`. Daily `PruneWorker` alongside the existing two.
- No UI. Ships the data so the later phases have something to read.

### Phase 2 — tell the account holder

1. **A line in the existing new-device email.** "There were also 12 failed
   sign-in attempts on your account since your last successful sign-in."
   Cheapest high-value change in the whole plan: the email already exists and
   already reaches the right person at the right moment. This is what
   distinguishes the compromise case from a new laptop.
2. **A threshold alert.** A new email when an account crosses N failures in a
   window (suggest ≥10 in 1h), gated by `failed_login_alert_enabled` (default
   `false` — it sends mail) and capped to one per account per 24h so the alert
   itself is not an amplification vector. Send synchronously, like every other
   auth email.
3. **The user's own security page** gains a recent-failures list.

### Phase 3 — tell the site owner

- `/admin/users/sessions` gains a "Failed attempts (24h)" stat tile and a
  table grouped by account and by IP network.
- Optionally a `security`-type notification to admins when one account crosses
  the threshold. `Notifications.Types` already has the `"security"` key
  (`types.ex:174`) — a new action string is added to its `actions` list so the
  per-user preference filter keeps working.

---

## Costs worth knowing before starting

- **Any new copy means the seven-locale gettext round-trip**, including
  hand-checking the fuzzy carryover. A single new msgid fuzzy-matched onto a
  wrong neighbour twice in one day on 2026-09-18.
- **Phase 1 touches the schema**, so `mix test` must be run against a real
  database. A database-less run excludes every `:integration` test and still
  exits 0 — a green summary proves nothing about a migration.
- **`test/integration/prefix_migration_test.exs`** runs the whole chain into a
  scratch schema and is the oracle for the prefix rules; bad SQL queued by one
  version often only blows up at a later version's `flush()`.

## Open questions for the maintainer

1. **Threshold and window** for the Phase 2 alert. 10-in-1h is a guess; the
   right number depends on how noisy real installs are, which Phase 1 answers.
   Phase 1 shipping alone for one release is a reasonable way to find out.
2. **Should a locked-out account (`rate_limited`) notify immediately**,
   separately from the count threshold? It is a stronger signal than N
   failures, and rarer.
3. **Is the no-match identifier worth keeping after all?** The argument for is
   "someone is hammering `admin@`, and I want to see that". The argument
   against is above. A middle path is storing a truncated hash, which supports
   "the same unknown identifier, repeatedly" without holding the address.
