# Deep zoom rework

**Status:** the library's *Deep zoom* switch is **locked** (disabled, with a note, and the
`deep_zoom` event refuses) while we redo how zooming works. Nothing else changed: the
serving code, `Libraries.setting(library, :deep_zoom)`, `VariantSets.deep_zoom_for_library?/1`
and the tile controller are untouched, so a library that already has it on keeps serving
tiles, and a library that has it off stays off. To unlock, undo the three edits listed in
[Unlocking](#unlocking).

Written 2026-10-12 after a read-only walkthrough of the code (no changes to tiles
themselves). Deep zoom had never been switched on in dev: zero tile rows exist, both dev
rendition profiles have `generate_tiles` false, and no library has a `deep_zoom` setting.
So everything below is from reading the code, **not** from watching tiles being cut.

## How it works today

- **Pieces.** Fresco (the viewer, OpenSeadragon-based) + Tessera (`deps/tessera` 0.3.8:
  JS that swaps image sources while zooming, and an Elixir tile cutter) + Etcher (the
  annotation layer). The viewer is
  `lib/phoenix_kit_web/components/media_canvas_viewer.ex`.
- **The ladder** (`tessera_ladder/1`, ~line 1785): `small` (300) → `medium` (800) →
  `large` (1920). The DZI manifest (`urls["dzi"]`) is appended **only if**
  `max(width, height) > 4096` **and** the file has a `dzi` URL. The ladder deliberately
  stops at `large`; the original is never loaded into the viewer (it stays a download).
- **Swap thresholds** (`deps/tessera/priv/static/tessera.js`): displayed width =
  scale × canvas width × devicePixelRatio; swap up at 1.1× the source's width
  (`UPGRADE_HEADROOM`), swap down below 0.85× (`DOWNGRADE_HYSTERESIS`); tiles activate at
  1.1× (`TILE_ACTIVATE_HEADROOM`) — about 2112 px displayed for the 1920 `large`.
- **URLs.** `URLSigner.put_dzi_url/4` (`url_signer.ex` ~398) adds `urls["dzi"]` for an image
  when tiles are on for the file's library (`VariantSets.tiles_for?/1`):
  `/tiles/<token>/<uuid>-<v>.dzi` and
  `/tiles/<token>/<uuid>-<v>_files/<level>/<col>_<row>.<ext>`. The version is in the path
  because OpenSeadragon drops query strings; a stale version is a 404; the legacy
  unversioned `.dzi` resolves to the current one and is not cached. Versioned tiles are
  `public, max-age=31536000, immutable`; private libraries use a time-window token and
  `private, max-age=3600`.
- **Serving** (`file_controller.ex`: `serve_manifest/2`, `serve_tile/2`). Tiles are cut
  lazily on the first request (`ensure_tile_cached`), one per-source-file lock
  (`with_tile_lock`, double-checked). `tile_source/2` reads the file and its original under
  `FOR SHARE` and refuses non-images, files being edited, and files with no dimensions.
- **Cutting** (`Tessera.TileGenerator.generate_tile/4`): tile 256 px, overlap 1, JPEG,
  quality 80. For **each** tile it runs
  `convert <original> -auto-orient -crop WxH+x+y +repage -resize outWxoutH! -quality 80`,
  i.e. it decodes the whole original again per tile.
- **Storage** (`Storage.TesseraAdapter`): every tile and the manifest go through
  `Storage.store_system_file/3` under `_tiles/<uuid>/<v>/…`, in every bucket, as a
  `system_managed` `File` row (`file_type: "tile"`, `parent_file_uuid`) plus an "original"
  `FileInstance`. They cascade on source delete (V112) and are never served or listed
  through the normal routes.
- **Setting.** Deep zoom belongs to the **library** (`Libraries.setting(library,
  :deep_zoom)`); a library that has not chosen follows its rendition profile's old
  `generate_tiles` flag (`VariantSets.deep_zoom_for_library?/1`). Turning it off only stops
  serving; existing tiles stay stored and are used again if it is turned back on.

## What is wrong with it (the reasons for the rework)

1. **The 4096 px gate leaves a gap.** An original of 4096 px or less never gets tiles, so it
   cannot be zoomed past `large` (1920). On dev, `IMG_4814.jpeg` (4896×3672) qualifies;
   `IMG_2260` (4200×2000) is only just over; a 4000 px photo gets nothing.
2. **A 4K display is past the thresholds at fit-to-screen.** At 3840 px wide (ratio 1) or a
   2× display, the viewer is already upscaling `large` at 100% zoom. This is the case the
   maintainer actually looks at (a huge 4K display), and the ladder tops out too low for it.
3. **Cutting is expensive.** One full decode of the original per 256 px tile; first view
   of a big image means dozens of decodes, serialised by the per-file lock. No eager
   pre-generation, no batch cutting from a pre-scaled intermediate.
4. **A tile is a database row plus bucket writes.** `File` + `FileInstance` + a write per
   bucket per tile; a 9000×3300 image is roughly 400 tiles over all levels (only the ones
   viewed get cut, but it adds up per file per bucket).
5. **Tiles are SDR, metadata-free JPEG q80.** Zooming into an HDR photo drops the gain map,
   so the picture changes look as you zoom. Animated GIFs only use the ladder, so they are
   not affected, but their interplay with the viewer is unverified.
6. **The switch is per library and invisible.** There is no indication on a file of whether
   tiles exist, no way to pre-cut them, no cleanup other than deleting the file.

## Ideas / direction (not decided)

- **Decide the gate by sharpness, not by a fixed 4096.** Offer tiles (or a bigger rung)
  whenever the largest ladder rung would be shown above 1:1 on the viewer's screen — i.e.
  the source is larger than `large`. Or add a rung between `large` and tiles.
- **Cheaper cutting.** Cut the lower levels from a pre-scaled intermediate (or use `vips`,
  whose `dzsave` writes a whole pyramid in one pass) instead of decoding the original per
  tile. Consider cutting a whole level at once rather than lazily per tile.
- **Fewer rows.** Store tiles as plain objects under one key prefix without a `File`
  row each (or one row per pyramid), keeping cascade and the "never served as a file"
  guarantee.
- **HDR.** High-end viewing policy belongs in `phoenix_kit_photos`, not core (the core
  viewer stays simple). Core's job: not make it impossible — e.g. let the host swap the
  tile source or add a gain-map layer. Decide whether tiles carry a gain map at all.
- **Pre-generation / lifecycle.** Optional eager cutting after upload (background job,
  job-run record like the library sync), a "remake tiles" action, and showing on the
  storage page whether a file has tiles and how many.
- **Per-tile `per_page`-style knobs** are not needed; the switch can stay per library.

## Open questions

- Is it worth keeping Tessera, or does a purpose-built cutter (vips) fit better?
- Should tiles be cut for every image at upload (cost/space) or stay lazy?
- What does the viewer do with an animated GIF or WebP source when Fresco is the viewer
  (unverified, also on iPad)?
- Should the viewer load the original directly when it is within a sane size (say ≤ 8000
  px or ≤ 30 MB) instead of tiles?

## Unlocking

Reverse the lock when the rework lands (or to experiment on dev):

1. `lib/modules/storage/web/library_page.html.heex` — remove the
   `library-deep-zoom-locked` paragraph and the two `disabled` attributes.
2. `lib/modules/storage/web/library_page.ex` — put the `put_viewing(:deep_zoom, …)` clause
   back in place of the refusing `handle_library_event("deep_zoom", …)`.
3. `test/integration/phoenix_kit_web/live/library_page_test.exs` — restore the "deep zoom is
   the library's own switch" test (it submits `#library-deep-zoom` with `on` then `off`).

To see tiles on dev without the UI: set the setting from IEx/a script with
`Libraries.put_setting(library, :deep_zoom, true, [])`, restart, and zoom into
`IMG_4814.jpeg`, watching `/tiles/…` requests in `/var/log/elixir.log`.

## Where to start next time

1. Turn deep zoom on for one dev library (via the script above), zoom into `IMG_4814.jpeg`
   on the 4K display and the iPad, and record: time to first tile, tile count, how it feels
   at 100%, what the ladder shows before tiles arrive.
2. Measure the per-tile decode cost on `IMG_2261` (8947×3317).
3. Pick the gate / ladder change (point 1–2 above), then the cutting change (point 3).
