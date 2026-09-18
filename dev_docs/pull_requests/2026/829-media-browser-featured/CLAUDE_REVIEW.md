# PR #829 — MediaBrowser: optional host-owned featured image

**Author:** Timujeen (`feat/media-browser-featured`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

14 files: an opt-in `:featured` attr on `MediaBrowser` (star badge + "Set as
featured" kebab item in the grid, list and stack views), a mirrored `:featured`
assign on `MediaCanvasViewer` for the modal sidebar, a 356-line test file, three
new msgids. Includes the round-1 follow-up `4451a214` (tooltip reachability).

## Verdict

The design is right — the browser relays and never persists, and the opt-in
default keeps every existing consumer untouched. One **BUG - MEDIUM** found and
fixed with a regression test; one doc correction applied; two notes.

Checked and correct:

- **The optimistic update cannot get stuck.** `update/2` runs `assign(assigns)`
  *before* the `assign_new(:featured, …)` default, so a host correction — whether
  by `send_update` or by its next ordinary re-render — overwrites the locally
  flipped uuid. The documented "corrects it with a later `featured` assign" path
  really works; `assign_new` only supplies the off default.
- **`send(self(), …)` reaches the host.** Inside a LiveComponent callback `self()`
  is the LiveView process, and the `{__MODULE__, id, payload}` shape already
  carries `{:navigate, …}` (`media_browser.ex:2654`), so this rides an established
  channel rather than inventing one.
- **No badge collision.** The star sits at `top-2 left-2`, shared with the video
  and PDF badges — which render only for `file_type == "video"` and
  `mime_type == "application/pdf"`, while the star renders only for
  `file_type == "image"`. Mutually exclusive, as the code comment claims.
- **`MediaCanvasViewer`'s other consumers are safe.** Its `update/2` has dedicated
  `%{action: …}` clauses for every partial `send_update`, so the catch-all clause
  that does `assign(:featured, assigns[:featured])` only ever sees a full parent
  render — a partial update cannot blank the assign. `MediaViewer`/`MediaDetail`
  pass nothing and get `nil`, and every `@featured.uuid` read in the template sits
  behind a short-circuiting `@featured &&`.
- The `4451a214` tooltip fix is sound: the inner `pointer-events-auto` span is
  inside the tile's `phx-click="click_file"` div, so a click on the star still
  bubbles up and opens the viewer. No dead zone.

## BUG - MEDIUM — the viewer let a trashed image be made the featured one *(fixed)*

All three kebab entries gate the action on `!@filter_trash`. The viewer sidebar
button did not:

```heex
<button :if={@featured && f.file_type == "image"}   <!-- media_canvas_viewer.html.heex -->
```

**Failure scenario:** open the trash listing, click a trashed image's tile — trash
tiles click straight through to the viewer via `click_file` → `locate_file/2`,
which searches the current listing — and the sidebar offers "Set as featured".
Clicking it sends `{:set_featured, uuid}` to the host, which persists a pointer to
a file already queued for deletion. The host then renders a featured image that
disappears at the next cleanup run. The three kebabs were written to prevent
exactly this; the fourth surface was missed.

**Fix:** gate the viewer button on the file's own status, which is strictly more
precise than `@filter_trash` (it also covers a file trashed in another session
while this listing is stale):

```heex
:if={@featured && f.file_type == "image" && Map.get(f, :status) != "trashed"}
```

`Map.get/2` rather than `f.status` because `MediaCanvasViewer` is shared with
`MediaViewer`/`MediaDetail`, whose file maps are not `MediaBrowser`'s — the
`@featured &&` short-circuit already protects them, and the defensive read means a
future host that opts in with a leaner map degrades to "not offered" instead of a
`KeyError` that takes the viewer down.

**Test:** `media_browser_featured_test.exs` — "a trashed image offers no toggle,
matching the kebabs' `!@filter_trash` gate". Verified it fails against the
pre-fix template (`refute has_element?` on the sidebar button) and passes after;
it also asserts the viewer actually opened, so it cannot pass vacuously.

## IMPROVEMENT - MEDIUM — the moduledoc understated how a mis-wired host fails *(fixed)*

The `:featured` docs said hosts routing every `{MediaBrowser, _, _}` through
`handle_parent_info/2` "must match `{:set_featured, _}` first, since
`handle_parent_info/2` does not handle it" — which reads like the host would find
out, loudly.

It would not. `handle_parent_info/2` ends in
`def handle_parent_info(_msg, socket), do: {:noreply, socket}`
(`media_browser.ex:1061`). The message is swallowed: no crash, no log, and the
star still flips in the UI because the optimistic local assign is independent of
the host ever hearing about it. The host ships something that looks like it works
and never writes a row. Reworded to state the catch-all and that exact symptom.

## Note — the relayed uuid is not validated against the listing

`handle_event("set_featured", %{"file-uuid" => uuid}, …)` relays whatever uuid the
client sends. The kebab and sidebar only render for images the browser is
currently showing, but a crafted or stale client can post any uuid — including a
non-image, a trashed file, or one outside the browser's `scope_folder_id`.

Left as is: the component's contract is explicitly "the browser never persists the
choice itself", so the host owns the write and is the only layer that can
meaningfully authorize it. Worth stating plainly in the host's own code, which is
what this note is for — a host must not treat `{:set_featured, uuid}` as
pre-validated.

## NITPICK — the star overlaps the select-mode checkbox

In select mode a featured tile draws the checkbox at `top-1 left-1 z-10` and the
star at `top-2 left-2`. They visually collide. Not introduced here — the video and
PDF badges have always sat in the same spot — and the star is
`pointer-events-none` on its outer div, so the checkbox still wins every click.
Cosmetic, and fixing it belongs to a pass over all three badges.

## Note — the list view shows no star

The badge is a tile overlay, so grid and stack views show it and the table rows do
not; there the kebab's filled-vs-outline star icon is the only indication. Matches
what the commit describes and is reasonable for a table row.
