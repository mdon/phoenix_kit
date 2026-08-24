# CLAUDE_REVIEW.md — PR #750: Timezones (IANA ids + DST), /profile/settings, media viewer aspect, settings overflow

- **Author:** alexdont
- **Merge commit:** 9921c533 (base a283c6b8, tip c131e6f0 — nine commits)
- **Scope:** timezone storage migrated from integer offsets to IANA identifiers
  (with DST support via the `tz` package), a new unconditional `/profile/settings`
  account page replacing the dashboard-gated `/dashboard/settings`, a
  browser/account timezone-mismatch notification, a media-canvas aspect-ratio
  fix, and a settings-page horizontal-overflow fix.

## Verification performed

- Read `v181.ex` (migration) in full against the prefix-safety rules in
  `CLAUDE.md`: table name is schema-qualified on both `ALTER TABLE` and
  `UPDATE` (`#{p}phoenix_kit_users`), it's a metadata-only `varchar` widen (no
  rewrite/lock hazard), `down/1` degrades ambiguous values to `NULL` rather
  than aborting, and `postgres.ex` threads it in as `@current_version 181`.
  No prefix-safety issues.
- Read `time_zone.ex` (1219 lines) in full. DST/offset math is delegated to
  `Tz.TimeZoneDatabase` via `DateTime.shift_zone/3` and `DateTime.from_naive/3`
  — not reinvented — so the classic self-rolled-DST-bug risk doesn't apply.
  The picker's 59 behaviour-groups are derived from a two-year sample of the
  compiled tz database and cross-checked by `time_zone_test.exs`, which
  re-derives the grouping and fails on drift; ambiguous/gap wall-clock
  resolution (`from_wall/2`) picks documented, deterministic sides.
- Read `time_zone_alert.ex` in full: notifications are scoped per-user
  (`target_uuid: user.uuid`, no broadcast), gated behind
  `TimeZone.identifier?/1` + `mismatch?/2` (same-behaviour-group zones are
  silent), and rate-limited to once per distinct detected zone via
  `custom_fields`. Traced the emitting hook (`handle_timezone_detected/3` in
  `phoenix_kit_web/users/auth.ex`) — attached once per authenticated
  live_session mount, not per-request.
- Read `profile_settings.ex`: the token-consuming `mount/2` clause
  push-navigates before the socket connects, which LiveView resolves as a real
  HTTP redirect rather than a live patch — so the reconnect-triggered second
  `mount/3` call never re-runs against an already-spent token. Same idiom
  already used elsewhere in this codebase (`/users/confirm`). Route confirmed
  gated by `:phoenix_kit_require_authenticated` + `ensure_authenticated_scope`
  on_mount, so it's in email-confirmation-gated territory per CLAUDE.md.
- Read `layout_wrapper.ex`'s new `timezone_detector/1` component: gated on
  `handler_attached` (only true where `Auth`'s on_mount actually attached the
  matching `handle_event` hook), specifically to avoid the
  event-nothing-handles crash the phoenix-thinking skill's "stale intercept
  state" class of bug describes — reads as a deliberate, well-documented
  guard, not an oversight.
- Read `media_canvas_viewer.ex`'s dimension fix and `notifications/render.ex` +
  `types.ex`'s new `user.timezone_mismatch` wiring — both correct and
  consistent with the surrounding registries.
- Ran the full targeted test slice: `mix test
  test/integration/notifications/timezone_mismatch_test.exs
  test/phoenix_kit/utils/time_zone_test.exs
  test/phoenix_kit/settings/timezone_label_test.exs
  test/phoenix_kit/notifications/render_test.exs` → 62 tests, 0 failures.
  The integration test (real Postgres via `DataCase`) exercises the full
  chain — genuine mismatch, same-group silence, legacy-offset-always-flagged,
  once-per-zone dedup, third-zone re-notify, no-preference silence,
  unrecognized-zone silence — not just `observe/2 == :ok`.

## Findings

### BUG - MEDIUM: `user_settings_path` override wasn't re-guarded against auth-page bounce on read

`lib/phoenix_kit/utils/routes.ex`, new `user_settings_path/1`.

The setting's changeset (`setting.ex:430`, `validate_local_path(:user_settings_path)`)
correctly refuses a save that points at `/users/log-out` or another
sign-in/sign-out page — it shares the same `validate_local_path` helper used by
`after_login_path`/`after_registration_path`/`main_page_path`, which the
CLAUDE.md "Login & Registration" section calls out specifically because
`/users/log-out` is a real GET route that signs everyone straight back out.

But the **read** side only re-checked `local_path?(value)`, not the
`auth_page?/1` bounce rule. `main_page_path/0` and the `after_login_path`
resolver both call the private `usable_candidate?/1` (which is
`local_path?(path) and not auth_page?(path)`) on read specifically so a
hand-edited database row can't reintroduce what the changeset blocks at save
time — `user_settings_path/1` was the one settings-resolver in this file that
didn't. A row manually set to `/users/log-out` — a perfectly valid local path
— would have turned every "Settings" link in the admin nav, notifications,
login alerts, and the users list into a silent sign-out link for every user.

**Why it matters:** this is exactly the failure mode the surrounding code was
written to prevent (see the `validate_local_path/2` moduledoc comment: "so a
new auth route can't be guarded on read and forgotten on write" — here it was
the mirror image, guarded on write and forgotten on read), and the existing
test file (`user_settings_path_test.exs`) had a whole `describe
"override guarding"` block that covered protocol-relative URLs, absolute
URLs, backslash-escaped roots, control characters, and relative paths, but not
this one.

**Fix applied:** `user_settings_path/1` now calls `usable_candidate?/1`
(matching `main_page_path/0`), and the docstring was updated to say so
explicitly. Added a test case, `"/users/log-out is refused and falls back"`,
to `user_settings_path_test.exs`. Full file re-run: 12 tests, 0 failures.

## Not flagged (considered and ruled out)

- **Double `mount/3` on `/profile/settings/confirm-email/:token`** — looks
  like the classic "mount runs twice" trap at first glance, but the
  `push_navigate` on the disconnected (dead) render becomes a genuine HTTP
  redirect before any WebSocket reconnect happens, so the token-consuming
  branch runs exactly once per visit. Confirmed this is the same pattern
  already used by `/users/confirm` elsewhere in the codebase.
- **`TimeZoneAlert` remembering only the single most-recently-alerted zone**
  (not a full history) — someone alternating between exactly two mismatched
  zones could theoretically get re-notified on every switch back. This is
  explicit, documented behavior in the moduledoc ("one more when they get
  home, because that is a different zone from the one last alerted about"),
  not an oversight, and the realistic case (travel, not minute-by-minute
  zone-hopping) is handled correctly by the tests. Left alone.
- **83 pre-existing Russian gettext gaps** — unrelated to this PR, tracked
  separately in the #749 review.
