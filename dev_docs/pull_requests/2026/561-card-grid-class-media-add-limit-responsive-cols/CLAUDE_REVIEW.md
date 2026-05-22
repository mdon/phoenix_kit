# PR #561 — `table_default` `card_grid_class`, MediaGallery hide-Add-at-limit, `draggable_list` responsive cols

State: MERGED into `dev` (merge commit `68d51b30`).
Author: @timujinne
Diff: +25 / -17 across 4 files (all `lib/phoenix_kit_web/components/`).

## Scope recap

Three independent, small component-API changes:

1. **`draggable_list.ex`** — `cols` attr widened from `:integer` to `:any`; a new
   `cols_to_class(cols) when is_binary(cols)` clause passes a string of Tailwind
   grid-column classes through verbatim, so consumers can supply a responsive
   grid (`"grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"`) instead of only a fixed
   integer count.
2. **`table_default.ex`** — extracts the previously-hardcoded card-view grid
   classes into a new `card_grid_class` attr (default unchanged), so consumers
   can override column density. Doc warns the override must **not** include a
   `display` utility.
3. **`media_gallery`** — at selection limit the "Add" tile is now **hidden
   entirely** (the `<:add_button>` slot is `:if`-gated) instead of rendered
   disabled-and-greyed.

I read both component files at the touched call sites, traced `cols_to_class/1`,
the `add_button` slot rendering in `draggable_list`, and the `media_gallery`
`cols` passthrough.

## Verdict

**Approve.** Three clean, well-documented, correctly-scoped enhancements. No
bugs. The two structural claims the diff relies on both hold (verified below).
A few documentation-level NITPICKs only.

---

## Verified — the two load-bearing claims hold

- **`cols_to_class/1` clause order + fallback.** The `is_binary` guard clause is
  first (`draggable_list.ex:170`), then the integer literals `1..6`, then a
  catch-all `defp cols_to_class(_), do: "grid-cols-4"` (`:177`). So a string is
  taken verbatim, a valid int maps to its static class, and an out-of-range int
  (or any other term, now that the attr is `:any`) falls back to `grid-cols-4`
  rather than crashing. Correct.
- **Hiding the Add tile leaves no empty cell.** `draggable_list` wraps the slot
  in `<%= if @add_button != [] do %>` (`:158`), so when media_gallery omits the
  slot via `:if`, `@add_button` is `[]` and the `<div class="sortable-ignore">`
  trailing cell isn't rendered at all. The PR comment's claim ("no trailing
  cell … not even an empty wrapper") is accurate.
- **media_gallery passthrough.** `cols` is supplied via
  `assign_new(:cols, fn -> 4 end)` (`media_gallery.ex:111`), not a typed
  `attr :cols`, so a string assign flows straight to `cols={@cols}`
  (`media_gallery.html.heex:19`) → `draggable_list` with no type boundary to
  widen. Consistent.

## NITPICK — `attr :cols, :any` drops the compile-time integer check

Widening to `:any` is the only option (Phoenix attrs have no int|string union
type), so this is a necessary cost, not a defect. Worth being aware: a literal
mistake like `cols={:four}` no longer warns at compile and now silently resolves
to `grid-cols-4` via the catch-all. Consider documenting in the attr doc that
non-integer/non-string values fall back to `grid-cols-4`, so the silent path is
at least discoverable. Low priority.

## NITPICK — `card_grid_class` doc omits the Tailwind-literal caveat

The `cols` doc spells out "the string form must be a literal in a
Tailwind-scanned source so the classes are compiled." The new `card_grid_class`
attr carries the same constraint (an override built dynamically won't be in the
compiled CSS) but its doc only covers the no-`display`-utility rule. Add the same
one-line literal caveat for symmetry — a consumer overriding with interpolated
classes would otherwise get silently-missing styles.

## NITPICK (UX, author's call) — hide vs. disable at limit

Hiding the Add tile is cleaner code (one `selection_at_limit?/3` call in the
`:if` vs. three in the old class list + `disabled`), and the change is
documented in the moduledoc. The trade-off: a disabled-but-visible tile
communicated "you've hit the max" in place; a vanished tile is more ambiguous
(did I hit a limit, or is adding just unavailable?). For `:single` mode this
means picking an image makes the Add affordance disappear until you remove the
current one — same *interaction* as before (the disabled tile wasn't clickable
either), just less discoverable. Purely a design preference; flagging, not
objecting.

---

## Positives

- The `display`-utility separation in `table_default` is preserved correctly:
  the override slot is layout-only and the per-view-mode `grid`/`hidden` is still
  appended by the component, so the "don't rely on Tailwind source order for
  hidden-beats-grid" invariant (called out in the existing inline comment) still
  holds after the extraction.
- Defaults are unchanged in all three components, so this is purely additive —
  no existing caller's rendering shifts.
- Docs were updated in lockstep with each change (draggable_list attr +
  helper comment, media_gallery moduledoc for both `cols` and `max_count`,
  table_default attr doc), including the load-bearing Tailwind-literal and
  no-`display` caveats.
- Slot-omission approach for the Add tile is more idiomatic than toggling
  `disabled` + swapping class branches — fewer states to reason about.

## Note — component test coverage

`draggable_list` (`:cols` string vs int) and `table_default` (`card_grid_class`)
are exactly the branches the CLAUDE.md "Component test coverage" TODO already
calls out as untested. This PR widens both surfaces without adding tests, which
is consistent with current repo state (no `test/phoenix_kit_web/components/core/`
yet) — fold into that future sweep rather than blocking here.
