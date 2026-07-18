# PR #647: Send profiles into core + Settings → Email Sending + migration V152

**Author**: @timujinne
**Reviewer**: Claude Sonnet 5, four parallel agents (migrations/schemas, mailer/integrations,
LiveViews/components, module wiring) + manual verification of every claim below
**Status**: ✅ Reviewed, one fix applied
**Date**: 2026-07-18

## Goal

Moves Send Profiles from `phoenix_kit_newsletters`-private into core as shared
infrastructure every module can send through, converges the emails/newsletters
settings pages into one core-owned **Settings → Email Sending** page, and ships
migration V152 (send-profiles copy-and-drop, CRM contact list tables, broadcasts
CRM source). 51 files, +5919/-260.

This review split the diff across four independent lenses. Every PR-description
claim was re-verified against the actual code rather than trusted — see "Verified
correct" below for what held up and what was overstated (harmlessly).

## BUG - HIGH (found and fixed): a blank required credential field could crash the mailer with the plaintext secret embedded in the exception message

`Mailer.swoosh_config_for/1` (`lib/phoenix_kit/mailer.ex`) built the Swoosh adapter
config straight from stored `Integrations` credentials with **no presence check**
on the fields Swoosh itself requires:

- AWS SES: `region: creds["aws_region"]` — never checked for blank.
- SMTP: delegated to `SmtpTransport.config/2`, which validates `port` but never
  validated `host` — `relay: creds["host"]` could be `nil`.

`Integrations.has_credentials?/1` trusts a connection's `status` flag
(`"connected"`/`"configured"`) rather than re-checking individual field presence,
so a connection that reached "connected" and was later edited to blank one
required field (host/region) kept resolving via `get_credentials/1` until the next
async re-validation — a window that could run to the full 15s `Probe` deadline (or
longer for any caller of `save_setup/3` that isn't the LiveView).

`deliver_via_integration/3` handed that config straight to
`Swoosh.Mailer.deliver/2`, which does `:ok = adapter.validate_config(config)` with
**no rescue**. `Swoosh.Adapter.validate_config/2` raises `ArgumentError,
"expected [...] to be set, got: #{inspect(config)}"` on any missing/blank required
key — and `inspect(config)` dumps the **entire** keyword list, not just the
offending key. So a blank SMTP `host` raised with the real `password` inlined in
the exception message; a blank AWS `aws_region` raised with the real
`access_key`/`secret` inlined. Any email sent during the stale-status window —
including this module's own auth mail (magic link, password reset) — would take
an uncaught crash whose message leaks the secret to Logger/crash reporting
(Sentry etc.).

**Fix**: `swoosh_config_for/1` now validates all Swoosh-required fields for
non-blankness (`aws_region`/`access_key`/`secret_key` for SES, `api_key` for
Brevo, `host` for SMTP) before building the config, returning
`{:error, {:incomplete_credentials, [String.t()]}}` (field *names* only, never
values) instead of letting Swoosh's own guard raise with secrets inlined.

`SmtpTransport.config/2` itself was deliberately left untouched — it is a pure
function also used by the "Test Connection" probe path, and an existing test
(`"SNI is disabled rather than sent empty when there is no host"`) locks in that
it must keep building valid TLS options with a blank host. The "is this connection
ready to actually send" decision now lives at the `swoosh_config_for/1` call site,
where the secret-bearing config is actually assembled for real delivery.

Regression tests added in `test/phoenix_kit/mailer_test.exs`:
`"aws_ses credentials missing a required field are rejected, not raised"`,
`"smtp credentials with a blank host are rejected, not raised"`,
`"brevo_api credentials with a blank api_key are rejected, not raised"`.

Files: `lib/phoenix_kit/mailer.ex` (`swoosh_config_for/1`, new `require_fields/2`
private helper), `test/phoenix_kit/mailer_test.exs`.

## Verified correct (no action needed)

- **Prefix-safety (V152)** — no violations of the CLAUDE.md rules. All
  `CREATE INDEX` calls use bare names; the one `DROP INDEX` correctly qualifies;
  `table_exists?/3` anchors on `table_schema`; no bare `::regclass` casts, no bare
  `CREATE EXTENSION`/`CREATE SCHEMA`; `uuid_generate_v7()` goes through the
  `Helpers` seam throughout.
- **The uuid-preserving copy-and-drop migration** (`email_send_profiles` created
  in core, copied from the old newsletters table, old table dropped) is correctly
  reversible: `up`/`down` are near-mirror DDL, the shared column list preserves
  the PK verbatim, both are idempotent via `table_exists?` guards, and
  `DROP TABLE ... CASCADE` is safe since the only referencing column
  (`broadcasts.send_profile_uuid`) carries no FK.
- **citext** is properly ensured via `Helpers.ensure_extension!/1` before first use
  in both new call sites.
- **Soft references** (`crm_list_uuid`, `send_profile_uuid`) carry no FK as
  claimed; `phoenix_kit_crm_list_members`'s `list_uuid`/`contact_uuid` correctly
  *do* carry real FKs, since those live in the same module (not a cross-module
  soft ref).
- **`set_default_send_profile/1`**: the PR description calls this "an atomic
  conditional `update_all`" — it's actually two sequential `update_all` calls
  inside a transaction, with the two-tab race closed by the pre-existing partial
  unique index (`idx_email_send_profiles_default`) as the real correctness
  backstop, not atomicity of the update itself. Hand-traced the concurrent
  interleavings; no window leaves two rows (or zero rows) `is_default: true`. The
  fix works — the description just mischaracterizes the mechanism.
  IMPROVEMENT-LOW, description accuracy only, not fixed.
- **`v145_test.exs` shrinking by ~103 lines** is a legitimate refactor, not a
  coverage loss — V152 drops the table V145's tests covered; every assertion
  reappears (expanded) in `v152_test.exs` against the new table name, plus new
  "old table is gone" and copy-semantics assertions.
- **Schema conventions**: `SendProfile` uses `@primary_key {:uuid, UUIDv7,
  autogenerate: true}` and `use PhoenixKit.SchemaPrefix` in the correct position.
- **Iron Law**: `send_profiles.ex` and `integration_form.ex` correctly load data
  in `handle_params/3`, not `mount/3`. **`email_sending.ex` and
  `send_profile_form.ex` do not** — both pipe several DB/decrypt-bearing loads
  (`Settings.get_setting` ×2, `Integrations.load_all_connections/1` — which
  decrypts every email-capable connection, `list_connections/1`) through `mount/3`
  unconditionally, so they run twice per navigation (disconnected HTTP render +
  connected WebSocket). Not a correctness bug (same result both times) but a real,
  silent perf regression against a project rule the PR otherwise follows
  correctly elsewhere (`send_profiles.ex` gets this right in the same PR).
  IMPROVEMENT-MEDIUM — flagged, not fixed in this pass to keep the fix set
  focused on the one exploitable issue; worth a follow-up moving the `assign_*`
  pipeline in both files to `handle_params/3`.
- **Pagination OOM fix**: traced `?page=9999999999`, `?page=-5`, `?page=0`, and
  `total_pages=0` through `pagination_range/2` and `pagination_controls/1` by
  hand — all land on a small, correctly-ordered range; the claimed 10-billion-
  iteration descending Range is no longer reachable. Test coverage matches.
- **`table_default.ex` search-toolbar form fix**: the search input is now always
  wrapped in a `<form>` regardless of whether `on_submit` was given; no `id`
  collision risk introduced.
- **Admin view permission map** (`auth.ex`): all five claimed LiveViews
  (`Integrations`, `IntegrationForm`, `EmailSending`, `SendProfiles`,
  `SendProfileForm`) are present, correctly spelled, mapped to `"settings"`.
- **`page_section`/`page_section_path` forwarding** through
  `layouts/admin.html.heex` into `LayoutWrapper.app_layout` works as claimed.
- **`module.ex`'s new `email_settings_sections/0` callback** is documented, added
  to `@optional_callbacks` with a default `[]` implementation and
  `defoverridable`, so existing external modules can't break.
- **`admin_tabs.ex`'s Send Profiles entry** faithfully follows the Media →
  Dimensions parent-tab pattern; no priority collision.
- **Integrations API stayed uuid-strict** throughout the diff; no new
  `provider:name` string construction outside the documented exceptions.
- **`Probe`/`Validators`** correctly run from `handle_event`/`handle_info`, never
  `mount`; error messages returned to the UI are generic and don't leak
  credentials; no `String.to_atom`/`to_existing_atom` on external data anywhere
  in the reviewed files.
- **No secret-leak risk from `ProviderOptions`/send-profile "advanced" fields**
  today (all declared fields are non-sensitive); flagged as fragile-but-not-a-bug
  since nothing currently stops a future provider from adding an API-key-shaped
  field there with no redaction in the form template — worth a TODO, not
  PR-blocking.

## Not fixed (tracked, not blocking)

- `email_sending.ex` / `send_profile_form.ex` loading data in `mount/3` instead
  of `handle_params/3` (see above) — real but non-corrupting; left as a follow-up
  to keep this pass focused on the credential-leak fix, which is the one with an
  actual security/crash impact.
- `set_default_send_profile/1`'s PR-description mechanism mischaracterization —
  documentation-only, the code itself is correct.

## Gate

`mix test test/phoenix_kit/mailer_test.exs test/phoenix_kit/mailer/smtp_transport_test.exs`:
11 tests, 0 failures (integration tests auto-excluded, no local Postgres — expected
per project convention). Full `mix precommit` run separately; see commit message
for result.
