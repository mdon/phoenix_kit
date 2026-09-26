# Recheck of Grok's V205 review

Grok's review (`GROK_REVIEW.md`, of `ba258188b..f296accea`) filed ten bugs.
All ten were confirmed against the code and fixed; tests are in
`test/integration/storage/storage_v205_review_test.exs` ("Grok's review")
and `test/phoenix_kit/migrations/v205_test.exs`.

| # | Finding | Fix |
|---|---|---|
| 1 | The migration stamped a spec hash onto thumbnails with an annotation burned into them, so the next size change would make over them. | The stamp skips a `thumbnail` whose file records `metadata.burn` or has a `burned`, `burned_large` or `thumbnail_annotated` instance (V205 changed; still unpushed). |
| 2 | The min-copies rollback checked references outside the directory lock and missed an upload still writing the same key. | `Storage.undo_store/3`: under the key's directory lock, deletes only an unreferenced key with no other upload into the directory in flight; the upload's own row is passed so it does not hold itself back. |
| 3 | A shared key was served at the best role any file sharing it gave the bucket, so one library's backup could be served. | Serving passes the file (`file_uuid:`); `Locations.ranked/2` ranks with that file's locations and profile only. |
| 4 | A reconciler copy was recorded outside the lock another file's unlink holds, so both could remove the real copies of a shared key. | Copy, check and record run under the key's directory lock, the one `unlink_location/2` takes. |
| 5 | For serving, a backup without a location row was still probed as a fallback. | With the file known, its profile's backup buckets are left out of the serve fallback (`Locations.backup_buckets/1`). |
| 6 | A change while the next batch was already `available` kept its cursor. | `enqueue/0` also replaces an available run's args. |
| 7 | Trashed, failed or still-processing files were stamped as having their set's sizes; the reorganizer's un-trash did not mark them again. | Sizes are stale, and stamped, only for active files; folder restore and the reorganizer's un-trash mark variants stale and queue the reconciler. |
| 8 | A private file's stand-in was cached for an hour at the variant's URL. | `private, max-age` only for the exact variant; a stand-in is `no-store`. |
| 9 | Bucket usage counted a shared key once per file. | Summed once per object (`DISTINCT` on the path). |
| 10 | Any bucket-row edit bumped the profile's revision, making every file stale. | Only `stores`, `status` and `role` (and adding or removing a bucket) bump it; serve order, write priority and storage class do not. |

Found while fixing #10: a role change could leave a file's only copies on
backup buckets, which are never served, and nothing would fix it. The
reconciler now makes one copy on a primary or replica when the profile has
one to write, and keeps the file stale until it has.

Not changed: the stale walk still scans files in uuid order (one pass per
walk; the Health count is a full count). With #10 a pass follows a real
placement change only. An index for it is left until a large install
shows the need.
