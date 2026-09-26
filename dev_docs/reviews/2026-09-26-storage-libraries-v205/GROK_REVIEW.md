# V205 review: storage profiles and variant sets

## Summary

Reviewed `ba258188b..f296accea` (9 commits, 67 files) on a clean `main`, against the V205 work order and the 25 fixes in `dev_docs/reviews/2026-09-26-storage-libraries-v205/CLAUDE_REVIEW.md`. Those fixes are in the tree and the single-file cases they describe are real: a location is not unlinked until `Manager.holds?/2` has seen another copy, a nil `spec_hash` is not regenerated, stamps are conditional, and file/folder restore in `Storage` clears `placed_variant_revision`. Four of them are incomplete, and those gaps are the findings below.

The upgrade itself does not rewrite a compliant file and does not move objects. The migration is prefix-safe (schema-qualified tables and FKs, bare index names on create, `pg_constraint`/`pg_namespace` existence checks, re-runnable seeds). Compliant files stay `placed_* NULL`, which the reconciler reads as Default at revision 1, so a healthy install does not start a copy or a resize just by migrating. I did not execute the migration or the manifest probe.

User-library owners cannot reach profiles or buckets. The set picker is only on libraries they own, re-checks the owner on the row, and `VariantSets.set_library_variant_set/2` rejects a non-selectable set. The profile picker is on the admin Libraries tab and `find/2` only resolves system libraries. Serving a private file still turns a plain public redirect into a proxy. A backup that already has a location row is left out of `get_file_access/2`. The serve path is one indexed lookup on `file_locations.path` plus the profile join, not a per-request scan of the file table.

The problems that remain are shared keys (clones, and the same bytes uploaded twice), the thumbnail burn slot, and a reconciler that walks every file of a profile whenever any bucket column changes.

## Issues

### Issue 1 -- Severity: bug

- File: lib/phoenix_kit/migrations/postgres/v205.ex:349
- Description: HIGH. The migration stamps `spec_hash` on every instance whose name matches a Default size, including annotation burns stored in the `thumbnail` slot, so the reconciler's nil-hash guard no longer applies to them. `AnnotationBurnController` writes the burn with `VariantGenerator.store_prepared_variant/6`, which sets `spec_hash: nil` (`variant_generator.ex:267`). The stamp at `v205.ex:349-356` sets the hash whenever `fi.variant_name = d.name`, and `thumbnail` is a standard dimension. `Reconciler.make_variants/2` (`reconciler.ex:433`) only skips a remake when the hash is nil. After upgrade the hash equals the current thumbnail spec, so nothing happens on migrate. The next thumbnail edit, or a library move onto a set whose thumbnail spec differs, takes the hash mismatch branch and `generate_variant` overwrites the burn with a clean resize of the original. `burned` and `burned_large` stay nil (they are not dimension names) and survive. Burns written after the migration stay nil and survive. Existing thumbnail burns do not.
- Suggestion: Do not stamp `thumbnail` instances on files that already have a `burned`, `burned_large`, or `thumbnail_annotated` sibling, or whose metadata still has a burn fingerprint. Leave those hashes nil so the guard in `make_variants/2` keeps them. A cleaner split is to stop writing burns into the `thumbnail` name and point list rows at `burned` / `thumbnail_annotated`, which the reconciler already ignores.
- Status: open

### Issue 2 -- Severity: bug

- File: lib/modules/storage/services/manager.ex:186
- Description: HIGH. The min-copies rollback decides a key is unreferenced and deletes it without the directory lock, and it ignores an in-flight upload that has a file row but no instance yet. `require_copies/3` calls `Storage.unreferenced_keys/1`, which only looks at `file_instances` rows (`storage.ex:3581`), then `undo_write/1` deletes the object from each bucket this attempt wrote. `delete_stored_objects/2` is the path that holds `lock_storage_paths/1` across the recheck; this path does not use it. `store_new_file_in_buckets/7` inserts the file as `processing` and only then stores the object (`storage.ex:4496-4517`); the instance row comes after `store_by_profile/4` returns. Two uploads of the same bytes both miss dedup (neither row is `active` yet). The one that meets `min_copies_on_write` is still between the write and the instance insert. Another attempt that wrote fewer than `min_copies_on_write` sees no instance, and deletes the buckets it managed to write. One such attempt drops the winner from N copies to N-1 and the winner still records a location for the bucket whose object just disappeared. Two partial attempts that between them cover the winner's buckets (different shuffle orders, `min_copies_on_write >= 2`, a bucket erroring) delete every copy, and the winner then inserts locations for objects that are gone. Derived writes are unaffected: their minimum is 1, so a partial success does not roll back.
- Suggestion: Roll back through `delete_stored_objects/1`, and treat as referenced any `processing` file whose `file_path` is the key's directory and that has no instance for the key yet — the same rule `key_needed_on?/2` already uses (`storage.ex:3712`). The check has to run inside the directory lock, immediately before the delete.
- Status: open

### Issue 3 -- Severity: bug

- File: lib/modules/storage/services/locations.ex:89
- Description: HIGH. `ranked/1` serves a bucket at the best role any file sharing the key gives it, so a library that marked the bucket `backup` still has that copy served. The query joins every active location of the key to that location's own file and library profile (`locations.ex:69-81`), then `Enum.min_by` on `{role_rank, serve_order}` (`locations.ex:89-92`). Ranks are primary 0, replica 1, not-in-profile 2, backup 3. A cross-user clone shares the key and, at clone time, the profile (`storage.ex:4565`). `Profiles.set_library_profile/2` can then point one library elsewhere. File A's profile says bucket X is `backup`. File B's profile says X is `primary`, or no longer lists X (role nil, rank 2). The minimum is primary or nil, and `read_order/3` only drops role `"backup"` (`manager.ex:452`). Requests for A's file redirect to X. Egress, a cold bucket, or a bucket A meant never to serve is what the client hits. While both libraries still resolve to the same profile the ranks agree and the bug stays dormant.
- Suggestion: Rank with the profile of the file being served. `get_file_access/2` is called with the instance in hand (`file_controller.ex:1165`); pass that file's library (or the instance uuid) into `ranked/2` and join only that file's locations. Do not let another file's profile pull a backup into the serve set.
- Status: open

### Issue 4 -- Severity: bug

- File: lib/modules/storage/services/reconciler.ex:386
- Description: HIGH. A reconciler copy writes the object and records the location outside the directory lock that `unlink_location/2` holds, so one file can delete a shared key after another file has already counted that copy as good. `copy_to_more/4` calls `Manager.replicate_to_buckets/2`, then `holds?/2`, then `Locations.record/2` (`reconciler.ex:381-390`). `record/2` inserts rows and never takes `lock_storage_paths/1` (`locations.ex:107`). `unlink_location/2` locks, drops this instance's location, then `key_needed_on?/2`, then `delete_from/2` (`storage.ex:3673-3689`). `record/2` can commit between that check and the delete: the lock is not shared, and the delete does not recheck. Concrete case after the libraries diverge (issue 3's setup). File B is copying the shared key onto bucket X and has already seen `holds?` succeed. File A is draining X, has a verified copy on P, and unlinks X. A's `key_needed_on?` ran before B's `record` committed, so A deletes the object on X. B's later `verified_copies/4` still saw the object, so B unlinks P. Both real copies are gone; B's new location points at an empty key. The single-file `holds?`-before-unlink fix does not cover this, because each reconciler only verifies the copies it itself is keeping.
- Suggestion: Take the directory lock in `replicate_to_buckets/3` before the write and hold it until `Locations.record/2` commits, and make `unlink_location/2` recheck `key_needed_on?/2` immediately before `delete_from/2` under that same lock. A copy that loses the race should not count as verified.
- Status: open

### Issue 5 -- Severity: bug

- File: lib/modules/storage/services/manager.ex:455
- Description: MEDIUM. For `:serve`, the fallback bucket list is every enabled bucket that has no location row, with no role check, so a backup that holds the object but missed its location row is served. `read_order/3` removes role `"backup"` from the located list and builds `named` from located rows only (`manager.ex:450-455`). A backup with a location is in `named` and is not probed. A backup whose `Locations.record/2` failed (it rescues to 0) is not in `named`. `get_file_access/2` then `serve_from`s it. Primary is down, the object is on the backup, and the response is a redirect to that bucket. A key with no location rows at all still probes every enabled bucket; the work order says that case keeps today's rule, and this finding is only the case where some locations exist.
- Suggestion: When `purpose` is `:serve`, drop buckets whose profile row for this key's file is `backup`, whether or not a location row exists. The same profile lookup as issue 3, restricted to the file being served.
- Status: open

### Issue 6 -- Severity: bug

- File: lib/modules/storage/workers/reconcile_job.ex:48
- Description: MEDIUM. A profile or set change that lands while the next batch is already `:available` does not restart the walk, so files the cursor has passed stay stale until some later enqueue. The worker is unique on `[:worker, :queue]` for `:available` and `:scheduled` (`reconcile_job.ex:30`). `enqueue/0` only replaces `:scheduled` jobs (`replace: [scheduled: [:args, :scheduled_at]]`). Oban applies `replace` only for the conflicting job's state (`deps/oban/lib/oban/engines/basic.ex:471`). After the 2s pause the continuation is `:available`. If `file_processing` is busy it can sit there. `enqueue/0` from a revision bump hits that job, replaces nothing, and the old `after` cursor is kept. `run_batch/3` only reads `uuid > cursor`. When the walk reaches the end it stops (`reconcile_job.ex:77`). Files before the cursor, including ones the change just made stale, wait for the daily prune or the next boot (`ReconcileJob.maybe_enqueue/0`). A drain started in that window does not empty the bucket for the files already passed.
- Suggestion: Include `:available` in `replace`, and replace `args` (clear `after`) as well as `scheduled_at`. The B5 fix covered the pause; it does not cover the job once it is waiting on the queue.
- Status: open

### Issue 7 -- Severity: bug

- File: lib/modules/storage/services/reconciler.ex:413
- Description: MEDIUM. The reconciler stamps a file as having its set's sizes whenever it did not generate any, and one restore path never clears that stamp. `reconcile_variants/2` returns true for anything that is not an active variant source (`reconciler.ex:410-415`), and `do_reconcile/1` then writes `placed_variant_revision` (`reconciler.ex:222`). A trashed file, a `failed` file, and a `processing` file older than an hour are marked current without a size being made. `restore_file/1`, `restore_file_into/2`, and `restore_folder/2` set `placed_variant_revision` back to 0. `restore_folder/2` does not call `ReconcileJob.enqueue/0` (`storage.ex:1332-1350`), so the work waits for prune or boot. `Reorganizer.restore_subtree_if_needed/1` sets `status: "active"` and does not touch `placed_variant_revision` or enqueue (`reorganizer.ex:393`). Moving a trashed folder back to a live parent therefore restores files whose missing sizes the reconciler will never make, because it already stamped them while they were trashed. A `processing` image the reconciler stamped, whose `ProcessFileJob` then dies inside `Task.await_many/2` before `VariantSets.record_variants/3`, is the same hole: the stamp says the set is done.
- Suggestion: Return true from `reconcile_variants/2` only when the sizes were actually checked. For a trashed or still-processing file, leave `placed_variant_revision` alone. Make `restore_folder/2` and `Reorganizer.restore_subtree_if_needed/1` call the same `variants_stale_after_restore/1` helper the single-file restore uses.
- Status: open

### Issue 8 -- Severity: bug

- File: lib/phoenix_kit_web/controllers/file_controller.ex:121
- Description: MEDIUM. A private-library stand-in is cached for an hour at the requested variant's URL. `serve_variant/5` forces `cache` to `:private_file` whenever `Libraries.private_file?/1` is true, including when `get_file_instance/2` returned `:pending` (`file_controller.ex:118-121`). `:private_file` sends `private, max-age=3600` (`file_controller.ex:1308-1311`). A public file's stand-in is `no-store` (`:pending` at `file_controller.ex:1296`). The private branch skips that. The browser pins the nearest smaller size (or, after issue 1, a burned thumbnail used as that stand-in) to the variant URL for the rest of the hour, which is the failure G17 calls out: the URL is deterministic for the life of the token. The placeholder response itself is `no-store` (`serve_size_placeholder/1`).
- Suggestion: Keep `:pending` as `no-store` for private files too. Apply `:private_file` only when `freshness` is `:exact`.
- Status: open

### Issue 9 -- Severity: bug

- File: lib/modules/storage/storage.ex:521
- Description: MEDIUM. Bucket fullness sums every instance location, so a shared key is counted once per file and a bucket under its cap is treated as full. `calculate_bucket_usage/1` is `SUM(fi.size)` over active locations (`storage.ex:517-521`). Two clones of a 400MB video contribute 800MB. `Manager.bucket_full?/1` skips the bucket for new writes when that sum reaches `max_size_mb` (`manager.ex:213-228`). The float-division fix is in place; the sum still counts references, not objects. Placement is new in V205, so the double count now changes where uploads go, not only the number on the health page.
- Suggestion: Sum one size per distinct `path` on that bucket (`DISTINCT ON (fl.path)` or `GROUP BY fl.path`).
- Status: open

### Issue 10 -- Severity: bug

- File: lib/modules/storage/profiles.ex:190
- Description: HIGH for a large install. Any save of a profile bucket bumps `revision`, and the stale walk is an unindexed scan of every file, so changing serve order marks every file of that profile stale and the worker seq-scans `phoenix_kit_files` every batch. `put_bucket/3` bumps whenever the changeset is non-empty (`profiles.ex:190-191`), including `serve_order`, `role`, and `storage_class`. The row form saves on `phx-change` (`profiles_component.ex:339`). `keep` in `place_instance/3` does not look at role (`reconciler.ex:297-301`), so a role or serve-order edit moves no bytes, but every file whose `placed_revision` was the old value (or NULL, read as 1) is stale. `stale_query/0` (`reconciler.ex:79-104`) is a join plus an OR of four coalesced comparisons. V205 adds no index on `placed_revision`, `placed_profile_uuid`, or `reconcile_attempted_at`. The job reads that query every batch (10 files, then 2s). Health calls `stale_count/0`, which is the same scan. A million files already on Default become a multi-day walk and a sequential scan every two seconds, on the same `file_processing` queue as uploads (concurrency 20, one reconciler at a time). The serve path is not this query: `ranked/1` hits `phoenix_kit_file_locations_path_index`.
- Suggestion: Bump `revision` only when the edit changes where bytes go or how many copies are required (`stores`, `status`, adding or removing a bucket, `copies_originals`, `copies_variants`). Serve order and role are read at request time from the profile row; they do not need a file stamp. For the walk that remains, add a partial index the stale predicate can use, or a `placement_stale` boolean maintained on the write, so a healthy install's health page does not scan every file.
- Status: open

## Fixes from the earlier review

Checked against the current tree. Not re-reported except where the fix does not hold.

| # | Verdict |
|---|---|
| 1 | `verified_copies/4` runs before any unlink, and a target of 0 cannot unlink the last copy (`max(target, 1)`). Holds for one file's own locations. Issue 4 is the shared-key hole around it. |
| 2 | Nil `spec_hash` is not remade or removed. True for rows that stay nil. Issue 1 is the migration assigning a hash to existing thumbnail burns. |
| 3 | Rollback calls `unreferenced_keys/1` first. The check is not under the directory lock and does not see a `processing` row. Issue 2. |
| 4 | Stamps match the values read at the start. A concurrent stale mark is kept. |
| 5 | `restore_file/1`, `restore_file_into/2`, and `restore_folder/2` set `placed_variant_revision` to 0. Folder restore does not enqueue, and the reorganizer un-trash does neither. Issue 7. |
| 6 | Copy target is capped at buckets that already hold a copy or can take one. |
| 7 | Usage is `SUM(size) / (1024.0 * 1024)`. Shared keys are still summed once per instance. Issue 9. |
| 8 | `failed` and `processing` older than an hour are in `stale_query/0`. Sizes are skipped for them, then stamped as done. Issue 7. |
| 9 | Remakes of a key another instance still names use `fresh_key:`. Other generators (`ProcessFileJob`, a manual regenerate) still overwrite a shared key in place. That overwrite predates the reconciler; not filed again. |
| 10 | `reconcile_attempted_at` backs off 10 minutes. |
| 11 | A failed bucket is skipped and the next candidate is tried (`store_until/4`). |
| 12 | Unlink re-reads `file_name` under the directory lock and deletes the location only when the path still matches. |
| 13 | `key_needed_on?/2` keeps the object while a `processing` file in that directory has no instance for the key. The min-copies rollback does not use this rule. Issue 2. |
| B1 | `stand_in/3` returns `:original` unless the size will actually be made. Matches the review's decision. Public stand-ins are `no-store`; private ones are not. Issue 8. |
| B2 | Default `copies_variants` is written only when the value changes, and only while it still tracks originals. |
| B3 | `generate_variants/2` reads the set at the start and stamps that revision. |
| B4 | Resetting Default's sizes bumps the set revision. |
| B5 | `enqueue/0` replaces a `:scheduled` continuation. Not an `:available` one. Issue 6. |
| B6–B12 | Owner re-check, current set still listed, one transaction for profile and set, `min_copies_on_write` does not bump, redundancy cast is at most two digits. These match the code. |

Left as they were, and still left: a draining bucket is served at its role until the reconciler moves the copy. `ProcessFileJob` still does not mark an unhandled type `active`.
