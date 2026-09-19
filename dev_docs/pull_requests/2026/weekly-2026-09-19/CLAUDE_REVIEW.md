# Weekly review — 2026-09-12 → 2026-09-19

**Range:** `ba1f80af..f54300d4` — 242 commits, 365 files (+67.9k/−15.1k), PRs #804–#835, releases 2.22.22 → 2.31.1.
**Reviewer:** Claude. Read-only pass over six areas; no `mix` command was run. Items already fixed by the per-PR reviews are not repeated.

**Verdict:** no CRITICAL findings. Two HIGH bugs, both data-exposure/data-loss paths that a single misstep triggers, and seventeen MEDIUM bugs. Fix H1 and H2 before the next release.

"Verified" = I re-read the code at HEAD myself. "Reviewer-confirmed" = traced by the area reviewer, not re-read by me. "Plausible" = not traced end to end.

## BUG - HIGH

### H1. Host file-reference sources fail open — orphan cleanup deletes live host files (verified)
`lib/modules/storage/storage.ex:2598-2646`

`apply_reference_source_mfa/4` rescues a raising source, logs a warning and returns the query **without** that source's `NOT EXISTS` guard. The missing-table and invalid-entry clauses do the same. `DeleteOrphanedFileJob`'s re-check (`file_orphaned?/1`) rebuilds the query through the same path, so it does not help.

Scenario: a host registers `{MyApp.Media, :file_reference_sources}`; after a deploy the function raises (rename, config read, module not loaded). Every file referenced only by host tables reads as orphaned and `delete_file_completely/1` removes the row and the bytes. The only trace is a log warning.

Fix: fail closed — any source that raises, is malformed or names a missing table makes the query return no orphans (`where(query, false)`), or return `{:error, :reference_source_failed}` and have the job and mix task abort. Resolve the shorthand table in the configured prefix rather than hardcoded `public`.

### H2. A stranger's Telegram group can link itself to a user's connection (verified)
`lib/phoenix_kit/integrations/telegram/chat_link.ex:72-84`, caller `lib/phoenix_kit_web/live/integrations/my_integration_form.ex:310-340`

`merge/3` in `"single"` mode is `lockable_private(existing, privates) ++ ids(groups)` — groups are exempt from the lock. Nothing binds the `/start@bot` sender to the connection's owner. Bot usernames are public and bots can be added to groups by default.

Scenario: a stranger adds the bot to their own group and runs `/start@thebot`. The next time the owner presses Test (within ~24h), `capturable_chats/1` returns that group, `merge` adds it and `save_setup` persists it. Every later notification is also delivered to the stranger's group; the only signal is a "Linked 1 chat(s)" flash. The same missing check lets a stranger's private chat win `Enum.take(-1)` when none is linked yet.

Fix: bind capture to a per-connection nonce (`t.me/<bot>?start=<nonce>` / `?startgroup=<nonce>`) and link only updates carrying it. At minimum, never auto-link groups — show them as candidates the owner confirms.

## BUG - MEDIUM

### Auth & sessions

**M1. Login limiter is check-then-act; a parallel burst bypasses it (verified).** `lib/phoenix_kit/users/rate_limiter.ex:200-222`, `:241`. This week's fix for counted successful sign-ins replaced the atomic `hit` with a peek; the increment now lands only after the bcrypt verify. 200 concurrent POSTs all peek 0 and all get verified, every window. `MultiSession.add_account` shares the path. Fix: keep the atomic `hit` before verification and refund (`inc -1`) on success.

**M2. Rate-limited requests still write `login_attempts` rows (verified).** `lib/phoenix_kit_web/users/session.ex:108-110` (and `:414`). The `:rate_limit_exceeded` branch calls `LoginAttempts.record`, which does a user lookup plus an upsert keyed on the identifier. A blocked IP sending random identifiers adds a row per request, kept 90 days — the "~900 rows/hour/network" bound in `login_attempts.ex:25` is false. Fix: collapse the key on that branch (one row per network per hour) and skip the lookup.

**M3. Failed-login alert cooldown is not atomic (reviewer-confirmed stamp; race plausible).** `lib/phoenix_kit/users/login_attempts.ex:242-290`. `alert_due?/1` reads the struct loaded at the start; `stamp_alert` is an unconditional JSONB merge. A concurrent burst at threshold-1 sends one email per process. Fix: make the stamp the gate — a conditional `UPDATE … WHERE stamp IS NULL OR stamp < cutoff`, send only on 1 row affected; pass `broadcast: false`.

### Migrations

**M4. V196 backfill copies `varchar(255)` into `varchar(160)` with no guard (verified).** `lib/phoenix_kit/migrations/postgres/v196.ex:62-79`. One Google `provider_email` over 160 chars raises `22001` and strands the host at V195. It also skips the `trim |> downcase` the changeset applies. Fix: `SET google_email = lower(btrim(src.provider_email))` and add `char_length(btrim(provider_email)) BETWEEN 1 AND 160` to the subquery.

### Storage & image editing

**M5. `unedited_` prefixes pile up across edit/revert cycles (verified builder; arithmetic not run).** `lib/modules/storage/workers/apply_image_edit_job.ex:292-295`, `:247-258`, `:516-524`. A revert keeps the prefixed keys; the next first edit prefixes them again (+42 chars). By about the fourth cycle a variant key passes `varchar(255)`, the publish transaction raises, and the file can never be edited again. Fix: strip an existing `unedited_<token>_` prefix before adding a new one.

**M6. A raise inside `publish/3` leaks the render and the private unedited copies (reviewer-confirmed).** `apply_image_edit_job.ex:367-391`, `:62-70`. `discard/1` runs only on tuple returns; an exception or Oban timeout skips it, and each retry writes fresh copies under new random keys that no row references. Fix: `try/rescue/catch` around prepare→publish calling `discard(prepared)`; record prepared keys in job `meta` for the timeout case.

**M7. Trashing a folder can re-home a file into an already-trashed folder (verified).** `lib/modules/storage/storage.ex:1396-1400`. `links_outside_subtree/2` has no live-folder filter, unlike `other_folder_links/2`. The file stays `active` homed in a trashed folder; permanently deleting that folder hard-deletes it. Fix: join `Folder` and require `is_nil(trashed_at)`, ordered by `inserted_at`.

### Settings & integrations

**M8. Settings history stores plaintext for secret-named keys the broadcast redacts (verified).** `lib/phoenix_kit/settings/history.ex:78-81`, `:234` vs `lib/phoenix_kit/settings/events.ex:72`, `:107`. `History.secret_row?/1` only checks `Settings.secret_setting?/2`; `Events.secret_key?/2` also matches `api_key`/`token`/`secret` fragments. A key like `comments_giphy_api_key` lands in a permanent `setting.changed` row, and `Activity.broadcast` sends the same values over PubSub. V194 does not scrub these. Fix: use `Events.secret_key?/2` in history and extend a follow-up migration to the fragment test.

### Gettext & tooling

**M9. Translation catalog goes stale after a recompile or hot upgrade (verified).** `lib/phoenix_kit_web/gettext.ex:202-214`. The decoded catalog is cached in `:persistent_term` under the fixed key `{__MODULE__, :catalog}`, never erased. An edited `.po` recompiles the module but the old term keeps being served until the VM restarts. Fix: put a content hash of `@catalog_bin` in the key.

**M10. The updater can insert a duplicate `default:` / `file_processing:` queue key (reviewer-confirmed by regex test).** `lib/phoenix_kit/install/oban_config.ex:470-475`. `queue_configured?/3` only recognises `name: <digits>` or `name: [`. The queue list now includes `default` and `file_processing`, so a host line like `default: String.to_integer(System.get_env(…))` gets a second `default: 10` appended; the file still parses, and Oban then fails to boot. Fix: decide presence from the parsed AST and reject a candidate with a repeated key.

**M11. `--no-start` can write a migration whose `down/0` rolls back 60+ versions (reviewer-confirmed, narrow).** `lib/mix/tasks/phoenix_kit.update.ex:1357-1359` → `phoenix_kit.gen.migration.ex:57-103`. `from_version` comes from filenames; a fresh install with no update file maps to 1, so the file is `…_update_v1_to_v197` with `down(version: 1)`. A later `ecto.rollback` tears down to the floor. Fix: start only the repo and read the real version, or generate a `down` that raises when `from` came from the heuristic.

### Web components

**M12. A manually controlled host cannot open the media viewer (verified).** `lib/phoenix_kit_web/components/media_browser.ex:625-631`. A missing `:file` key means "close". A host using the documented controlled recipe without the `Embed` macro never echoes `file`, so every click opens and immediately closes the modal. Fix: treat `file` as authoritative only when `Map.has_key?(params, :file)`; document the key.

**M13. Late URL echoes move the viewer backwards (plausible).** Same function. Holding ArrowRight, the echo for step B arrives after the viewer reached C and `open_viewer(B)` runs. Fix: ignore echoes of values the component emitted itself.

**M14. Sticky `JS.toggle_class` overrides a server-forced sidebar state (reviewer-confirmed incl. LiveView JS source).** `lib/phoenix_kit_web/components/folder_explorer.ex:351-360`, `media_browser.ex:1163`. After one chevron click, `submit_new_folder`'s `sidebar_collapsed: false` has no visible effect and the UI inverts against the persisted setting until reload. Fix: drive the DOM on server-forced changes (`JS.add_class`/`remove_class` or a pushed event).

**M15. ImageEditor loses the EXIF-turned frame after every `load/3` (reviewer-confirmed).** `priv/static/assets/phoenix_kit.js:8445-8447`, `image_editor.ex:129-146`, `:259-264`. The hook re-reports only when the `<img>` node changes; Save/retry/revert reset `:size` and the preview stretches, with crop and redaction rectangles rendered against the wrong frame. Fix: call `_reportSize()` from `updated()` whenever the image is complete.

**M16. Clearing a redaction number field deletes that region and renumbers the rest (reviewer-confirmed).** `image_editor.ex:385-396`. `phx-change` with no debounce; an empty value fails to parse and the region is dropped, so the next keystrokes edit a different area of a destructive redaction. Fix: keep the previous rect when the incoming one does not parse; drop regions only via `remove_region`; add `phx-debounce="blur"`.

**M17. `save_media_details` writes title/description with no scope check (verified handler; `Storage.update_file` has no guard visible at the call site).** `lib/phoenix_kit_web/components/media_canvas_viewer.ex:481-510`. `rotate_file` deliberately requires `within_scope?`; this does not, so a scoped user can retitle a file only linked into their folder. `String.trim(params["title"])` also crashes on a forged non-binary. Fix: pass an explicit `can_edit_meta` computed with the home-in-scope rule; guard the params.

## IMPROVEMENT - MEDIUM

- **Active-role narrowing does not reach actor rank checks (reviewer-confirmed).** `lib/phoenix_kit/users/auth.ex:3517-3555`, `roles.ex:1214`. An Admin acting as "Support" can still set passwords and deactivate users; an Owner acting as Admin can still grant Owner. Not an escalation past real grants, but contradicts the ActiveRole moduledoc. Derive rank from `ActiveRole.effective_role_names/1`.
- **Typed identifier stored verbatim and shown to admins (reviewer-confirmed).** `login_attempts.ex:120-122`. A password pasted into the email field sits in plaintext for 90 days on the Sessions page. Mask identifiers that resolve to no user and contain no `@`.
- **Edit render has no resource limits.** `image_processor.ex:357-415`. `sanitize` has a 40 MP budget and `-limit` args; the edit path has neither and `File.read!`s the render to hash it. Shares the `file_processing` queue with thumbnails.
- **Variant temp files leak on every failure path,** and `:stale_source` has made failure routine. `variant_generator.ex:119-147`. Use `try/after`; delete the stored object on every publish error.
- **Unversioned URLs of never-edited images are cached `public, max-age=86400`,** so a redaction takes up to a day to reach `preview_card`, `comment_resources`, `annotations`, `user_info`, `layout_wrapper`. Pass `version:` or serve unversioned with `no-cache` + ETag.
- **V192 `down/1` guard blocks a full teardown.** `v192.ex:58-64`. Skip the guard when the rollback target is below the version that creates the table (V157 has the same inherited pattern).
- **V191/V195 take strong locks on hot tables without V193's `lock_timeout`;** V193's session-level `SET lock_timeout` leaks onto a pooled connection if the build fails under an in-VM run (plausible).
- **Only the oldest 100 Telegram updates are read** (`telegram.ex:74-80`); a busy bot never shows the owner's fresh `/start`. Peek the tail with a negative offset.
- **`Integrations.reading/2` and `validate_connection/3` rescue but do not `catch :exit`** (`integrations.ex:1223-1233`, `~1068`).
- **Viewer title/description form has `phx-submit` only;** an unrelated re-render resets the unfocused input. Add a `phx-change` mirroring the draft.

## NITPICK

- `record/4` does extra work (a `SUM` query, a synchronous email) only for existing accounts when alerts are on — a timing oracle the moduledoc denies. Send from a Task/Oban job.
- Role removal revokes only sessions that stored the role's uuid; a never-switched (`NULL`) session acting as it by default survives. Disconnect broadcast fires before commit.
- `mix phoenix_kit.repair` rebuilds `phoenix_kit_user_roles.position` as 0 for every role; add `position` to the four seed INSERTs.
- V197 `now()` defaults on `timestamp(0) without time zone` (dormant — `upsert/3` always sets both).
- `hand_declared_manifest_test.exs` moduledoc still lists the V170 index keys as open; `@hand_declared_from` can widen to 170. V193 indexes are `owner: :core` while the table's other objects are `:ai`. CLAUDE.md says integration rows are keyed `integration:{provider}:{name}`; the code keys by uuid.
- `--no-start` ignores mistyped flags (`--prefx auth` runs against `public`); use `OptionParser.parse!` with `strict:`.
- `queues_disabled?/2` misses the one-line `queues: false` form and prints nine "Could not safely add" pairs.
- A host `interpolation:` module other than the default breaks the catalog compiler (`to_interpolatable/1` is not in the behaviour).
- `query_and_cache_json_setting/2` has no clause for a row with no JSON and empty `value`: `CaseClauseError`, swallowed, never cached, re-queried every read.
- Chat link/unlink build the list from the LiveView's cached copy; two tabs silently re-link an unlinked chat.
- A channel linked by numeric `-100…` id is labelled "Group".
- Bare `Manager.delete_file(original_path)` at `storage.ex:3795` and `:4355` — the pattern the CLAUDE.md landmine forbids; also leaves the `processing` row.
- PDF metadata merged from the struct read at job start overwrites a title saved mid-job (`process_file_job.ex:201-206`).
- `ImageEditor.load/2` mints the unedited-original token before any `allowed?` check.
- Untranslated copy: `user_settings.ex:756` (`" on "`), `admin_nav.ex:414` (`"Remove "`). `remove_region` accepts a negative index.

## Checked and found sound

- **Active role:** written only by the session-token loader; every `Scope.for_user` call site loads through the token; refresh reloads by token and refuses deactivated users; `switch/3` scoped to token + user.
- **Redirects and oracles:** every new redirect goes through `Routes.local_path?`/`safe_destination`; login failure branches do identical bucket work; `{:phoenix_kit_require, _}` shares the confirmation gate.
- **`IpAddress.network/1`:** strict parsing; IPv4-mapped/NAT64 unmap; loopback and link-local stay whole; malformed input passes through.
- **Migrations V190–V197:** prefix-safe throughout, idempotent, downs reverse ups, V194 predicates match the writer and re-run safely, indexes match the new queries, every manifest entry agrees with its SQL, `@chain_hash` recomputed and correct, `@current_version` 197.
- **Serving:** no path serves or lists a `system_managed` file or the unedited original; the unedited endpoint is signed-in + `can_edit?`/token, uniform 404, `private, no-store`; stale `v` redirects without looping.
- **Deletion and derived data:** every new path goes through `delete_stored_objects/2` under the directory lock; variants, dimensions and thumbnails check `original_key?` in the recording transaction. ImageMagick args are numeric or whitelisted via `System.cmd` arg lists.
- **Reorganizer:** re-reads FOR UPDATE, verifies counts, dry-run shares the apply logic.
- **Settings cache:** generation scheme closes the write-vs-miss-fill race on every path; broadcasts only after commit; integration bodies `:redacted`; every personal LiveView event passes `owner: {:user, uuid}`; validators use fixed URLs with timeouts.
- **Gettext:** plural selection, header resolution, msgctxt, fuzzy and missing-binding behaviour all match upstream 1.0.2; `.po` changes trigger a recompile.
- **Tooling:** pooler probe returns its connection and has rescue + catch; `--no-start` names every skipped step; Oban queue names are validated atoms from module code.
- **Components:** `parse_decimal/2` edge cases; viewer `?file=` gates; no hardcoded `/admin`, no inline-script hooks, no `raw/1`, no id-less `phx-change` form; JS hooks clean up in `destroyed()`.
