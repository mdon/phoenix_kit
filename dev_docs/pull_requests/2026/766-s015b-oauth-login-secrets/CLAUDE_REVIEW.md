# PR #766 — Add coverage for rotating a still-plaintext restricted setting

**Author:** timujinne (`s015b-oauth-login-secrets`) · **Merged:** 2026-08-28 · **Reviewed:** 2026-08-29

## Verdict

Good test. One nitpick, fixed.

## What the PR does

Test-only. Adds a case to `test/integration/integrations_key_rotation_test.exs`
covering a restricted setting whose `value` is genuinely plaintext — the row
shape on a host upgrading from a pre-#759 core — and asserts that `KeyRotation.rotate/2`
encrypts it and that the OAuth read path still returns the original secret.

## Verification

- **It closes a real gap.** Every other test in the block seeds via
  `Settings.update_setting/2`, which is itself the encrypting write path, so
  none of them could distinguish "rotation handles a restricted setting" from
  "rotation handles one that was already encrypted".
- **The seam is the right one.** `write_plaintext_setting_value!/2` uses
  `Ecto.Changeset.change/2` rather than `Setting.update_changeset/2`
  specifically to bypass `maybe_encrypt_restricted_value/1` — without that, the
  seeded row would be re-encrypted immediately and the test would prove nothing.
- **It asserts through the real consumer,** not just `decrypt_value/1`:
  `Settings.get_oauth_credentials_direct(:google).client_secret` is what
  `OAuthConfig.configure_providers/0` calls to build the live Ueberauth
  `client_secret:`. A ciphertext, `nil`, or `""` regression would break OAuth
  login, and this catches it.
- **Global state is handled.** The file is `async: false` and its `setup`
  captures and restores `:integrations_encryption_key` via `on_exit`, so the
  new `Application.put_env/3` is covered by the existing teardown.

## Findings

### NITPICK — a `!` helper that doesn't assert its own write

`write_plaintext_setting_value!/2` discarded the result of
`Queries.update_setting/1`. A failed write would still have passed the two
`refute`/`assert` lines that follow (`before_row.value` would be the
`"placeholder-overwritten-below"` sentinel, which also isn't `enc:v1:`-prefixed)
and only surfaced at the final equality assertion, with a misleading message.

**Fixed:** the call now pattern-matches `{:ok, _}`, so the helper fails at the
line that actually broke.
