# PR #807 — Extend restricted-setting encryption to Apple/billing secrets, add perimeter guard

**Author:** timujinne (`s015-full-coverage`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Correct. The billing package keeps working because all of its reads go through
the decrypting path. One test-placement fix was applied; one limitation is
recorded.

## Summary of the PR

- `oauth_apple_private_key` and eight `billing_*` secrets are added to
  `@restricted_setting_keys` (encrypted at rest), to `get_defaults/0` (so the
  partition invariant sees them), and to `Setting`'s optional-empty list.
- `PhoenixKit.Test.SecretKeyPerimeter` (test support) statically scans `lib/`
  for secret-shaped key literals and migration seeds, and asserts that each one
  it finds is restricted.

## Verified

- **phoenix_kit_billing reads decrypt.** Every read of these keys in
  `/workspace/phoenix_kit_billing` uses `Settings.get_setting/2`: providers
  `stripe`/`paypal`/`razorpay`/`everypay`, `ProviderSettings`, and
  `WebhookController.get_webhook_secret/1`. The PR's round-trip tests prove that
  path decrypts. Writes use `Settings.update_setting/2`, which encrypts through
  `Setting.changeset/2`.
- **The `get_defaults/0` additions are inert.** The only non-display consumer is
  `update_all_settings_from_changeset/2`, which uses a default only to replace a
  blank submission, and these defaults are `""` anyway.
  `Settings.public_setting_keys/0` does not include them.
- **Key rotation now covers them.** `Integrations.KeyRotation` iterates
  `restricted_setting_keys/0`, so `mix phoenix_kit.integrations.rotate_key`
  re-encrypts the new keys with no further change.
- **Legacy plaintext is still readable** (`{:legacy, value}` branch, with a
  dedicated test).

## IMPROVEMENT - MEDIUM — perimeter test was DB-gated for no reason (fixed)

`settings_secret_perimeter_test.exs` used `PhoenixKit.DataCase, async: false`.
It never touches the database: it reads files, and `restricted_setting_keys/0`
is a compile-time list. `DataCase` auto-tags `:integration`, so the guard was
silently **excluded on every database-less run**, which is exactly where a
contributor adding a secret-shaped key is least likely to notice.

**Fix:** switched to `ExUnit.Case, async: true`. The fixture directories are
already unique per test, so async is safe.

## NITPICK — existing plaintext billing secrets stay plaintext until re-saved

Only new writes encrypt. An install that already stored a Stripe key keeps it
in the clear until an admin re-saves it or `rotate_key` runs. That matches how
S015 shipped for the OAuth/AWS keys, so it is recorded, not changed.
