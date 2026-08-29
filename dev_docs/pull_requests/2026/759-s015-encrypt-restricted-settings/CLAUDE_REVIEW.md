# Claude Review — PR #759

**Title:** Encrypt restricted setting values at rest
**Author:** timujinne (branch `s015-encrypt-restricted-settings`)
**Merge commit:** `b153b0a6` (parents `255a742a` + `9f1bca9a`)
**Reviewer:** Claude (AI)
**Date:** 2026-08-28
**Scope reviewed:** `lib/phoenix_kit/settings/setting.ex`, `lib/phoenix_kit/settings/settings.ex`,
`test/phoenix_kit/settings_test.exs`, plus the in-PR fixup commit `9f1bca9a`
("Fix S015 review findings: cache warmer bypassed decryption") — that fixup already
landed as part of this same merged PR, so this review covers the PR's final state,
not just the original `79e31a04` commit.

## Summary

The core mechanism is sound and well-tested: `oauth_google_client_secret`,
`oauth_github_client_secret`, `oauth_facebook_app_secret`, `aws_access_key_id`,
`aws_secret_access_key` are now encrypted at rest via the existing
`PhoenixKit.Integrations.Encryption.encrypt_value/1` / `decrypt_value/1`, applied on
write through `Setting.maybe_encrypt_restricted_value/1` and on every multi-key read
path through the new `PhoenixKit.Settings.decrypt_and_map_settings/1` /
`decrypt_if_restricted/2`. The in-PR fixup already closed the one real gap a prior
review round found (the boot-time cache warmer bypassing decryption) and added a
regression test for it. I re-verified that fix is complete — see below — and did not
find a way to still get raw `enc:v1:` ciphertext back from a `PhoenixKit.Settings`
read function.

I found one significant finding that is **outside this PR's own files** but is a
direct, unaddressed consequence of it, so it belongs on the record here.

## Findings

### BUG - HIGH: `mix phoenix_kit.integrations.rotate_key` silently strands S015-encrypted settings

`PhoenixKit.Integrations.KeyRotation.rotate/2` (added by PR #756, merged just before
this one) re-encrypts rows under a new secret, but its query is scoped to
`where: s.module == "integrations"` (`rotate_rows_query/0` in
`lib/phoenix_kit/integrations/key_rotation.ex:225`). The five S015 restricted setting
keys this PR encrypts are written via `PhoenixKit.Settings.update_setting/2`, which
inserts/updates through `Setting.changeset/2` **without ever setting `:module`**
(`lib/phoenix_kit/settings/settings.ex:1495-1510`) — so on a real install these rows
have `module: nil`, not `module: "integrations"`.

Both `Setting.maybe_encrypt_restricted_value/1` (this PR) and
`PhoenixKit.Integrations.Encryption.encrypt_fields/1` (used for `module:
"integrations"` rows) resolve the same active key via `encryption_key()`
(`lib/phoenix_kit/integrations/encryption.ex`). That means:

1. An operator runs `mix phoenix_kit.integrations.rotate_key` (first adoption of a
   dedicated key, or after a suspected compromise). It reports success, having
   rotated every `module: "integrations"` connection.
2. The app restarts under the new key.
3. Every S015 restricted setting (Google/GitHub/Facebook OAuth client secret, AWS
   access key/secret) — still encrypted under the *old* key, since rotation never
   touched these rows — now fails to decrypt.
4. `PhoenixKit.Settings.decrypt_if_restricted/2` correctly refuses to leak
   ciphertext (`lib/phoenix_kit/settings/settings.ex:1271-1291`): it logs an error
   and returns `nil`. That is the right behavior for *that* function, but the
   practical effect is that OAuth login for every configured provider, and AWS
   SQS/S3 config, goes dark immediately after a routine key rotation — with no
   warning from the rotation task itself, which currently only promises to rotate
   "every stored integration connection."

This is a real production-impacting gap, not a theoretical one: `mix
phoenix_kit.integrations.rotate_key`'s own moduledoc frames rotation as
comprehensive ("Rotates the encryption key protecting stored integration
credentials" / step 4: "either every connection rotates, or none do"), but never
mentions the separately-encrypted restricted settings this PR introduces. I grepped
both `test/integration/integrations_key_rotation_test.exs` and
`test/mix/tasks/phoenix_kit_integrations_rotate_key_test.exs` — neither exercises a
restricted setting key, so nothing currently catches this.

**Why I did not fix this here:** the fix belongs in `key_rotation.ex` /
`rotate_key.ex` (widening `rotate_rows_query/0` to also cover
`PhoenixKit.Settings.restricted_setting_keys/0` rows, and updating the task's
docs/output to say so), which are files owned by PR #756's scope, not this PR's.
Editing them from this review risks colliding with that PR's own review pass
running in parallel. Flagging it here since it is a direct consequence of this PR's
design (reusing the shared `Encryption` key) and needs to be picked up — either as a
follow-up PR against `key_rotation.ex`, or noted prominently in the rotate_key
task's docs until it's fixed.

**Status: FIXED post-merge (this same review sweep, after all five parallel PR
reviews landed).** `rotate_rows_query/0` now matches `s.module ==
"integrations" or s.key in ^Settings.restricted_setting_keys()`. Rotation
branches per row shape: `module: "integrations"` rows still go through
`Encryption.decrypt_fields/1` / `encrypt_fields_with_secret/2` (the
`value_json` map path); restricted-setting rows go through a new
`Encryption.decrypt_value/1` / `encrypt_value_with_secret/2` (the bare
`value` string path) added specifically for this. Moduledocs and the mix
task's user-facing output were updated to say rotation covers both, and
`test/integration/integrations_key_rotation_test.exs` gained a "restricted
PhoenixKit.Settings values (S015)" describe block covering: a restricted
setting rotating on its own, an integration connection and a restricted
setting rotating together in one run, and `rotate_rows_query/0` matching a
`module: nil` row by key. See the fix in `lib/phoenix_kit/integrations/key_rotation.ex`,
`lib/phoenix_kit/integrations/encryption.ex`, and
`lib/mix/tasks/phoenix_kit.integrations.rotate_key.ex`.

### Verified correct (no action needed)

- **Cache-warmer fix (the in-PR fixup, `9f1bca9a`) is complete.** I checked every
  caller of `Queries.list_settings_key_values_by_keys/1`, `Queries.list_settings_key_values/0`,
  and `Queries.list_settings/0` in `settings.ex`: `get_settings_direct/1`,
  `get_settings_cached/2`'s miss-fill, `list_all_settings/0`, `query_settings_batch/1`,
  and `warm_cache_data/0` all now funnel through `decrypt_and_map_settings/1` /
  `decrypt_if_restricted/2`. The single-key path (`get_setting_cached/2`'s DB-miss
  branch) also decrypts before both caching and returning
  (`lib/phoenix_kit/settings/settings.ex:2054-2061`). I did not find a sixth read
  path that was missed.
- **Fail-closed on decrypt failure, both singular and plural read paths** — confirmed
  by tracing `decrypt_if_restricted/2` (returns `nil` + logs, never the raw value)
  and `decrypt_and_map_settings/1` (applies the same per-key). The log message
  interpolates only the setting key and the decrypt failure reason (an atom/tuple),
  never the ciphertext or any plaintext — no secret-leak-via-logs concern.
- **OAuth credential getters don't bypass this.** `get_google/github/facebook_oauth_credentials/0`
  (cached) and `..._direct/0` (uncached) both read through `get_settings_cached/2` /
  `get_settings_direct/1`, which decrypt. The Authorization settings LiveView's
  `mount/3` populates its form via `Settings.list_all_settings()`, also decrypting.
  I did not find any place that reads `Queries.get_setting_by_key/1` or
  `Queries.list_settings*/0` directly and skips `decrypt_if_restricted/2` for a
  restricted key on a live, non-test code path.
- **Write-side encryption is idempotent and edge-case-safe**, per
  `Encryption.encrypt_value/1`'s own contract (nil/empty pass through; an
  already-`enc:v1:`-prefixed value isn't double-wrapped) — verified this holds by
  reading `encrypt_value/1` directly rather than trusting the comment.
  `Setting.changeset/2` runs `maybe_encrypt_restricted_value/1` **after**
  `validate_setting_value/1`, so validation sees plaintext, not ciphertext — correct
  order.
- **No column-length risk**: `phoenix_kit_settings.value` was widened to `TEXT` in
  V160, so ciphertext (base64 + IV/tag overhead, always longer than the plaintext)
  can't overflow a `varchar(255)` the way it could have pre-V160.
- **Partition invariant**: `oauth_*_client_id`/`app_id` are correctly excluded from
  `@restricted_setting_keys` (public by OAuth's own design), matching the existing
  `settings_test.exs` invariant test that every setting key falls into exactly one
  of `@public_setting_keys` / `@restricted_setting_keys`.

### NITPICK: every restricted key is re-encrypted on every Authorization settings save, not just when it changed

`update_settings/1` → `update_setting/2` compares the submitted **plaintext**
against `changeset.data.value`, which for a restricted key holds the **ciphertext**
from the previous save — those never match, so `get_change(changeset, :value)` is
never `nil` for a restricted key on this path, and `maybe_encrypt_restricted_value/1`
re-encrypts it every time the Authorization settings form is submitted, even when
only an unrelated field (e.g. the callback-URL notice text, or a non-OAuth field on
the same page) changed. This doesn't produce a wrong result — the plaintext survives
the round-trip — but the in-code comment on `maybe_encrypt_restricted_value/1`
("`get_change/2` is `nil`... when it did but the submitted value equals what
`changeset.data` already holds") overclaims for this specific case, since
`changeset.data.value` is never the plaintext an admin would resubmit. Not worth a
structural fix (comparing decrypted-vs-submitted plaintext at the changeset layer
would need to thread the decrypted value in, adding real complexity for a
cosmetic/perf-only issue) — left as-is, noted here so the comment's claim isn't taken
at face value later.

## Testing

`test/phoenix_kit/settings_test.exs`'s `"restricted-key encryption at rest (S015)"`
describe block (23 assertions across 7 tests, added by the original commit + the
fixup) already covers: all three `decrypt_restricted_value/1` states, a full
write-then-read round trip against the raw row, the cache-warmer path (the fixup's
addition), legacy-plaintext passthrough, and the fail-closed guard through both
`get_setting/1` and `get_settings_direct/1`. I did not find a gap in this file's own
test coverage worth adding to — the one gap I found (key rotation) needs a test in
`key_rotation.ex`'s own suite, not here.

## Files edited by this review

None. No fix was applied — the encryption/decryption logic in this PR's own files
(`setting.ex`, `settings.ex`) is correct as merged; the one real bug found lives in
a different PR's files (see BUG - HIGH above) and its own test suite is the right
place for a regression test once fixed there.
