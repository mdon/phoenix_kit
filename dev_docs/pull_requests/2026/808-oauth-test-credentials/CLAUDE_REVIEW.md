# PR #808 — Fix OAuth Test Credentials button to actually test credentials

**Author:** timujinne (`i135-oauth-test-credentials`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Good change with an honest scope: a live check for Google only, and a
three-way `:ok | :error | :inconclusive` result. Two post-merge fixes: a log
line that contradicted the PR's own "never log exception data" rule, and nine
new msgids that were never extracted. The CHANGELOG entry said "now translated",
but every locale was still rendering English.

## Summary of the PR

- For Google, `OAuthConfig.test_connection/3` POSTs to Google's token endpoint
  with a fake code. `invalid_client` → rejected, `invalid_grant` → accepted,
  anything else → `:inconclusive`. The call is bounded by
  `Integrations.Probe.run/2`.
- `validate_secret_format/2` rejects secrets that are blank-looking or shorter
  than 16 characters. The Authorization page runs it on save against the raw
  params, before `preserve_unset_secrets/2`, so a short secret saved earlier
  never blocks an unrelated save.
- Client IDs and secrets are trimmed before they are saved or tested.

## Verified

- **The save gate only judges typed values.** An untouched password field
  arrives blank, and `validate_secret_format(_, "")` returns `:ok`.
- **`opts` cannot override the request.** Only `:plug` is taken
  (`Keyword.take(opts, [:plug])`).
- **Req decodes Google's JSON error body,** so the `%{"error" => ...}` match
  reaches both the 400 and the 401 responses.
- **Only the Authorization page calls `test_connection/2,3`.** No sibling
  package does.

## BUG - MEDIUM — nine new msgids were never extracted, so no locale translated them (fixed)

`mix gettext.extract` found 9 msgids in `oauth_config.ex` / `authorization.ex`
that were in no `.pot` file, so every locale showed the English text. That
included the new flash messages and the "Reload Config" flash this PR wrapped.

**Fix:** ran `extract` + `merge` (9 new per locale, 0 fuzzy) and translated all
nine by hand into de/es/et/fr/it/pl/ru, using each catalogue's existing
credential terms (Anmeldedaten / credenciales / mandaadid / identifiants /
credenziali / dane logowania / учётные данные).

## IMPROVEMENT - MEDIUM — exit/throw reason was logged verbatim (fixed)

The `rescue` in `google_live_check/2` deliberately logs only the exception's
module, because this path holds `client_secret`. The sibling `catch kind,
reason` logged `inspect(reason)`. A `GenServer.call` exit reason carries the
call's arguments, so that broke the same rule. It also printed "throwed".

**Fix:** log only the kind (`"... failed (exit)"`).

## IMPROVEMENT - MEDIUM — the check blocks the LiveView for up to 8s (not changed)

`handle_event("test_oauth")` runs `Probe.run/2` inline, so the page cannot
process other events until Google answers or the 8s deadline passes.
`phx-disable-with` covers the button itself. **Not changed:** the Integrations
page's "Test Connection" validators call `Probe.run/2` inline the same way, so
moving to `start_async/3` belongs in a change that covers both.

## NITPICK — Probe's own deadline returns an untagged `{:error, _}`

When Probe's 8s deadline fires, the button shows an error flash rather than the
inconclusive warning. The PR's comments acknowledge this, and Req's 3s + 4s
timeouts make it unlikely.
