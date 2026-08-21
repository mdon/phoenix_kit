# Claude Review — PR #742 "Fix Authorization page leaking OAuth secrets via DOM and event logs"

**Merge commit:** 36e9ed27ee6cfac4e5225afb9a856283c3aa0853
**Author:** timujinne (fix/authorization-secret-dom-log-exposure)
**Files:** `lib/phoenix_kit_web/live/settings/authorization.ex`, `lib/phoenix_kit_web/live/settings/authorization.html.heex`, `test/integration/phoenix_kit_web/live/settings/authorization_secret_leak_test.exs`

## Summary of the change

The Authorization settings page (`/admin/settings/authorization`) rendered the
real Google/GitHub/Facebook OAuth client secrets into `value=` on
`type="password"` inputs. `type="password"` only masks the on-screen glyphs —
the real value still sits in the HTML `value=` attribute, readable via
view-source/DevTools. Because the pre-filled secret round-tripped back through
the DOM, editing *any other field* on the form re-submitted it as part of the
`validate_settings` event's full-form params (LiveView `phx-change` sends the
whole form on every change), which Phoenix's built-in LiveView telemetry
logger then wrote to the application log on every keystroke elsewhere on the
page.

The fix:
- The three secret inputs now always render `value=""`. A placeholder string
  ("A secret is already configured — leave blank to keep the current value")
  is the only signal that a secret is stored, computed server-side and never
  containing the real value.
- `preserve_unset_secrets/2` runs on both `validate_settings` and
  `save_settings`: for `@oauth_secret_keys` (the 3 rendered password fields,
  deliberately not `Settings.restricted_setting_keys/0` — that list also
  covers `aws_access_key_id`/`aws_secret_access_key`, never rendered here), a
  blank/nil incoming value is replaced with the currently-held value before
  validation/save; a non-blank incoming value (an admin actively typing a new
  secret) always wins.

## Review

- **Correctness of the restore logic.** Traced both call sites
  (`handle_event("validate_settings", ...)` and `do_save_settings/2`) —
  `preserve_unset_secrets/2` is applied before the changeset/`update_settings`
  call in both, using `socket.assigns.settings` (which itself gets the
  restored value re-assigned after each `validate_settings`, so the real
  value is available for the next event) as the source of truth. Confirmed
  the 3-key list matches exactly the 3 `type="password"` inputs in the
  template and matches `Settings.@restricted_setting_keys` minus the two AWS
  keys, as the comment claims.
- **No new DOM leak introduced.** `oauth_secret_placeholder/2` only branches
  on `nil?`/`""` and returns one of two static strings — it never echoes
  `current_value` itself into markup.
- **Trade-off, not a bug: an admin can no longer blank out a stored secret
  via this form.** Submitting an empty password field now always restores the
  old value (locked in by the "saving with the secret fields left blank does
  not wipe the stored secrets" test), so there's no way to *clear* a secret
  short of typing a new one. Checked for a workaround: each provider has its
  own `oauth_<provider>_enabled` toggle, which is how an admin actually
  disables a provider in practice — the missing "clear" path isn't a
  functional gap worth blocking on.
- **Telemetry-log claim verified by test, not just asserted.** The new
  suite's "editing another field does not leak the real secret via HTML or
  logs" test uses `ExUnit.CaptureLog.with_log/1` around a
  `render_change(view, "validate_settings", ...)` call and asserts the
  captured log doesn't contain the secret — this is a real regression test
  for the log-exposure half of the bug, not just the DOM half.

No findings. Ran the full suite (`mix test`, 3931 tests) and `mix precommit`
clean against `phoenix_kit_test` — see the PR #743 review doc for the shared
gate run (both PRs were merged locally and validated together).

## Verdict

No changes needed.
