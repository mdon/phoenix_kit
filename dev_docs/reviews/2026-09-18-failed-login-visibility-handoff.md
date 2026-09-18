# Review handoff — failed sign-in recording and visibility (2.31.0)

**For:** a second reviewer, working from the repo.
**Author of the change:** Claude (Opus 5), 2026-09-18.
**Design record:** `dev_docs/plans/2026-09-18-failed-login-visibility.md` — read
that first; it carries the reasoning, the maintainer's answers to the open
questions, and the departures from the plan.

## What to review

Three commits on `main`, unreleased as **2.31.0**. Range `323434d3..HEAD`.

```
f1e827f7  Phases 2+3 — visibility (email line, threshold alert, user page, admin panel)
facd81b7  Rate limiter fix (deliberately its own commit)
12af4a01  Phase 1 — V197 + LoginAttempts + write hook + retention
323434d3  The scope doc it was built from
```

39 files, but roughly 2,800 of those lines are the generated expected-schema
manifest and the seven PO catalogues. The code worth reading is:

| File | What |
|---|---|
| `lib/phoenix_kit/migrations/postgres/v197.ex` | the table |
| `lib/phoenix_kit/users/login_attempt.ex` | schema |
| `lib/phoenix_kit/users/login_attempts.ex` | context: record, read, alert, prune |
| `lib/phoenix_kit/users/rate_limiter.ex` | the peek/record split |
| `lib/phoenix_kit/users/auth.ex` | two failure branches now count |
| `lib/phoenix_kit_web/users/session.ex` | the write hook, three branches |
| `lib/phoenix_kit/users/auth/user_notifier.ex` | count line + the new alert email |
| `lib/phoenix_kit_web/live/users/sessions{.ex,.html.heex}` | admin panel |
| `lib/phoenix_kit_web/live/components/user_settings.ex` | the account holder's list |
| `test/integration/users/login_attempts_test.exs` | 36 tests |

## The problem it solves

Core persisted nothing about a wrong password: no row, no activity entry,
nothing either the targeted account holder or the site owner could see. The
only trace was Hammer's ETS counter — node-local, lost on restart, counting
successes too, and silent until a bucket overflowed.

The motivating case: an attacker who guesses right on attempt 400 triggers only
the new-device email, which is indistinguishable from "I signed in from my new
laptop". The 399 failures before it are the signal that tells them apart.

## Already verified — please don't spend the time re-deriving it

- `mix test` — **5778 tests, 0 failures** (real database, integration included)
- `mix precommit` — exit 0 (compile as errors, deps.unlock, test.compile,
  format, credo --strict, dialyzer, JS tests)
- `mix phoenix_kit.release_check` — every gate passes but clean-tree
  (V135..V197 contiguous over 63 files, chain_hash matches)
- `test/integration/prefix_migration_test.exs` — the whole chain into a named
  schema
- `mix gettext.merge priv/gettext` a second time — 0 new / 0 removed /
  0 reworded across all 24 catalogues
- `mix gettext.extract --check-up-to-date` — exit 0
- All seven translated locales at **0 fuzzy**, untranslated unchanged at the
  pre-existing 72 (de/es/fr/it/pl) and 69 (et/ru)

## Where to look hardest

### 1. The dedup key changed from what the plan said

`login_attempts.ex:144`. The plan specified
`(user_uuid, ip_network, outcome, bucket_start)`. That does not work:
`user_uuid` is NULL for exactly the rows an attacker generates most of, and
NULL never equals NULL in a Postgres unique index, so `ON CONFLICT` would have
silently stopped deduplicating them. `identifier` is NOT NULL and carries the
key instead.

**The cost, accepted by the maintainer:** the aggregation bound holds *per
identifier*, not across them. An attacker spraying distinct addresses writes
one row each — bounded by the rate limiter in front (`login_limit * 3` per IP
network per minute, so roughly 900 rows/hour/network at defaults) and by
retention, but weaker than the plan's bound.

**Questions:** is that bound good enough? Is keying a unique index on
attacker-controlled text acceptable?

### 2. An extra query per failed login

`login_attempts.ex:162`. `Auth` deliberately collapses "no such user" and
"wrong password" into one return value, so the context re-looks-up the user to
set `user_uuid`.

I argue this is *why* it is not a timing oracle — both branches that share the
generic flash do identical work. But it is a second indexed query on an
unauthenticated endpoint. Worth a second opinion.

### 3. The alert cooldown's read-then-write

`login_attempts.ex:231-254`. Stored in `custom_fields` via
`Auth.merge_user_custom_fields/3`, stamped **before** the send so a raising
send still burns the cooldown.

The activity feed was the other candidate and was rejected: it is
`Code.ensure_loaded?`-guarded elsewhere in this same subsystem, and a missing
module would have disabled the *cap* rather than the feature — turning the
alert into an amplification vector against the person being attacked.

**Question:** does `alert_due?` → `stamp_alert` race badly enough under
concurrent failures to matter? Worst case should be one duplicate email, not a
flood, but please check that reasoning.

### 4. The rate limiter split weakens the pre-auth gate

`rate_limiter.ex:201`, `:241`, `:717`. `check_login_rate_limit/2` now peeks;
`record_failed_login/2` fills the bucket from the failure branch in `Auth`.

Two concurrent requests can both pass the peek where `hit` would have denied
one. I believe that is acceptable — failures still count, the limit still
bites — but it is a genuine weakening and deserves a look.

The other buckets (magic link, password reset, registration, upload) still hit
on check, deliberately: those gate a *send*, where every request should count.

### 5. The expected-schema manifest

The 20 objects were emitted from the live catalog rather than transcribed, so
types, positions, opclasses and FK action codes are catalog-exact. Proven with
`PhoenixKit.Migrations.Repair.repair(dry_run: true)` against a database freshly
migrated to V197 reporting **zero** findings mentioning the table — neither a
missing object nor an `:extra_object`, which is the pair that catches a
manifest disagreeing with what the chain builds.

`dev_docs/squash/restamp_chain_hash.exs` explicitly refuses to vouch for a
schema-moving change, and s7/s8 are still P2 stubs, so that was the proof
available. **If there is a better oracle I missed, that is worth knowing.**

## Deferred on purpose, not forgotten

**The admin notification** from Phase 3. `Notifications.Types`' `"security"`
key is a per-recipient preference about things happening to *that reader's
own* account, and `maybe_create_from_activity/1` fires on
`target_uuid != actor_uuid` — which for a failed login means the victim, not
an administrator. There is no `notify_admins` helper anywhere in
`PhoenixKit.Notifications`.

Building one needs decisions that belong to the maintainer: which
administrators, what stops it flooding during an attack, whether it needs its
own preference key. Full reasoning under "Deferred" in the plan doc. The admin
panel already gives an administrator the visibility.

## One regression that nearly shipped, if you want something specific to probe

Adding `{{failed_attempts}}` changed the new-login email body's msgid, so
gettext fuzzy-matched the *old* translation back in — **without the new
placeholder**, in all seven catalogues. The count would have rendered in
English and silently vanished in every other language, with nothing failing.

Restored structurally (anchored to `{{browser_os}}`, not to each locale's
wording) and a test now sends to a German recipient and asserts the
substitution survives. Two sibling carryovers were also wrong and were
rewritten: `%{count} attempt` had arrived as ru *событие* ("event"), and
`Last seen` as *Последняя генерация* ("last generation").

Fuzzy entries are compiled and served by Elixir gettext, so this class of bug
ships silently. Both counts are worth re-checking on any change touching
`priv/gettext`.

## Known-weak spots I would not defend hard

- **Only the password form is covered.** Magic link, QR login and OAuth have
  their own failure modes and record nothing. Deliberate for a first pass,
  stated in the plan, but it means "failed sign-ins" is narrower than the name.
- **`Tried` as a table column header** is terse. The column content makes it
  obvious, but better wording would cost another seven-locale round trip.
- **The 24-hour window** in the email and the admin panel is a choice, not a
  finding. The plan's "since your last successful sign-in" needs a timestamp
  core does not keep.
