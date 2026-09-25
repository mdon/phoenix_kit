# Storage libraries phase 3 (V204): recheck of Grok's review (2026-09-25)

Grok reviewed `39bfbc5f9`..`e3ea96367` and left findings only
(`GROK_REVIEW.md`, no code). Claude checked each against the code: every one
is real. All are fixed here, V204 still unreleased, so its schema changed too.

| Severity | Finding | Fix | Test |
|---|---|---|---|
| **BUG - HIGH** | A read that found a key in a fallback bucket recorded that one bucket; the backfill visited only instances with no row, so the other copies were never recorded, and variants were pinned to the one bucket. | "Visited" is its own record: `phoenix_kit_file_location_checks` (added to V204). The backfill walks unchecked instances, records every copy and marks each checked. A read's record is not a check. Writers mark theirs checked (they know every bucket they wrote), a clone copies its donor's check, and V204 marks instances that already had rows. | `locations_test.exs` "a read that records one bucket does not retire the instance"; `v204_test.exs` "marked checked by up" |
| **BUG - HIGH** | A contributor could trash, delete or move someone else's files by acting on a folder, or on selected folders. | `own_files_only` also refuses `trash_folder`, `delete_folder` and `move_folder_to_folder` when the folder's subtree homes another uploader's file (a move's target is not checked), and a bulk action whose `selected_folders` do. Folder names and looks stay shared. | `media_browser_own_files_test.exs` "a folder write whose subtree holds someone else's file" |
| **BUG - MEDIUM** | An object missing from every bucket kept the backfill queued forever, the Health count never reached zero, and every request for it probed every bucket. | The backfill marks a miss checked (`found_in: 0`). `Locations.known_missing?/1` then lets a read answer "not found" without probing. | "a miss is remembered" |
| **BUG - MEDIUM** | A restore committing after `PurgeLibraryJob` loaded the row still lost the library. | `purge_library/1` first claims the library in one statement that requires it trashed (a `purging` mark in `settings`); `restore_library/2` re-reads under `FOR UPDATE` and refuses a claimed one. | `user_libraries_test.exs` "restore and purge cannot both win" |
| **BUG - MEDIUM** | `ApplyImageEditJob`'s render and unedited copies went to a freshly chosen bucket set. | Both are forced to the buckets the source key is recorded in (the usual selection when nothing is recorded). | not covered by a test (needs a real edit render) |
| **BUG - MEDIUM** | A recorded bucket that raised aborted the read before another copy was tried. | `bucket_holds?/2` and `safe_retrieve/4` treat a raise as "not this bucket", logged. | not covered (needs a failing provider) |
| NITPICK | The detail-page audit had no user agent; neither audit caught `:exit`. | The detail page captures IP and user agent at mount; both catch `:exit`. | |
| NITPICK | `LibraryMember`'s moduledoc stopped mid-sentence. | Rewritten. | |
| NITPICK | `ChecksumBackfillJob` re-downloaded duplicate and unreadable rows on every pass. | They are marked in `metadata["checksum_backfill"]` and skipped. | `checksum_backfill_test.exs` |

Manifest: the checks table (6 objects) declared catalog-exact, `chain_hash`
restamped; the repair, hand-declared manifest, release-check and prefix
suites pass against the real database.
