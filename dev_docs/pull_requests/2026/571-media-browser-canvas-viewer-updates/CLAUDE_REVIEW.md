# PR #571 — Updates to the media browser

**Reviewer:** Claude (Opus 4.8)
**State:** MERGED into `dev` (2026-05-29, merge `c89535c3`). Post-merge review.
**Scope:** V124 migration (partial media-folder name index), fresco/etcher/leaf dep bumps, embed `:leaf_changed` forwarding, `MediaCanvasViewer` `viewer_only` mode + annotation-title decorations, `MediaDetail` rebuilt on the canvas viewer, instant-rename UX, sidebar layout/scroll fixes.

## Status — fix applied post-review (2026-05-29)

- **NITPICK (etcher JS pin lags hex)** — **fixed.** `priv/static/assets/phoenix_kit.js` etcher lazy-load CDN pin bumped `v0.5.2 → v0.5.3` to match the resolved hex dep (`etcher 0.5.3`) and the mix.exs comment's stated intent ("jsdelivr-pinned to the matching version"). Verified the `v0.5.3` tag serves (`HTTP 200`). leaf (`0.2.21`) and fresco (`0.6.3`) were already in lockstep between hex and CDN.

Everything else below is left as-is — the remaining findings are either pre-existing patterns I judged too risky to refactor blind (no runnable LV tests here) or intentional design choices worth recording, not fixing.

## Verdict

Clean, well-commented PR. The standout design win is reusing `MediaCanvasViewer` in a new `viewer_only` mode so `MediaDetail` gets the exact same Fresco+Etcher rendering as the in-place modal instead of a second divergent preview implementation — and routing inline annotation-title edits from the comments sidebar back to the embedded component via `parent_module`/`parent_id`. The V124 migration is correct and faithfully reversible. No CRITICAL/HIGH findings.

---

## Verified correct (no action)

- **V124 partial index.** `down/1` recreates the exact V95 shape (same bare index name, same `COALESCE(parent_uuid, '0000…')` expression, no `WHERE`). The moduledoc's note — index name must be bare in `CREATE INDEX` (schema-qualified only in `DROP`) — is correct and applied consistently in both `up` and `down`. Idempotent via `DROP IF EXISTS` + `CREATE … IF NOT EXISTS`. Incidentally more correct than V95, which schema-qualifies the index name in `CREATE` (latent issue for non-`public` prefixes — pre-existing, out of scope here).
- **V122 touch-up** (3 add / 9 del) is pure `mix format` reflow — no semantic change to the migration I reviewed in #570.
- **`@version` / mix.lock.** Version lands at `1.7.124`; `mix.lock` is in sync (fresco 0.6.3, etcher 0.5.3) and `mix deps.get` resolves cleanly even though mix.lock wasn't in this PR's file set (bumped in an earlier commit).
- **`file.width` / `file.height`** exist on the file schema (`schemas/file.ex`), so `MediaDetail`'s `file_data` build can't `KeyError`; `build_viewer_canvas/2` reads via `Map.get(file, :width) || 1000`, so the modal path (whose file map omits dims) keeps its square fallback. Correct.
- **No duplicate `CommentsComponent`.** `viewer_only` suppresses the canvas viewer's whole sidebar (comments included), so `MediaDetail`'s own comments card is the only one — no DOM-id collision. The annotation-title round-trip (`metadata_value` = annotation uuid, `label` = new title) maps correctly to `apply_annotation_title_update/3`.
- **`SelectOnMount`** hook is wired (folder rename input) and carries the required `id`. `file_icon/1` was removed from `MediaDetail` along with its only call site — no dangling reference.
- **Embed `:leaf_changed` forwarding** correctly uses runtime `Code.ensure_loaded?` + `apply/3` (not compile-time module binding) for the optional `phoenix_kit_comments` sibling dep, injected via `@before_compile` so user clauses win.

---

## IMPROVEMENT - MEDIUM — DB queries in `MediaDetail.mount/3` (Iron Law)

`lib/phoenix_kit_web/live/users/media_detail.ex:48-49`

```elixir
|> load_file_data(file_uuid)
|> assign(:viewer_annotations, MediaCanvasViewer.load_annotations_for(file_uuid))
```

`mount/3` for a routed LiveView runs **twice** (dead HTTP render + live WebSocket mount), so both `load_file_data` and the newly-added `load_annotations_for` query the DB twice per page open. This PR didn't introduce the pattern — `load_file_data` was already in mount — but it adds a second query to it.

Recommended (separate cleanup, not this PR): move the data loads to `handle_params/3`, leaving `mount/3` to set only locale/title/defaults. Not fixed here because it's a module-wide pre-existing pattern and a mount→handle_params move can't be verified without running the LiveView (this repo isn't set up for that).

## NITPICK — `forward_leaf_event/2` result match has no catch-all

`lib/phoenix_kit_web/components/media_browser/embed.ex`

```elixir
case apply(mod, :forward_leaf_event, [msg, socket]) do
  {:noreply, _} = result -> result
  :pass -> {:noreply, socket}
end
```

If a future `phoenix_kit_comments` returns anything other than `{:noreply, _}` or `:pass`, this raises `CaseClauseError` and takes down the host LiveView. Since this is an optional cross-package contract, a defensive `other -> {:noreply, socket}` (or a logged warning) would degrade more gracefully. Left as-is because the strict match is arguably intentional (fail loud on contract drift) — flagging for the author's call.

## NITPICK — inline title update swallows write failures

`MediaCanvasViewer.apply_annotation_title_update/3`

```elixir
_ = PhoenixKit.Annotations.update(annotation_uuid, %{title: title_val})
fresh = if file_uuid, do: load_annotations_for(file_uuid), else: []
```

An `{:error, changeset}` from `update/2` is discarded; the subsequent reload silently shows the unchanged title with no feedback. The "no flash" choice is deliberate for an inline edit, but a failed write currently looks identical to a no-op. Consider at least a `Logger.warning` on the error branch so failures are diagnosable.
