# PR #648: Media: small header default, cover/logo visibility, trash scoping, et fixes

**Author**: @alexdont
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, fix applied
**Date**: 2026-07-19

## Goal

Five stacked commits on the Media browser:

1. New folders default to a small hero header (`header_size` schema default
   `"medium"` → `"small"`), backfilled via V153 (bumps `@current_version`
   152→153).
2. Folder cover/logo files are no longer hidden from the folder's own file
   listing (`exclude_folder_header_assets/2` removed from
   `list_files_in_scope/2`) — they're real files and should show up.
3. Trash is now scoped to the current folder's subtree instead of always
   showing every root's trashed files (`scope_trashed_folders/2`,
   `trash_scope/1`).
4. Esc exits select mode (mirrors the toolbar Cancel button).
5. Adds a counter-clockwise rotate to the per-file kebab menu
   (`rotate_file` event, `±90` on `metadata["rotation"]`), plus Estonian
   translation fixes (several `.po` entries were literally wrong words, not
   just untranslated).

## Verified correct (no action needed)

- `scope_trashed_folders/2` walks `folder_subtree_uuids/1` (BFS by
  `parent_uuid`, doesn't filter `trashed_at`) and subtracts the scope
  folder itself — matches the stated intent ("the folder trash shows what's
  *under* it, not the folder you're standing in"). Confirmed against
  `build_trashed_query/1` (files' existing recursive-CTE scoping, untouched
  by this PR) — folder scoping and file scoping now agree on what "this
  folder's trash" means.
- `trash_scope/1` (`current_folder_uuid(socket) || scope_folder_id(socket)`)
  and `folder_or_scope/2` (used on the nav path, where `current_folder` is
  still a local and the socket hasn't been updated yet) resolve to the same
  value in every case checked: true root → `nil` (show everything, matches
  the pre-PR "top-level view" behavior); inside a folder → that folder's
  uuid; embedded-and-unnavigated → the embed's `scope_folder_id`. All call
  sites that read `:trash_count` or list trashed folders/files were updated
  to the new scope-aware helpers (`toggle_trash_filter`, `empty_trash`,
  `reload_folder_lists`, `reload_current_page`, `apply_nav_params`,
  `init_socket`'s transient pre-`handle_params` value).
- `rotate_file`: `Integer.mod(current + delta, 360)` wraps correctly in
  both directions (Elixir's `mod` is not `rem` — no negative results), scope
  guarded via `Storage.within_scope?/2` same as the other per-file kebab
  mutations, broadcasts the thumbnail update so the grid reorients without
  re-encoding. Test exercises the left-from-0 wrap (→270) explicitly.
- `phx-window-keydown={@select_mode && "exit_select_mode"}` — HEEx omits the
  attribute entirely when the expression is `false`, so the window listener
  genuinely isn't attached outside select mode, matching the inline comment.
- Removing `exclude_folder_header_assets/2` is the intended fix (see the new
  `scope_test.exs` regression test) — a folder's cover/logo are real,
  re-selectable files; hiding them from the folder's own listing was the
  bug, not the other way around.
- `V153` migration: schema-qualification, prefix handling, and the
  `COMMENT ON TABLE #{p}phoenix_kit IS '153'` version marker all match the
  established convention (compare V134's `ALTER TABLE ... ADD COLUMN`
  style). Plain `ALTER COLUMN ... SET DEFAULT` / `UPDATE ... WHERE` — no
  `CREATE INDEX`, extension, or schema statements, so none of the
  prefix-safety pitfalls in CLAUDE.md apply. Idempotent as documented.
- `mix.lock` bump (etcher/fresco/tessera patch versions) is incidental
  `deps.get` churn, unrelated to this PR's behavior.

## Fixed

### NITPICK: V153's `down/1` docstring says "Rolls V152 back"

`lib/phoenix_kit/migrations/postgres/v153.ex:48` — copy-paste leftover from
whichever migration this was scaffolded from. Every other migration in the
chain (V148, V149, V151) documents `down/1` as "Rolls V<self> back". V152 is
also, confusingly, a real and different in-progress migration (the
newsletters/CRM/core restructuring accumulator) — so the wrong number here
isn't just cosmetic, it could send a future reader looking at the wrong
migration when reasoning about the rollback.

**Fix applied:**

```diff
-  Rolls V152 back.
+  Rolls V153 back.
```

## Noted, not fixed

### NITPICK: `scope_trashed_folders/2` does N+1 round trips vs. files' single recursive CTE

`folder_subtree_uuids/1` (used by `scope_trashed_folders/2`) walks the tree
breadth-first with one query per depth level, while `build_trashed_query/1`
(files, pre-existing/untouched by this PR) does the same walk in a single
recursive CTE. Not a regression from this PR — `folder_subtree_uuids/1`
already existed and is reused as-is from trash/restore/delete call sites
that predate this PR. Left alone: consistent with existing code, and folder
trees in practice are shallow enough that this isn't a hot path.
