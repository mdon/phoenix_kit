# V205 review: storage profiles and variant sets

**Scope:** `ba258188b..HEAD` on `main` (the V205 work order and its seven
steps). Two independent read-only reviews, one on the data-loss surface
(reconciler, unlinks, placement, generation), one on the migration,
manifest, serving and editors. Every finding below was checked against the
code before it was fixed; each fix has a test in
`test/integration/storage/storage_v205_review_test.exs` unless noted.

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | BUG - CRITICAL | The reconciler counted a kept copy as good from its location row alone, and could unlink (and delete) the only real copy when the kept row had outlived its object. | Before any unlink, the copies that stay are checked with `Manager.holds?/2`; fewer than the target (never fewer than one) leaves the file stale. |
| 2 | BUG - CRITICAL | A burned annotation thumbnail sits in the `thumbnail` slot with no `spec_hash`; the reconciler treated nil ≠ hash as "remake" and made over it on every pass. | An instance in a size slot with no spec hash is never made over. |
| 3 | BUG - HIGH | The `min_copies_on_write` rollback deleted the written key from every bucket, even when another file (a same-bytes upload not yet a dedup donor) owned it. The older instance-insert failure paths did the same across all buckets. | The rollback deletes only an unreferenced key; the old paths go through `delete_stored_objects/1` (reference check under the directory lock). |
| 4 | BUG - MEDIUM | The reconciler's stamp overwrote a stale mark set during its own run (an incomplete variant) or by another job. | Stamps are conditional on the values read at the start; sizes run before locations. |
| 5 | BUG - MEDIUM | Trashed files were stamped as having their set's sizes; restoring one never made them. | A restore (file, into a folder, or with its folder) marks the file's variants stale and queues the reconciler. |
| 6 | BUG - MEDIUM | The copy target counted read-only or full buckets it could not write, so a drain could never finish. | Target capped at buckets that hold or can take a copy. |
| 7 | BUG - MEDIUM | Bucket usage divided each file to whole megabytes before summing: files under 1 MB counted as 0 and `max_size_mb` never tripped. | `SUM(size) / (1024.0 * 1024)`. |
| 8 | BUG - MEDIUM | Files left in `processing` (types the processing job skips, failed runs) and `failed` were never reconciled, so a draining bucket holding them never emptied. | Included: `failed`, and `processing` untouched for an hour. Sizes still only for active files. |
| 9 | BUG - MEDIUM | A cross-user copy shares its donor's variant keys; remaking the donor's size under a new spec overwrote the bytes the copy serves. | A remade size whose key another file references goes under a key of its own (`fresh_key:`, spec hash in the name). |
| 10 | BUG - MEDIUM | A permanently failing file was retried on every restart, ahead of every other file. | `files.reconcile_attempted_at` (added to V205 before it was pushed): a file the reconciler could not finish waits ten minutes. |
| 11 | IMPROVEMENT - MEDIUM | A failed write did not fall through to the next eligible bucket, so an upload could fail with a spare available. | Writes continue down the candidate list until the wanted copies succeed. |
| 12 | BUG - MEDIUM | An unlink deleted the location by instance and bucket only; an image edit moving the row to another key meanwhile lost the backup's location. | Re-read under the lock; the delete also matches the key. |
| 13 | BUG - MEDIUM | An unlink could delete a key an upload into the same directory had written but not yet recorded. | The object stays while a `processing` file in that directory has no instance under the key yet. |
| B1 | BUG - HIGH | G17 served a placeholder for ever for a size that will never be made (a set that makes no sizes, a disabled size, a size for the other kind of file). Before V205 that was the original. | `stand_in/3` gives the original unless the size will be made. Test in `variant_set_generation_test.exs`. |
| B2 | BUG - MEDIUM | Any save on the Configuration tab rewrote the Default profile's `copies_variants` (and bumped its revision); a count over the enabled buckets blocked unrelated saves. | Saved only when changed; variants follow only while equal to originals. |
| B3 | BUG - MEDIUM | An in-flight variant run stamped the set's revision at its end, hiding a size changed while it ran. | The set is read when the run starts and that revision is stamped. |
| B4 | BUG - MEDIUM | Resetting the Default's sizes did not bump its revision, so nothing was remade or removed. | Bumped inside the reset. |
| B5 | IMPROVEMENT - MEDIUM | A change during the pause between batches was absorbed by the waiting continuation instead of restarting the walk. | `enqueue/0` replaces a waiting run's cursor. |
| B6 | NITPICK | The user's set picker trusted the tab's list. | Re-checks the row (not trashed, the owner) before changing it. |
| B7 | NITPICK | A library on a set no longer selectable showed the wrong value. | The current set is listed, disabled. |
| B8 | BUG - MEDIUM | An install whose `small` was cropped before V205 could not change anything about it. | The aspect rule applies when the size is made, renamed, or its aspect setting changes. |
| B9 | NITPICK | `variant_for/2` could return a video transcode. | `:output` option, `:image` by default. |
| B10 | NITPICK | The Libraries tab could save the profile and fail the set. | One transaction. |
| B11 | NITPICK | Changing only `min_copies_on_write` made every file stale. | It changes no placement, no revision bump. |
| B12 | NITPICK | An absurd `storage_redundancy_copies` value could overflow the cast and abort the migration. | At most two digits are read. |

## Left as they are

- A draining bucket ranks by its role for serving, so it can be served
  before an active primary while it drains. Its copies are still good; the
  reconciler removes them once they are elsewhere.
- `ProcessFileJob` never marks a file of an unhandled type (audio, archives)
  `active` (pre-existing, not V205). The reconciler now places such files
  after an hour; making them active is a separate change.

## Verification

Full suite 6877 tests, 0 failures. Gettext round-trip 0/0/0 in every
catalogue, 0 fuzzy in the seven translated locales. `chain_hash` restamped
after the V205 column was added; its manifest entry emitted from the
catalogue like the other 59.
