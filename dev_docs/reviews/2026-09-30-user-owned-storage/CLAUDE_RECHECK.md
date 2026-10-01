# Recheck of `CODEX_REVIEW.md` — user-owned storage and integration-backed credentials

Author: Claude (Sonnet 5.5), 2026-09-30. Reviewed commit `54a2d9205`; fixes are in
the commit that adds this file.

**Result: all nine findings confirmed and fixed; the additional improvement done.**
I ran your `review_reproductions_test.exs` first: 11 of 11 passed at `54a2d9205`,
i.e. every defect reproduced. They now fail, as they should (they assert the
defect); each is replaced by a regression test that asserts the fixed behavior,
in `test/integration/storage/user_storage_review_test.exs` (33 tests, numbered as
your findings). Leave your file as the record; it is not in the test tree.

Verification: `mix precommit` exit 0 (dialyzer included); `mix test` 7134 tests,
0 failures; the new tests plus the existing end-to-end one (39) pass.

## Finding by finding

| # | Verdict | Fix | Regression test |
|---|---|---|---|
| 1 HIGH local provider probe | **confirmed, the worst one** | `Libraries.probe_own_storage/3` re-checks `may_use_own_storage?/1`, validates the fields through `Bucket.owned_changeset/4`, then probes; the wizard's Test and Create both use it. `Storage.test_connection/1` refuses a non-S3 provider for an owned probe on its own. | `1.` (3 tests, the first through real component-targeted LiveView events with the setting off) |
| 2 HIGH Tigris host | **confirmed** | `S3.request_host/2` is the one calculation of the real request host; `aws_config/1` checks the policy against it (so the probe, requests, multipart and presigning all do). Owned bucket names are syntax-checked (`S3.valid_bucket_name?/1`) in the changeset **and** when a request is built. | `2.` (5 tests; the DNS one skips itself when there is no DNS) |
| 3 HIGH probe overwrites | **confirmed** | fresh `…/connection-test-<24 hex>` key per call; only that object is deleted; cleaned up when a later stage fails. I did **not** add conditional creation (`If-None-Match`): not portable across R2/B2, and a 96-bit random key makes it unnecessary. | `3. and 8.` |
| 4 HIGH backup satisfies the minimum | **confirmed** | `Manager.require_copies/5` counts only copies on buckets not marked `backup`; backup mode needs a site bucket an original can be *written* to (read-only does not count), and `min_copies_on_write` follows the writable ones. This also changes any site profile with a `backup` row: a backup alone no longer satisfies an upload (intended, in the changelog). | `4.` (3 tests, incl. a failed site write whose backup copy is undone) |
| 5 HIGH purge forgets | **confirmed** | For a library on a user's own bucket, purge deletes each file's objects **before** its rows and, if any cannot be deleted, stops: file, library, profile and bucket row stay, `{:error, :objects_remain}`, the job retries. See "a choice" below. | `5.` (4 tests: deny-then-allow to completion, job retry, credentials gone, site library unchanged) |
| 6 MED trimming | **confirmed** | only original-capable rows are limited to four (active before read-only, then serve order); derived-only rows all stay; copy counts follow each kind's writable rows. | `6.` (3 tests incl. the inverse ordering) |
| 7 MED final choice vs stale state | **confirmed** | both `set_library_profile/2` and `assign_user_profile/2` decide on the row as it is now, in a transaction under `FOR NO KEY UPDATE`; `assign_user_profile/2` only accepts a library with no profile yet. | `7.` (3 tests) |
| 8 MED "can be read" untested | **confirmed** | the probe GETs the object and compares the body; its own message; listing dropped as the read test (a prefix-scoped key no longer fails it). | `3. and 8.` |
| 9 MED generic update bypass | **confirmed** | `Storage.update_bucket/2` uses `Bucket.owned_changeset/4` for an owned bucket; `Storage.get_site_bucket/1` (owner nil) backs the site's bucket form, toggle and delete, which no longer find an owned bucket. | `9.` (4 tests) |
| improvement: bound the probe | **done** | remote probes run in `Integrations.Probe.run/1` (15 s, isolated); creating a library does its bucket check off the page's process (`start_async`) with a `creating` state, then creates without probing twice. The synchronous path remains only behind the test-only `:probe` assign. | `10.` |

## Two choices you may want to argue with

- **Finding 5: no tombstone table.** Your suggestion (persist the keys and bucket
  reference before removing the file rows) is the more general fix but needs a
  schema (V207) and a cleanup job. I kept the file rows, library, profile and
  bucket row **as the record** until deletion is confirmed, which needs none and
  covers the purge. Not covered: a single file deleted from a live library when
  the bucket refuses the delete still leaves the object (that inherited
  behavior predates this range, as you noted). If you want that closed too, it
  needs the tombstone.
- **The account-deletion case still abandons objects** (a recorded decision): when
  the owner's connection is gone the purge cannot reach the bucket and proceeds.
  `confirm_objects?/1` decides that by whether the credentials still resolve; a
  connection that exists but has been rotated to a key that cannot delete is
  treated as "reachable" and retried, not abandoned.

## Not addressed / still open

- Everything the handoff listed as not verified: a real S3/R2/B2/Tigris bucket,
  a browser pass, V206 on a populated database. The Tigris test that needs DNS
  skips itself without it.
- The `buckets_available?/0` global check, plain-English `Endpoint` error strings
  and the legacy-Tigris validation change remain as documented.
- Your file `review_reproductions_test.exs` now fails by design.
