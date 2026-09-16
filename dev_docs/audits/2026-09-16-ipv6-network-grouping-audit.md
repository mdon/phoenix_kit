# IPv6 `/64` grouping — review of `04084d93`

**Date:** 2026-09-16 · **Author:** Grok · **Trigger:** review of
`04084d93` ("Fix IPv6 handling: group clients by /64 for rate limits and
IP checks"), then the follow-up fixes in the same tree.

## What the commit did

`PhoenixKit.Utils.IpAddress.network/1` is the key/comparison for a visitor,
not the stored or displayed address:

- per-IP auth rate limits (login, registration, magic link, password reset,
  confirmation resend, QR login, referral codes)
- session-fingerprint IP matching
- known-device reuse on login alerts
- Active Sessions enrichment

Full addresses still go into tokens, known-device rows, activity metadata,
geolocation, and log lines. IPv4 is unchanged. IPv4-mapped IPv6
(`::ffff:a.b.c.d`) unmaps to the IPv4 address before comparison. The tests
added in `04084d93` fail without the production change.

That split is correct. The rest of this note is about the gaps.

## Verdict

No correctness bugs in the intended `/64` SLAAC/privacy path. Three
suggestions were worth fixing in the follow-up (special prefixes, indexed
known-device lookup, missing tests/docs). Two remain, both blocked on a
schema column: known-device identity at the database layer, and
website-access lockout.

## Findings

### 1. Known-device identity is still exact-IP in the database — remaining

**Severity:** suggestion · **File:** `lib/phoenix_kit/users/auth/known_device.ex:58`
(unique on `(user_uuid, ip_address, user_agent_hash)`),
`lib/phoenix_kit/users/login_alerts.ex` (`matching_device/3`)

Reuse is “same `/64` + same UA” in Elixir. Persistence is still unique on
the exact address. Two concurrent logins from different temporary addresses
in the same `/64` both miss, both insert, and the table keeps growing. A
match only bumps `last_seen_at`; it never writes a canonical network key.

**Follow-up (needs a migration):** persist `IpAddress.network/1` (generated
column or explicit field), unique-index `(user_uuid, network,
user_agent_hash)`, and `get_by` that key. Keep storing the full
`ip_address` for display/geo/audit. On match, update `last_seen_at` (and
optionally the current address). That closes the race, restores an indexed
lookup, and lets a later cleanup fold pre-change IPv6 rows.

**Done in the follow-up (no migration):** `matching_device/3` hits the
unique index first and only scans same-UA rows by `/64` when grouping is
coarser than the address (IPv4 cannot match a different stored address, so
a miss is a miss). Several legacy IPv6 rows that share a `/64` now pick the
most recently seen one (`order_by: [desc: last_seen_at]`).

### 2. `network/1` over-grouped special IPv6 prefixes — fixed

**Severity:** suggestion · **File:** `lib/phoenix_kit/utils/ip_address.ex`

Every 8-tuple that was not IPv4-mapped was truncated to
`{a,b,c,d,0,0,0,0}/64`. That is right for SLAAC/privacy addresses and wrong
for prefixes that are shared by many hosts by definition:

| Input | Before | After |
|---|---|---|
| `::1` | `"::/64"` (collides with unspecified and `::a.b.c.d`) | `"::1"` |
| `::` | `"::/64"` | `"::"` |
| `fe80::1` | `"fe80::/64"` (the whole link-local LAN) | `"fe80::1"` |
| `64:ff9b::203.0.113.7` | `"64:ff9b::/64"` | `"203.0.113.7"` |
| `::203.0.113.7` | `"::/64"` | `"203.0.113.7"` |
| `::ffff:203.0.113.7` | `"203.0.113.7"` (already) | `"203.0.113.7"` |

Loopback is usually rewritten via XFF when `local?/1` is true, so the
practical hit was LAN/link-local deploys and any proxy that presents NAT64.

**Fix:** loopback, unspecified, and `fe80::/10` are the address itself.
Well-known NAT64 (`64:ff9b::/96`) and deprecated IPv4-compatible
(`::a.b.c.d`) unmap to the embedded IPv4, same as mapped addresses.

### 3. Website-access lockout still counts the full address — remaining

**Severity:** suggestion · **File:** `lib/phoenix_kit/website_access/gate.ex:358`
(advisory lock) and `:427` (`a.address == ^address`)

Auth IP limits now count by `/64`, but the website-access gate still locks
and counts on the exact string. An IPv6 client that can pick a fresh
address per request — the failure mode `04084d93` fixes for
login/registration/mail/QR — still walks the gate lockout one try at a
time.

Attempts should keep storing the full address (audit). Only the count/lock
key needs `network/1`. Naive `a.address == ^network` will not match rows
that already stored the full IPv6 address, so this needs a `network` column
(or equivalent) on `phoenix_kit_access_attempts`, same shape as finding 1.

Skip this if lockout is deliberately exact-IP. The setting copy talks about
“a whole office shares one address”, which for IPv6 is the `/64`.

### 4. `/64` sharing was only asserted on the QR limiter — fixed

**Severity:** suggestion · **File:** `test/phoenix_kit/users/rate_limiter_test.exs`

Login, registration, and the mail `charge_ip/4` path all got the same
`network/1` wiring in `04084d93` with no test that would fail if someone
reverted only those call sites. Active Sessions enrichment was untested for
a token IP that differs from the known-device IP inside the same `/64`.
Login-alerts covered reuse of one `/64`, not “a different `/64` still
inserts a row”.

**Fix:**

- login IP bucket spray (`check_login_rate_limit/2`)
- mail IP bucket spray (`check_password_reset_rate_limit/2` → `charge_ip/4`)
- sessions-device: known device at `2001:db8:1:1::1`, session token at
  `2001:db8:1:1::2`, same UA → location attaches; `2001:db8:1:2::1` does not
- login-alerts: a second `/64` still creates a second row
- `network/1` unit cases for `::1`, `::`, `fe80::1`, `::203.0.113.7`,
  `64:ff9b::203.0.113.7`

### 5. Moduledocs still described identity as exact `(ip, ua)` — fixed

**Severity:** nit · **File:** `lib/phoenix_kit/users/login_alerts.ex`,
`lib/phoenix_kit/users/auth/known_device.ex`

Match is `(network, user_agent_hash)` via `IpAddress.network/1`. The stored
`ip_address` remains the full address. IPv4 still creates one row per
address. Docs now say that.

## What was verified

Unit: `test/phoenix_kit/utils/ip_address_network_test.exs`,
`test/phoenix_kit/users/rate_limiter_test.exs`,
`test/phoenix_kit/utils/session_fingerprint_ip_test.exs` — 44 tests, 0
failures.

Integration (PostgreSQL): `test/integration/users/login_alerts_test.exs`,
`test/phoenix_kit/users/sessions_device_test.exs` — 31 tests, 0 failures.

`mix credo --strict` on the touched library files: no issues.

## Open follow-ups

Both need a versioned, prefix-safe migration. Do not fold them into a
drive-by:

1. `phoenix_kit_user_known_devices.network` + unique
   `(user_uuid, network, user_agent_hash)`, keep `ip_address` for
   display/geo/audit, backfill, fold duplicate `/64` rows.
2. `phoenix_kit_access_attempts.network` (or equivalent), lock and count on
   it, keep storing the full client address on the attempt row.
