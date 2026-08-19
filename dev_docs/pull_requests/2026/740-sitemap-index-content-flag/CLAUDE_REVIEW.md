# Claude Review — PR #740 "Add crawlers_sitemap_exempt_from_no_index: decouple sitemap content from the noindex directive"

**Merge commit:** 71de0215a89c8cb38e029fc1a28e405cad1ec34a
**Author:** timujinne (feature/sitemap-index-content-flag)
**Files:** `lib/modules/crawlers/crawlers.ex`, `lib/modules/sitemap/generator.ex`, `lib/phoenix_kit_web/live/settings/crawlers.ex`, `lib/phoenix_kit_web/live/settings/crawlers.html.heex`, `test/integration/phoenix_kit_web/live/settings/crawlers_sitemap_exemption_test.exs` (new), `test/integration/sitemap/no_index_test.exs`

## Summary of the change

New boolean setting `crawlers_sitemap_exempt_from_no_index` (default `false`,
preserves today's behavior) lets an operator keep the sitemap publishing real
URLs while `crawlers_no_index` is on, without touching the `noindex` robots
meta directive itself. Wired into `Generator.generate_all/1`'s cond as an
additional `and not sitemap_exempt_from_no_index?()` guard on the
`crawlers_no_index?()` branch, plus a settings-page toggle.

## Review

- **Blast radius of the new flag is correctly narrow:** it only narrows the
  existing `crawlers_no_index?()` branch (`and not ...`); it can't fire on its
  own, so every install that never sets it keeps exactly the current
  lockstep-with-noindex behavior. Confirmed the `noindex` meta tag emission
  path is untouched — the flag only affects `Generator`.
- **Fail-safe on lookup failure:** `sitemap_exempt_from_no_index?/0` in
  `generator.ex` wraps the settings read in `rescue`/`catch :exit`, same as
  the pre-existing `crawlers_no_index?/0`, and defaults to `false` (i.e. to
  the safer "blank the sitemap" behavior) rather than risking a full sitemap
  publish on a settings-lookup failure.
- **Toggle isn't the disabled-checkbox settings trap:** the new control is a
  raw `<input type="checkbox">` with `phx-click`, mirroring the existing
  `toggle_no_index` pattern in the same LiveView — not a `<.checkbox>` bound
  to the generic changeset-based Settings form, so the "disabled checkbox
  still submits an un-disabled hidden `false`" gotcha (`AGENTS.md`) doesn't
  apply here.
- **Minor inconsistency (not a bug):** `crawlers_no_index` has an entry in
  `Settings.get_defaults/0` (`lib/phoenix_kit/settings/settings.ex`) but the
  new `crawlers_sitemap_exempt_from_no_index` key doesn't. Checked whether
  this matters: `get_defaults/0` only feeds the *generic* Settings page's
  changeset-merge and empty-value fallback (`live/settings.ex`,
  `update_all_settings_from_changeset/1`) — the crawlers page is a dedicated
  LiveView with its own `handle_event` calling
  `Crawlers.update_sitemap_exempt_from_no_index/1` directly, and
  `sitemap_exempt_from_no_index?/0` supplies its own explicit `false` default
  via `Settings.get_boolean_setting/2`. So this doesn't affect correctness;
  left as-is rather than "fixing" an inconsistency that isn't load-bearing.
- **Tests:** both the generator-level contract (`no_index_test.exs` — asserts
  actual `<loc>` content and `total_urls >= 1`, not just "an integer", so the
  test can't pass against an unfixed generator) and the LiveView toggle
  (`crawlers_sitemap_exemption_test.exs` — default-unchecked, persists on/off,
  survives remount, doesn't touch `no_index_enabled?/0`) are covered.

## Findings

None blocking. One documented non-issue (defaults-map inconsistency, no
functional effect) noted above for the record.

## Verdict

Clean. Release-safe as-is.
