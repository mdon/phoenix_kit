# CLAUDE_REVIEW.md — PR #752: Stop OAuth and AWS setting secrets from leaking into the application log

- **Author:** timujinne
- **Merge commit:** a64dace7 (base a18ebb90, tip 5b16f378 — includes the version bump to
  2.13.10 and CHANGELOG entry as part of the same PR)
- **Scope:** two independent secret-leak paths closed. (1) `PhoenixKit.boot/1` now
  installs `password`/`token`/`secret`/`api_key` plus every
  `Settings.restricted_setting_keys/0` entry into `config :phoenix, :filter_parameters`,
  so `Phoenix.LiveView.Logger`'s per-`handle_event` "Parameters: ..." log line no longer
  prints raw OAuth/AWS credentials submitted through the Settings/Authorization form.
  (2) `Settings.Queries.insert_setting/1` and `update_setting/1` now pass `log: false`,
  since Ecto's SQL debug logger has no notion of which column holds a secret and was
  printing every raw bound value on every settings write.

## Verification performed

- Read `lib/phoenix_kit.ex`'s `harden_filter_parameters/0` in full. Confirmed:
  - `Settings.restricted_setting_keys/0` (`lib/phoenix_kit/settings/settings.ex`) is a
    compile-time `@restricted_setting_keys` module attribute — no DB/cache access, so
    calling it at the very top of `boot/1` (before `ModuleRegistry.rescan/0`) cannot
    race a not-yet-started repo or cache.
  - The `{:keep, _}` early-return is correct: Phoenix's own `filter_values/1` already
    treats anything not explicitly kept as filtered in that mode, so leaving it alone
    is safe, not a gap.
  - The whole function is wrapped in `rescue` + `Logger.error`, so a future failure
    mode degrades to "unfiltered logging, logged loudly" rather than crashing boot.
  - Cross-checked the actual param shape the Settings/Authorization LiveView receives:
    `handle_event("validate_settings", %{"settings" => settings_params}, socket)` in
    `lib/phoenix_kit_web/live/settings/authorization.ex`, with the HEEx template using
    `name="settings[oauth_google_client_secret]"` — confirmed the nested map key
    Phoenix's filter matches against is the literal setting name (`oauth_google_client_secret`,
    `aws_access_key_id`, ...), which is exactly what `restricted_setting_keys/0` lists.
    The generic words (`secret`, `token`) already catch most OAuth secret keys by
    substring; `aws_access_key_id` genuinely needs the exact-name list since it
    contains none of the generic words — confirmed present in `@restricted_setting_keys`.
- Read `lib/phoenix_kit/settings/queries.ex`'s diff: `log: false` added to both
  `insert_setting/1` and `update_setting/1`. Confirmed via `CLAUDE.md`'s own documented
  gotcha that `redact:` on a changeset field doesn't reach Ecto's SQL logger, so
  per-field redaction isn't an option here — blanket `log: false` on this one table is
  the correct scope-limited fix (settings writes only, not every query in the app).
- Ran the full targeted + related test slices, all against a real Postgres:
  - `mix test test/phoenix_kit_test.exs
    test/phoenix_kit/settings/authorization_secret_leak_test.exs
    test/phoenix_kit/settings/queries_secret_logging_test.exs` → 26 tests, 0 failures.
  - Full `mix test` (4065 tests + 43 doctests) → 0 failures attributable to this PR
    (one unrelated environment-only failure in PR #751's doctor test, documented in that
    PR's review doc).
  - `mix precommit` (format, compile, deps.unlock, credo --strict, dialyzer, JS tests) →
    green.

## Findings

None. The fix is narrowly scoped, each of the two leak paths is backed by a
"destructive"-style test that exercises the real code path (a real LiveView event /
a real Ecto write with `capture_log`), and the CHANGELOG entry + version bump were
already included in the PR itself, matching this repo's release conventions.

## Verdict

No issues found. Both leak paths are correctly closed, the reasoning for "replace, not
merge" on `:filter_parameters` (Phoenix pre-compiles a package-level default on every
boot, so "leave existing config alone" would have protected nobody) is verified
correct against Phoenix's actual boot ordering, and the trade-off of losing a host's
own `filter_parameters` customization beyond Phoenix's default is called out honestly
in the code comment rather than hidden.
