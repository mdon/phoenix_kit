# PR #853: Open the media viewer on the burned copy, and burn only when the drawing changed

**Author**: @alexdont
**Reviewer**: Claude
**Status**: ✅ Merged (`9845a489`), not yet released; every finding below is fixed post-merge
**Date**: 2026-09-21

## Goal

Follows #846 (the burn). The media viewer should open on the **burned copy**
— the picture with its markup rendered in, the thing people look at and
copy — and the pencil switches to the live, editable layer. A burn should
happen once per change of the drawing rather than once per visit: the client
hashes a canonical form of the shapes, the burn endpoint stores that
fingerprint in `file.metadata["burn"]`, and the viewer hands it back on the
next open so an unchanged drawing is not recomposed. `burned` grows from 800
to 1920px since it is now the viewer's copy. The editor's Tessera ladder
starts at `small` and tops out at `large`, and all three canvases are forced
light so the burned copy (composed on white) does not flash against a dark
theme.

## Verified

- **The fingerprint is sound as a change detector.** `burnCanonical` sorts
  object keys recursively, so a shape read back from the database
  (`{h, w, x, y}`) hashes like the one just drawn (`{x, y, w, h}`); shapes
  are sorted by their canonical form, so server order is not a change. FNV-1a
  32-bit is ample for "did this drawing change": a collision only skips one
  burn.
- **An image edit does not leave unredacted pixels in `burned`.** The first
  edit moves every instance to the hidden backup (`move_to_copies!(backup,
  :all, …)`) and later edits `delete_all` the file's instances, so a redaction
  removes the stale burn along with every other variant. (See the BUG -
  MEDIUM below for what the *fingerprint* does afterwards.)
- The Tessera ladder change is correct: Tessera assumes it is showing
  `sources[0]`, so listing `small` first makes the climb small → medium →
  large as described.
- `theme={:light}` also fixes the burn's background by construction, since
  the compositor reads the viewer's computed background.
- The full suite on the merged tree (this PR, #854 and everything before
  them): 6191 tests, 0 failures — the PR breaks nothing that was tested; the
  findings below are what no test covered.

## Findings

### BUG - HIGH: the viewer never opens on the burned copy — it looks for a variant called `annotated`, which nothing writes

The burn endpoint stores its rendering as the variant **`burned`**
(`@writable ~w(thumbnail burned)`, `store_prepared_variant(file, "burned",
…)`), the client asks for and reads back `burned` (`"thumbnail,burned"`,
`v.variant === "burned"`), and `MediaThumbnail` cards read `urls["burned"]`.
But the three new server-side lookups this PR adds all read **`annotated`**:

- `MediaBrowser.burn_size/1` — `Enum.find(instances, &(&1.variant_name == "annotated"))`
- `MediaCanvasViewer.burned?/1` — `is_binary(file.urls["annotated"])`
- `MediaCanvasViewer.build_burn_canvas/1` — `src = file.urls["annotated"]`

No code in core writes an `annotated` variant (the baked thumbnail is
`thumbnail_annotated`), and `git log -S'"annotated"'` shows these lookups
first appear in this PR — the name never existed on the write side. Probed on
the merged tree, with a file map shaped exactly as
`generate_urls_from_instances/4` builds one after a burn:

```
burned?(file whose burn is stored as `burned`)      = false
burned?(same, url key renamed to `annotated`)       = true
```

So `burn_canvas` is `nil` on every open, `data-has-burn` is `false`, and the
viewer opens on the live layer — the PR's headline behaviour does not happen.
It only *appears* to work within a session: right after a burn, the client's
`burn_stored` event builds the canvas from the URL it was handed, so "draw →
pencil off → the burned view shows the new rendering" holds, and any reopen
(or reload) loses it again.

**Fix:** read `burned` in all three places (`burn_size/1`, `burned?/1`,
`build_burn_canvas/1`). A test that stores a real `burned` instance and
asserts the viewer mounts with `burn_canvas` set would have caught it.

> **Fixed post-merge.** `MediaBrowser.burn_size/1` looks for the names the
> endpoint writes — `burned_large`, else `burned` (see the IMPROVEMENT below)
> — and returns the variant with the size, so `burned?/1` and
> `build_burn_canvas/1` show exactly the image those dimensions describe.

### BUG - HIGH: recording the fingerprint overwrites `metadata` with the map loaded before the burn — a lost update

`remember_fingerprint/2` builds a whole new `metadata` from the `file`
struct fetched at the top of the request and writes it with
`Storage.update_file/2`:

```elixir
metadata = (file.metadata || %{}) |> Map.put("burn", %{...})
Storage.update_file(file, %{metadata: metadata})
```

A burn request runs for seconds (a multi-MB upload, a sanitize, one resize
and store per variant). Any other write to the same `metadata` in that
window is silently reverted: the rotation (`metadata["rotation"]`, written by
the viewer's rotate button and by `ApplyImageEditJob`), the primary-language
title/description copy `FileDetails` keeps there, tags, the EXIF/PDF keys.
The burn now fires when the user turns the pencil off — and the natural next
move in the same viewer is often to rotate the picture or fix its title.

Core already names this exact pattern. `Storage.update_file_metadata/2`'s
doc: *"Every read-modify-write of `metadata` belongs here; `update_file/2`
with a `metadata:` built from a struct in hand is the lost update."*

**Fix:**

```elixir
Storage.update_file_metadata(file, fn metadata ->
  Map.put(metadata, "burn", %{"fingerprint" => fingerprint, "at" => now})
end)
```

— it re-reads the row `FOR UPDATE` and merges into the map as it is now.

> **Fixed post-merge** exactly so.

### IMPROVEMENT - HIGH: grid cards now download the 1920px burn

`MediaThumbnail.resolve_url(file, :card)` prefers `urls["burned"]` over
`small` (300px). Raising `@burned_edge` from 800 to 1920 makes every annotated
file's card fetch a 1920px JPEG — roughly 40× the pixels of `small` — and
"cards scale it down as they always did" is exactly the waste: the browser
downloads and decodes it all to paint a card. A grid page of annotated photos
goes from light to heavy.

The endpoint already writes several variants from one upload in one request;
keep a card-sized burn (≤ 800, what cards read) and add the viewer-sized one
as its own variant (e.g. `burned_large` at 1920) for the viewer to open with.

> **Fixed post-merge** so: `burned` is back to 800 (cards), `burned_large`
> is a new writable slot at 1920 (the viewer), and the hook's default slots
> are `thumbnail,burned,burned_large`. A client that asks for no large copy
> still gets a viewer that opens on `burned`.

### BUG - MEDIUM: after an image edit the burn is never recreated — the fingerprint outlives the copy it described

An edit deletes the file's `burned` instance (see Verified), but
`metadata["burn"]["fingerprint"]` is not touched. On the next visit the
viewer hands that fingerprint back (`burn_fingerprint`), the client's shapes
still hash to it, and `burnIfChanged` returns early — so no burn is made, and
the file stays without a burned copy (cards fall back to the bake or the
plain `small`) until somebody changes the drawing.

The fingerprint describes the shapes only, not the picture under them.
Either fold the source version (the original's `v`, which the client already
sends as `source_version`) into the hash, or have `MediaBrowser` hand back
`burn_fingerprint` only when a `burned` instance actually exists.

> **Fixed post-merge** the second way (`MediaBrowser.burn_fingerprint/2`):
> no stored burn, no fingerprint, so the next session end burns.

### NITPICK: `burn_stored` trusts the client's URL and size

`handle_event("burn_stored", …)` builds the canvas from `params["url"]`,
`"width"` and `"height"` as sent. Only the sender's own socket renders it, so
this is not a cross-user issue, but the server can compute the signed URL and
extent itself from the stored instance instead of echoing them. Its
`burn_version` fallback, `Integer.to_string(w * h)`, also collides for two
burns of the same size (the canvas is `phx-update="ignore"`, so an unchanged
id keeps the old image); the fingerprint should be required there.

> **Fixed post-merge.** The client now names only the slot that landed;
> `burn_stored` reads that instance of the file the viewer has open and
> builds the URL, extent and version itself. The version is the stored
> bytes' (`URLSigner.version/1`), so it changes exactly when a new burn does.

## Tests added post-merge

`test/integration/phoenix_kit_web/burned_copy_test.exs` (stored files and
instances, end to end through `MediaBrowser`'s lookups, `burned?/1`,
`remember_fingerprint/2` and `burn_stored`) and two cases in
`annotation_burn_controller_test.exs`. With the original `annotated` lookup
and the whole-map write put back, exactly the four tests that pin them fail.
`test/js/annotation_burn.test.cjs` now compares the default slots as whole
names — its substring check would have rejected `burned_large` as the
ladder's `large` — and pins that `burn_stored` never carries a URL or size.
