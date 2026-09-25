# GROK_REVIEW — storage libraries phase 3 (V204, location-truth)

**Reviewed:** commits `39bfbc5f9`..`e3ea96367` on `main` (unreleased, after tag
`v2.39.0`). Migration, location reads, both backfill jobs, the phase-2
follow-ups (contributor limit, library restore, detail-page audit).
**Not in this pass:** the adoption-check work that also sits above `v2.39.0`
(`#868`).
**Code left as it is.** Findings for triage.

The migration, the bucket FK, `force_bucket_ids`, and the new writers
(`store_system_file/3`, `store_file/2`, the recreate path) do what the phase
says. Two of the guarantees do not hold once the backfill is running next to
real traffic, and the contributor limit can be stepped around with a folder.

## BUG - HIGH

**A read records one bucket and the backfill then skips the rest.**

`LocationBackfillJob` only visits an instance that has no location row
(`missing_query/1`). Every read path records the first fallback bucket that
has the key and stops:

- `Manager.file_exists?/2` (`manager.ex` `Enum.find(fallback, holds?)`)
- `Manager.retrieve_file/2`
- `Manager.public_url/2`
- `Manager.get_local_file_path/1` / `get_file_access/2`

`Locations.record/2` writes that one bucket for **every** instance stored
under the key. One view of a tile, a clone, or a comment attachment during
the backfill (50 instances, then a 5s pause; a large library takes hours)
gives the whole dedup group a single row. The next batch's `NOT EXISTS`
skips them.

Whatever else still holds the object — the other redundancy copies — is
never written down. `get_file_instance_bucket_uuids/1` then returns that one
bucket, and `VariantGenerator` pins new variants to it (`force_bucket_ids`).
The plan's own description of the steady state ("once the backfill is done,
a probe only happens for a key that really has no row") is the opposite of
this race: the hot files, the ones served while the job runs, are the ones
left with a partial set, and they stop being probed.

The backfill job itself does check every enabled bucket. A read must not be
able to retire an instance from that walk. Either the read probes every
fallback bucket and records each hit before the instance counts as done, or
"done" is a mark the backfill sets, not "at least one row exists".

**A contributor can still trash, restore, or permanently delete someone
else's files.**

`own_files_only` refuses a write whose params or `selected_files` name
another uploader's file, and it refuses `empty_trash` and
`delete_all_orphaned`. It never looks inside a folder.
`Storage.trash_folder/2` trashes every file homed in the subtree
(`storage.ex` `do_trash_folder/1`). `delete_folder_completely/2` and
`restore_folder/2` do the same in the other direction.

From a contributor session, all of these are accepted:

- `trash_folder` / `delete_folder` (the trash view's `delete_folder` is the
  permanent one)
- `delete_selected` and `restore_selected` when `selected_folders` is
  non-empty and `selected_files` is empty — selecting only folders is
  `toggle_select_folder`, which names no file, so the guard lets it through
- `move_folder_to_folder` / `move_selected_to_folder`, which carry every file
  in the folder with it

`Libraries.allows?/2` gives a contributor `:read` and `:upload` only. The
new test covers `trash_file`, a `selected_files` bulk delete, and
`empty_trash`. It does not put a folder in `selected_folders`.

The check has to reject a folder write when any file homed in that subtree
belongs to someone else (and the bulk events have to include
`selected_folders`, not only `selected_files`). Shared folder metadata
(rename, colour, description) can stay.

## BUG - MEDIUM

**The backfill cannot finish if any object is gone, and those keys are
probed forever.**

An instance found in no bucket is left with no row (`LocationBackfillJob`
counts `:missing` and moves on). `maybe_enqueue/0` is "any instance has no
row", called on boot and by the daily prune. One lost tile keeps both of
those jobs walking every missing key against every enabled bucket, and
`Locations.missing_count/0` on the Health page never reaches zero. A request
for that key still HEADs every enabled bucket (`bucket_uuids/1` is empty, so
the whole list is fallback) and tries `record/2`, which inserts nothing.

The two decisions in the phase notes — "leave missing instances alone" and
"keep the probe until every instance has a row" — don't compose. Needs a
remembered negative result (a checked-at on the instance, not a location
row) so a confirmed miss is not work anymore, and so the Health number is
"not looked at yet".

**Restoring a library races its purge.**

`PurgeLibraryJob` reloads the row, then calls
`purge_library(%Library{})`. The `trashed_at == nil` clause only matches
that struct. The reload and the deletes are not one locked read: a restore
that commits after the reload and before `delete_file_completely/1` still
loses the library and its files. Restore is new in this phase;
`purge_library/1` has to re-check `trashed_at` under a row lock and stop
when the library is live.

**An image edit still places the new bytes on a freshly chosen bucket
set.**

The work list for this phase says `ApplyImageEditJob`'s outputs are pinned
to the original's buckets. `prepare/1` calls `Manager.store_file/2` with no
`force_bucket_ids` (the render at `apply_image_edit_job.ex` around the
`path_prefix: key` store, and `copy_object/1` for the unedited copies).
`select_buckets_for_storage/2` still shuffles priority-0 buckets and takes
`storage_redundancy_copies`. The new `forced_buckets/1` is correct, and
variant generation uses it; the edit path never calls it. Locations for the
new key match where this write happened, so reads of that key are right.
The file's copies move to whatever the pool picks today.

**A recorded bucket that raises is not a miss.**

`file_exists?/2`, `public_url/2` and `get_file_access/2` call
`provider.file_exists?/2` with no rescue. An exception on a located bucket
(credentials, a timeout) aborts the call before the fallback list is tried.
The backfill's `safe_exists?/3` already treats that as "not this bucket".
The read path now prefers located buckets, so a sick recorded bucket is the
one that fails the serve even when another copy is fine.
`retrieve_file/2` already continues on `{:error, _}` and only loses on a
raise.

## NITPICK

- The detail-page audit (`MediaDetail.audit_admin_opening/2`) omits
  `user_agent`. Opening the library at `/admin/libraries/:uuid` stores it.
  Same function rescues and does not `catch :exit`, so a dead pool takes the
  page down instead of showing the file. The library page has the same gap.
- `LibraryMember`'s moduledoc stops mid-sentence ("and emptying the trash").
- `ChecksumBackfillJob` leaves `:duplicate` and `:unreadable` rows on the
  MD5 predicate, so every boot and every prune downloads those originals
  again and hits the same unique violation. Correct, and permanent for a
  real collision.

## What holds

- V204's SQL: oldest-of-pair dedupe, bare unique
  `(file_instance_uuid, bucket_uuid)`, path index, bucket FK swapped to
  `RESTRICT` through `V203.replace_constraint/7` with its own `_v204`
  suffix, re-run and down covered in `v204_test.exs`. `delete_bucket/1`
  surfaces that as a changeset error the settings page can say out loud.
- `forced_buckets/1` keeps the caller's order, drops disabled ids, and does
  not cap at redundancy. The variant generator's existing
  `force_bucket_ids` now mean what they say.
- `store_system_file/3`, `store_file/2` (via
  `create_original_instance_and_variants/4`) and the recreate path record
  the buckets the write actually used, after the instance row exists.
  `record/2` is idempotent (`on_conflict: :nothing`) and a failure there
  does not fail the read.
- Deletes are still "unreferenced key, every enabled bucket", which matches
  deferring per-`(bucket, key)` counts to V205.
- Upload API checksums are SHA-256. The MD5 job updates `file_checksum` and
  the library-aware `user_file_checksum`, guarded on the old checksum, and
  leaves a unique-index collision as MD5.
- Bucket create/update/delete drops `:phoenix_kit_buckets_cache`.
- Library restore gives back a free slug, respects the owner cap under the
  same advisory lock as create, and becomes the default only when the owner
  has none. A purge job that observes the restored row cancels
  (`:not_trashed`); the hole is the stale struct above, not the job clause.
- The detail-page audit fires for a connected Owner/Admin who is neither
  the uploader nor a member, once per mount, and reuses the allowlisted
  `storage.library_opened` action.
