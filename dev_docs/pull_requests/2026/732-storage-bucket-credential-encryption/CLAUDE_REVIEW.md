# PR #732 Review — Encrypt Storage bucket credentials, add an Integrations-backed source

**Author:** timujinne · **Merged:** fa42b5e6 (2026-08-18) · **Reviewer:** Claude (post-merge)

## Summary

Encrypts `phoenix_kit_buckets.secret_access_key` at rest (`PhoenixKit.Integrations.Encryption`,
new `encrypt_value/1`/`decrypt_value/1` single-value API), widens the column from
`varchar(255)` to `text` (V175 migration — the encrypted encoding overflows the old
ceiling past a ~158-char plaintext secret), and adds an alternative credential source
(`integration_uuid`, mutually exclusive with direct `access_key_id`/`secret_access_key`)
so a bucket can point at a `PhoenixKit.Integrations` connection instead.

## Findings

### IMPROVEMENT - MEDIUM: `integration_uuid` ships with no UI and no backing provider

`Bucket.changeset/2`, `Storage.build_probe_bucket/1`, and
`Providers.S3.resolve_credentials/1` all correctly support a bucket resolving its
credentials from an `Integrations` connection by uuid. But:

- `PhoenixKit.Integrations.Providers.object_storage/0`, referenced in both
  `v175.ex`'s moduledoc and `s3.ex`'s `resolve_credentials/1` comment as the provider
  this field exists for, does not exist anywhere in `lib/` — confirmed via
  `rg object_storage lib/`. The test suite works around this by pointing
  `integration_uuid` at an `aws_ses` connection instead (same `:key_secret` shape,
  field keys `access_key`/`secret_key` happen to match).
- `bucket_form.html.heex` has no input, select, or picker for `integration_uuid` —
  `grep integration` on the template only matches the `test_connection` param
  threading in `bucket_form.ex`. There is currently no way for an admin to set this
  field through the UI.

Net effect: the feature is real and tested at the data/provider layer, but is
unreachable by an actual user today — it only exists for direct API/DB use. The
in-code comments acknowledge this ("added in a parallel branch", "in-flight,
separately-shipped provider"), so this reads as a deliberately incremental rollout
rather than an oversight. Not fixing — no code change needed, just flagging so the
follow-up (the `object_storage` provider + a picker in `bucket_form.html.heex`) isn't
lost. Worth a TODO entry once a second PR is expected.

### No other issues found

Reviewed against `elixir:ecto-thinking` (schema/changeset gotchas) — changeset pipeline
order is correct (`validate_credentials_exclusive` → `validate_cloud_credentials` →
`encrypt_secret_access_key`, so required-field validation runs against the raw value
before encryption, and re-saves of an already-encrypted value are idempotent via
`encrypted?/1`). Traced every caller of `Bucket.secret_access_key` /
`resolve_credentials/1` / `build_probe_bucket/1` — no path decrypts outside
`Providers.S3.resolve_credentials/1`, matching the doc comment on `Storage.get_bucket/1`.

Specifically checked and ruled out as non-issues:
- **Edit-form password field prefill.** `bucket_form.ex` mount populates the
  `secret_access_key` changeset param from `bucket.secret_access_key`, which after this
  PR is ciphertext, not plaintext. Looked like a regression (form now round-trips
  gibberish instead of a real secret) but it isn't: the field is `type="password"` so
  the browser masks it identically either way, an untouched submit round-trips the
  same ciphertext unchanged (`encrypted?/1` short-circuits `encrypt_secret_access_key/1`,
  no double-encryption), and a deliberate edit still re-encrypts correctly. Arguably a
  net security improvement — the browser DOM never holds the plaintext secret anymore.
- **Prefix-safety of the V175 migration.** `CREATE INDEX`/`DROP INDEX` follow the
  bare-name-on-create, qualified-on-drop convention (matches `dev_docs/guides/2026-07-27-prefix-safe-migrations.md`);
  `ALTER COLUMN secret_access_key TYPE TEXT` needs no existence guard (column is
  guaranteed present since V20) and matches the V160 (`settings.value`) precedent.
- **`ExpectedSchema` manifest.** New column + partial index hand-declared consistently
  with the V165/V166/V170/V171/V173 precedent; `secret_access_key`'s revision is
  *appended* (`{175, ...}`), not rewritten, matching the V167 precedent so pre-V175
  installs don't read as drift. `@chain_hash` was restamped in the PR.

## Validation

- `mix test test/modules/storage/ test/phoenix_kit/integrations/encryption_test.exs test/phoenix_kit/migrations/`
  — 16 doctests, 487 tests, 0 failures.
- `mix precommit` — see chat reply for result.

## Verdict

No code changes made. The one finding (unreachable `integration_uuid` without a UI or
a registered `object_storage` provider) is an incremental-rollout gap, not a bug —
recorded here for whoever picks up the follow-up.
