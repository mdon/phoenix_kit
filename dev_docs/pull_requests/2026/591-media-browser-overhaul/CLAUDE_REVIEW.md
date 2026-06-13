# PR #591 — Media browser overhaul: folder hero header, customization, shared tree, persisted state

**Status:** MERGED to `main`. Review was retrospective; **all findings below have now been fixed** in a follow-up commit on `main` (see "Resolution" under each item).
**Scope:** 14 files, +1784 / −625. Version bump → `1.7.145` (merge bumped from PR's 1.7.144), migration **V134**.

Overall: solid, well-commented work. Migration is correctly wired (dynamic `V#{version}` dispatch), idempotent, with a symmetric `down/1`. No crashers found. The findings below are correctness gaps and avoidable per-navigation DB/URL work.

> **Follow-up fixes landed.** Touched files: `lib/modules/storage/storage.ex`,
> `lib/phoenix_kit_web/components/media_browser.ex`,
> `lib/phoenix_kit/migrations/postgres/v134.ex`. The V134 migration was edited
> in place (1.7.145 is unreleased, matching how this PR developed the migration);
> installs that already ran the old V134 keep the old shape — the new
> `header_size NOT NULL` and FK constraints only apply on a fresh run.

---

## BUG - MEDIUM — Cover/logo files are NOT excluded from the folder listing

Three places explicitly document that the cover/logo files "live in the folder, **excluded from its visible listing**":
- `lib/modules/storage/schemas/folder.ex` (field comment)
- `lib/phoenix_kit/migrations/postgres/v134.ex` (moduledoc)
- `media_browser.html.heex` hero comment

But there is **no such exclusion**. `Storage.list_files_in_scope/2` only filters `status != "trashed"` and `exclude_system_managed/1` (`system_managed == false`). The cover/logo are normal user files (`system_managed == false`), so:

- The chosen background/icon shows up as a regular file card in that folder's grid/list — exactly the thing the comments promise it won't.
- A user can move or trash that file from the grid, silently breaking the header (no warning, no re-pick prompt).

**Fix:** either implement the exclusion in `list_files_in_scope` (when listing a folder, drop rows whose uuid equals the folder's `cover_file_uuid`/`logo_file_uuid`), or delete the three "excluded from its visible listing" comments so the docs match reality. The first is what the design intends.

`grep -n cover_file_uuid lib/modules/storage/storage.ex` → no hits, confirming the gap.

**Resolution:** Implemented the exclusion. `list_files_in_scope/2` now pipes through a new `exclude_folder_header_assets(query, folder_uuid)` helper that loads the listed folder and `where: f.uuid not in [cover_file_uuid, logo_file_uuid]`. Applies only when listing a specific folder (flat all/orphaned/search views pass `folder_uuid = nil` and are untouched). The schema comment is now accurate.

---

## IMPROVEMENT - MEDIUM — Per-navigation header work runs unconditionally

`apply_nav_params/2` now does, on **every** folder navigation, regardless of the folder's visibility toggles:

- `Auth.get_user(user_uuid)` → creator user (for `folder_creator_user` / `creator_label`)
- `Storage.get_file(cover_uuid)` + `enrich_files/1` → cover URL (signed-URL generation)
- `Storage.get_file(logo_uuid)` + `enrich_files/1` → logo URL (signed-URL generation)

That's up to 3 extra DB round-trips + 2 signed-URL builds per navigation, even when `header_show_creator` / `header_show_background` / `header_show_icon` are all off. Gate each computation on the corresponding `header_show_*` flag (and on the column being set) so a folder with a plain header costs nothing extra.

**Resolution:** Replaced the four unconditional assigns in `apply_nav_params/2` with `assign_folder_header_media/2`, which gates the creator lookup on `header_show_creator`, the cover URL on `header_show_background`, and the logo URL on `header_show_icon`. To keep the Edit-header previews working when those toggles are off, `start_edit_folder_header` now loads the cover/logo URLs unconditionally on open, and `maybe_refresh_current_folder` (editor-time, infrequent) keeps loading them unconditionally. Folders without a cover/logo set already cost nothing (uuid nil → early nil).

---

## IMPROVEMENT - MEDIUM — `persist_tree_state/1` re-reads the user from DB on every chevron click

`persist_tree_state` does `Auth.get_user(uuid)` (fresh read) then `update_user_custom_fields`. It fires on every `toggle_folder_expand` and `toggle_sidebar`. Expand/collapse is a high-frequency interaction, so this is a read+write per click. It mirrors `persist_user_view_mode/2`, but view-mode toggles are rare while tree toggles are not. Consider writing from the in-socket `phoenix_kit_current_user` (the merge already guards `{:error, _}`), or debouncing the persist.

**Resolution:** Dropped the `Auth.get_user(uuid)` re-read; `persist_tree_state/1` now merges into the in-socket user's `custom_fields` directly. The in-socket struct is kept current by this function and `persist_user_view_mode/2` (both re-assign `phoenix_kit_current_user` on write), so it's a safe source. One fewer query per expand/collapse/sidebar toggle.

---

## NITPICK — Dead `restore_tree_state` handler

The JS hook no longer pushes `restore_tree_state` / listens for `save_tree_state` (localStorage path removed; state now server-rendered). The server still defines `handle_event("restore_tree_state", …)` at `media_browser.ex:996`. It's now unreachable — remove it.

**Resolution:** Removed the `handle_event("restore_tree_state", …)` clause.

## NITPICK — `folder_cover_url/1` and `folder_logo_url/1` are byte-identical

Same body, only the matched field differs. Collapse to one `folder_image_url(uuid)` taking the uuid: `folder_image_url(folder && folder.cover_file_uuid)`.

**Resolution:** Collapsed both into a single `folder_image_url(uuid)` that takes a file uuid (or nil). All call sites updated.

## NITPICK — Name sort is case-sensitive and has no tiebreaker

`apply_file_sort(query, "name_asc")` → `order_by(asc: f.original_file_name)`. Postgres default collation sorts uppercase before lowercase, so `Zebra.png` precedes `apple.png`. Use `fragment("lower(?)", f.original_file_name)`. Likewise `largest`/`smallest`/name sorts have no secondary key, so rows with equal size/name can shuffle across pages — add `:uuid` (or `inserted_at`) as a stable tiebreaker.

**Resolution:** Name sorts now order by `fragment("lower(?)", f.original_file_name)`, and every sort (including `oldest`/`newest`) carries `asc: f.uuid` as a stable tiebreaker.

## NITPICK — Whitelisted handlers have no fallback clause

`set_sort`, `set_file_filter`, `set_header_size`, `toggle_header_option` use `when … in @valid…` guards with no catch-all. A push outside the whitelist raises `FunctionClauseError` and takes down the LiveComponent. Values come from fixed UI buttons (low real risk), but a `_ -> {:noreply, socket}` tail is cheap insurance.

**Resolution:** Added `_params -> {:noreply, socket}` fallbacks to `set_sort`, `set_file_filter`, and `set_header_size`. (`toggle_header_option` was already safe — `header_option_field/1` returns nil for unknown options and the handler no-ops.)

## NITPICK — `header_size` column nullability inconsistent

`header_size TEXT DEFAULT 'medium'` is nullable, while every `header_show_*` boolean is `NOT NULL DEFAULT TRUE`. Harmless (schema default + the heex `case … _ -> medium` both cover nil) but inconsistent; consider `NOT NULL`.

**Resolution:** V134 now adds `header_size TEXT NOT NULL DEFAULT 'medium'`.

## NITPICK — No FK on `cover_file_uuid` / `logo_file_uuid`

Plain `UUID` columns, no `references`/`ON DELETE`. A hard-deleted file leaves a dangling reference. Render handles it gracefully (`get_file` → nil → no cover), so not a crash — but combined with the MEDIUM exclusion bug it's easy to reach. A `set null` FK would self-heal.

**Resolution:** V134 now adds `cover_file_uuid`/`logo_file_uuid` FKs to `phoenix_kit_files(uuid)` with `ON DELETE SET NULL`, via a reusable `add_header_asset_fk/3`. It first nulls any pre-existing dangling values (so `ADD CONSTRAINT` can't fail on legacy dev data), then adds the constraint guarded by a `pg_constraint` existence check scoped to the table (idempotent — `ADD CONSTRAINT` has no `IF NOT EXISTS`). `down/1` needs no change: `DROP COLUMN IF EXISTS` drops the constraints with the columns.

---

## Verified OK

- V134 dispatch: `Module.concat([__MODULE__, "V134"])` via `String.pad_leading("134", 2)` → resolves correctly; `up`/`down` idempotent; `COMMENT … IS '134'`/`'133'` symmetric.
- `move_selected_to_folder` param key unified to `folder-uuid` across the root button, shared tree node, and handler; `""` → scope-root mapping preserved.
- Shared `folder_tree_node` with `current_folder={nil}`, `show_rename={false}`, `enable_drag={false}` in the move modal — `is_active`/`is_renaming` both resolve false; no duplicate-component drift.
- `show_search` is initialized in `init_socket` (no KeyError on the inline-search branch).
- `creator_label/1` falls back to email when `User.full_name/1` returns nil.
- Long-press swallow uses capture-phase click listener; pointer move-tolerance cancel; mouse-only native drag unaffected.
