# PR #835: Add breadcrumb level switchers to the admin header, and name Catalogues on the Modules page

**Author**: @mdon (Max Don)
**Reviewer**: @claude (Opus 5)
**Status**: ✅ Merged
**Commit**: `b80e9c1e` (merge of `5e931f36..2bcfb24c`)
**Date**: 2026-09-19

## Goal

Give any breadcrumb level a GitHub-style repository switcher: a ▾ beside a
segment that opens a searchable list of the other things on that level and
switches to one. The admin header's breadcrumb is core's, so the component
lives here and every page — core's own and a module package's — can reach it
through `page_crumbs[].switcher` / `page_title_switcher`. Separately, the
catalogue module renamed itself "Catalogues", so the Modules page's translation
catalog needs the new name beside the old.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/components/core/crumb_switcher.ex` | New. `crumb_switcher/1` — ▾ + `PopoverPanel` + `focus_wrap` + searchable link list |
| `lib/phoenix_kit_web/components/layout_wrapper.ex` | `page_crumbs[].switcher` honored; new `page_title_switcher` attr |
| `lib/phoenix_kit_web/components/layouts/admin.html.heex` | Threads `page_title_switcher` for plugin pages |
| `lib/phoenix_kit_web/live/modules.ex` | `gettext_noop("Catalogues")` beside `"Catalogue"` |
| `priv/static/assets/phoenix_kit.js` | New `ListFilter` and `CrumbSwitcher` hooks |
| `priv/gettext/**` | "Catalogues" in all eight locales |
| tests | 3 Elixir files + `test/js/list_filter.test.cjs` |

## Verdict

**No bugs found.** The claims in the PR description hold when checked against
the producing code; the two hooks are the careful part and they are correct.
What follows is the verification that mattered, then three nitpicks — one of
which is fixed here.

## Verification performed

These are the places this design could plausibly have gone wrong. Each was
checked against LiveView's own source in `deps/`, not assumed.

- **`aria-expanded` / open detection.** `CrumbSwitcher.sync/0` reads
  `getComputedStyle(panel).display`. `JS.toggle` (`deps/phoenix_live_view/
  assets/js/phoenix_live_view/js.js:411`) drives visibility through
  `style.display` wrapped in `DOM.putSticky(el, "toggle", …)` — so the state
  the hook reads is both the state LiveView writes *and* the one it re-applies
  after a DOM patch. Watching `attributeFilter: ["style", "class"]` on the
  subtree catches it; the show path sets `style.display` inside a nested
  `requestAnimationFrame` after the transition classes land, and the observer
  fires on both. The `aria-expanded` write is outside the filter, so it cannot
  re-enter. A server re-render that resets `aria-expanded="false"` from the
  server markup is recovered by `updated()`, which LiveView calls for every
  morphed element (`dom_patch.ts:369` pushes each `onElUpdated` element).
- **The re-filter-on-re-render claim.** Correct and load-bearing: the `<li>`
  `style.display` the filter writes is *not* sticky (it comes from the hook,
  not a `JS` command), so morphdom does strip it. `apply()` disconnects before
  writing and re-`observe()`s after, so its own writes cannot loop.
- **No focus steal on page load.** Every switcher's `focus_wrap` sits in the
  DOM while hidden, and LiveView's `FocusWrap` hook calls `ARIA.focusFirst`
  when `getComputedStyle(el).display !== "none"` — which is true for a `<div>`
  inside a `display:none` ancestor, because `display` is not inherited. It ends
  up calling `.focus()` on the hidden search input, which browsers ignore for a
  non-rendered element, so `attemptFocus` returns false and focus stays put.
  Benign, but it is the reason this markup is safe rather than an accident.
- **No termination hazard between the two hooks.** `opened()` → `input` event →
  `ListFilter.apply()` → `<li>` style + `[data-filter-empty]` class writes →
  `CrumbSwitcher.sync()` again. The second `sync()` sees `open === this._open`
  and stops. Checked because the two observers overlap on `class`.
- **Id uniqueness.** `@page_crumbs` is rendered exactly once in
  `layout_wrapper.ex` (one breadcrumb, progressive collapse by CSS, not a
  mobile/desktop duplicate), so `pk-crumb-switcher-#{idx}` and
  `pk-title-switcher` cannot collide. `admin.html.heex` is the only layout
  entry point that feeds `app_layout`, and it threads the new attr.
- **The Modules-page claim.** `modules.html.heex:336` renders the card title as
  `Gettext.gettext(PhoenixKitWeb.Gettext, ext.name)` — a runtime lookup of
  `mod.module_name()`, so registering the msgid is genuinely all that is
  needed. `phoenix_kit_catalogue` does now return `"Catalogues"`
  (`lib/phoenix_kit_catalogue.ex:55`), and no other core call site formats a
  module name through a catalog. Both msgids are translated in all eight
  locales; `"Search..."` and `"No results."` were already translated, so the
  switcher really does ship no untranslated string.
- **Hook-name collisions.** `ListFilter` and `CrumbSwitcher` are new across all
  60 `PhoenixKitHooks` entries; the `module.exports` test export follows the
  file's existing pattern (11 other blocks do the same).
- **Prefix/admin-path rules.** The component hardcodes no path and emits no
  `/admin`; item destinations come from the caller already resolved, which is
  what the surrounding `page_crumbs` links do.

## Findings

### NITPICK — gettext source references went stale (FIXED)

`priv/gettext/default.pot` and all eight `default.po` carried no reference for
`crumb_switcher.ex` under `"Search..."` or `"No results."`. PR #832/#833's
fix-up commit (`5af80428`) ran the extract/merge round-trip on a tree that did
not yet have `crumb_switcher.ex`; #835 branched before that and hand-edited
only the `"Catalogue"` block, so the two never met.

Nothing was mistranslated — both msgids already existed and are translated —
but the next person to run `mix gettext.extract --merge` would have got a
1 000-line diff mixed into their own work.

**Fix:** ran the round-trip. Result: `0 new messages, 0 removed, 0 reworded
(fuzzy)` in every locale, and the diff is reference comments only (verified:
zero changed lines that are not `#:`). Fuzzy count stays 0 per locale and the
untranslated count is unchanged at 69 real msgids, none of them from this PR.

### NITPICK — an item with neither `navigate` nor `patch` silently renders `<a href="#">`

`<.link>`'s fallback clause (`phoenix_component.ex:3155`) renders
`<a href="#">` rather than raising, so a caller who builds an item map without
a destination gets a row that looks right, keeps its classes and tick, and does
nothing when clicked.

**Not fixed.** The moduledoc is explicit that every item is a real link, and a
`raise` or a plain-`<span>` branch buys a guard against one typo at the cost of
a second rendering path in a component whose whole point is that every row is a
link. On record instead.

### NITPICK — flow content inside phrasing content

The switcher's wrapper is a `<span>` containing a `<div>` (the panel) and a
`<ul>`, and it is nested inside the breadcrumb's `<span>`s. Invalid per the
HTML content model; parsers do not auto-close `<span>` the way they do `<p>`,
so the DOM comes out as authored and nothing misbehaves. Changing the wrapper
to a `<div class="relative inline-flex">` would be strictly more correct and
costs nothing visually — worth doing the next time this file is touched, not
worth a release-day diff on its own.

### Note — the component is not in the global import list

`crumb_switcher/1` must be called qualified (or imported explicitly, as
`layout_wrapper.ex` does), because `PhoenixKitWeb.Components.Core.CrumbSwitcher`
is not in `phoenix_kit_web.ex`'s `html_helpers`. The moduledoc's "use the
component directly only for a trail you draw yourself" reads as though it were.

**Not changed**, and this is not a defect: a good half of `components/core/`
sits outside that list too (`ModuleCard`, `PreviewCard`, `RoleSwitcher`,
`RowLink`, `HeroStatCard`, `ChangeCue`, …) and is used fully qualified — that
list is deliberately conservative, because every name added to it lands in
every LiveView in the ecosystem and a consumer's own `crumb_switcher/1` would
stop compiling. Qualified use is the house style for a component this
specialised.

## Changes made in this review

- `mix gettext.extract --merge` — reference comments only, 0 fuzzy.
- `test/phoenix_kit_web/components/core/crumb_switcher_test.exs` — assert the
  row's `phx-click` hide rides on the `<li>`, not on the `<a>`. The moduledoc
  defends that placement at length (on the link, a `patch` would leave the
  panel open over the page it leaves in place) and nothing locked it in.

## Testing

- [x] Unit tests added/updated — 39 tests across the PR's three files, green
- [x] JS tests — `mix test.js`
- [x] Full suite — `mix test`
- [x] Gate — `mix precommit` (format, warnings-as-errors, credo --strict,
      dialyzer, test.compile, JS)
- [ ] Migration tested — n/a, no schema change
- [x] Backward compatibility — both new attrs default to nil/[]; a page that
      passes neither renders byte-identically

## Related

- Component guide: `dev_docs/guides/2026-09-11-core-components.md`
- Previous PR: [#833](../833-etcher-0.15.0-pin/)
