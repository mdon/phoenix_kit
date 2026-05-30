# PR #574 — Updated media browser (url_sync, Move-modal tree, empty-folder fixes)

**Reviewer:** Claude (Opus 4.8)
**State:** MERGED into `dev` (2026-05-30). Review is post-merge; findings are follow-up candidates.
**Scope:** `MediaBrowser.Embed` gains an opt-in `url_sync`; Move modal becomes a collapsible directory tree; empty-folder view-toggle + pagination-info fixes. Version bump 1.7.125 → 1.7.126 + CHANGELOG. Touches `embed.ex`, `media_browser.ex`/`.html.heex`, `pagination.ex`, `live/users/media.ex`, `AGENTS.md`, `mix.exs`.

## Verdict

Strong PR, and the hard part — `url_sync` — is done the *right* way. It uses LiveView lifecycle hooks (`attach_hook(:handle_params)` + `attach_hook(:handle_info)` in `on_mount`) instead of injecting `handle_params`/`handle_info` clauses into the host, so it genuinely composes with a host that already owns those callbacks (the `…/orders/:id/edit/files` case). The `{:halt}` on the `{:navigate, …}` message is behavior-preserving — that message was already terminal in the old bespoke `media.ex` clause (it never reached `handle_parent_info/2`), so halting changes nothing for component registration / upload piping, which still flow through the injected fallback on `{:cont}`. `media.ex` shrinks ~45 lines with identical behavior.

The one genuinely subtle thing — the injected `handle_params/3` stub — is correctly reasoned and correctly *conditional*: a `push_patch` issued from a `handle_info` hook makes LiveView invoke `view.handle_params/3` unconditionally, so a host with none would crash; the stub is injected only when `url_sync` is on **and** `Module.defines?(env.module, {:handle_params, 3})` is false, so a host with its own keeps it and composes. `Module.defines?/2` at `@before_compile` time correctly reflects user clauses (compiled before injection). Verified.

No CRITICAL/HIGH/MEDIUM findings. A couple of nitpicks and one low-severity design note.

---

## Verified correct

- **Helper imports.** The new tree uses `folder_icon_style/1` + `folder_color_hex/1`; both are defined in `FolderExplorer` and imported into `media_browser.ex` (the import list already requests `folder_color_hex: 1, folder_icon_style: 1`). No undefined-function risk.
- **Move-modal expansion state is properly isolated.** `:move_expanded` is a separate `MapSet` from the sidebar's `:expanded_folders`; `open_move_modal/1` *seeds* it from `expanded_folders` (so the picker opens matching the sidebar) then tracks independently. `toggle_move_folder` flips membership. `move_folder_option` threads `move_expanded` through the recursion and renders children only when expanded. Coherent.
- **Move guarded both ways.** Button `disabled` when `selected_files + selected_folders == 0`, and the `show_move_modal` handler re-checks before `open_move_modal/1` — a stray event can't pop an empty modal. The two single-item kebab entry points (`prepare_move_file`/`prepare_move_folder`) route through `open_move_modal/1` too, so they get the seeded expansion for free.
- **`pagination_info` cond.** `total_count == 0` → "No results"; `> per_page` → "…of N results"; else → "Showing 1 to N results". Replaces the nonsensical "Showing 1 to 0 results". Correct across the boundary.
- **Empty-folder view toggle.** `@total_count > 0 or @folders != [] or not is_nil(@current_folder)` correctly surfaces the toggle/count for files **or** folders **or** when inside an (even empty) folder.
- **`parse_nav_params`/`build_nav_query` are an exact relocation** of the old `media.ex` logic (default-omitting query build, `Integer.parse` page guard, `orphaned=="1"`, `view=="all"`), now public and reused by the hook. Round-trips symmetrically; no behavior change.
- **No DB query added to mount.** `on_mount` only parses params + attaches hooks; `send_update` is gated on `connected?/1`. Iron Law respected (`media.ex` mount actually got *lighter*).

---

## NITPICK — CHANGELOG 1.7.126 has two separate `### Changed` subsections

The entry lists `### Added`, `### Changed` (url_sync on `/admin/media`), `### Fixed`, then a **second** `### Changed` (Move-modal tree). AGENTS.md says match the existing Added/Changed/Fixed grouping — the two `### Changed` blocks should be merged into one. Cosmetic; renders as two headings in the changelog.

## NITPICK — Move button tooltip is unconditional

`title={gettext("Select items to move")}` shows even when the button is enabled (items selected). Minor; ideally the hint only applies in the disabled state. Harmless tooltip otherwise.

## NITPICK — mixed `phx-value` key casing on sibling buttons

In `move_folder_option`, the chevron uses `phx-value-folder-uuid` (→ param `"folder-uuid"`, matched by `toggle_move_folder`) while the name button uses `phx-value-folder_uuid` (→ `"folder_uuid"`, matched by `move_selected_to_folder`). Both are internally correct; the dash-vs-underscore split between adjacent buttons is just a readability wrinkle.

## Design note (not a bug) — URL is the single source of truth, single-browser-per-page

The `:handle_params` hook `send_update`s `nav_params` on **every** `handle_params` (gated only on `connected?`). On a multi-purpose host page, any host `push_patch` that drops the `folder`/`q`/`page` query keys will reset the browser to root — inherent to URL-owned state, and **identical to the pre-PR `media.ex` behavior** (so no regression). Already documented: query keys aren't namespaced, so only one url-synced browser per page. Worth keeping in mind for hosts that patch their own URL for unrelated reasons — they should preserve the media query string. Also: the `{:navigate}` hook falls back to base `"/"` if it somehow fires before the first `handle_params` sets `:__phoenix_kit_mb_path__`; not reachable in practice (connected mount runs `handle_params` before any user interaction).
