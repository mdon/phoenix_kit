# PR #851: Route the Settings sidebar entry to the first subtab a scope can open

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`ddcd4c38`), not yet released; review only, no fixes applied (no BUG findings)
**Date**: 2026-09-21

## Goal

The Settings sidebar entry is visible to anyone holding `"settings"`,
`"media"`, `"integrations_system"` or any module's settings-subtab key, but
it always linked to `/admin/settings` (General), gated on `"settings"` alone
— so a role holding only, say, `"crm"` saw the entry and was refused behind
it. The PR sets `redirect_to_first_subtab: true` on the parent, so the link
goes to the first subtab the scope can open, and refines the mechanism so the
parent's own landing subtab (General) wins whenever it is reachable,
regardless of module subtab priorities (bookings registers at 650, below
General's 911).

## Verified

- The subtab list `maybe_redirect_to_first_subtab/2` picks from is already
  filtered by `Registry.get_tabs/1` for the scope, so "first subtab" is
  "first subtab this visitor can open", in priority order.
- A `"settings"` holder still lands on General, whatever priority a module
  gives its own subtab — the refinement's purpose, and covered by the new
  render tests.
- A scope with no settings-related permission never sees the parent; the
  redirect never runs for it.
- `redirect_to_first_subtab: true` is used by no other core tab, so the
  landing-subtab refinement changes no existing core behaviour.
- Tests on the combined tree (this PR, #847, #850 and the unreleased V200
  work): 317 tests, 0 failures.

## Findings

### IMPROVEMENT - MEDIUM: the sidebar is fixed, the other ways into Settings are not

The PR changes where the sidebar **link** points; `/admin/settings` itself
still refuses the same visitor. Other links to it remain:

- the section header of every settings subpage — `page_section_path` is
  bare `/admin/settings` in Storage (`settings`, `health`, `dimensions`,
  `dimension_form`), Sitemap and Languages;
- Sitemap's settings page navigates to `/admin/settings` (`settings.html.heex:534`);
- bookmarks, typed URLs, and a stale browser tab after a role change.

So the `"sitemap"`-only visitor the new tests use lands on
`/admin/settings/sitemap` from the sidebar, clicks "Settings" in the page's
own section header, and gets the refusal this PR was fixing.

Handling it at the destination fixes every entry point at once: when
`Live.Settings` (`:index`) mounts for a scope that cannot open General but
can open another settings subtab, redirect to that subtab instead of
refusing. The sidebar change then stays as the cheap path that avoids the
round trip.

### NITPICK: two `maybe_redirect_to_first_subtab/2` now disagree, and the flag's doc is stale

`Components.Dashboard.Sidebar` (the user dashboard) has its own
`maybe_redirect_to_first_subtab/2` (`sidebar.ex:263`) that still always takes
the first subtab; only the admin sidebar got the landing-subtab rule. The
flag means different things depending on which sidebar renders it, and
`Tab`'s doc for it (`tab.ex:225`, "Navigate to first subtab when clicking
parent") describes neither nuance. Either share one implementation or
document the admin rule on the field.
