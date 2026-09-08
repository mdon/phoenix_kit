# Claude Review — PR #793

**Title:** Add a rows-per-page selector to the Users admin tabs
**Author:** timujinne
**Merge commit:** 0aef4d94
**Verdict:** Approve, two bugs fixed post-merge (a `mix precommit`-breaking JS test and a CHANGELOG placement bug)

## Summary

Users, Sessions, Live Sessions, Roles and the media picker now share
`<.page_size_selector>` (new, `PhoenixKitWeb.Components.Core.Pagination`) next
to `<.pagination_controls>` — size lives in the URL as `?per_page=`
(allowlisted `[10, 25, 50, 100]`, each tab's own default folded in), survives
reload, resets to page 1 on change. Roles is paginated for the first time
(count-based summary cards instead of counting rendered rows). Sessions moved
from an in-memory `join` + slice to `list_sessions_paginated/1`, filtering and
paging in SQL. Users pilots an opt-in "Auto" size backed by a
`PageSizeAutoFit` JS hook that fits the table to the viewport.

## Review scope

Read `pagination.ex` (new `page_size_selector/1`, translated
`pagination_info/1`), `sessions.ex` (`list_sessions_paginated/1` and its
filter helpers), and the gettext diff. Traced the actual route table and
`Repo.get/2` behavior rather than trusting descriptions where a claim was
checkable.

## Findings

### BUG - HIGH: new JS unit test crashes the whole file on Node >= 21 — fixed

`test/js/fit_page_size.test.cjs:52` did `global.navigator = { userAgent: "node" }`.
Node >= 21 ships a built-in global `navigator` as a getter-only accessor
property (no setter), so the plain assignment throws
`TypeError: Cannot set property navigator of #<Object> which has only a
getter`, crashing the entire test file before any of its 4 assertions run —
`mix precommit`'s JS-test step failed outright on this environment's Node
v24.16.0. The property is `configurable: true`, so
`Object.defineProperty(global, "navigator", {value, configurable: true,
writable: true})` redefines it cleanly; fixed and reverified
(`node --test test/js/fit_page_size.test.cjs` → 4/4 pass). The other stub
globals in the same file (`document`, `window`, etc.) don't collide with a
Node built-in and were unaffected. `push_to_owner.test.cjs`, the file this
one's comment says it mirrors, never sets `global.navigator` at all — this
was new, not a repeated existing pattern.

### BUG - MEDIUM: PR's own CHANGELOG entry landed in the wrong place, and got silently dropped when #794 merged — fixed

Two separate defects, both from the same root cause (see #794's review for
the mechanism): the PR branch had merged `main` multiple times across the
2.20.0 → 2.22.1 release cuts, and each merge's own conflict resolution on
`CHANGELOG.md` mis-picked a side.

1. **At merge time (`0aef4d94`):** the PR's "Unreleased" entry (rows-per-page
   selector, Roles pagination, Auto-fit, the `pagination_info`/Sessions SQL
   changes) landed *between* `## 2.21.0` and `## 2.20.0` instead of at the
   top of the file — a "line-based 3-way merge picked the position from an
   old ancestor" bug, not a hand-edit mistake. It sat there, invisible to
   anyone reading from the top, from `0aef4d94` through `ab20d686`.
2. **When PR #794 was merged** (this session), its own stale `CHANGELOG.md`
   edit (based on a pre-`2.22.1` ancestor) would have deleted the real
   `## 2.22.1` section outright, since main hadn't touched that file since
   the misplaced-block merge — see #794's review.

Fixed both in the same pass, while merging #794: restored `## 2.22.1`,
un-buried this PR's full original entry (unedited content, just relocated)
under a single top-of-file `## Unreleased`, and folded #794's fix entry in
alongside it. No content was lost or altered — verified via diff against
`0aef4d94:CHANGELOG.md`.

### NITPICK: gettext translation lag (not a regression from this PR specifically)

This PR alone added 8 new translatable strings (`Rows per page`, `Auto`,
`No %{noun}` / `Showing %{from} to %{to}[, of %{total}] %{noun}`, `results`,
`sessions`, plus i18n-ing what was previously hardcoded English). Combined
with untranslated strings from #786/#792 (change-email flow, dev-site preset
copy), all 7 non-English locales are now missing 21 strings each (up from 3
before this batch) — English `.po` files are expectedly all-blank (source
locale). Not a regression introduced by this PR's mechanics (compiles clean,
no fuzzy entries), and strings fall back to English rather than breaking, so
not a release blocker — but worth a translation sweep like the one done
2026-09-01 before it grows further.

### Spot-checked, no issues

- `list_sessions_paginated/1` — `escape_like/1` escapes `\`, `%`, `_` before
  building the `ilike` pattern (literal wildcards in search input can't turn
  into SQL wildcards); page is clamped into `[1, total_pages]` before the
  offset is applied; single joined `select` avoids N+1.
- `page_size_selector/1` — raises early on `auto_fit` without `table_id`;
  `phx-hook={@auto_fit && "PageSizeAutoFit"}` / `data-*` attrs correctly
  resolve to omitted (not `"false"`) when `auto_fit` is false, per HEEx's
  `false`/`nil` attribute-omission rule; stable form `id` (LiveView form
  recovery).
