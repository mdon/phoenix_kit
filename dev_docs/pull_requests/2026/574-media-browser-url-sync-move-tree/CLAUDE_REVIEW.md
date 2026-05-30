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

---

## Second pass — `/code-review` high effort (2026-05-30)

A recall-biased 7-angle pass (3 correctness + 3 cleanup + 1 altitude, ≤6 candidates each → verify). Two high-profile candidates were raised and **refuted** by grounding in the code, worth recording so they aren't re-raised:

- **REFUTED — `phx-value-folder-uuid` → handler key mismatch.** A finder claimed LiveView lowercases/underscores `phx-value-folder-uuid` into `"folder_uuid"`, so `toggle_move_folder`'s `%{"folder-uuid" => uuid}` clause wouldn't match and the chevron would be dead. False: LiveView keeps the literal attribute suffix as the param key (dashes preserved). The codebase relies on this throughout — `start_rename_folder`, `toggle_folder_expand` (the sidebar twin this PR mirrors, `media_browser.ex:969`), `toggle_select_folder`, etc. all use `phx-value-folder-uuid` ↔ `%{"folder-uuid" => …}`. The toggle works.
- **REFUTED — base-path regression (`URI.parse(uri).path` vs old `Routes.path("/admin/media")`).** The hook builds the `push_patch` target from the live URL's path, which already includes any router/locale prefix and every parent segment — so it's equal-or-better than the old hardcoded `Routes.path/1` (which couldn't know the locale segment). Not a regression; it's why url_sync composes onto `…/orders/:id/edit/files`.

### Findings applied (fixed on branch `fix/media-browser-url-sync-followups`)

- **IMPROVEMENT - MEDIUM (efficiency) — hook re-queried on every host navigation.** `embed.ex` The `:handle_params` hook `send_update`d `nav_params` on every connected `handle_params`, and `MediaBrowser.update/2` → `apply_nav_params/2` (`media_browser.ex:187`) runs four Storage queries (`resolve_folder`→`list_folders` + breadcrumbs, `load_nav_files`, `count_orphaned_files`, `full_trash_count`) with no "did nav change" guard. On a multi-purpose host that `push_patch`es for its own reasons, every such patch re-queried the whole browser even though folder/q/page/view were unchanged. **Fixed:** `on_mount` now seeds a `:__phoenix_kit_mb_nav__` baseline and the hook only `send_update`s when the freshly-parsed nav differs — so unrelated host patches (and the redundant connect-time re-sync) are skipped, while real folder navigation still flows through. Benign on `/admin/media` (it only navigates via the browser), but a real waste for generalized hosts.
- **NITPICK (dead code) — unreachable `on_mount({:embed, false}, …)` clause.** `__using__` maps `url_sync` to `false` → `:default` or a `%{id:}` map → `{:embed, %{id:}}`; it never emits `{:embed, false}`, so the clause could not be dispatched. **Fixed:** removed; comment updated to state the no-url_sync path uses `:default`.

### Findings left as-is (recorded, not fixed)

- **IMPROVEMENT - MEDIUM (reuse) — Move-modal tree duplicates the sidebar tree.** `move_folder_option/1` (chevron, colored folder icon, recursion, border-color) re-implements `FolderExplorer`'s tree-row UX, and `toggle_move_folder` duplicates `toggle_folder_expand` (`media_browser.ex:969`). Not fixed here: extracting a shared tree-row component is a larger refactor than these two follow-up fixes warrant, and `FolderExplorer` currently bundles sidebar-only chrome (root / trash / new-folder rows). Tracked as a future component-extraction candidate; future tree-interaction changes (keyboard nav, icon states) need dual maintenance until then.

No correctness bugs found in either pass; the fixes above are perf + cleanup. Verdict unchanged: ship-clean.
