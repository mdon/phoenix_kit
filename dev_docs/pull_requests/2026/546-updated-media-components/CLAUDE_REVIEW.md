# PR #546 — Updated media components

Review of `MediaGallery` / `MediaViewer` extraction, `<.draggable_list>` adoption,
`Storage.get_files/1`, and the native-`<dialog>` migration.

PR #546 was already merged to `dev`. The findings below were triaged after merge;
follow-up fixes were applied on top — see **Resolution** at the end of each item.

## BUG - CRITICAL — drag-reorder never reaches `MediaGallery`, crashes the host LiveView

`MediaGallery` is a **LiveComponent**, and its reorder handler lives in the
component:

```elixir
# media_gallery.ex:133
def handle_event("reorder_images", %{"ordered_ids" => ids}, socket) do
```

But `<.draggable_list>` drives reordering through the `SortableGrid` JS hook, and
that hook pushes the event **untargeted**:

```js
// priv/static/assets/phoenix_kit.js:457 / :459
self.pushEvent(destEvent, payload);
...
self.pushEvent(eventName, payload);
```

`pushEvent` (as opposed to `pushEventTo`) always routes to the **host LiveView**,
not the LiveComponent the hook element happens to live in. So on every
drag-reorder:

1. `SortableGrid` fires `pushEvent("reorder_images", %{ordered_ids: ...})`.
2. The event lands on the host LiveView, which has no `reorder_images` clause.
3. `handle_event/3` raises → the LiveView process crashes and the page reloads.

`MediaGallery.handle_event("reorder_images", ...)` is **dead code** — it can
never fire from a real browser.

The moduledoc actively asserts the opposite:

> The thumbnail grid uses the canonical `<.draggable_list>` primitive ... scoped
> to this component via `phx-target`. No event-name collision between multiple
> galleries on the same page.

There is no `phx-target` on `<.draggable_list>` or any ancestor, and
`SortableGrid` has no component-targeting support — the claim is false. The same
wording was copied into the test comments (`media_gallery_test.exs:250-252`,
`:465-467`), so the docs and tests reinforce a model that does not hold.

**Why this slipped through:** the two pre-existing `<.draggable_list>` consumers
(`live/users/users.html.heex`, `live/modules/languages.html.heex`) are both
`:live_view`s, where `pushEvent` correctly targets them. `MediaGallery` is the
**first `:live_component` consumer** and the pattern does not carry over.

**Why the tests don't catch it:** `media_gallery_test.exs` invokes
`MediaGallery.handle_event/3` directly (`call_handle_event/3`, lines 388-394) and
asserts the rendered `data-sortable-event` string. It never exercises the
JS→server routing, so it gives false confidence on exactly the broken path.

Note: `remove_image` / `preview_image` / `open_picker` are fine — those are
`phx-click` with `phx-target={@myself}`, which LiveView's DOM event handling
resolves correctly. **Only the hook-pushed reorder event is broken.**

**Suggested fix:** give `SortableGrid` optional component targeting — read a
`data-sortable-target` attribute and use `pushEventTo(target, ...)` when present;
add a `target` (or `phx-target`) attr to `<.draggable_list>` that emits it. Then
`MediaGallery` passes `target={@myself}`. This keeps the component self-contained
(as the moduledoc promises) and unblocks any future LiveComponent consumer.

**Resolution — FIXED.** `SortableGrid` now reads `data-sortable-target` and
routes via `pushEventTo` (an `emitReorder` helper covers both same-container and
cross-container drag); `<.draggable_list>` gained an optional `target` attr (CSS
selector) that emits the attribute; `MediaGallery` passes `target={"#" <> @id}`,
so the reorder event reaches the component's own `handle_event/3`. The moduledoc
and the misleading test comments were corrected, and a render-level assertion on
`data-sortable-target` was added. Still uncovered: an end-to-end `live_isolated`/
`render_hook` test exercising the JS→server hop (see TODO in the verdict).

## IMPROVEMENT - MEDIUM — production code rescues a test-only exception

`do_load_files/2` (`media_gallery.ex:167-182`) rescues
`DBConnection.OwnershipError`, and the comment is explicit that this is for
`Ecto.Adapters.SQL.Sandbox` "in tests that exercise update/handle_event paths
without checking out a connection."

Catching a test-infrastructure failure mode in shipped code is a smell — it
hides genuine sandbox misconfiguration and bloats the production rescue clause.
Prefer fixing the tests to check out a connection (or stub `Storage`), and keep
the production rescue scoped to real runtime failures (`ConnectionError`,
`CastError`). `MediaViewer.safe/2` already does the narrower thing — worth
aligning the two.

**Resolution — NOT CHANGED (deliberate).** The proper fix is test-side
connection checkout, which touches the no-DB test path; left as-is rather than
risk it. Tracked here for a future test-infrastructure sweep.

## NITPICK — dead `phx-target` on a plain `<div>`

`media_gallery.html.heex:22` — `<div class="relative group aspect-square"
phx-target={@myself}>` carries `phx-target` but has no event binding; the
attribute is inert. Each child button already sets its own `phx-target`. Drop it.

**Resolution — FIXED.** The inert `phx-target` was removed from the wrapper.

## NITPICK — `MediaViewer` sticky `current_uuid` vs. shrinking `files`

`update/2` keeps `current_uuid` via `assign_new`, but always re-assigns `files`
from the parent. A standalone consumer that keeps the viewer mounted while the
`files` list shrinks (current image removed) leaves `current_uuid` pointing at an
absent file. Harmless for `MediaGallery` (mount-gated via `:if`, remounts fresh),
and the moduledoc documents the standalone caveat — noting only for completeness.

**Resolution — NOT CHANGED (deliberate).** Documented behavior, harmless for the
mount-gated `MediaGallery` use.

## Looks good

- `Storage.get_files/1` — single-query batch fetch, input order preserved, the
  duplicate-UUID contract is documented. Avoids N+1 across the gallery.
- `MediaViewer` extraction is clean; `step_viewer/2`'s `with` clamps bounds
  correctly and the `current` "seed" semantics are well documented.
- Native `<dialog>` + top-layer `showModal()` for `PkDialog` / `MediaViewerDialog`
  is the right fix for z-index/stacking-context escape, and the hooks correctly
  re-assert open state in `updated()`.
- `notify: {module, id}` indirection on `MediaSelectorModal` is a reasonable,
  backward-compatible way to deliver selection to a LiveComponent.

## Verdict

Solid extraction and good docs/tests overall. The CRITICAL finding — drag-to-
reorder via `<.draggable_list>` was non-functional and crashed the page for any
2+ image gallery — has been **fixed** via a `target`/`pushEventTo` mechanism on
`SortableGrid` + `<.draggable_list>`. The two MEDIUM/NITPICK items left unchanged
are deliberate (see their Resolution notes).

**Outstanding TODO:** the reorder path is now covered only at render level
(`data-sortable-target` attribute). An integration-level test (`live_isolated` +
`render_hook`) is still needed so the JS→server contract is actually exercised.
