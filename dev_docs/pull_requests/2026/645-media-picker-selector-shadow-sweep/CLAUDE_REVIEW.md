# PR #645 — Fix media picker circle, selector route shadowing, and a media-surface bug sweep

**Author:** Max Don (mdon)
**Merged:** 3f52117b (into `main`)
**Reviewer:** Claude (post-merge)

## Summary of changes

- **Route shadowing fix** (`integration.ex`): `/admin/media/:file_uuid` was
  declared before `/admin/media/selector`, so Phoenix matched `selector` as a
  `:file_uuid` param and the dedicated selector route was unreachable.
  Reordered so the literal segment wins.
- **`MediaSelectorModal` / `MediaSelector` selection model**: `selected_uuids`
  changed from a `MapSet` to an ordered list everywhere (both LiveViews plus
  `UserMediaSelectorModal`). Order now matters — `MediaGallery` treats the
  first selected uuid as the "featured" image, which a set silently
  reshuffled. Added an optional `max_select` cap (multi-select pickers reject
  further picks past the limit and show a "Maximum N files" badge instead of
  the consumer silently truncating on confirm) and a `normalize_mode/1` /
  `normalize_selection/3` pass so string vs. atom `:mode` and seeded
  selections can't desync a `case` downstream.
- **Folder-header image rotation**: `folder_image_url/1` → `folder_image_data/1`
  now returns `%{url:, rotation:}`, threaded through two new assigns
  (`folder_cover_rotation`, `folder_logo_rotation`) so a folder's
  cover/logo respects the file's saved rotation instead of always rendering
  unrotated. `cover_image_class/1` handles the quarter-turn case with
  container-query units (the cover box's aspect is arbitrary, unlike the
  fixed-aspect stacks pile from PR #644).
- **`MediaBrowser` bug sweep** — selection/stack/pagination correctness under
  scenarios the earlier stacks-view work didn't cover:
  - `select_all` now also covers files inside expanded stacks
    (`stack_files`), not just the top-level `uploaded_files` page.
  - `download_file`/`download_selected` now resolve via `locate_file/2` /
    a direct DB fetch (scope-guarded) instead of `uploaded_files` only, so
    downloading a file inside an expanded stack, or a selection that spans
    pages, no longer silently no-ops.
  - Permanent delete (`delete_selected`, `delete_file`) gained a
    `file.status == "trashed"` guard as a second check beyond the existing
    scope guard.
  - Leaving trash view now reloads `folders` from `Storage.list_folders/2`
    instead of reusing the stale trashed-folder assign, and both trash and
    normal views now clear `selected_files`/`selected_folders` on toggle —
    previously a selection made before switching views could carry into
    the wrong (and for trash, destructive) delete branch.
  - `set_page` under controlled mode now excludes trash/orphaned views (not
    URL-addressable in the nav contract) from the `{:navigate}` round-trip,
    routing them through the same `reload_current_page/1` local path used
    elsewhere, which also picks up sort/type filter opts that a separate
    hand-rolled loader here had dropped.
  - `reload_current_page/1` clamps back to the last populated page when a
    delete empties the current page (bounded recursion — the clamp target
    only differs from the current page once).
  - `deselect_all` no longer also exits select mode (that's the toolbar's
    separate Cancel button now).
  - "Delete folder" copy corrected: folders are deleted recursively (whole
    subtree), never "moved to parent" as the old strings claimed; trash-view
    deletes are labeled "permanently" and irreversible.
  - Empty-search-results state added (distinct from "no media yet").
  - `max_upload_size_mb/0` centralizes the free-text setting parse with a
    safe fallback (previously two duplicated `String.to_integer/1` call
    sites that would crash the mount on a non-numeric setting value).
- **`MediaDetail`**: `params["file_uuid"]` now goes through `Ecto.UUID.cast/1`
  before use — a malformed/truncated uuid segment previously reached
  `Ecto.Query.CastError` inside the DB lookup; now it degrades to the
  existing "file not found" state.
- **`MediaSelector`**: `return_to` is validated to a same-origin path
  (rejects `//host` and `/\host` protocol-relative bypasses), `page` goes
  through a safe `Integer.parse` instead of `String.to_integer`, pagination
  links switched from `navigate` to `patch` (a full remount would drop the
  in-memory multi-select), the query now excludes trashed/system-managed
  files (matching `MediaSelectorModal`), and `handle_progress`'s upload path
  no longer returns `{:error, _}` from inside `consume_uploaded_entry`'s
  callback (that return shape isn't supported there and crashed the
  LiveView) — it now returns `{:postpone, :error}` and surfaces a flash.

## Findings

None in the PR's own diff — see verification below for what was checked
and ruled out.

**One pre-existing, unrelated gate blocker fixed in this pass:** `mix credo
--strict` was exiting 2 (3 "Software Design — nested modules could be
aliased" suggestions in `test/phoenix_kit_web/components/multilang_form_test.exs`,
introduced by PR #643, before #645 existed). Because `quality.ci` runs
`credo --strict` before `dialyzer`, this silently prevented dialyzer from
ever running as part of `mix precommit` — the alias chain aborts on the
first non-zero step. Fixed by aliasing `Phoenix.LiveView.Lifecycle` at the
top of the test module instead of the three fully-qualified call sites
credo flagged. Unrelated to PR #645's own changes; recorded here because
fixing it was necessary to get a real (not truncated/misread) `mix
precommit` result for this release.

## Verification performed

- Confirmed the route reorder actually fixes the shadowing: Phoenix router
  matches routes in declaration order and has no fallthrough after a
  segment binds, so `/admin/media/selector` previously always bound
  `:file_uuid => "selector"` in the earlier-declared show route. Selector
  now precedes the `:file_uuid` catch-all.
- Grepped every consumer of `selected_uuids` (`user_form.html.heex`,
  `media_gallery.html.heex`, `settings.html.heex`,
  `authorization.html.heex`, `user_settings.ex`,
  `media_browser.html.heex`'s own use) — all already pass/expect a list,
  none still assume a `MapSet`. `bulk_actions_bar.ex`'s `selected_uuids` is
  an unrelated, still-MapSet-based assign on a different component; not
  touched by this PR and not affected.
- Traced `rotation_class/1,2` (used unqualified in `media_browser.html.heex`
  for the new logo-rotation calls) back to the project-wide
  `import PhoenixKitWeb.Components.Core.MediaThumbnail` in
  `phoenix_kit_web.ex`'s `live_component/0` — resolves correctly, no local
  alias/import needed.
- Confirmed `folder_cover_rotation`/`folder_logo_rotation` are unconditionally
  assigned before first render on every path that can produce the initial
  `update/2` render: `init_socket/1` → `assign_folder_header_media/2` (both
  the folder and no-folder clauses go through the new `assign_folder_image/3`
  helper, which always sets both the `_url` and `_rotation` keys). No
  `@folder_cover_rotation` KeyError path.
- Verified `load_scoped_files/6` and `load_all_view_files/5` (both had their
  `extra \\ []` default removed, making the argument mandatory) — every call
  site in the module was updated to pass `extra` explicitly (grepped all
  12 call sites).
- Diffed `default.pot`/locale `.po` files for the 4 new/changed msgids
  (`Move %{files}...`, `Permanently delete %{files}...`, the two folder-only
  variants, `%{count} of %{max} selected`, `Maximum %{count} files`, the
  search-empty-state pair) — present with correct plural forms in
  `default.pot`; `ru`/`et` are fully translated, `de`/`es`/`fr`/`it`/`pl`
  remain the existing untranslated stubs (consistent with prior PRs, not a
  regression).
- Checked `download_selected`'s new DB-backed resolution doesn't skip the
  scope guard that the old `uploaded_files`-filter path got for free —
  `Storage.within_scope?/2` is still applied per file after the `uuid in
  ^uuids` fetch.
- Read `parse_return_to/1`'s pattern match against protocol-relative
  (`//evil.com`) and backslash (`/\evil.com`) bypass attempts by hand — both
  rejected (`next` lands on `?/`/`?\\`, excluded by the guard), falling back
  to `"/"`.

## Gate result

`mix precommit` (compile --warnings-as-errors --all-warnings,
deps.unlock --check-unused, quality.ci → format --check-formatted, credo
--strict, dialyzer): **clean, exit 0** (verified with an unpiped exit-code
capture, not truncated output — see the credo note above for why a naive
run of this gate was previously silently skipping dialyzer). Dialyzer: 187
errors, 187 skipped by `.dialyzer_ignore.exs`, 0 new — passed successfully.
