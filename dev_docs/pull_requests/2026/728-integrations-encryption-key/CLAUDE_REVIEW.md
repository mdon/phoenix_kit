# PR #728 — Fix integrations encryption: decouple key, add rotation, warn

Merge commit: `f1838d1d` · Author: timujinne · Reviewed by: Claude

Files in scope: `lib/phoenix_kit/integrations/encryption.ex`,
`lib/phoenix_kit/integrations/key_rotation.ex`, `lib/phoenix_kit/integrations/integrations.ex`,
`lib/mix/tasks/phoenix_kit.integrations.rotate_key.ex`,
`lib/phoenix_kit_web/live/settings/integrations.ex` (+ heex),
`lib/phoenix_kit.ex`, `lib/phoenix_kit/config/config.ex`, `.dialyzer_ignore.exs`,
8 locale `.po` files + `.pot`, plus the two new integration test files.

## Summary

This PR already went through four internal review rounds before merge — see
`dev_docs/investigations/2026-08-16-integrations-encryption-key-independence.md` for
the full history, including a round-4 bug (write path erasing undecryptable fields
instead of rotating them) found by an independent reviewer and fixed in `87baa620`.
This review's job was to find what those four rounds missed, not to re-review what's
already documented there.

## Review

- **Round-4 fix re-verified complete.** `has_sensitive_field?/1` checks the
  *decrypted* view (`present?/1` over `Map.get(decrypted, field)`), not the raw
  `enc:v1:`-prefix, so a still-plaintext row (first-adoption case) is correctly
  picked up for rotation instead of skipped. The regression test in
  `integrations_key_rotation_test.exs` writes a raw plaintext field bypassing
  `Encryption.encrypt_fields/1` and asserts it gets encrypted (`rotated: 1`, value
  gains the `enc:v1:` prefix, round-trips). No leftover raw-prefix check anywhere in
  `key_rotation.ex`.
- **`.dialyzer_ignore.exs` addition is genuine**, not suppressing a real bug — the two
  new entries for the new Mix task (`:unknown_function`, `:callback_info_missing`)
  mirror the exact entries every other PhoenixKit Mix task already carries in the
  same file (PLT has no `:mix` app info at analysis time).
- **Gettext drift is pre-existing, not new.** All 8 locale files carry the same
  already-tracked ~79 empty `msgstr` count from before this PR (see
  `project_gettext_drift_fixed.md`); the 6 new banner strings this PR adds are
  present and translated in all 8 locales, with identical msgid counts (2342) across
  every locale.
- **LiveView UI has no gotchas.** `encryption_status` is recomputed in
  `load_connections/1` on both mount and every PubSub refresh, not cached once at
  mount — no DB-query-in-mount issue, no stale status.
- **Fail-closed, not fail-open.** `rotate/2`'s guard is an allowlist
  (`status in [:dedicated, :legacy_secret_key_base]`), confirmed still in place from
  the round-2 fix — no analog of the storage signed-URL fail-open issue tracked
  elsewhere in this codebase.

## Findings

**NITPICK** — `encryption.ex`'s `configured_dedicated_key/0` checks `secret != ""`
but doesn't trim whitespace; a whitespace-only key ≥20 chars would silently pass as
`:dedicated` (healthy). Extremely unlikely operator error, not worth a dedicated fix.

## Verdict

No new CRITICAL/HIGH findings. The round-4 fix holds. No fix applied.
