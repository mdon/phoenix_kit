# Pre-release review — 2.37.0

**Range:** `v2.36.1` (`4a54ab00`) .. `9207765d` on `main`. 87 files, +11797 / −4009. Not tagged. `mix.exs` is already `@version "2.37.0"`.
**Reviewer:** Grok, 2026-09-22.
**Already tagged on origin, not part of this publish:** `v2.31.1` through `v2.36.1` (2026-09-19 → 2026-09-21). This note is the unpublished delta only.
**Not run:** PostgreSQL was down, so no `mix test`. `mix precommit` and `mix prerelease` were not run. Findings below were re-read at `9207765d`.

**Verdict: do not tag 2.37.0.** The migration, the trash/restore selection, the settings redirect, and the header home link can ship. The viewer work this release opens on, the untabbed-action permission fallthrough, and three capture-date writers cannot.

## Outcome (2026-09-22)

H1, H2 and M1–M8 are fixed in the working tree. The presence navigation disconnect is unchanged and is now described in the 2.37.0 changelog; the grace period was not added. Unit tests for the permission fallthrough and the video-epoch parser passed (101 tests, 0 failures). The JS burn and neighbour-prefetch tests passed. The integration tests were not run: PostgreSQL is not reachable from this machine.

## Fix before tagging

### BUG - HIGH

**H1. A saved rotation makes every burn a silent no-op.**
`priv/static/assets/phoenix_kit.js:3804-3809`, matrix at `:3863-3868`. Fresco: `deps/fresco/priv/static/fresco.js:207-216`, `imageToScreen` at `:1835-1844`.

`burnCapturePlan` recovers scale from the screen X delta of image points `(0,0)` and `(1000,0)`, then returns null unless that delta is positive. `imageToScreen` is `translate · rotate · scale`. At 90° and 270° the X delta is 0; at 180° it is negative. The live layer is mounted with `initial_rotation`, so any file rotated in the viewer never uploads a new `burned_large`. Closing the viewer or turning the pencil off — the two session-ends the changelog names — does nothing, and there is no error. The viewer then keeps opening on the old burned picture.

The SVG matrix just below is axis-aligned (`matrix(m,0,0,m,…)`). Removing the `s > 0` bail would still compose a rotated drawing wrong. Sample a full 2×3 mapping and compose in image space. The burned canvas already reapplies `initial_rotation`.

**H2. Untabbed actions fail open when a LiveView's tabs disagree.**
`lib/phoenix_kit_web/users/auth.ex:2392-2400`, `sole_action_permission/2` at `:2430-2434`.

`sole_action_permission/2` returns nil when a module's `{module, action}` entries disagree, and the comment says that action stays unmapped and fails closed. `permission_key_for_admin_view/2` then `||`s into `infer_permission_key_from_module/1`. `PhoenixKit.Modules.<Name>.Web.*` becomes `Macro.underscore(Name)`; a plugin LiveView becomes `ModuleRegistry.get_module_key_for_namespace/1`. A partial role that holds that key can open `:show` / `:edit`. A bare-module cache entry (`Map.get(custom, view_module)`, including a tab registered as `{Mod, nil}`) is consulted before `sole_action_permission/2`, so a legacy module-wide key wins for every untabbed action even when the action-specific tabs disagree.

The unit tests assert nil only for fixtures that are not under `PhoenixKit.Modules.*` and are not a registered plugin namespace, so they never reach this fallthrough. Owner is not locked out of the actions the tabs themselves name. Two tabs on the same LiveView with different `live_action`s do not collapse for those actions; the cache key is `{module, action}`.

Fix: if any `{module, _}` entries exist and their keys are not a single key, stay unmapped. Use a bare-module entry only when there are no action-specific entries. Add a regression on a `PhoenixKit.Modules.*.Web` module (or a registered namespace) whose `:index` and `:edit` tabs use different keys.

### BUG - MEDIUM

**M1. Next / previous never burns, so the next open shows the old `burned_large`.**
`priv/static/assets/phoenix_kit.js:3997-4007`. Chevrons: `lib/phoenix_kit_web/components/media_canvas_viewer.html.heex` (`phx-click="step_viewer"`).

`_onClosing` calls `burnIfChanged` only for Escape, `[phx-click="close_viewer"]`, and `.modal-backdrop`. ArrowLeft / ArrowRight and the chevrons remount `MediaCanvasViewer` (its id includes the file uuid) without burning. `destroyed` only detaches listeners, and by then the overlay is gone. Annotations are already persisted by `etcher:annotations-changed`. The burned slots are not. The viewer opens on that burned copy, so the next visit shows the previous session's markup until someone closes or turns the pencil off while still on that file.

Run the same capture-before-destroy path for `step_viewer` and for the arrow keys, while the overlay is still mounted.

**M2. Stepping flashes the clean picture.**
`lib/phoenix_kit_web/components/media_browser.html.heex:2704-2744`.

`data-step-prev-src` / `data-step-next-src` are `urls["small"]`. `data-neighbor-prefetch` is `small` plus `large`. Cards prefer `burned` and the viewer opens on `burned_large` (else `burned`). An arrow or chevron paints the markup-free rung for the length of the round trip, then replaces it. Point the step src and the neighbour prefetch at the variant `burn_size/1` selects, including its `version` query.

**M3. A readonly viewer still creates annotation comments.**
`lib/phoenix_kit_web/components/media_canvas_viewer.ex:458-468`. Tooltip: `priv/static/assets/phoenix_kit.js:7076-7082`.

`handle_event("annotation_reply", …)` does not consult `can_annotate`. It calls `ensure_master_comment/2`, which inserts a comment. `Etcher.tooltipActions` adds Reply for every persisted shape; only Edit is hidden when `shape.readonly`. Readonly passes `can_annotate={false}`, which stops `etcher:annotations-changed`, `fresco:rotate`, and the close burn (`burnIfChanged` returns when `dataset.canAnnotate !== "true"`, `phoenix_kit.js:4162`). The Reply button is still on screen. No-op `annotation_reply` when `can_annotate` is false. `etcher:colors-changed` (`:388`) and `etcher:line-params-changed` (`:416`) also persist the user's palette with no `can_annotate` check; those write the user's prefs, not the file.

**M4. A trashed file's 404 is cacheable on the shared URL.**
`lib/phoenix_kit_web/controllers/file_controller.ex:64-67` (`info/2` ~`:303`, `unedited/2` ~`:343`).

The 200 for a media holder is `private, no-store` (`cache_mode/3` at `:155`, applied before any other mode). The 404 from `show/2` sets no `Cache-Control`. `get_servable_file/2` runs before `verify_token/3`, so a trashed file is a 404 even with a bad token. A shared cache that stores 404s (Varnish's default is 120s) pins the denial. A prefetch or logged-out hit then makes the media holder's thumbnail 404 until that entry expires. Send `cache-control: private, no-store` on these denials. HEAD is the same action.

**M5. Deep-zoom tiles of a trashed image skip the media gate.**
`lib/phoenix_kit_web/controllers/file_controller.ex:647-648`, `tile_snapshot/1` at `:677-692`.

`tile_cache_control/1` returns `public, max-age=31536000, immutable` for a versioned manifest or tile. `tile_snapshot/1` excludes `system_managed` and does not look at `status` or the media permission. `serve_manifest/2` and `serve_tile/2` never call `get_servable_file/2`. The dzi token is the same for every caller. `storage_tile_generation_enabled` defaults off, so this is dormant until tile generation is on. When it is on, it is the same shared-URL leak the `/file` fix just closed. 404 unless `authorize_trashed_read/1` allows it, and answer `private, no-store` when it does.

**M6. A backfill that overlaps an edit can lock in a filename or upload date.**
`lib/modules/storage/workers/capture_date_backfill_job.ex:109-118`, `:148-149`, `:177-181`.

`record/1` chooses the backup from an unlocked `get_file` (`original_file_uuid || uuid`). A nil storage key — any `retrieve_original/1` error — makes `same_bytes?/3` return true, and the filename or upload time is written. The self-file clause calls `Storage.original_key?/2` and does not notice that `original_file_uuid` appeared during the read. Historical files are already `active`, so they can be edited during the pass. `pending_query` is `taken_at IS NULL`, and `ProcessFileJob.with_capture_date/3` (`process_file_job.ex:246-250`) skips any file that has a backup, so nothing later upgrades that weaker source to the EXIF still on the backup. A file that already has `exif` or `manual` is protected by `replace?/2`. This hole is the first write.

The other interleaving is fine: the download of the old key succeeds, `original_key?/2` fails, the outcome is `:changed`, and `taken_at` stays nil for the next pass.

Inside the locked transaction, if `current.original_file_uuid` is set, date that backup (and check `original_key?/2` on the backup key) or return `:changed`. Do not apply the nil-key fallback when the download failed or a backup pointer appeared.

**M7. A stream-level epoch hides the container's `creation_time`.**
`lib/modules/storage/services/capture_date.ex:219-231`, `:241-244`, `:263-275`, `plausible?/1` at `:361-363`.

`parse_ffprobe_tags/1` keeps the first `creation_time` (`Map.put_new/3`). The comment on that function says ffprobe prints `[STREAM]` before `[FORMAT]`, so the stream tag wins. `from_creation_time/1` rejects the QuickTime and Unix epochs (`1904-01-01`, `1970-01-01`) and returns nil, and `from_video_tags/1` has no other `creation_time` left. A non-Apple video whose stream tag is an unset epoch and whose format tag is the real instant is stored as `filename` or `inserted_at`. That weaker source sticks, because a later read through the same parser still finds no container date. QuickTime `com.apple.quicktime.creationdate` is a different key and is unaffected.

Apply the epoch check per candidate. Do not let an implausible stream tag shadow a later plausible format tag.

**M8. Two create paths never record a capture date.**
`lib/modules/storage/storage.ex:4185-4202` (`clone_file_for_user/5`). `store_file/2` at `:3282`, `store_new_file/8` at `:4680-4708`, `create_original_instance_and_variants/3` at `:4755-4777`. Caller: `lib/phoenix_kit_web/components/annotation_composer.ex:342`.

The normal upload path does record one. Media browser, the upload controller, and the media selector go through `store_file_in_buckets/7`, which queues `ProcessFileJob`.

- `clone_file_for_user/5` copies `width` and `height` from the donor and not `taken_at`, `taken_on`, `taken_at_offset`, or `taken_at_source`. It does not enqueue `ProcessFileJob`. The clone is inserted already `active`.
- `Storage.store_file/2` (comment attachments) inserts `status: "active"`, generates variants inline, and never calls `CaptureDate`.

`CaptureDateBackfillJob` would see both, because `taken_at` is nil, but that job is a one-shot for pre-V200 rows, not part of upload. After the upgrade pass, every later cross-user duplicate and every `store_file/2` upload stays undated. Copy the four columns on the clone, under the same path lock. Run the same resolve-and-`original_key?/2` write from `store_file/2`, or enqueue `ProcessFileJob` for both.

## Decide, and write it into the changelog

**Presence (#845) ships in 2.37.0 and is not in the 2.37.0 notes.**
`lib/phoenix_kit_web/users/auth.ex:1494-1558`.

It is folded into `mount_phoenix_kit_current_scope/3`. Every connected, authenticated LiveView mounted through a scope hook — admin, feature modules, host pages, and the public auth session — is tracked. Anonymous visitors are not recorded on this path; login / register / magic-link still call `Presence.track_anonymous/2` themselves. The legacy hooks `:phoenix_kit_mount_current_user` and `:phoenix_kit_ensure_authenticated` are not covered. No new host setup: `SimplePresence` is already under `PhoenixKit.Supervisor`. A dead server is `catch :exit`'d and does not take the page down. `session_id` on this path is `SHA-256` of the session token (`Base.url_encode64/2`, no padding), not the raw token or `live_socket_id`. Exit logs keep only the exit class. One ETS row per `(user, session_id)`, deleted when the last monitor goes down. The hourly sweep no longer drops a row that still has monitors (`simple_presence.ex:397-405`). Presence is node-local; the moduledoc says so.

Two findings from `dev_docs/pull_requests/2026/845-presence-track-on-mount/CLAUDE_REVIEW.md` were not fixed. That review's status line says "review only, no fixes applied":

- **IMPROVEMENT - HIGH.** A `live_redirect` destroys the old LiveView before the new one mounts. `cleanup_session_by_monitor/1` (`simple_presence.ex:368-370`) deletes the row when the last monitor goes down, with no grace period. With one tab open, that broadcasts a disconnect, then the new mount broadcasts a connect and resets `connected_at`. Live sessions reloads twice on every page change. Before this release the same thing happened only on the two admin pages that tracked themselves.
- **IMPROVEMENT - MEDIUM.** `Overview.track_authenticated_session/3` (`lib/phoenix_kit_web/live/dashboard/overview.ex:429`) still stores `session["live_socket_id"]`, which is `"phoenix_kit_sessions:" <> Base.url_encode64(token)`. Reversible. Reached only when a host calls `assign_overview/3` without a scope hook; core `/admin` sets the tracked flag first. Logout (`auth.ex:399`) still broadcasts `extract_session_id_from_live_socket_id/1`, an 8-character token prefix that matches no row.

If presence ships as-is, the 2.37.0 changelog has to say it is on, that it is node-local, and that a navigation looks like a disconnect.

## What can ship

Re-read at `9207765d`. These match the changelog and the post-merge fixes already on `main`:

- **V200** is additive and prefix-safe. Columns and `COMMENT ON TABLE` are schema-qualified. The index name is bare on `CREATE` and qualified only on `DROP` (`lib/phoenix_kit/migrations/postgres/v200.ex`). `@current_version` is 200. `expected_schema` has `taken_at`, `taken_on`, `taken_at_offset`, `taken_at_source`, and `phoenix_kit_files_capture_date_index`. Nothing is backfilled inside the migration.
- **Steady-state capture dates do not downgrade.** `CaptureDate.replace?/2` refuses a weaker source and never replaces `manual` (`capture_date.ex:127-129`). `admit/2` drops the four keys on a downgrade. `ProcessFileJob` skips an edited image (`original_file_uuid` set — an edit keeps only the ICC profile) and writes only while `Storage.original_key?/2` still matches, inside the same `FOR UPDATE` transaction as the dimensions (`process_file_job.ex:353-369`). EXIF midnight handling keeps `taken_on` as the local date. A nil offset is the documented local-as-UTC approximation. The backfill cursor (`uuid > after`, one batch, then a successor) visits each uuid once per pass, including rows that error.
- **Folder trash.** `do_trash_folder/1` does not re-stamp a row that already has `trashed_at` (`storage.ex:1365`). `do_restore_folder/1` reads the folder stamp inside the transaction and restores only subtree rows with that exact stamp (`:1432-1445`). One list event per folder operation; `broadcast_files/2` sends nothing for `[]` (`:267`). A permanent-delete re-home into a trashed folder is announced. `FeaturedImage` and `MediaBrowser` match both the single-uuid tuple and the list tuple. `MediaDetail` has a catch-all and ignores both.
- **Trashed 200s.** `cache_mode/3` returns `:private` for `status == "trashed"` before pending / immutable / day. `authorize_trashed_read/1` keys `:trashed_file_access` by `{user_uuid, active_role_uuid}` (`file_controller.ex:209`). TTL is 5 seconds (`supervisor.ex:78`). Anonymous callers are not cached. The session loader puts `active_role_uuid` on the user. A trashed file the caller may not see is a 404, not a 403. System-managed rows are refused before the trash exemption.
- **The burn that does run** merges the fingerprint into the row as it is now (`AnnotationBurnController.remember_fingerprint/2` → `Storage.update_file_metadata/2`, `annotation_burn_controller.ex:352-355`), so a rotation or title saved while a burn ran is not reverted. The fingerprint is handed back only while a `burned_large` or `burned` instance is stored. A readonly close does not POST (`phoenix_kit.js:4162`). `POST /api/files/:uuid/burn` was not widened: owner, active-role Owner/Admin, or `media`.
- **Settings.** A `"settings"` holder still lands on General (`TabHelpers.redirect_target/2` prefers the subtab that shares the parent path). Someone who can open another subtab is sent there from the sidebar, a section header, a bookmark, or a typed URL (`auth.ex:2166-2191`). If that rule names General, which the gate just refused, the result is nil and the ordinary denial, not a loop. Email confirmation and the admin-area gate run before this redirect.
- **Header home link.** `Routes.home_path/2` (`routes.ex:409-418`) tries `"/" <> locale` only when `routable?/2` matches, else `"/"`. It does not go through `path/2`, so `url_prefix` is not applied twice. A non-default language is kept when the host routes `/:locale`.
- **Etcher `~> 0.17.0`** is an intentional floor. Hosts that pin `~> 0.16` will fail dependency resolution. `phoenix_template` 1.0.4 → 1.1.0 in `mix.lock` does not reach hosts; left as-is in the #854 review.
- Previously filed highs that are actually fixed in this tree: the trashed **200** is `private, no-store`; the burn fingerprint is a merge, not a stale metadata replace; the viewer looks for `burned_large`, not a variant named `annotated`; a readonly close does not burn.

Same-second trash stamps are a residual, not a blocker. `trashed_at` is `:utc_datetime` (seconds). Two independent trashes in the same second share a stamp, so restoring the later folder can restore the earlier one's rows when they sit in the subtree.

## Upgrade notes that have to stay in the release

- `mix phoenix_kit.update` for V200, then `mix phoenix_kit.storage.backfill_capture_dates` (or `CaptureDateBackfillJob.enqueue/0`). Do not send hosts to run that backfill until M6 is fixed. Video dates need `ffprobe`. Without it they fall back to the file name or the upload time.
- Folder operations broadcast `{:phoenix_kit_files_trashed | _restored | _deleted, [uuid]}`. A host that only matches the single-uuid tuple misses folder sweeps. A host with no catch-all `handle_info` crashes. Single-file operations keep `{:phoenix_kit_file_*, uuid}`.
- Etcher 0.17 is required.

## Suggested order

1. H1 and M1–M3 (the burned copy this release opens on).
2. H2 (one-function fallthrough; the tests do not cover a real module namespace).
3. M4, and M5 if any host has deep-zoom on.
4. M6 before the backfill is documented as the upgrade step. M7 and M8 in the same pass.
5. Presence section in the 2.37.0 changelog, including the navigation disconnect if that grace period is not added.
6. `mix test` against a real database, then `mix prerelease`.
