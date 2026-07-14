# PR #635: Add user Active Sessions, QR remember-me, and new-device alerts

**Author**: @alexdont
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

## Goal

Three related additions to the auth surface:

1. **Active Sessions** self-service UI (`UserSettings` `:sessions` section) —
   list a user's own live sessions (enriched with browser/OS/location from
   `KnownDevice` history), flag the current one, revoke one or "all others".
2. **QR remember-me** — a "Keep me logged in" checkbox on the desktop QR
   sign-in page, threaded through the mint → approve → finish handoff to
   `UserAuth.log_in_user/3`'s existing `remember_me` param, plus a sanitized
   `return_to` carried the same way.
3. **New-device alerts get an in-app notification** — `LoginAlerts` now
   fires a standalone `Notifications.create/1` (type `"security"`, new core
   notification type) alongside the existing email, and persists the
   resolved geo-location on `KnownDevice` (V147) so Active Sessions doesn't
   need a live lookup per render.

Plus the already-separate `f73b2b9f` fix: `qr_login.ex` now treats
`IpAddress.extract_from_socket/1`'s literal `"unknown"` sentinel as "no IP"
so the phone confirm screen omits the row instead of showing a bare
"unknown".

## Verified correct (no action needed)

- `Sessions.revoke_user_session/2` and `revoke_other_user_sessions/2` are
  properly user-scoped in the `WHERE` clause (not just filtered client-side)
  — a session-uuid guess against another user's session is a no-op. Covered
  by `sessions_device_test.exs`'s explicit cross-user test.
- `notify_in_app/2` calling `Notifications.create/1` directly (rather than
  going through `Activity.log` → `maybe_create_from_activity/1`) matches the
  documented "standalone notification" API (`Notifications.create/1`,
  V126) — correct choice, since the `user.new_login_detected` activity is
  self-actor (`actor_uuid == target_uuid`) and the activity-driven hook
  deliberately skips self-actions.
- `qr_login_complete.ex` re-validates `params["return_to"]` with
  `Routes.local_path?/1` server-side rather than trusting the LiveView's
  prior sanitization of the same value carried over the query string —
  correct defense-in-depth against a tampered redirect.
- `known_devices_by_fingerprint/1` rescues `Postgrex.Error` /
  `DBConnection.ConnectionError` so Active Sessions still renders (without
  enrichment) on a host that's deployed this code before running the V147
  migration.
- New Ecto integration tests (`sessions_device_test.exs`) and unit tests
  (`qr_login_test.exs`) are meaningful, not just coverage padding — they
  specifically assert the cross-user-revoke refusal and the
  no-network-call short-circuit for placeholder IPs.

## BUG - MEDIUM (found and fixed): QR mint blocks the QR code behind a synchronous, ~10s-worst-case geolocation call

`PhoenixKit.Users.QrLogin.device_meta/1` is called inline from the desktop
QR page's **connected** mount (`qr_login.ex` mount, guarded correctly by
`connected?(socket)` so it only runs once — no Iron Law violation there).
As of this PR it calls `location_for/1`, which calls
`Geolocation.lookup_location/1` synchronously. That function tries two
providers **sequentially**, each with its own 5s `Req` timeout — up to
~10s in the worst case before falling back to `nil`.

The QR page's entire purpose is to show a scannable code as fast as
possible; the template already has a `"Preparing your code…"` fallback for
`@keyfob == nil`, so this doesn't crash anything, but a slow or unreachable
geolocation API now stalls that "preparing" state for up to 10 seconds on
**every** connected mount of a public, pre-auth page — worse than the
existing (also-synchronous) geolocation call in
`register_user_with_geolocation/2`, which runs on a form POST where some
processing latency is expected, not on a page whose whole job is instant
QR display. The `device_meta/1` doc comment even claims the lookup is
"best-effort, timeout-bounded" — true only in the loose sense that 10s is
technically a bound.

**Fix applied** (`lib/phoenix_kit/users/qr_login.ex`): wrapped the
`Geolocation.lookup_location/1` call in `location_for/1` with
`Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, ...)` +
`Task.yield/2` + `Task.shutdown/2`, bounded to 1.5s. `async_nolink` (not
plain `Task.async`) is deliberate — the existing `PhoenixKit.TaskSupervisor`
child (already in `PhoenixKit.Supervisor`, used for other fire-and-forget
work) means a crash inside the lookup can never propagate to and kill the
calling LiveView via a link, only ever resolve to `nil`. On timeout the
task is killed and the QR code renders without a location, same as any
other lookup failure — no behavior change for the fast/success path, no
change to the public `location_for/1` contract, and the existing
`location_for/1` unit tests (nil/blank/`"unknown"`/`127.0.0.1` — none of
which reach the network) are unaffected.

## BUG - MEDIUM (found and fixed): wrong Russian/Estonian translations for new session strings, including an inverted "Sign out" → "Log in"

`priv/gettext/{ru,et}/LC_MESSAGES/default.po` are the project's two
"100%-complete and correct" locales (see `AGENTS.md`/memory). `mix
gettext.merge` fuzzy-matched several of this PR's new msgids against
unrelated existing translations and the `, fuzzy` flag was never resolved
before commit:

| msgid | ru (before) | et (before) | Problem |
|---|---|---|---|
| `"Sign out"` | `"Войти"` | `"Logi sisse"` | Both mean **"Log in"** — the literal opposite of the button they label, on a security-sensitive session-revocation control. |
| `"Active today"` | `"Активировать"` | `"Aktiveeri"` | Both mean **"Activate"** (verb), not "active today". |

Additionally, 11 of the 15 new msgids (session-list copy, the new-login
notification text, "This device", etc.) were left with an empty `msgstr` —
silently falling back to English, breaking the locales' 100%-complete
invariant.

**Fix applied**: corrected the two wrong translations and filled in the
other 13 empty ones in both `ru` and `et` (30 entries total), removed the
now-resolved `, fuzzy` flags on the four the merge had flagged. Verified
`Sign out` → `Выйти` / `Logi välja` (matches this codebase's existing
`"Log Out"`/`"Logout"` → `"Выход"`/`"Väljalogimine"` and `"Exit
selection"` → `"Выйти из выбора"`/`"Välju valikust"` precedent).

## Gate

`mix precommit` (format + `compile --warnings-as-errors` + `credo --strict`
+ dialyzer) — clean.
