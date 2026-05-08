# PR #525 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**IMPROVEMENT - MEDIUM: DnD bundle is undocumented in the PR
  body.** Documented in this FOLLOW_UP (see "## DnD bundle audit
  trail" below). Closes the audit-trail gap so future maintainers
  searching `git log --oneline` for "drag handle" / "sortable
  flash" / "TR cell width" land in a reachable doc.~~

- ~~**IMPROVEMENT - LOW: `resolve_url/3` is invoked twice per
  language `<a>` tag.** Refactored all four call sites in
  `language_switcher.ex` (continent-grouped flat list, flat-list
  variant, `language_switcher_buttons/1`, `language_switcher_inline/1`)
  to compute `url = resolve_url(...)` once at the top of each
  iteration and reuse it for both `href={url}` and
  `phx-value-url={url}`. Halves the per-render cost and pins both
  call sites to the same URL — a future `resolve_url/3` change
  can't silently diverge `href` from `phx-value-url`.~~

- ~~**NITPICK: `entry_base_code/1` clauses for atom and string keys
  not in moduledoc.** Updated the `:per_translation_urls` attr
  doc on `language_switcher_dropdown/1`
  (`lib/phoenix_kit_web/components/core/language_switcher.ex:114-132`)
  to explicitly state both shapes are accepted ("Both atom-keyed and
  string-keyed entries are accepted — useful when the list comes
  from JSON/JSONB rather than Elixir code") and to document the
  `DialectMapper.extract_base/1` normalization plus the nil-URL
  fallback. The `buttons` and `inline` variants reference back to
  the dropdown's full doc, so the contract is self-documenting from
  any entry point.~~

- ~~**NITPICK: `sortable:flash` event has no defensive status
  handling.** Tightened the JS handler
  (`priv/static/assets/phoenix_kit.js:230-244`) — `payload.status`
  is now mapped explicitly to `"ok"`/`"error"`, and unknown values
  bail with `if (!cls) return;` rather than silently falling into
  the err-class branch. A typo on the server side (`"OK"` vs
  `"ok"`) now produces no DOM mutation rather than a misleading
  red flash.~~

## Skipped (deferred / out-of-scope)

- **NITPICK: `resolve_url/3`'s nil-URL silent fallback.**
  `Logger.debug` for the entry-exists-but-url-is-nil case would
  help diagnose draft-post / unpublished-translation issues, but
  draft posts in the publishing module are a normal occurrence.
  Adding a debug log would be noisy. Cosmetic deferral.
- **NITPICK: `data-sortable-handle` value depends on `@on_reorder`
  truthiness.** Defense-in-depth working as intended. No action.
- **NITPICK: `sortable:flash` no test coverage.** JS unit tests
  aren't part of the workspace's test infra today. Out of scope.

## Open

None.

---

## DnD bundle audit trail

This PR's title and body advertised the LanguageSwitcher attr only,
but the diff also shipped substantial DnD improvements. Documenting
them here so the audit trail is searchable:

### `lib/phoenix_kit_web/components/core/table_default.ex`

- New `data-sortable-handle=".pk-drag-handle"` attribute when
  `@on_reorder` is set. Wires SortableJS's `handle` option so drag
  initiation requires the pointer to land on the handle element,
  not anywhere on the card.
- Card surface no longer gets `cursor-grab` / `active:cursor-grabbing`
  classes — only the `.pk-drag-handle` element does. Click-to-expand
  / button-press / text-selection on a card no longer fights with
  drag.
- Footer-row layout: `card-actions justify-between` → `flex flex-wrap
  items-center gap-2`. Action buttons can now wrap to a second row
  on narrow cards instead of squishing. Empty `<span>` placeholder
  removed (no longer needed because flex-wrap handles alignment).

### `priv/static/assets/phoenix_kit.js` — `SortableGrid` hook

- New `sortable:flash` LV→client event handler. The host LV pushes
  `{uuid: "...", status: "ok" | "error"}` after each `reorder_items`
  attempt; the hook applies `pk-sortable-flash-{ok,err}` class for
  ~1.2s, idempotent via `void item.offsetWidth` reflow trigger.
  Queries *all* `[data-id]` elements (not just the closest) so
  table-view + card-view both animate. Now also has explicit
  status-validation guard (this triage's fix).
- New `<tr>` cell-width preservation via `onChoose` / `onUnchoose`
  callbacks. SortableJS's `forceFallback: true` +
  `fallbackOnBody: true` clones the dragged `<tr>` to
  `document.body`, where it loses its `<table>` ancestor and every
  `<td>` collapses to content width. The `onChoose` hook snapshots
  computed widths and pins them inline before the drag preview
  renders; `onUnchoose` restores the original styles. Standard
  workaround; no longer flakes column layout during drag.
- `data-sortable-handle` attr → SortableJS's `handle` option (when
  set, drag initiates only when pointer lands on a descendant
  matching the selector).
- `moved_id` always included in `reorder_items` payload (previously
  only on cross-container moves) so the LV can push back a
  `sortable:flash` event keyed to the just-moved row.

### CSS keyframes (in the injected `<style>` block)

- `pk-sortable-flash-ok` / `pk-sortable-flash-err` keyframes —
  green and red transient overlays via `::after` pseudo-element
  rather than `background-color` keyframes. The pseudo-element
  approach avoids the "card briefly becomes transparent and bleeds
  page bg through" artifact that a naïve background-color keyframe
  would produce.
- `prefers-reduced-motion: reduce` opts out of the flash animation
  for users with that accessibility setting.
