# PR #556 Review — table_default: card_media slot, controlled view_mode, header class override

**Scope:** Only commit `15ddac1e` (the table_default changes). Commit `0805bb59` (MediaGallery max_count) is NOT reviewed here.
**File:** `lib/phoenix_kit_web/components/core/table_default.ex`
**Reviewer:** Claude Opus 4.6

---

## Backwards Compatibility

Verified all 15 existing usage sites of `<.table_default>` and `<.table_default_header>` across `lib/`. None pass `view_mode`, `view_event`, `card_media`, or `class` to `table_default_header`. All defaults preserve existing behavior:

- `view_mode=nil` -> JS hook + localStorage (unchanged)
- `table_default_header` class defaults to `"bg-primary text-primary-content"` (unchanged)
- `card_media` slot empty -> no wrapper div rendered (`:if` guard)
- Toggle buttons: `data-view-action` still emitted in JS mode, `phx-click` is `false` (suppressed by Phoenix)

**Verdict: No regressions for existing consumers.**

---

## Findings

### NITPICK: `above_cards` slot doc mentions only JS hook hiding

**File:** `lib/phoenix_kit_web/components/core/table_default.ex:171`

The `above_cards` doc says _"Hidden automatically when the JS hook switches to table mode"_. In controlled mode (`view_mode="table"`), hiding is driven by the CSS class `hidden` on the parent `data-card-view` div, not by the JS hook. The behavior is correct either way (slot is hidden in table mode), but the doc is JS-mode-specific. Consider adding a note: _"In controlled mode, hidden when `view_mode=\"table\"` via the parent container."_

### NITPICK: `card_media` wrapper div has no class — intentional but worth a doc note

**File:** `lib/phoenix_kit_web/components/core/table_default.ex:354`

The `<div :if={@card_media != []}>` wrapper is classless. The moduledoc says _"slot owns its own padding/background"_, which is correct — the consumer controls styling. However, since this div sits outside `card-body` (above it), consumers using daisyUI's `figure` pattern might expect an auto-applied `<figure>` tag. Current approach is fine — a plain `<div>` is more flexible — but confirming this is a deliberate design choice, not an oversight.

### NITPICK: Duplicate `"grid"` class in card-view controlled mode

**File:** `lib/phoenix_kit_web/components/core/table_default.ex:323-327`

```elixir
class={[
  "grid gap-4 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4",  # always has "grid"
  is_nil(@view_mode) && "md:hidden",
  @view_mode == "card" && "grid",  # <-- redundant "grid"
  @view_mode == "table" && "hidden"
]}
```

The base class list already includes `"grid"`. The `@view_mode == "card" && "grid"` line is redundant — it adds `"grid"` again. Harmless (CSS deduplicates), but noisy. Could be removed, or changed to just `true` / no-op since the element is already visible by default when not `hidden`.

Similarly, the table-view div (line 298-302) has `"block"` in the controlled-table branch, but since `<div>` is block by default this is also redundant. These are symmetry/readability choices more than bugs.

---

## Technical Verification

**`phx-click={@view_mode && @view_event}` when `view_mode=nil`:** `nil && "switch_view"` evaluates to `nil`. Phoenix/HEEX suppresses attributes with `nil` values — no `phx-click` attribute is emitted in the DOM. Correct.

**`phx-value-mode={@view_mode && "card"}` when `view_mode=nil`:** Same — `nil`, suppressed. Correct.

**`data-view-action={if is_nil(@view_mode), do: "card"}` when `view_mode` is set:** `if` returns `nil`, attribute suppressed. The JS hook won't see `data-view-action` on the buttons, which is correct since the hook itself is also suppressed (`phx-hook={if is_nil(@view_mode), do: "TableCardView"}`). Consistent.

**`values: [nil, "card", "table"]` on `view_mode`:** Phoenix.Component `values` validation accepts `nil` in the list — it means the attr can be unset or one of the listed strings. This is the documented pattern for optional enum attrs.

**Visibility logic — no class conflicts in controlled mode:** In controlled mode, the JS hook is not attached (no `phx-hook`), so no JS will toggle `md:hidden`/`md:block`. The conditional class lists emit exactly one visibility class per div:
- `view_mode="table"`: table-view gets `"block"`, card-view gets `"hidden"`. No `md:` prefixed classes.
- `view_mode="card"`: table-view gets `"hidden"`, card-view gets `"grid"`. No `md:` prefixed classes.
- `view_mode=nil`: table-view gets `"hidden md:block"`, card-view gets `"md:hidden"`. Same as before.

No conflicts.

---

## Verdict: Approve

Clean, well-scoped extension. All three features (card_media, controlled view_mode, header class override) are backwards-compatible and correctly implemented. No bugs found. Three nitpicks, all optional.
