# PR #4 Review Findings — Fixes Report

Commit: `fe462b9d` on `feature/media-module-extraction`
Branch pushed to `origin` after changes.

---

## BLOCKER — `MediaViewerDialog` JS hook has no `updated()`

**Verdict: FIXED** (`priv/static/assets/phoenix_kit.js`)

**Investigation:** The two reviewers disagreed on severity. The frontend reviewer said it is currently safe because the `<dialog>` opening tag has only "stable" attributes (`id={@id}`, `class="modal"`, `phx-hook="MediaViewerDialog"`, `phx-target={@myself}`). The Elixir reviewer said it is BUG-HIGH.

**Conclusion:** The frontend reviewer is technically correct about current behaviour. LiveView sends incremental diffs — only changed dynamic parts. Since `@id` and `@myself` (the CID) are fixed for the component's lifetime, the `<dialog>` opening tag's attrs don't change on `step_viewer` events. That means no attr patch is sent, morphdom never reconciles the opening tag, and the runtime `open` attribute is never stripped. Prev/next stepping does not currently close the viewer.

**Why fixed anyway:** The task specified to apply the fix unless there is a concrete reason not to. The fix — `updated() { if (!this.el.open && typeof this.el.showModal === "function") this.el.showModal(); }` — is safe and idempotent. More importantly, it removes the unexplained asymmetry with `PkDialog`, which was written in the same PR and already guards this exact case. Any future developer adding a dynamic attribute to the `<dialog>` tag (e.g. for theming, data attributes, or ARIA state) would silently introduce the morphdom stripping bug without the guard. The `updated()` prevents that regression.

---

## IMPROVEMENT — `MediaViewer.update/2` has no test coverage

**Verdict: FIXED** (`test/phoenix_kit_web/components/media_viewer_test.exs`)

Added a `describe "update/2"` block with 4 tests:

1. **`current`→`current_uuid` mapping** — calls `MediaViewer.update/2` with a fresh socket and asserts `socket.assigns.current_uuid` equals the `current:` attr passed in.
2. **`notify` passthrough** — asserts the `notify` tuple is stored in assigns unchanged.
3. **Pre-passed `variants_map`/`file_structs` skip resolution** — passes non-nil values and asserts they are stored as-is (no DB call, no fallback — tested without a running DB).
4. **`assign_new` preserves navigation state on re-render** — seeds `current_uuid` with `@u1`, simulates navigation to `@u2` by mutating the socket, then calls `update/2` again with `current: @u1`; asserts `current_uuid` is still `@u2` (assign_new semantics).

All 17 tests pass (13 original + 4 new), no DB required.

---

## IMPROVEMENT — `MediaViewer.update/2` `assign_new(:current_uuid)` ignores a new `current` from parent

**Verdict: DECLINED as code change; moduledoc note added** (`lib/phoenix_kit_web/components/media_viewer.ex`)

**Investigation:** Grepped all usages of `MediaViewer` across the codebase. The only embedding is in `lib/phoenix_kit_web/components/media_gallery.html.heex:95-104`:

```heex
<.live_component
  :if={@preview_uuid}
  module={PhoenixKitWeb.Components.MediaViewer}
  ...
/>
```

The `:if={@preview_uuid}` guard mount-gates the component — it is unmounted when `preview_uuid` is nil and remounts fresh on each open. There is no standalone always-mounted consumer anywhere in the codebase.

**Conclusion:** The `assign_new` behavior is correct and intentional for the only real use case. Adding re-seed tracking would be YAGNI. Instead, added a clear moduledoc note explaining that `current` is an initial seed (not a live tracker), and that a standalone always-mounted consumer must unmount/remount to jump to a different image.

Also added moduledoc notes for `variants_map` and `file_structs` clarifying that `%{}` and `[]` are truthy in Elixir and count as pre-resolved — callers must pass `nil` or omit the attr to trigger internal DB resolution (addresses the `resolve_data/1` nitpick simultaneously).

---

## IMPROVEMENT — `MediaSelectorModal` `<dialog>` conversion consumer regression check

**Verdict: NO ISSUES FOUND** — no fixes applied

**Investigation:** Found 4 consumers of `MediaSelectorModal` (plus `UserMediaSelectorModal` which delegates entirely to it):

| Consumer | Pattern | Risk |
|---|---|---|
| `settings.html.heex:541` | `:if={@show_media_selector}` on the `<.live_component>` | Mount-gated — remounts on open, no PkDialog toggle needed |
| `authorization.html.heex:1074` | `:if={@show_media_selector}` on the `<.live_component>` | Mount-gated — same |
| `user_form.html.heex:969,978` | No `:if`; always-mounted within `:if @mode == :edit`; uses `show={@show_media_selector}` | Always-mounted; relies on `PkDialog` |
| `media_gallery.html.heex:82` | No `:if`; always-mounted; uses `show={@show}` | Always-mounted; relies on `PkDialog` |

The `MediaSelectorModal` template uses `data-show={to_string(@show)}` on the `<dialog>`. `PkDialog`'s `updated()` callback reads `this.el.dataset.show` and calls `showModal()`/`close()` accordingly. This is the correct pattern for always-mounted consumers and works correctly in both `user_form` and `media_gallery`. Compile verified clean (`mix format && mix quality` passed).

---

## NITPICK — `modal-box` + `!important` chain (`media_viewer.html.heex:13`)

**Verdict: SKIPPED**

Cosmetic/maintainability. The override works and produces the correct mobile-fullscreen / desktop-centered layout. Reworking it to a plain Tailwind-styled `<div>` would require re-implementing the modal backdrop and positioning from scratch — not trivial and out of scope.

---

## NITPICK — `<dialog>` missing `aria-labelledby`; focus not restored on close

**Verdict: PARTIALLY FIXED**

- **`aria-labelledby`**: Added to both `<dialog>` elements.
  - `media_viewer.html.heex`: Added `aria-labelledby={"#{@id}-title"}` to the `<dialog>` and `id={"#{@id}-title"}` to the filename `<h2>`.
  - `media_selector_modal.html.heex`: Added `aria-labelledby="media-selector-modal-title"` to the `<dialog>` and `id="media-selector-modal-title"` to the "Select Media" `<h2>`.

- **Focus restoration on close**: SKIPPED. When the viewer unmounts (`:if` becomes false), the browser does not reliably restore focus to the triggering button. Fixing this properly requires the `MediaViewerDialog` hook to capture a reference to `document.activeElement` at `mounted()` time and call `.focus()` on it from `destroyed()`. This is a non-trivial addition that affects the hook lifecycle, and no existing test or accessibility requirement was blocked on it.

---

## NITPICK — Hardcoded `id="media-selector-modal-backdrop"` (`media_selector_modal.html.heex:2`)

**Verdict: SKIPPED**

Pre-existing before this PR. The reviewer noted it is practically safe: `showModal()` makes the entire page inert, so two pickers cannot be open simultaneously and the duplicate-id collision never materialises. Fixing it would require plumbing the `@id` assign into all hardcoded references within the template — a broader refactor not warranted here.

---

## NITPICK — `resolve_data/1` truthy semantics for `%{}`/`[]`

**Verdict: ADDRESSED via moduledoc** (`lib/phoenix_kit_web/components/media_viewer.ex`)

Added to the `variants_map` and `file_structs` attr docs:
> Note: `%{}` (empty map) is truthy and counts as pre-resolved — pass `nil` or omit to trigger internal resolution.
> Note: `[]` (empty list) is truthy and counts as pre-resolved — pass `nil` or omit to trigger internal resolution.

No functional change. This is the intended N+1-avoiding behaviour when `MediaGallery` passes pre-loaded data.

---

## NITPICK — JS style: `t.isContentEditable === true` redundant; `function(){}` + `self` vs arrow

**Verdict: `=== true` FIXED; arrow style SKIPPED**

- `t.isContentEditable === true` → changed to `t.isContentEditable` in `MediaViewerDialog._onKey`. `isContentEditable` is already a boolean; the `=== true` was redundant.
- `function(){}` + `const self = this` vs arrow functions: SKIPPED. This is the pre-existing style for the `MediaViewerDialog` and `PkDialog` hooks (both written in this PR). Changing it is churn with no functional benefit and makes the diff harder to read in hindsight.

---

## Test results

```
mix format && mix quality  →  passed (dialyzer 164/164 skipped, no credo issues)
mix test test/phoenix_kit_web/components/media_viewer_test.exs  →  17 tests, 0 failures
```
