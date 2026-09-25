# PR #875 — Add a setting to hide page descriptions in the admin header

**Author:** mdon · **Reviewer:** Claude · **Date:** 2026-09-25
**Verdict:** sound; merged into 2.40.1. Light review while cutting the release.

`show_page_descriptions` (default `"false"`, registered with the other
settings keys) gates `LayoutWrapper`'s `page_subtitle` and
`AdminPageHeader`'s `subtitle`, each with an explicit override attr resolved
the `resolve_admin_panel_label/1` way (not `||`, so `false` survives). Both
read `get_boolean_setting/2`, which goes through the settings cache. The
settings page has the checkbox; the header trail guide and the AGENTS.md
landmine document the four assigns.

Findings: none in the code. The PR carried no CHANGELOG entry, and hiding
descriptions by default is visible on every admin page: added under 2.40.1
"Changed". Its translation files conflicted with 2.40.1 on line references
only (resolved by an extract/merge round-trip, 0 fuzzy).
