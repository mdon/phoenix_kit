# PR #556 — Review 2: `table_default_header` default class change

**Commit:** `20132de6` — `table_default_header: switch default to bg-base-300`
**Reviewer:** Claude
**Verdict:** Approve

---

## Scope of change

Single attr default flip in `table_default_header/1`:
- **Before:** `"bg-primary text-primary-content"` (loud primary band)
- **After:** `"bg-base-300"` (calm, theme-neutral)

## Call-site audit

14 real call sites (none pass an explicit `class`):

| File | Count |
|---|---|
| `lib/phoenix_kit_web/live/activity/index.html.heex:131` | 1 |
| `lib/phoenix_kit_web/live/users/users.html.heex:179` | 1 |
| `lib/phoenix_kit_web/live/users/sessions.html.heex:215` | 1 |
| `lib/phoenix_kit_web/live/users/live_sessions.html.heex:196` | 1 |
| `lib/phoenix_kit_web/live/users/roles.html.heex:161` | 1 |
| `lib/phoenix_kit_web/live/settings/users.html.heex:414` | 1 |
| `lib/phoenix_kit_web/live/settings/integrations.html.heex:77` | 1 |
| `lib/phoenix_kit_web/live/modules/jobs/index.html.heex:188,292` | 2 |
| `lib/modules/referrals/web/list.html.heex:126` | 1 |
| `lib/modules/storage/web/dimensions.html.heex:143,339` | 2 |
| `lib/modules/storage/web/settings.html.heex:184` | 1 |
| `lib/modules/storage/web/health.html.heex:217` | 1 |

All 14 will silently adopt the new look. None appear to intentionally rely on the loud primary band for UX emphasis — these are standard admin data tables where a subtle header is appropriate.

## Contrast check

`bg-base-300` uses the `base` color scale. In daisyUI, `base-content` (the inherited text color) is designed for all `base-*` backgrounds. The `<th>` cells have no explicit text color class, so they inherit `base-content` from the page. This is correct and contrast-safe across all themes including dark ones.

The old default was actually less robust in edge cases: `text-primary-content` forced a specific text color tied to `bg-primary`, which is fine — but `bg-base-300` + inherited `base-content` is the more idiomatic daisyUI pattern for non-accent UI.

## Documentation

The `@doc` for `table_default_header/1` at `table_default.ex:440-449` is updated correctly. It documents:
- The new default (`"bg-base-300"`)
- How to restore legacy look (`"bg-primary text-primary-content"`)
- How to go fully bare (`class=""`)

The moduledoc examples at lines 14 and 40 use `<.table_default_header>` without `class` — they stay accurate since the moduledoc never mentioned the header color.

No stale references to `bg-primary` as a default remain anywhere in the file.

## Tests

No tests in `test/` reference `table_default_header` or assert on header CSS classes. No breakage.

## Findings

No issues found. The change is well-scoped, safe for all existing consumers, and correctly documented.
