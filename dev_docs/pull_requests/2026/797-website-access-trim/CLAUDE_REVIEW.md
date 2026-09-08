# PR #797 Review — Website access: drop the environment banner, the presets, and the visitor notice

**Author:** mdon (Max Don)
**Merged:** 2026-09-08, by fotkin (merge commit `f6a1002a`)
**Files:** `lib/phoenix_kit/website_access.ex`, `lib/phoenix_kit/website_access/notice.ex` (deleted),
`lib/phoenix_kit/website_access/environment.ex`, `lib/phoenix_kit_web/live/settings/website_access.{ex,html.heex}`,
`lib/phoenix_kit_web/plugs/{website_access,integration}.ex`, `lib/phoenix_kit_web/components/layout_wrapper.ex`,
`lib/phoenix_kit_web/users/auth.ex`, `lib/modules/maintenance/{maintenance.ex,README.md}`,
`priv/static/assets/phoenix_kit.js`, gettext catalogs (7 locales + pot), tests, `dev_docs/plans/2026-09-06-website-access.md`

## Summary

Removes three pieces from the Website access settings page, each requested
directly ("the boss," relayed by Max): the environment banner (superseded by
the admin header's automatic `[dev]` tag), the presets (`presets/0` /
`apply_preset/2` and the stock closed-page texts they chose between — every
feature is switched on its own now), and the visitor notice feature in full
(the `Notice` context, its four settings, the `<body>`-injection in the
plug, the preview, the icon picker, and the `WebsiteAccessNotice` JS hook).
The one real risk — `X-Robots-Tag` was riding inside the notice's
`before_send` callback — is called out explicitly and covered: the header
survives as its own `robots/1` callback, with new test coverage for the
two branches (allowed-address, gate-bounce) the old tests never exercised.

This directly resolves what a prior memory entry flagged ("WebsiteAccess.Notice
dev-site bar — Max owns it now... don't re-attempt removal on your own
initiative") — Max's own removal has now landed cleanly.

## Verification performed

- Read the full diff for every changed file (not just the stat), confirming
  no leftover references to removed code:
  - `rg` across `lib/` and `test/` for `WebsiteAccess.Notice`, `.presets(`,
    `apply_preset`, `Notice.enabled_key`/`text_key`/`icon_key` — the only
    hit is a `refute` assertion confirming the preset button is gone from
    the rendered page.
  - `rg` for `WebsiteAccessNotice`, `pk-website-access-notice-sync`,
    `website_access:notice`, `data-phoenix-kit-notice` — zero hits; the JS
    hook removal (`-28` lines in `phoenix_kit.js`) has no dangling caller.
  - Checked the LiveView template for calls to functions removed from the
    `.ex` (`reason_text/1`, `icon_options/0`, `@environment`, `@presets`,
    `@notice`/`@notice_html`) — none remain.
- `mix compile --warnings-as-errors` clean on the merged tree.
- Ran the three website-access suites directly: 55 tests, 0 failures.
- Confirmed the PR's own stated risk area (`X-Robots-Tag` extraction from
  the notice's combined `before_send`) reads correctly in the plug diff:
  `robots/1` is a standalone `register_before_send` call, still ordered
  first in both the `allowed?` and redirect/gate/maintenance branches.
- Checked gettext state post-merge (this PR's branch predates my own
  "Modules tabs" and "Emails Transactional" work, both merged separately):
  0 fuzzy entries in all 7 non-English locales, only the long-standing
  English baseline (pre-existing empty-msgstr source strings, expected)
  remains fuzzy. The 3-way merge across four separate lines of work
  (PR #796's migration, my Modules-page tabs, my Email Sending rename,
  this PR's trim) produced no gettext corruption.
- Independently verified the PR description's "four orphan settings rows"
  claim (`website_access_notice_enabled`/`_icon`/`_text`/`_link`): grepped
  for any remaining reader — none — confirming they're inert, matching the
  PR's own analysis. No action needed (no key allowlist on the settings
  table, so orphaned rows can't break a save, listing, or migration).

## Findings

None. The removal is thorough, self-corrected across its own 5 commits
(including a dedicated "pin the absences" commit and a comment-accuracy
pass), already externally reviewed per the PR description, and independently
re-verified here with no gaps found.

## Verdict

**Approved, no changes required.**
