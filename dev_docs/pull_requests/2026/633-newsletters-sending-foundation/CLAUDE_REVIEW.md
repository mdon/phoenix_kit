# PR #633: Phase 1 "Sending Foundation" — Integrations-backed email credentials, per-integration delivery, V145

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, ready to merge
**Date**: 2026-07-13

## Goal

Moves all email credentials into `PhoenixKit.Integrations` (encrypted, keys
only) and adds a delivery path (`Mailer.deliver_via_integration/3`) that can
send through any configured integration — `aws_ses`, a universal `smtp`
provider (one connection per vendor/account), or `brevo_api`. Core half of a
three-repo change; `phoenix_kit_emails` and `phoenix_kit_newsletters` both
depend on code introduced here and will not compile against any currently
released `phoenix_kit`.

## Renumbered V143 → V145 (same-day collision, third PR)

This PR also originally claimed V143 — the third same-day PR to do so (after
the now-merged new-login-alerts and manufacturing/warehouse-consolidation
PRs, which took V143 and V144 respectively). Rebased onto current `main` and
renumbered throughout: module name, moduledoc prose, `COMMENT ON TABLE`
version markers on `up/1` (→ `'145'`) and `down/1` (→ `'144'`, the new
immediately-prior version), the `postgres.ex` moduledoc entry (now the
`⚡ LATEST` block, ahead of V144 and V143) and `@current_version` (145). Also
renamed `test/phoenix_kit/migrations/v143_test.exs` →
`v145_test.exs` (module name + the version-marker assertion). Otherwise pure
renumbering — no DDL or logic touched by the rename itself.

## BUG - MEDIUM (found and fixed)

**`uuid_generate_v7()` unqualified in the migration's `CREATE TABLE` default
— the exact bug class fixed elsewhere in the same day's prefix-hardening
work (PR #631's V26 fix) and present in every sibling migration
(`#{p}uuid_generate_v7()`), but missed here.** The original:

```elixir
uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
```

has no schema qualification at all — not even `#{p}` like every other
migration in this chain uses. Per `PhoenixKit.Migrations.Postgres.Helpers`'
own documented rule: an unqualified `uuid_generate_v7()` call resolves via
the *connecting role's* `search_path` at execution time, not the install's
own schema — on the hardened multi-schema scenario the whole PR631
prefix-hardening effort targeted (a DBA-pre-created prefix schema outside
the connecting role's default `search_path`), this call would either fail
outright (`function uuid_generate_v7() does not exist`) or — worse — silently
resolve to a *different* schema's function if one happens to be visible via
`search_path`. Public-schema installs never hit this (their `search_path`
always includes `public`), which is presumably how it shipped unnoticed —
the new `v145_test.exs` doesn't exercise a prefixed install either, so
ordinary tests wouldn't have caught it.

**Fixed:** added `alias PhoenixKit.Migrations.Postgres.Helpers`, threaded
the raw `prefix` value through `up/1` alongside the existing `p` (bare-vs-
dot-qualified string), and changed the default to
`#{Helpers.uuid_v7_call(prefix)}` — the current canonical helper for this
exact purpose.

## Independent verification of the PR's own security-fix claims

The PR body describes two "behavior change" items as intentional fixes, not
regressions. Verified both against the actual code rather than trusting the
description:

- **Encryption key fallback (`encryption.ex`).** Claim: the installer never
  sets `config :phoenix_kit, secret_key_base:`, so `encryption_key/0`
  previously always returned `nil` and every integration secret was stored
  in plaintext; the fix falls back to the host app's own Endpoint
  `secret_key_base`. Confirmed `PhoenixKit.Config.get_parent_endpoint/0`
  exists (`config/config.ex:424`), returns `{:ok, module()} | :error`
  exactly as the new `endpoint_secret_key_base/0` assumes, and the
  `rescue _ -> nil` around it fails safe (early boot / endpoint not yet
  configured → no key → `enabled?()` false, same as the pre-existing
  behavior, not a new crash path). Traced `do_encrypt_fields/2`/
  `do_decrypt_fields/2`: a value without the `enc:v1:` prefix passes
  through unchanged on read and gets encrypted on the next write — matches
  the "plaintext values still read back fine, re-encrypted on next save"
  claim. AES-256-GCM with a fresh random 12-byte IV per encryption and a
  16-byte auth tag — correct authenticated-encryption usage. The KDF
  (single SHA-256 over a domain-separated string, not PBKDF2) is
  acceptable-if-imperfect for this purpose and is now accurately documented
  (previously claimed PBKDF2, which was simply wrong) rather than a new
  weakness introduced here.
- **SMTP TLS selection (`mailer.ex`).** Claim: gen_smtp picks the wire
  protocol solely from the `ssl` option, so port 465 (implicit TLS) needs
  `ssl: true` — `tls: :always` on 465 would open a *plaintext* socket to an
  SMTPS port and hang. I can't verify the cited gen_smtp source line
  directly in this environment, but the underlying claim matches standard,
  well-established SMTP protocol behavior (SMTPS/465 = TLS-wrapped from
  connection start; STARTTLS/587 = plaintext connect, then upgrade) and the
  code's branching (`smtp_transport(465, _)` → `[ssl: true]`; other ports →
  `tls: :always` when credentials are present, `:if_available` when they
  aren't) is internally consistent with that model and fails closed (never
  silently downgrades a credentialed connection to plaintext).
- **Recipient blocklist gating.** `check_recipient_allowed/1` runs before
  `Provider.current().intercept_before_send/2` in both `deliver_email/2`
  and `deliver_via_integration/3` — the single chokepoint both delivery
  paths share. Soft-dependency pattern (`Code.ensure_loaded?/1` +
  `function_exported?/3` + `apply/3`, with the `credo:disable-for-next-line`
  explaining why direct module-attribute dispatch would fail
  `--warnings-as-errors` when the optional `emails` package isn't a
  dependency) matches this codebase's established convention for genuinely
  optional integrations. Fails open on a blocklist-check error (logs and
  allows the send) — deliberate and documented ("a transient DB hiccup must
  not take delivery down"), consistent with this codebase's other
  fail-open checks (e.g. `Notifications.Prefs.user_wants?/2`).

No further findings in `providers.ex`/`integrations.ex`'s
`has_flat_credential_fields?/2` gate — the empty-required-list footgun is
explicitly guarded, and numeric setup fields (SMTP `port`) are handled via
`field_present?/1` rather than the binary-only `present?/1`.

## Testing

- `mix compile --warnings-as-errors` — clean, on the merged (with `main`)
  branch.
- `mix test test/phoenix_kit/mailer_test.exs test/phoenix_kit/integrations/
  test/phoenix_kit/migrations/v145_test.exs` — 42 tests, 0 failures (36
  correctly excluded as `:integration`, no PostgreSQL in this environment).
- `mix precommit` (format, `compile --warnings-as-errors`, `credo --strict`,
  dialyzer) — see commit for result.
- `test/integration/prefix_migration_test.exs` (the chain's oracle for the
  exact bug class fixed above) is `:integration`-tagged and wasn't run here
  — no PostgreSQL reachable in this environment. Worth a manual check
  against a real prefixed install before the next prefix-hardening pass,
  per this repo's own documented gap in that area.

## Related

- Bug class / fix precedent: PR #631 (`dev_docs/pull_requests/2026/
  631-prefix-hardening-low-privilege-installs/CLAUDE_REVIEW.md`), the same
  `uuid_generate_v7()` qualification issue in V26.
- Migration: `lib/phoenix_kit/migrations/postgres/v145.ex`
- Same-day V143/V144 collisions: PR #632
  (`dev_docs/pull_requests/2026/632-manufacturing-warehouse-tables-consolidation/`)
