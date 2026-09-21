# PR #839: Right-click a row for its ⋮ menu, a Sort by label, and keep generated sitemaps out of the Hex package

**Author**: @mdon
**Reviewer**: @claude (Fable 5.1 / Opus 5)
**Status**: ✅ Merged
**Commit**: `e47a92ea`
**Date**: 2026-09-21

## Goal

- `data-row-menu-context` on a row (or `card_context_menu` on
  `table_default`) opens the row's own `table_row_menu` at the pointer on
  right-click, through one document listener.
- `sort_selector` gains an opt-in visible "Sort by" `label`.
- `mix.exs` excludes generated sitemaps from the package.
- Doc note on `bulk_select_scope`'s `swap` target needing
  `JS.ignore_attributes(["style"])`.

## Verified

- **The sitemap exclusion works.** With `priv/static/sitemap.xml` and two
  `priv/static/sitemaps/domains/*/sitemap.xml` on disk, a `mix hex.build`
  tarball carries no generated sitemap. The four `priv/static/assets/sitemap-*.xsl`
  stylesheets still ship, as they must: both regexes are anchored to paths
  that do not match them.
- **The pointer-placement rule has one copy.** `contextMenuPosition` in the
  ContextMenu IIFE delegates to `window.PhoenixKitMenus.pointerPosition`,
  which the hooks IIFE defines earlier in the same bundle. The removed `PAD`
  constant has no other uses.
- **`data-row-menu-context={@card_context_menu}`**: a `false` boolean
  attribute renders no attribute, so the default leaves cards untouched.
  `table_default_row` and `sortable_row` both take `:rest, :global`, so the
  documented `data-row-menu-context` passes through on table rows.
- **"Sort by"** already existed in `default.pot` and every locale, so there
  was nothing to translate.
- **The hook reference is a property** (`el._pkRowMenu`), which morphdom does
  not strip. `updated()` publishes it again and `destroyed()` clears it.
- **The listeners are ordered correctly.** The document capture-phase click
  swallow is registered at the first mount, before any menu's own outside-click
  listener, so it runs first and `stopImmediatePropagation` keeps the menu open
  after an Android long-press release.
- JS suite: 199 → 200 tests, all passing.

## Findings

### IMPROVEMENT - MEDIUM: a patch while the menu was open dropped keyboard focus (fixed)

The new `updated()` path moves the fresh duplicate's items into the open
menu with `replaceChildren`. The item that had focus is detached, so focus
fell back to `<body>`. The effect on a keyboard user in the middle of
navigating:
- the next ArrowDown/ArrowUp started again from the first item (`indexOf`
  returns -1), and
- the `Escape` handler still worked, but Tab left the menu for the page.

A PubSub refresh of a row is enough to trigger this. Before the PR, the
stale items stayed, so focus was never lost. The PR traded that stale-items
bug for this focus bug.

Fixed: the index of the focused item is recorded before the swap, and focus
goes back to the item in the same slot afterwards. It is clamped to the last
item when an action was removed, and uses `preventScroll` so the scroll-close
does not fire. New test: *"a patch while open keeps keyboard focus on the item
in the same slot"*.

### NITPICK: the guide did not mention the right-click gesture (fixed)

`dev_docs/guides/2026-09-11-core-components.md` is where CLAUDE.md sends
people who build list UIs, and it had no entry for the gesture or for
`sort_selector`'s `label`. Both are added under the list-UI toolkit.

### NITPICK: `Core.ContextMenu.updated()` still drops the duplicate (not changed)

`Core.ContextMenu.updated()` still discards the duplicate instead of adopting
its items. This is deliberate: its one shared menu is stamped per row when it
opens, so the duplicate holds no row's current items. Left as it is.
