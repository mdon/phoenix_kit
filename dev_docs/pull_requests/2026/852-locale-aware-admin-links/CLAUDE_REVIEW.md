# PR #852: Keep the current locale in the admin header title link and user_settings_path overrides

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`4afe985f`), not yet released; the IMPROVEMENT below is applied post-merge (no BUG findings)
**Date**: 2026-09-21

## Goal

Two links dropped a visitor working in a non-default language back to the
default one: the admin header's project title (a hardcoded `href="/"`), and
a host's `user_settings_path` override (returned verbatim, while the
default page is localized). The header now links through
`Routes.home_path/2` — the host's own `/<locale>` when its router proves it
routable, else `/`, never core's mount point — and an override gets only a
locale segment inserted (`Routes.localize_served_path/2`), never
`url_prefix`.

## Verified

- `split_served_prefix/1` matches `url_prefix` on a whole segment
  (`prefix <> "/"`), so `/phoenix_kitten/x` is not mistaken for a path under
  `/phoenix_kit`.
- `usable_candidate?/1` (the open-redirect / auth-page guard) still runs
  before an override is localized; localizing only ever prepends a known
  locale segment to a path that already passed it.
- The prefixless-primary rule is honoured in both functions.
- On a root-mounted host (Fotki, `url_prefix: ""`) nothing routes a bare
  `/:locale`, so `/ru` is not routable and the header keeps linking to `/` —
  no behaviour change there.
- The full suite on the merged tree passes, including the PR's router-probing
  header tests.

## Findings

### IMPROVEMENT - MEDIUM: the home link was resolved twice per render, with change tracking off

Both title variants called `Routes.locale_aware_home_path(assigns, @socket)`
inside the template. Each call probes the router (`routable?/2`), so every
render of the admin chrome probed twice; and handing `assigns` itself to a
function in HEEx turns LiveView's change tracking off for the expression, so
it re-ran on every render regardless of whether anything it reads changed.

> **Applied post-merge.** `admin_template_assigns/2` resolves it once as
> `home_path`, and both variants read `@home_path`. The PR's header tests
> (which pin both links by count) pass unchanged.

### NITPICK: an override that names another language keeps it

`localize_served_path/2` leaves an override untouched when its leading
segment is already an enabled locale — so a setting typed as
`/ru/crm/settings` sends an Estonian visitor to the Russian page. The PR
does this on purpose (re-running must not stack segments), and replacing
the segment would misread a host path whose first segment merely looks like
a locale code (`/id/…`). Left as is; worth a sentence in the setting's help
text that an override should be entered without a locale.
