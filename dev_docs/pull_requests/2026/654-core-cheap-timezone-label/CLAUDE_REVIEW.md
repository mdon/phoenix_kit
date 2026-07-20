# PR #654 — Add a cheap timezone-label accessor that never queries roles

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Sonnet 5
**Date:** 2026-07-20
**Verdict:** ✅ APPROVE — already merged; no bugs found.

---

## Summary

`Settings.get_timezone_label/2` needed a full `get_setting_options/0` map just to
resolve a timezone offset to its label — and building that map calls
`get_role_options/0` → `Roles.list_roles/0`, a real DB query, on every call site that
only wanted the timezone string (e.g. `mount/3` of
`PhoenixKitWeb.Live.Modules.Maintenance.Settings`).

This PR:

1. Extracts the static timezone list into `Settings.timezone_options/0` (single
   source, reused by `get_setting_options/0`'s `"time_zone"` key).
2. Adds `Settings.get_timezone_label/1` — resolves against `timezone_options/0`
   directly, no role query, no full options map.
3. Keeps `get_timezone_label/2` (existing full-map path) for callers that already
   have the whole options map on hand, but makes it fall back to `timezone_options/0`
   if the given map has no `"time_zone"` key (instead of exploding).
4. Switches three call sites (`modules/maintenance/settings.ex`, `user_settings.ex`,
   `user_form.ex`) to the cheap accessors, and drops a genuinely-unused
   `setting_options` assign from `live/settings/authorization.ex`.

## Files Changed (6)

| File | Change |
|---|---|
| `lib/modules/maintenance/settings.ex` | `get_timezone_label/2` → `/1` |
| `lib/phoenix_kit/settings/settings.ex` | +97/−52 — `timezone_options/0`, `get_timezone_label/1`, fallback in `/2` |
| `lib/phoenix_kit_web/live/components/user_settings.ex` | uses `timezone_options/0` directly |
| `lib/phoenix_kit_web/live/settings/authorization.ex` | drops unused `setting_options` assign |
| `lib/phoenix_kit_web/users/user_form.ex` | uses `timezone_options/0` directly |
| `test/phoenix_kit/settings/timezone_label_test.exs` | +125 — new suite |

## Verification performed

- **Reality-checked the "never queries roles" claim** — the new test
  `"never issues a repo query"` attaches `:telemetry` on
  `[:phoenix_kit, :test, :repo, :query]` (correctly derived from the *repo module's*
  name, not the OTP app — `PhoenixKit.Test.Repo` → `[:phoenix_kit, :test, :repo]`) and
  asserts a zero count around `get_timezone_label/3`. This is exactly the class of
  claim the review process calls out for verification against the emitting code
  rather than trusting the PR description, and it holds: `get_timezone_label/1` never
  touches `get_setting_options/0` (and therefore never `get_role_options/0` /
  `Roles.list_roles/0`).
- **Checked the "two lists must stay in sync" risk** — `get_setting_options/0`'s
  `"time_zone"` key now delegates to `timezone_options/0` (single source), and a test
  (`"is the same list get_setting_options/0 uses for \"time_zone\""`) pins that
  equality directly, so the lists can't silently drift apart again.
- **Checked the `authorization.ex` assign removal wasn't a regression** — grepped
  `authorization.ex` and `authorization.html.heex` for any `@setting_options` /
  `time_zone` usage; the page's time-zone field is a raw text input
  (`name="settings[time_zone]"`, `value={@saved_settings["time_zone"]}"`), not a
  `<.select>` built from `setting_options`. The removed assign was genuinely dead —
  confirmed by reading the template, not assumed from the diff.
- **Checked every other caller of the old two-arg path** —
  `lib/phoenix_kit_web/live/settings.ex:219` still wraps `Settings.get_timezone_label/2`
  and is used once, in `settings.html.heex:406`, where `@setting_options` is already
  built for several other dropdowns on the same page (date/time format, roles) — the
  right call to keep the expensive path there, matching the PR's own stated rationale
  ("callers that already have the full options map on hand").
- **Checked the fallback semantics change** (`setting_options["time_zone"] ||
  timezone_options()`) doesn't mask a real bug elsewhere — it only changes behavior
  for a map missing the `"time_zone"` key entirely (previously would have raised
  inside `Enum.find(nil, ...)`); the new test locks in the new, more defensive
  behavior explicitly.

No issues found — the migration to the cheap path is complete (all three previous
map-building call sites for timezone-only lookups are gone), the two lists can't
drift, and the removed assign was dead code, not lost functionality.

## Gate

`mix precommit` run at HEAD (format + compile --warnings-as-errors + credo --strict +
dialyzer) — see repo root for the run tied to this review session; no fixes were
required for this PR's changes.
