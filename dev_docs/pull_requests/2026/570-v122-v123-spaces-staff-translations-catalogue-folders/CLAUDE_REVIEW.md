# PR #570 — V122 + V123: location_spaces, staff translations, catalogue folders

**Reviewer:** Claude (Opus 4.8)
**State:** MERGED into `dev` (2026-05-29). Review is post-merge; findings are follow-up candidates.
**Scope:** 2 new migrations (V122, V123), migration dispatch bump, installer PDF.js mount, `<.load_more>` infinite-scroll.

## Status — fixes applied post-review (2026-05-29)

All three findings below were fixed in the working tree after the review (this branch, post-merge):

- **MEDIUM (InfiniteScroll over-fetch)** — fixed. `priv/static/assets/phoenix_kit.js`: `updated()` now re-fires only when `data-cursor` actually changes (not on every diff), and a `loading` in-flight guard (`maybeLoad()`) prevents stacking pushes; the guard clears on the next cursor change. `pagination.ex`: `data-cursor` now defaults to `@loaded` (which already changes per page) via `resolve_cursor/1`, so the guard works out-of-the-box even when a caller omits `cursor` — and an explicit `cursor` still wins.
- **NITPICK (`data-cursor` unused in JS)** — fixed as a consequence; the hook now reads `dataset.cursor` as its real page signal.
- **NITPICK (`infinite` without `id`)** — fixed. `load_more/1` now raises a clear `ArgumentError` at render time instead of surfacing an opaque LiveView hook error.
- **NITPICK (V122 moduledoc "Two"/three)** — fixed. Now reads "Three unrelated additions."

The "Verified correct" items needed no change. Original findings preserved below for the record.

## Verdict

Solid, well-documented PR. Both migrations are correctly wired (auto-dispatch via `Module.concat([__MODULE__, "V122"])` keyed on the zero-padded version — no manual registration needed) and genuinely idempotent. All tables the migrations `ALTER` are created unconditionally in earlier **core** migrations (staff → V100/V101, locations → V91, catalogue → V87/V96), so V122/V123 will never hit a missing-table error on any host at that version. The `down/1` chains reverse cleanly in rollback order (`123 → 122 → 121`).

No CRITICAL/HIGH findings. One MEDIUM on the JS hook, plus nitpicks.

---

## IMPROVEMENT - MEDIUM — `InfiniteScroll.updated()` fires on *every* LV diff with no in-flight guard

`priv/static/assets/phoenix_kit.js` (InfiniteScroll hook) + `pagination.ex` `load_more/1`

```js
updated() {
  if (this.intersecting) {
    this.pushEvent(this.loadMoreEvent(), {});
  }
}
```

`updated()` runs on **any** LiveView patch that touches the sentinel's subtree — not just the load-more round-trip. While the user is parked at the bottom of the list (sentinel within the 200px `rootMargin`, so `this.intersecting === true`), any unrelated diff — a flash message, a PubSub-driven row update, a sibling assign change — pushes another `load_more`. There is also no in-flight/loading guard, so several pushes can be in flight at once before the server responds.

Net effect: spurious extra page loads and wasted server work whenever the list is scrolled to the bottom and something else on the page updates. It self-terminates (the hook is dropped once `@loaded >= @total`), so it's not unbounded — hence MEDIUM, not HIGH.

The manual button path is already protected (`phx-disable-with`); the auto path has no equivalent. Suggest a loading flag cleared when the cursor actually changes:

```js
mounted() {
  this.intersecting = false;
  this.lastCursor = this.el.dataset.cursor;
  this.observer = new IntersectionObserver((entries) => {
    this.intersecting = entries[0].isIntersecting;
    if (this.intersecting) this.maybeLoad();
  }, { rootMargin: "200px" });
  this.observer.observe(this.el);
},
updated() {
  // Only fire when a new page actually landed (cursor changed), not on
  // every unrelated diff.
  if (this.el.dataset.cursor !== this.lastCursor) {
    this.lastCursor = this.el.dataset.cursor;
    if (this.intersecting) this.maybeLoad();
  }
},
maybeLoad() {
  if (this.loading) return;
  this.loading = true;            // cleared by the next updated() (cursor change)
  this.pushEvent(this.loadMoreEvent(), {});
}
```

This also gives `data-cursor` a real consumer (see nitpick below) and makes the "keep firing while still on screen" behavior intentional rather than a side effect of arbitrary diffs.

---

## NITPICK — `data-cursor` is written but never read in JS

`pagination.ex` sets `data-cursor={@infinite && @cursor}` and the hook comment claims the cursor "changes per page so the LV patch re-triggers `updated()`." That works only as an indirect side effect: changing the attribute guarantees the sentinel is part of the diff so `updated()` is called. The hook never actually reads `dataset.cursor`. It functions today, but the intent is non-obvious — adopting the cursor-comparison guard above turns it into a real, self-documenting dependency.

## NITPICK — `infinite` without `id` fails only at runtime

When `infinite` is true the hook needs `id`, but `id` defaults to `nil` and nothing enforces the pairing. A caller who sets `infinite` and forgets `id` gets a LiveView "hook requires a unique id" runtime error rather than a clear compile-time signal. Documented in the attr doc, so low priority — a guard clause in `load_more/1` raising a friendly message would be nicer.

## NITPICK — V122 moduledoc says "Two unrelated additions" but lists three

`v122.ex` opens with "Two unrelated additions bundled together" then documents three sections (location_spaces, staff translations, Person.name). Cosmetic; the section headers themselves are clear.

---

## Verified correct (no action)

- **V123 sku-index drop matches V87's name.** V87 creates `unique_index(:phoenix_kit_cat_items, [:sku], where: "sku IS NOT NULL")` with no `name:`, so the default `phoenix_kit_cat_items_sku_index`. V123's `drop_if_exists(index(:phoenix_kit_cat_items, [:sku]))` resolves to the same default name — drop succeeds. `down/1` recreates the identical partial unique index.
- **Idempotency.** V122/V123 use `create_if_not_exists`, `ADD COLUMN IF NOT EXISTS`, DROP-then-ADD for CHECK constraints, and an `information_schema` guard for the `folder_uuid` FK — all safe to re-run, including on hosts that picked up the pre-bundling "early V122."
- **V122 `down` over-drops deliberately.** Dropping `first_name/middle_name/last_name` (never created by this `up`) with `IF EXISTS` is harmless defensive cleanup for the abandoned early sketch — documented inline.
- **Translations shape** mirrors the V112 projects precedent (`JSONB NOT NULL DEFAULT '{}'`, primary in dedicated columns, JSONB for non-primary overrides). Consistent.
- **PDF.js installer mount** is idempotent (`String.contains?(~s(at: "/_pdfjs"))` short-circuit), gated on `Deps.has_dep?(:phoenix_kit_catalogue)`, and the install/update double-call is safe because of that guard. Inserted right after `use Phoenix.Endpoint` (early in the pipeline) — correct for a static mount.
- **Cross-row "child shares parent's location" invariant** left to the consumer context rather than a composite FK — reasonable given the surface, and explicitly documented.
