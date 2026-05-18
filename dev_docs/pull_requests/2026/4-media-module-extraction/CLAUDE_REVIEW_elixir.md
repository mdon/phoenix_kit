# PR #4 — Media module extraction — Elixir/LiveView Review

Reviewer: reviewer (Elixir/LiveView scope). Commit range `f080f55f..feature/media-module-extraction` (9 commits).
Scope: `media_gallery.{ex,heex}`, `media_viewer.{ex,heex}`, `media_selector_modal.{ex,heex}`,
`Storage.get_files/1`, component tests. JS/frontend covered by a separate reviewer.

## Stage 1: Spec Compliance

Verified against `2026-05-17-media-module-extraction.md` (Part A) and the implementation plan.

- A1 `MediaViewer` standalone LiveComponent — PRESENT. Attrs `id/files/current/variants_map/file_structs/notify`.
  Plan deliberately renamed `index`→`current` and replaced the `show` boolean with mount-gating
  (`:if={@preview_uuid}`). Coherent with the plan; no spec violation.
- A1 features (prev/next chevrons, ←/→ keys, Esc/backdrop close, Download, `<.image_set>`, filename) — PRESENT.
- A1 `MediaGallery` refactored to embed `<MediaViewer>` instead of inline lightbox — PRESENT
  (`media_gallery.html.heex:95-104`), inside the single root `<div>`.
- A2 `SortableGrid` payload canonicalised to `"ids"` — PRESENT and documented in the moduledoc.
- A3 Commit grouping + CHANGELOG against bumped `@version` (1.7.111→1.7.112) — PRESENT.
- A4 Tests — `media_viewer_test.exs` + `media_gallery_test.exs` present; `render_component`
  single-root regression tests added (commit 8592cdd4).
- Change-notification contract — `{MediaGallery, id, {:changed, uuids}}` via `send/2`; `media_viewer_closed`
  and `media_selector_closed` `update/2` clauses — ALL PRESENT.
- `:single`/`:multiple` modes (`apply_selection/3`) and `readonly` — PRESENT and tested.
- `notify: {module, id}` on `MediaSelectorModal` (`confirm_selection` + `close_modal`) — PRESENT.

EXTRA (not requested by the spec, flagged not blocked):
- [media_selector_modal.html.heex:1] `EXTRA` — `MediaSelectorModal` was converted to a native
  `<dialog>` + new `PkDialog` hook (commit c9afc540). The spec only asked for the `notify:` option.
  `MediaSelectorModal` is a shared component with other consumers (catalogue item picker, etc.);
  changing its root element + adding a hook is wider-impact than the stated scope. Justified by the
  spec's "LiveComponent-in-LiveComponent z-index" risk note, but other consumers should be
  regression-checked. Not a blocker.

**Spec Verdict: PASS**

---

## Stage 2: Code Quality

### BUG - HIGH: `MediaViewerDialog` JS hook has no `updated()` — morphdom will strip the runtime `open` attribute
**File**: `priv/static/assets/phoenix_kit.js` (`MediaViewerDialog`) + `media_viewer.html.heex:1`
**Problem**: The `<dialog>` is server-rendered with **no `open` attribute**; the hook adds it at
runtime via `showModal()`. Every prev/next step (`step_viewer`) and every Escape-less re-render
re-renders the component, and LiveView's `DOM.mergeAttrs` removes any attribute on the live node
that is absent from the newly rendered node (`if(!source.hasAttribute(name)) target.removeAttribute(name)`).
`open` is not excluded — so on the **first chevron click the modal loses `open` and closes**, breaking
the headline prev/next feature ("no loss of functionality" constraint).
The sibling hook `PkDialog` — written in the same PR (commit c9afc540) — anticipates exactly this
and re-asserts state in an `updated()` callback. `MediaViewerDialog` (commit 4ea858a7) only has
`mounted()`/`destroyed()`. The asymmetry strongly suggests the author found the bug after writing
`MediaViewerDialog` and fixed only `PkDialog`.
**Suggestion**: Add an `updated()` to `MediaViewerDialog` mirroring `PkDialog._sync`:
`updated() { if (!this.el.open && typeof this.el.showModal === "function") this.el.showModal(); }`.
**Rationale**: Without it, stepping through images closes the viewer — a core regression.
Must be verified in a running app (chevron + ←/→) before merge; if live testing proves morphdom
preserves `open` here, downgrade to NITPICK, but the divergence from `PkDialog` should still be
reconciled.

### IMPROVEMENT - MEDIUM: `MediaViewer.update/2` uses `assign_new(:current_uuid, …)` — a new `current` from the parent is silently ignored
**File**: `lib/phoenix_kit_web/components/media_viewer.ex:39`
**Problem**: `current_uuid` is both the navigation state (mutated by `step_viewer`) and the seed
from the `current` attr. `assign_new` preserves navigation state across re-renders (correct) but
means once the component is mounted, a parent passing a *different* `current` has no effect. The
moduledoc advertises `current` as "UUID currently shown", implying it tracks. In the `MediaGallery`
embedding this is masked because the viewer is mount-gated (`:if={@preview_uuid}`) and remounts
fresh each open — but a standalone consumer that keeps the viewer mounted and jumps images
programmatically gets a silent no-op.
**Suggestion**: Document `current` as an initial seed only, or track the incoming `current` against
a "last seeded" assign so an explicit external change is honoured.
**Rationale**: Latent contract bug for the "reusable on its own" use case the moduledoc promises.
(Note: the plan itself specified `assign_new` here, so this is partly a plan-level ambiguity.)

### IMPROVEMENT - MEDIUM: `MediaViewer.update/2` is never exercised by tests
**File**: `test/phoenix_kit_web/components/media_viewer_test.exs`
**Problem**: All render tests call `MediaViewer.render/1` with hand-built assigns that already use
the internal name `current_uuid`; all event tests call `handle_event/3` against a fake socket.
Nothing calls `MediaViewer.update/2`, so the `current`→`current_uuid` mapping, `resolve_data/1`,
the `safe/2` rescue, `assign_new` semantics, and `notify` passthrough are untested. The
`render_component/2` tests are a genuine improvement (they hit the real `Diff.component_to_rendered`
path and catch the single-root `ArgumentError`), but they pass `variants_map`/`file_structs`
directly so still bypass resolution.
**Suggestion**: Add `update/2` tests: seed via `current:`, assert `current_uuid`; pass
`file_structs`/`variants_map` and assert no resolution; assert the `notify` tuple is stored.
**Rationale**: The attr-mapping layer is the component's public contract and currently has zero coverage.

### NITPICK: `resolve_data/1` truthiness on empty collections
**File**: `lib/phoenix_kit_web/components/media_viewer.ex:75-87`
`socket.assigns.variants_map || safe(...)` and `... file_structs || safe(...)` — `%{}` and `[]` are
truthy in Elixir, so once a parent passes an empty map/list (as `MediaGallery` does for
`variants_map`/`files`) the viewer never self-resolves from the DB. This is the intended,
N+1-avoiding behaviour when embedded, but it means a standalone caller cannot pass `[]`/`%{}` to mean
"resolve for me" — only `nil`/omission works. Worth a one-line moduledoc note. No functional bug.

### Positives
- `Storage.get_files/1` — input-order preservation via `uuid_index` + `flat_map` is correct;
  duplicate-UUID and missing-UUID behaviour is explicitly documented. Single query, no N+1.
- `MediaGallery.load_files/1` memoises on `selected_loaded` to skip redundant DB round-trips;
  rescue guard on `DBConnection.ConnectionError`/`Ecto.Query.CastError` is consistent with `MediaViewer.safe/2`.
- `MediaViewer` embedded in `MediaGallery` receives pre-resolved `variants_map`/`file_structs`,
  so the lightbox adds no extra queries.
- `step_viewer/2` `with` chain clamps boundaries correctly; covered by tests.
- Single-root constraint handled correctly (commits a4dedd84/fe28c888) and now regression-guarded.
- `notify` paths in `MediaSelectorModal` correctly fall back to `send/2` when `notify` is nil.

**Quality Summary:** 0 critical, 1 major (BUG-HIGH), 2 medium improvements, 1 nitpick
**Quality Verdict:** Needs Work

---

## Overall Verdict: FAIL (pending the BUG-HIGH fix / live verification)

Spec compliance is solid and the code is well-structured. The blocker is the `<dialog>` open-state
bug:

1. **BUG-HIGH** — Add `updated()` to the `MediaViewerDialog` JS hook (mirror `PkDialog`), or prove
   in a running app that prev/next stepping keeps the modal open. Without this the lightbox closes
   on the first chevron click — a functional regression against the "no loss of functionality" constraint.
2. IMPROVEMENT-MEDIUM — clarify/handle `current` re-seeding in `MediaViewer.update/2`.
3. IMPROVEMENT-MEDIUM — add `MediaViewer.update/2` test coverage.

Items 2–3 can land as follow-ups; item 1 must be resolved or disproven before merge.
