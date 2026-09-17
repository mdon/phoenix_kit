# PR #825 — Title and description in the media viewer's sidebar

**Author:** alexdont (`viewer-media-meta`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-17 (post-merge)

3 files: `MediaCanvasViewer` gains a collapsible "Title & description" section
between the action buttons and the technical row, an inline editor where the host
already offers a road to the metadata editor (`details_path` / `edit_target`), and
a new test file. Writes merge into the file row's `metadata` JSONB under the same
`"title"` / `"description"` keys `MediaDetail`'s editor uses. The rotation seed
read is folded into one `seed_file_row_state/2` that serves both.

## Verdict

The feature is right and the merge-don't-replace discipline is right — it is the
detail. But the editability rule lives only in the template, so the write handler
accepts the event from every host, including the ones that deliberately render the
section read-only. And the DB half of the test suite could never have passed, so
none of the guarantees the commit message leads with were actually verified.

Both fixed, plus the status-pill token guard the neighbouring rotation code already
has and the PR's own comment already claimed.

## Findings

### BUG - HIGH — `save_media_details` had no server-side gate (FIXED)

`lib/phoenix_kit_web/components/media_canvas_viewer.ex:449`

The template decides editability with `can_edit_meta = @details_path != nil or
@edit_target != nil` and renders a read-only paragraph pair otherwise. The
`handle_event("save_media_details", …)` clause checked nothing: it read the row and
wrote `metadata["title"]` / `["description"]` for any sender.

The section renders for every host that shows the sidebar. `MediaViewer` — the
lightbox `MediaGallery` embeds, including in `readonly` mode, where its moduledoc
says "preview (lightbox) still works" — passes neither `details_path` nor
`edit_target`, and its `current_user` is documented nil-tolerant. So an anonymous
visitor of a host page carrying a readonly gallery could push
`save_media_details` by hand and rewrite the title and description of the shared
file row for every surface that reads it, `/admin/media/:uuid` included. No
rendered control offers it; a hidden form is not a boundary.

This is the rule the module already states for annotations — `can_annotate: false`
means "the server refuses `etcher:annotations-changed` / `etcher:shape-drawn`
outright — Etcher's flag is UX, this is the boundary" — and the same rule
`persist_rotation` follows in `handle_event("fresco:rotate", …)`.

Fix: a leading clause refusing the event on
`%{assigns: %{details_path: nil, edit_target: nil}}`, mirroring the
`can_annotate: false` clauses, and one shared predicate,
`can_edit_media_meta?/2`, that both the template and the handler now read, so the
two cannot drift into a hidden form the server still honours. The refusal is a
silent no-op rather than an `:error` pill: those hosts render no form to report a
failure in.

### BUG - MEDIUM — the DB tests never passed (FIXED)

`test/phoenix_kit_web/components/media_canvas_viewer_media_meta_test.exs`

On the merged tree, `mix test` on this file gave 4 tests, 2 failures — both DB
tests dying in `setup`, for two independent reasons:

1. The `Storage.File` fixture omitted `user_uuid`, `file_checksum` and
   `user_file_checksum`, all `validate_required`, so `Repo.insert/1` returned
   `{:error, changeset}` and the `{:ok, file} =` match raised.
2. Even with a valid row, the setup returns `%{file: file}` and `:file` is a
   reserved ExUnit context key — `raise_merge_reserved!/4`.

So the two assertions the commit message leads with — that a title edit does not
eat `rotation` or `tags`, and that a vanished row reports an error instead of
raising — had never run. Nothing catches this: `mix precommit` compiles test files
but runs no tests, and CI is `workflow_dispatch`-only.

Fix: a `file!/2` helper that registers a user and supplies both checksums, and the
context key renamed to `:row`. The file now runs 7 tests, 0 failures.

### IMPROVEMENT - MEDIUM — the save-status pill had no token guard (FIXED)

`send_update_after(…, :clear_media_meta_status, 2000)` carried no token, so a
second Save inside the two-second window left the first save's timer alive to wipe
the status the second one had just put up. The rotation pill immediately below
solves exactly this with `rotation_status_token`, and the comment the PR left
sitting above the new clause described that guard as if it applied here.

Fix: `media_meta_status_token`, bumped per save and checked in the `update/2`
clause, mirroring the rotation code. Covered by a new test.

### NITPICK — misplaced and stale comments (FIXED)

The new `update(%{action: :clear_media_meta_status}, …)` clause was inserted
*between* the rotation clause and the rotation clause's own comment, leaving that
comment describing the wrong function. And `seed_file_row_state/2` kept
`load_saved_rotation/1`'s header comment ("The image's saved orientation
(degrees)…") although it now seeds the title and description too. Both rewritten.

### IMPROVEMENT - MEDIUM — no length bound on the stored strings (not fixed)

`title` and `description` go into JSONB straight from the form with no cap, where
the module is otherwise careful with client-supplied values that reach storage
(`@max_etcher_colors`, `@etcher_color_format`). Left alone deliberately: with the
gate above in place the writers are exactly the users who already have
`MediaDetail`'s `save_metadata`, which is equally uncapped, so a bound here would
be half a rule. If one is wanted it belongs on both surfaces, in one place.

## Not findings

- **Metadata merge.** `(row.metadata || %{}) |> Map.put(…)` on a freshly re-read
  row is correct, and matches `persist_rotation/3` and `MediaDetail`'s
  `save_metadata`. The re-read is necessary — the parent-passed file map carries no
  `metadata`.
- **Folding the rotation read into one query.** `seed_file_row_state/2` runs in the
  `viewer_canvas == nil` branch only, i.e. once per mount, and replaces a read that
  was already there. No extra query, and no query in `mount/1`.
- **Form id.** `id={"media-meta-form-" <> f.file_uuid}` is present and unique per
  file, as the repo requires.
- **Same keys as the detail page.** Verified: `media_detail.ex:328` reads
  `metadata["title"]` / `metadata["description"]`, and only that page reads them.
