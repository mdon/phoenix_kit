# PR #544 Review — MediaBrowser: folder trash, drag-drop, kebabs, scope fixes, Fresco/Etcher bumps

**Status:** Merged (commits `6d3dc3f4` through `6521b3f4`). Post-merge retrospective review.
**Author:** @alexdont
**Scope:** ~2,256 insertions / ~1,037 deletions across 14 files.

What the PR actually does:

1. **Breadcrumb + scope fixes** — `Storage.folder_breadcrumbs/2` returns the full chain including the target folder, but the heex duplicated the last entry and hardcoded "All Media" as the root label even when scoped. Fixed by dropping the last crumb from the link loop and reading `@scope_folder_name` when a scope is active.
2. **Per-file kebab menus** — grid and list views now have `...` overflow menus on every file row with Download (when an original URL exists) and Delete. Closes the gap where single-file delete required select-mode → tick → toolbar trash.
3. **Folder list view parity** — folder rows now have discrete Type ("Folder" badge), Date (`inserted_at`), and Path columns instead of a single `colspan=5` name cell. Removed the stray empty `<td>` that pushed the kebab into a phantom 9th column.
4. **Move action in kebabs** — single-item Move flow seeds `selected_files`/`selected_folders` with a one-item set and opens the existing bulk-move modal. Modal title generalized to "Move N item(s)". `close_move_modal` clears transient single-item selections so a cancelled kebab move doesn't leave stale state.
5. **Move-to-root scope fix** — the modal's "root" button and drag-drop empty-area target sent `folder_uuid=""`, which both `move_file_to_folder/3` and `update_folder/3` converted to `nil` (system root). For files this failed with `:out_of_scope`; for folders it silently escaped the scope. Both handlers now resolve `""` → `scope` before calling Storage.
6. **Storage layer defence** — `update_folder/3` now uses `Map.has_key?` to distinguish "attrs omits `:parent_uuid`" (rename/recolor, no move) from "attrs has `parent_uuid: nil`" (explicit move to system root). The previous `new_parent &&` short-circuit treated both the same, letting scoped folders escape to the true root.
7. **Drag-to-trash + trash/orphan `KeyError` fix** — files can be dragged onto the sidebar Trash button to soft-delete. `load_trashed_files` and `load_orphaned_files` previously hand-rolled their per-file display map and omitted `:folder_path`, causing a `KeyError` in list view. Both now delegate to `enrich_files/1`, removing ~78 lines of duplication.
8. **Trash sidebar highlight fix** — when toggling into trash view, the sidebar no longer highlights the previously-active folder/root/All Files button. Only Trash carries the active highlight; toggling trash off restores the previous highlight.
9. **Folder drag-and-drop** — folders are now drag sources from grid, list, and sidebar. Drop targets accept both file and folder drags. Self-drop is suppressed at hover time via `application/x-pk-folder` marker type. Cycle drops (folder onto descendant) are rejected server-side with `{:error, :cycle}` surfaced as a flash. Folder mutations refresh `@folders` + `@folder_tree` via new `reload_folder_lists/1`.
10. **Drop-into-current-folder** — dropping an item onto the main content area body moves it into `@current_folder`. Nested drop targets use `_activeDropTarget` exclusivity so only the innermost highlights. Outline-only visual via `data-drop-no-bg` so the large wrapper doesn't get an overwhelming primary tint.
11. **Batch drag-and-drop** — picking up any selected item drags the whole selection. Selected items gray out (`opacity-50`) for visual feedback. Drop pushes the existing `move_selected_to_folder` bulk handler. Trash rejects batch drags (bulk trash stays explicit via toolbar).
12. **Kebab clipping fix** — all four kebabs (folder grid, file grid, folder list, file list) refactored from daisyUI inline `dropdown` to `<.table_row_menu>` with `phx-hook="RowMenu"`, which uses `position: fixed; z-[9999]` to escape `overflow-hidden` ancestors. Side benefit: Esc + arrow-key navigation work; `onclick="this.blur()"` and `phx-click="noop"` wrappers dropped. `trigger_class` attr added to `TableRowMenu` for custom trigger styling.
13. **Instant folder creation + folder trash (V119)** — replaces inline-input "New Folder" UX with Finder-style instant `untitled` / `untitled 1` / `untitled 2` creation. Folder soft-delete arrives via `trashed_at TIMESTAMPTZ` on `phoenix_kit_media_folders` (V119 migration). `Storage.trash_folder/2`, `restore_folder/2`, `delete_folder_completely/2` are recursive over the subtree. Trashed folders are hidden from `list_folders/2`, `list_folder_tree/1`, and `list_all_folders/0` by `is_nil(trashed_at)` filters. Trash view renders trashed folders alongside trashed files.
14. **Sidebar rename polish** — inline rename input switched from transparent/no-border to thin primary-bordered field on white bg. `phx-blur="cancel_rename_folder"` cancels on click-away.
15. **Folder icon sizing** — grid folder card icons bumped `w-12` → `w-20`; list view folder icons `w-6` → `w-10`.
16. **FolderExplorer extraction** — sidebar tree + toolbar + buttons extracted to `PhoenixKitWeb.Components.FolderExplorer` as a pure presentation function component with three reuse flags (`show_create`, `show_all_files`, `show_trash`). MediaBrowser imports color helpers back from it.
17. **Tree indentation fix** — child `ul` padding `pl-1` → `pl-1.5` so nested chevrons align under parent folder icons.
18. **Fresco daisyUI theme integration** — Fresco bumped to `~> 0.1.5`; viewer uses `theme={:inherit}` and receives `--fresco-*` mappings from daisyUI tokens via both `app.css` and runtime JS injection for parent apps that don't load phoenix_kit's stylesheet.
19. **Etcher dimension annotation** — Etcher bumped to `~> 0.2.6`; `Annotation` schema adds `"dimension"` to `@kinds`. V119 widens the CHECK constraint to include `'dimension'`.
20. **Simplification pass** — `folder_parent_path/1` N+1 eliminated by `folder_list_path/2` (one breadcrumb walk per render). `breadcrumb_path/1` helper extracted for shared path-string formatting. `folder_subtree_uuids/1` used by trash/restore/delete.

---

## BUG — HIGH

### #1 Outdated folder delete confirmation text

The `data-confirm` on folder kebabs (grid + list) still says:

> "Delete '%{name}'? Files move to parent."

But `delete_folder` now branches on `@filter_trash`:
- **Outside trash:** recursive soft-trash via `Storage.trash_folder/2` (descendant folders + files in the subtree are trashed, not reparented).
- **Inside trash:** recursive permanent delete via `Storage.delete_folder_completely/2`.

The confirmation text is wrong for **both** paths. Outside trash there is no "move to parent" — everything goes to trash. Inside trash there is no "move to parent" either — everything is permanently destroyed.

**Suggested fix:**
- Outside trash: either no confirmation (reversible, matching the file soft-delete pattern) or "Move folder and its contents to trash?"
- Inside trash: "Permanently delete '%{name}' and its contents? This cannot be undone."

**Locations:** `lib/phoenix_kit_web/components/media_browser.html.heex` — grid folder kebab and list folder kebab.

---

## BUG — MEDIUM

### #2 `folder_subtree_uuids/1` hangs on cycles

```elixir
defp folder_subtree_uuids(root_uuid) do
  Stream.unfold([root_uuid], fn
    [] -> nil
    pending ->
      children =
        from(f in Folder, where: f.parent_uuid in ^pending, select: f.uuid)
        |> repo().all()

      {pending, children}
  end)
  |> Enum.to_list()
  |> List.flatten()
end
```

If a self-reference or cycle exists in `phoenix_kit_media_folders` (direct SQL, migration glitch, or a future bug), this infinite-loops because there is no termination guard against revisiting UUIDs. `update_folder/3` has cycle detection, but `folder_subtree_uuids` is also called by `do_delete_folder_completely` which can bypass that gate.

**Fix:** Track visited UUIDs and terminate when no new children are discovered:

```elixir
defp folder_subtree_uuids(root_uuid) do
  Stream.unfold({[root_uuid], MapSet.new([root_uuid])}, fn
    {[], _visited} -> nil
    {pending, visited} ->
      children =
        from(f in Folder, where: f.parent_uuid in ^pending, select: f.uuid)
        |> repo().all()
        |> Enum.reject(&MapSet.member?(visited, &1))

      new_visited = Enum.into(children, visited)
      {pending, {children, new_visited}}
  end)
  |> Enum.to_list()
  |> List.flatten()
end
```

---

## BUG — MEDIUM

### #3 `delete_folder_completely` is not transactional

```elixir
defp do_delete_folder_completely(%Folder{} = folder) do
  subtree_uuids = folder_subtree_uuids(folder.uuid)

  files =
    from(f in PhoenixKit.Modules.Storage.File, where: f.folder_uuid in ^subtree_uuids)
    |> repo().all()

  Enum.each(files, &delete_file_completely/1)

  Enum.each(Enum.reverse(subtree_uuids), fn uuid ->
    case repo().get(Folder, uuid) do
      nil -> :ok
      f -> repo().delete(f)
    end
  end)

  {:ok, folder}
end
```

- `delete_file_completely/1` return values are swallowed by `Enum.each`.
- The whole operation is not wrapped in a transaction. If a file deletion fails partway through, the folder tree may be left in a partially-deleted inconsistent state.
- Since this is the "permanent delete" path for trashed folders, the blast radius is contained, but atomicity matters for storage-backend cleanup (S3/GCS deletions that may fail independently of the DB row delete).

**Fix:** Wrap the file and folder deletions in `repo().transaction`, collect `delete_file_completely` results, and surface failures instead of returning `{:ok, folder}` unconditionally.

---

## IMPROVEMENT — MEDIUM

### #4 Bulk operation error swallowing

`move_selected_to_folder` and `delete_selected` use `Enum.each` over storage calls and ignore all return values:

```elixir
Enum.each(socket.assigns.selected_files, fn file_uuid ->
  Storage.move_file_to_folder(file_uuid, target, scope)
end)

Enum.each(socket.assigns.selected_folders, fn folder_uuid ->
  folder = Storage.get_folder(folder_uuid)
  if folder do
    Storage.update_folder(folder, %{parent_uuid: target}, scope)
  end
end)
```

If some items fail with `:out_of_scope` or `:cycle`, the user still sees a success flash ("N items moved") with no indication that a subset failed. This is pre-existing behavior that the PR inherits, but the new batch drag-drop path and the new single-item kebab Move path both feed into this handler.

**Suggested fix:** Collect results and surface a partial-failure message, e.g. "3 of 5 items moved — 2 were outside the allowed scope."

---

## IMPROVEMENT — LOW

### #5 `delete_folder` catch-all matches non-ok returns

```elixir
case result do
  {:error, :out_of_scope} ->
    {:noreply, put_flash(socket, :error, gettext("Cannot delete folder outside the allowed scope"))}

  _ ->
    {:noreply,
     socket
     |> reload_folder_lists()
     |> reload_current_page()
     |> put_flash(:info, flash)}
end
```

Currently `trash_folder/2` and `delete_folder_completely/2` only return `:out_of_scope` as an error reason, so this works today. But the catch-all is fragile — if a future change adds `{:error, :cycle}` or another reason, it silently flashes success.

**Fix:** Match explicitly on `{:ok, _}` for the success path, and treat everything else as an error with a generic failure flash.

---

### #6 Edge case: active files inside trashed folders

`restore_selected` lets users restore individual files without restoring their parent folder. A file can become `status: "active"` / `trashed_at: nil` while its folder still has `trashed_at != nil`. The file-listing queries filter on `status != "trashed"` but do not check the folder's `trashed_at`, so these files could resurface in listings or searches while technically "orphaned" inside a trashed folder tree.

This is an edge case (requires manually selecting only files in trash view, not folders), but worth guarding against in `list_files_in_scope` and similar queries with an additional `where: is_nil(folder.trashed_at)` join.

---

## NITPICK

### #7 `trash_file` handler ignores `Storage.trash_file/1` return value

```elixir
def handle_event("trash_file", %{"file_uuid" => file_uuid}, socket) do
  ...
  true ->
    Storage.trash_file(file)
    {:noreply, socket |> put_flash(:info, gettext("File moved to trash")) |> reload_current_page()}
end
```

`Storage.trash_file/1` can presumably fail. A silent no-op on failure is consistent with other handlers, but worth a `Logger.warning/1` on error.

### #8 `other_files_share_path?/1` short-circuit is good but the comment could reference the fix

The nil short-circuit is correct, but there's no regression test for it. Since it was surfaced by `delete_folder_completely` test coverage, a dedicated test in `scope_test.exs` would prevent regression.

---

## GOOD CALLS — worth keeping visible

- **V119 migration** is clean, idempotent, and correctly folds the annotation `dimension` kind into the same version since neither had shipped to a tagged release.
- **`load_trashed_files` / `load_orphaned_files` delegating to `enrich_files/1`** fixes the `KeyError` on `folder_path` in list view and removes ~78 lines of duplicated map construction.
- **Breadcrumb scope fix** is precise: `Enum.drop(@breadcrumbs, -1)` for the link loop + `@scope_folder_name` at the root button eliminates both the duplication and the hardcoded "All Media" bug.
- **Move-to-root scope fix** (`""` → `scope`) is the right fix for the silent failure/escape bug. The server-side defence in `update_folder/3` (`Map.has_key?` instead of `new_parent &&`) is a solid defence-in-depth layer.
- **FolderExplorer extraction** is a clean separation: pure presentation, consumer owns state, events wire back through `@myself`, reuse flags gate MediaBrowser-specific buttons.
- **TableRowMenu refactor** fixes the `overflow-hidden` clipping properly, removes manual `onclick="this.blur()"` / `phx-click="noop"` hacks, and gains Esc + arrow-key navigation for free.
- **JS drag-drop batch mode** is well-implemented: `application/x-pk-batch` marker type, `_activeDropTarget` exclusivity between nested targets, `data-drop-no-bg` opt-out, folder self-drop suppression, and trash rejection of batch drags.
- **`folder_list_path/2`** eliminates the N+1 breadcrumb walks for folder list rows by computing the shared parent path once per render.
- **Tree indentation fix** (`pl-1` → `pl-1.5`) is a small but correct visual alignment improvement.
- **Fresco/Etcher bumps** are well-coordinated: `mix.exs`, CDN URLs, annotation schema `@kinds`, and V119 CHECK constraint all stay in sync. The daisyUI theme injection (both CSS and JS paths) handles parent apps that don't load phoenix_kit's stylesheet.
- **Test coverage** for `trash_folder`, `restore_folder`, and `delete_folder_completely` in `scope_test.exs` asserts recursive subtree behavior, scope guards, and side effects on `list_folders` / `list_folder_tree` / `list_trashed_folders`.

---

## Disposition summary

| # | Severity | Title | Suggested action |
|---|---|---|---|
| 1 | BUG-HIGH | Outdated folder delete confirmation text | Update `data-confirm` to match trash-vs-permanent behavior |
| 2 | BUG-MEDIUM | `folder_subtree_uuids/1` hangs on cycles | Add visited-set guard |
| 3 | BUG-MEDIUM | `delete_folder_completely` not transactional | Wrap in `repo().transaction`; surface file-deletion failures |
| 4 | IMPROVEMENT-MEDIUM | Bulk operation errors silently swallowed | Collect results; flash partial-failure message |
| 5 | IMPROVEMENT-LOW | `delete_folder` catch-all matches non-ok returns | Match `{:ok, _}` explicitly for success path |
| 6 | IMPROVEMENT-LOW | Active files inside trashed folders edge case | Guard `list_files_in_scope` with `is_nil(folder.trashed_at)` |
| 7 | NITPICK | `trash_file` handler ignores return value | Add `Logger.warning/1` on failure |
| 8 | NITPICK | `other_files_share_path?/1` lacks regression test | Add nil-path test to `scope_test.exs` |

**Overall verdict:** Ship-quality with three follow-up items worth addressing before the next release: #1 (misleading user-facing copy), #2 (infinite-loop risk), and #3 (data consistency under failure). The rest can ride along with the next PR that touches these files.
