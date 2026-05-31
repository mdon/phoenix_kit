# PR #561 Review — table_default card_grid_class, MediaGallery hide-at-limit, draggable_list responsive cols

**Verdict: PASS with one MEDIUM bug to fix**

---

## Stage 1: Spec Compliance

### Commit 1 — `table_default`: `card_grid_class` attr

- [PASS] New attr with correct default matching the previous hardcoded value (`gap-4 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4`) — `table_default.ex:123-126`.
- [PASS] `display` utility (`grid`/`hidden`) is still set per-branch at `table_default.ex:334-336`, not in the attr default. Doc warns against including `display` classes.
- [PASS] Backwards compatible — no existing call-sites pass `card_grid_class`; all get the default which matches the previous hardcoded value.

### Commit 2 — MediaGallery: hide Add tile at limit

- [PASS] `:if` guard correctly combines `not @readonly` with `not selection_at_limit?(...)` — `media_gallery.html.heex:75`.
- [PASS] Disabled-state classes removed; only the enabled-state classes remain.
- [PASS] `disabled` attr removed from the button.
- [PASS] Doc updated to say "hidden entirely" instead of "disabled" — `media_gallery.ex:45-46`.

### Commit 3 — `draggable_list`: `cols` integer|string overload

- [PASS] Attr type changed from `:integer` to `:any` — `draggable_list.ex:87`.
- [PASS] `cols_to_class/1` binary guard clause added before integer clauses — `draggable_list.ex:168`. Pattern matching order is correct.
- [PASS] Default remains `4` (integer) — backwards compatible for all existing call-sites (languages.html.heex, users.html.heex, media_gallery.html.heex — none pass `cols` explicitly except MediaGallery which defaults to `4` via `assign_new`).
- [PASS] Doc mentions Tailwind literal scanning requirement — `draggable_list.ex:90`.
- [PASS] MediaGallery moduledoc updated to reflect the new type — `media_gallery.ex:30-33`.

**Spec Verdict: PASS**

---

## Stage 2: Code Quality

### [MEDIUM] BUG: Empty grid cell when Add tile is hidden

**File**: `lib/phoenix_kit_web/components/media_gallery.html.heex:71-85` + `lib/phoenix_kit_web/components/core/draggable_list.ex:156-160`

**Problem**: When `selection_at_limit?` returns `true`, the `:if` on the `<button>` (line 75) prevents the button from rendering, but the `<:add_button>` slot itself is still declared (non-empty). In `draggable_list.ex:156`, the check `@add_button != []` evaluates to `true` because the slot is defined (Phoenix slots are lists of slot entries, not their rendered content). This means the `<div class="sortable-ignore">` wrapper at line 157 will render as an **empty div**, creating a visible empty grid cell in the thumbnail grid.

**Suggestion**: Move the `:if` guard from the `<button>` to the `<:add_button>` slot itself:
```heex
<:add_button :if={not @readonly and not selection_at_limit?(@selected, @mode, @max_count)}>
  <button ...>
```
This way, when the condition is false, the slot entry is excluded from `@add_button`, making it `[]`, and the `<div class="sortable-ignore">` wrapper in `draggable_list` won't render at all.

**Rationale**: An empty grid cell breaks the visual density of the gallery, especially noticeable at small `cols` values (e.g. 2-3 columns). The previous disabled-button approach did not have this problem because the button always rendered.

### [NITPICK] `cols` attr type `:any` is broader than needed

**File**: `lib/phoenix_kit_web/components/core/draggable_list.ex:87`

**Problem**: `:any` accepts atoms, lists, maps, etc. Only integers and strings are valid.

**Suggestion**: This is a minor type-safety concern. A runtime guard in `cols_to_class` already handles it (the catch-all falls back to `grid-cols-4`), so no crash risk. Documenting the expected types in the doc string (already done) is sufficient. No action needed.

### [NITPICK] Tailwind breakpoint cascade note absent from docs

**File**: `lib/phoenix_kit_web/components/core/draggable_list.ex:90`

**Problem**: When consumers pass responsive classes like `"grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"`, the behavior depends on Tailwind's mobile-first cascade. The doc doesn't mention that breakpoints must be ordered ascending. However, this is standard Tailwind knowledge and the example in the doc already shows correct ordering.

**Suggestion**: No action needed. This is standard Tailwind behavior and documenting it would be over-explaining.

---

**Quality Summary:** 0 critical, 1 medium (empty grid cell bug), 0 minor, 2 nitpick

**Quality Verdict: Needs Work** (one targeted fix)

---

## Overall Verdict: PASS after fixing the empty grid cell

**Priority fix list:**
1. **[MEDIUM]** Move `:if` from `<button>` to `<:add_button>` slot in `media_gallery.html.heex` to prevent empty `<div class="sortable-ignore">` wrapper from rendering as an empty grid cell.
