# PR #593 — Media viewer deep-zoom: progressive resolution + DZI tiles (Tessera 0.3)

**Status:** MERGED to `main` (`0f76ba72`, Merge: `41057ae2 a70a95d3`). Retrospective review.
**Scope:** 11 files, +168 / −70. Version bump → `1.7.147`. Dep bump `tessera ~> 0.2 → ~> 0.3` (+ jsDelivr pin `v0.2.1 → v0.3.1`). Two logical changes bundled:
1. Tessera 0.3 deep-zoom (medium → large → DZI tiles ladder) wired into the canvas viewer, and the `"dzi"` manifest URL centralized in `URLSigner.put_dzi_url/3`.
2. A scoped-`MediaBrowser`-root fix (commit `a70a95d3`) that shows the scope folder's header customizations at the root of an embedded browser.

Overall: clean, well-commented work. The `put_dzi_url/3` extraction is a genuine improvement (one source of truth across browser / detail page / lightbox — verified all three now pipe through it and that the lightbox actually renders `MediaCanvasViewer` so the URL is consumed, not dead). Component wiring is correct: `Tessera.layer`'s attr API (`fresco_id`, `sources`, `dzi_url`) matches the call site exactly, and `sources`'s `%{url, width}` element shape is what the layer JSON-encodes. Lifecycle ordering is sound (`:scope_folder` is assigned in `init_socket` before the nav path or template read it), and `assign_folder_header_media/2` has a nil-safe catch-all clause. The hardcoded width hints `800`/`1920` match the real variant dims (`file_instance.ex` medium 800×600 / large 1920×1080). `mix compile` is clean. **No BUGs / crashers found.**

Findings below are improvements + one context note.

---

## IMPROVEMENT - MEDIUM — `header_folder` fallback is broader than "the root" the commit targets

Commit `a70a95d3` ("Show folder header customizations at a **scoped root**") introduces `header_folder = @current_folder || @scope_folder` (`media_browser.html.heex:237`) and the matching `assign_folder_header_media(current_folder || socket.assigns[:scope_folder])` (`media_browser.ex:318`).

`current_folder` is `nil` not only at the scoped root but also in the **all-files**, **orphaned**, **trash**, and **search-result** views (`resolve_folder/2` returns `nil` whenever `folder_uuid` is blank — `media_browser.ex:347`). So in a scoped browser the scope folder's *description + creation-info* (creator / date / file-count) now render under those views too — not just at the root.

That is fine *if* intended (an embedded browser keeping its visual identity across all its views). The wrinkle is the title `<h2>` (`media_browser.html.heex:605-618`) is driven by a separate `cond` and still reads "All Files" / "Trash" / "Orphaned Files" in those views — so the **title and the metadata below it disagree** (title says "All Files", description/creator/date describe the scope folder). At the actual root, and in search (which falls through to the `scope_folder_name` title arm), title and metadata agree.

Caveat that bounds the impact: `/admin/media` is *unscoped*, so `scope_folder` is `nil` there and the fallback is a no-op — no regression on the full admin page. The disagreement only surfaces in **scoped** (embedded) browsers that actually expose all-files / trash / orphaned views.

**Fix (if the disagreement is unwanted):** gate the fallback to the real root — e.g. only fall back to `@scope_folder` when there is no active search, `file_view != "all"`, and neither `filter_orphaned` nor `filter_trash` is set. Otherwise leave as-is but confirm the embedded-browser intent.

---

## IMPROVEMENT - MEDIUM — No tests for `put_dzi_url/3`, and the scoped-root header feature is untested

`rg 'put_dzi_url|"dzi"|tile_generation|Tessera' test/` → **no hits.** `put_dzi_url/3` (`url_signer.ex:148`) is a pure function (map in → map out, conditional on `mime_type` + the `storage_tile_generation_enabled` setting) that **mints a signed URL** — exactly the kind of security-adjacent, side-effect-free logic that is trivial to unit-test and costly to regress silently. Worth covering at minimum:

- non-image mime → map unchanged
- image + tile-gen **disabled** → unchanged (no `"dzi"` key)
- image + tile-gen **enabled** → `"dzi"` present, path shape `/tiles/<token>/<uuid>.dzi`, token `== generate_token(uuid, "dzi")`
- `nil` mime and non-binary `mime_type` → unchanged
- fallback clause (`urls` not a map, or `file_uuid` not binary) → unchanged

Separately, the **headline behavior of `a70a95d3`** — a scoped `MediaBrowser` showing the scope folder's header at its root — has no test either. The existing `media_browser_test.exs` / `media_browser_scope_test.exs` cover `scope_folder_id` validity banners and upload targeting, not header rendering. A rendering assertion (`render_component` scoped to a customized folder → description/creator present at root, Edit button absent) would lock the read-only-at-scoped-root contract that the template carefully enforces (`:if={@current_folder}` on the Edit button + add-description placeholder).

---

## IMPROVEMENT - LOW — Lost security-rationale comment; the `dzi` token inherits the known signing weakness

The pre-refactor inline code in `media_browser.ex` carried a useful security note that did **not** survive the extraction into `put_dzi_url/3`: the `"dzi"` instance name is deliberately distinct from storage variants (`"original"`/`"small"`/`"medium"`/`"large"`) so **a leaked file-serving token can't grant tile access** (and vice-versa). `put_dzi_url/3`'s `@doc` (`url_signer.ex:135-147`) explains *what* the URL is but not *why* the namespace is separate. Worth a one-line restore in the doc.

Related context (not a regression introduced here — the inlined code minted the token identically): the `dzi` token is `generate_token(file_uuid, "dzi")` → first 4 hex chars of MD5, ~65k space, **never expires**, exactly like every other variant token. That weakness is already tracked in the `AGENTS.md`/`CLAUDE.md` TODO ("Signed file-URL hardening"). The extraction is a fine place to keep that in mind, but no action is required in this PR — just noting the `dzi` path shares the same exposure, and tile manifests are arguably the most interesting target (one URL → whole-pyramid access).

---

## IMPROVEMENT - LOW — Hardcoded width hints `800` / `1920` duplicate variant-dimension knowledge

`media_canvas_viewer.html.heex:116` builds the Tessera ladder with literal widths:

```elixir
([{f.urls["medium"], 800}, {f.urls["large"], 1920}] ++
   if(use_tiles, do: [], else: [{f.urls["original"], Map.get(f, :width) || 4096}]))
```

`800` / `1920` are correct today (medium 800×600, large 1920×1080 — `lib/modules/storage/schemas/file_instance.ex:9-10`, `storage.ex:615,628`). But the detail page already derives this from instances (`build_variant_dimensions/1`), and the canvas viewer hardcodes it. If variant dims ever change, the Tessera swap points drift silently (swaps at the wrong zoom level — a subtle UX regression with no compile signal).

**Fix:** either source the widths from the file's instances the way the detail page does, or at least anchor the literals with a comment tying them to the variant defs so a future change is caught.

---

## IMPROVEMENT - LOW — `>4K` image with `dzi` but no `medium`/`large` → Tessera layer skipped entirely

`media_canvas_viewer.html.heex:111-126`:

```elixir
over_4k = max(...) > 4096
has_dzi = is_binary(f.urls["dzi"]) and f.urls["dzi"] != ""
use_tiles = over_4k and has_dzi
tessera_sources = ([{medium,800}, {large,1920}] ++ if(use_tiles, do: [], else: [{original,…}]))
                 |> Enum.filter(...)   # drops nil/"" urls
...
<%= if tessera_sources != [] do %> <Tessera.layer ... dzi_url={tessera_dzi} /> <% end %>
```

When `use_tiles` is true the `original` is intentionally dropped (the DZI pyramid covers the top). But the layer is then gated on `tessera_sources != []`. For a `>4K` image that has a `dzi` manifest but is missing **both** `medium` and `large` variants, `tessera_sources` is empty → the layer never renders → **no deep zoom despite a perfectly good DZI manifest** that could serve the whole pyramid on its own. Rare (images normally get medium/large during processing), and the `dzi_url` is passed but the `if` guard prevents the layer from mounting.

**Fix:** render the layer whenever `has_dzi` even if the raster ladder is empty — e.g. guard on `tessera_sources != [] or has_dzi`, or seed `tessera_sources` with a dzi-derived base level.

---

## Nits

- `media_canvas_viewer.ex:404` now opens on `medium` and keeps the canvas at the original `:width`/`:height` so the coordinate space matches the DZI pyramid and Etcher annotations. Correct — just noting the initial paint of a large original is an upscaled medium until Tessera swaps up (intended; the 0.3.1 pin lowers the headroom so the swap is prompt).
- `mix.exs` `tessera ~> 0.3` is correctly `0.3.x`-only (no `0.4`), and the jsDelivr pin (`phoenix_kit.js` → `@v0.3.1`) matches the locked hex version (`mix.lock` → `0.3.1`). The new comment in `phoenix_kit.js` about keeping the pin in sync is a good guard against the silent-no-op failure mode called out there.
- CHANGELOG entry is well-written and matches the existing Added / Changed section style.
