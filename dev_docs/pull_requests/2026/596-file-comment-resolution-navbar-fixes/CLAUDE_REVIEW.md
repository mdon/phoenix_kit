# PR #596 — File-comment resolution, annotation deep-link, admin navbar fixes

Reviewed post-merge (2026-06-17). No blocking issues. The deep-link wiring is correct and
the navbar/CSS fixes are sound. Two low-severity notes on `resolve_comment_resources/1`.

## NITPICK — `thumb_url` is emitted for every image, even without a thumbnail variant

`lib/phoenix_kit/annotations/annotations.ex` — `resolve_comment_resources/1`

```elixir
if file_type == "image",
  do: Map.put(info, :thumb_url, URLSigner.signed_url(to_string(uuid), "thumbnail")),
  else: info
```

`URLSigner.signed_url/2` only builds a URL string — it does **not** check that a
`"thumbnail"` instance actually exists for the file. So an image that never had a thumbnail
variant generated still gets a `thumb_url`, and the moderation chip would render a broken
image (the `/file/:uuid/thumbnail/:token` route 404s). The doc comment claims it "falls
back to no thumb for … missing variants", but the code has no such fallback.

Low impact (most images get thumbnails), but either soften the comment or gate on the
variant's existence if the moderation UI doesn't already guard against a failed image load.

## NITPICK — `rescue _ -> %{}` collapses all resolutions on a single failure

The `rescue` wraps the whole query + `Map.new`, so one bad row / one `signed_url` raise
drops **every** resolution to `%{}`, not just the offending uuid. Fine as defensive belt-
and-suspenders for an admin display path, but worth knowing it's all-or-nothing.

## Verified good

- **Deep-link target matches.** `media_detail.ex` pushes `fresco_id: "media-zoom-" <>
  file_uuid`, which is exactly the id `media_canvas_viewer` assigns to its Etcher canvas —
  so `etcher:select-shape` reaches the right layer.
- **`push_event` in `mount/3` is safe.** It's a no-op on the disconnected (static) mount and
  fires on the connected mount; the JS bridge retries `layer.selectShape` for ~6s (60 ×
  100ms) until the layer + shape exist, covering async canvas init. Guarded by
  `is_binary(annotation_uuid) and annotation_uuid != ""`.
- **navbar / CSS fixes** are presentational and correctly scoped: `isolate` confines the
  hero `z-30` to the card's stacking context (modals live outside, unaffected); the mobile
  breadcrumb collapse hides the `Admin Panel /` prefix only when `@page_title` is present.
