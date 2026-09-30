# Codex review — integration-backed credentials and user-owned storage

Reviewed 2026-09-30 at `54a2d9205`, range `04f5ce04a..54a2d9205`.

**Result: changes needed before release.** Nine concrete findings below, five
HIGH and four MEDIUM. The important gaps are in the personal bucket probe,
Tigris request-host validation, deletion failure handling and backup placement.
The general site-listing and connection-owner separation is implemented, but
the successful existing tests do not exercise these boundaries sufficiently.

Following the handoff, production code was not changed. Suggested fixes are
provided for the author to implement and recheck.

## Verification and scope

Read the handoff, the V206 decisions and threat model, the changed application
code and tests, the placement/read/delete/reconciliation paths, and the installed
ExAws/Req implementations. Reviewed the schema changes and the callers of site
bucket listings, direct bucket getters and profile assignment.

Executed against the real `phoenix_kit_test` PostgreSQL database:

```sh
PGPOOL=12 mix test test/integration/storage test/modules/storage \
  test/phoenix_kit/migrations test/integration/phoenix_kit_web/live --max-cases 8
```

Result: **16 doctests, 1,580 tests, 0 failures, 1 excluded**. The database role
lacks CREATEROLE; that exclusion is unrelated to these findings.

`mix precommit` also passed (exit 0), including Dialyzer and all 240 JavaScript
tests. The diagnostic file separately passes `mix format --check-formatted`.

The accompanying `review_reproductions_test.exs` contains **11 diagnostic tests,
all passing at the reviewed commit**. They assert the current defective behavior
to demonstrate each finding, rather than asserting the desired fixed behavior.
They are deliberately outside the normal test tree and must be run explicitly:

```sh
PGPOOL=12 mix test \
  dev_docs/reviews/2026-09-30-user-owned-storage/review_reproductions_test.exs \
  --max-cases 8
```

HTTP calls are intercepted by `Req.Test`; no internal endpoint or real cloud
bucket was contacted. The Tigris hostname test additionally uses real DNS to
demonstrate different addresses for the base host and the bucket-prefixed host.
The filesystem reproduction runs through a mounted LiveView and confines writes
to a disposable temporary directory. Other reproductions exercise the contexts
and providers against database sandbox transactions.

No claim is made that real S3/R2/B2/Tigris, a browser session, or a populated host
upgrade has been verified. The documented decisions about snapshots, quotas,
owner FKs and account-deletion order are not treated as findings.

## 1. BUG - HIGH: personal “Test the bucket” permits the local filesystem provider

**Location:** `lib/phoenix_kit_web/live/components/library_settings.ex:96`,
`lib/modules/storage/storage.ex:568`,
`lib/modules/storage/providers/local.ex:213`.

`form_change` accepts the provider and endpoint from the client. `test_storage`
then runs `Storage.test_connection/1` without checking
`Libraries.may_use_own_storage?/1` or building an owned-bucket changeset. The
probe dispatches any registered provider, and its local-provider branch bypasses
the endpoint guard entirely. Local testing creates the supplied directory,
overwrites `.phoenix_kit_test` there and removes that file.

**Confirmed scenario:** a user with only `storage` and `storage.create_library`,
with `storage_user_buckets_enabled` **false**, sends crafted component events.
An existing sentinel file beneath the selected temporary server directory is
deleted. No personal connection, own-storage permission or library creation is
needed. Hiding the button does not protect the handler.

**Fix:** expose one scope-aware personal probe that rechecks permissions and
validates `Bucket.owned_changeset/4` before dispatch. Use it for both Test and
Create. Also reject an owned `local` probe inside the storage context so another
caller cannot repeat the mistake. Test disabled settings and missing permissions
through actual component-targeted LiveView events.

## 2. BUG - HIGH: Tigris validates a different host from the request destination

**Location:** `lib/modules/storage/providers/s3.ex:316` and `:333`,
`lib/modules/storage/schemas/bucket.ex:248`.

The personal endpoint guard checks the base endpoint host. For Tigris,
ExAws subsequently prepends the bucket name to that host
(`deps/ex_aws/lib/ex_aws/operation/s3.ex:71`). The resulting hostname is never
checked. A public base record and a private bucket-prefixed record can coexist
permanently: this does not depend on the acknowledged DNS-rebinding window.

**Confirmed scenario:** the base `sslip.io` resolves to a public address and
passes the personal guard. Its bucket-prefixed hostname in the diagnostic test
resolves to loopback and is independently rejected by `Endpoint.check/3`, yet
`S3.file_exists?/2` sends its HEAD request to that hostname. The request is
intercepted before any network connection.

There is a second path in the same construction: an owned bucket name is only
length-validated. URL delimiters are accepted, and a malformed Tigris bucket name
produces a successfully presigned URL whose parsed host is a literal loopback
address although the saved endpoint is a public IP. This is independently
reproduced in the diagnostic file.

**Fix:** validate provider-appropriate bucket-name syntax, reject URL delimiters,
and run the policy guard on the **effective request/URL host**, after virtual-host
addressing is applied. Share the effective-host calculation between probes,
ordinary requests, multipart operations and presigning. Checking only the base
host again will not fix this.

## 3. BUG - HIGH: the new S3 probe overwrites and deletes an existing object

**Location:** `lib/modules/storage/providers/s3.ex:207`, `:219`, `:233`.

Every connection test puts `"ok"` at the same `.phoenix_kit/connection-test` key
and then deletes it. The bucket can already contain an object at that key; no
reservation or conditional creation protects it. Testing and creating a library
both invoke this destructive sequence. Concurrent tests also share the object.

**Confirmed scenario:** seed that key with existing content in the in-memory
bucket, then run `S3.test_connection/1`. It returns `:ok`; the content is gone.
On an unversioned real bucket this loses the prior object permanently.

**Fix:** generate a fresh unpredictable probe key for each invocation and pass
it through all probe stages. Delete only that invocation's object, including
best-effort cleanup when a later stage fails. Use conditional creation where the
provider supports it. Add an existing-object preservation test.

## 4. BUG - HIGH: a backup alone satisfies the upload minimum, but cannot be served

**Location:** `lib/modules/storage/profiles.ex:469`,
`lib/modules/storage/services/manager.ex:183`.

The backup profile preserves a single numeric `min_copies_on_write`, which the
manager checks against **all** successful copies, including the user's backup.
The Default's success condition was about site storage. Meanwhile backups are
intentionally excluded from serving. The plan also accepts read-only site rows
as sufficient site storage.

**Confirmed scenario:** Default has one enabled, read-only site bucket. Creating
a backup profile succeeds. An original upload returns `{:ok, file}` and is
stored only in the user's backup, but `Manager.get_file_access/2` returns
`{:error, :not_found}`. A failed active site bucket can cause the same result.
With larger minimums, the backup can similarly replace a required site copy.

**Fix:** count successful site/servable copies separately from backup copies
when deciding whether an original upload succeeds. Preserve the Default's
minimum on those site copies. Reject a new backup plan with no writable site
original destination. Leave a missing backup eligible for reconciliation, as
already intended.

## 5. BUG - HIGH: purge discards the only cleanup metadata after an object delete fails

**Location:** `lib/modules/storage/libraries.ex:1161` and `:1167`,
`lib/modules/storage/profiles.ex:554`.

`delete_file_completely/1` deletes database rows before the remote object and
logs object-deletion errors while returning success
(`lib/modules/storage/storage.ex:4442`). Purge therefore proceeds to delete the
library, its profile and its now-location-free owned bucket even when the remote
delete failed. There is no durable retry record naming the abandoned objects.

**Confirmed scenario:** successfully upload a file on owned-only storage, then
make the fake bucket deny DELETE while leaving the connection available. Purge
returns `:ok`; the private bytes remain in the bucket, but the file/library/
profile/bucket metadata is gone. This is distinct from the documented
account-deletion case: the user and their usable connection still exist.

The earlier file-delete behavior predates this range, but V206's removal of the
entire personal storage configuration makes that inherited failure terminal for
automatic cleanup.

**Fix:** persist the object keys and bucket/credential reference in a cleanup
job or tombstone before removing the file rows. Retain enough owned-storage
metadata until deletions are confirmed, and retry failed cleanup. Returning an
error alone after the rows are gone does not restore retryability.

## 6. BUG - MEDIUM: trimming backup snapshots can remove all derived storage

**Location:** `lib/modules/storage/profiles.ex:449`, `:468`, `:480`.

`keep_room_for_backup/1` takes the first four **rows**, regardless of what they
store. The five-copy limit applies to originals, but derived-only rows also
consume these four slots. Copy counts then use the total row count rather than
the eligible buckets for each object kind.

**Confirmed scenario:** Default has four originals-only buckets followed by one
derived-only bucket. Default can store variants. The new backup profile drops
the derived bucket, still advertises `copies_variants: 1`, and has no placement
candidates for any derived object. Thumbnails, renders and tiles cannot be
stored even though site storage supported them before this choice.

The inverse ordering can discard all original destinations and report
`:no_site_storage` despite a usable original bucket later in the Default list.

**Fix:** enforce the four-site-original limit on original-capable rows only,
preserve derived-only destinations, and calculate counts using eligible rows of
the corresponding kind. Respect the agreed snapshot policy; this finding does
not require following later Default changes.

## 7. BUG - MEDIUM: the final storage choice is not enforced against current DB state

**Location:** `lib/modules/storage/profiles.ex:330` and `:341`.

`set_library_profile/2` checks the caller's library struct rather than the
current stored assignment. `assign_user_profile/2` checks matching owners but
does not enforce its documented NEW-library restriction. `@doc false` does not
make a function private or restrict when it can run.

**Confirmed scenarios:** retain a site-storage struct, assign that library an
owned profile, then call `set_library_profile/2` with the stale struct and a
different site profile: the move succeeds. Separately, a currently assigned
owned library can be reassigned to a second owned profile through
`assign_user_profile/2`. Both APIs queue reconciliation after the change.

These are context-boundary violations, not demonstrated ordinary-user UI
exploits; the current UI does not expose these assignments.

**Fix:** reload and lock the library during a single transactional check/update.
Restrict the creation assignment to the creation operation rather than offering
an unrestricted reassignment primitive. Test stale callers and concurrent changes
alongside fresh-struct refusals.

## 8. BUG - MEDIUM: “can be read” is reported without checking object-read permission

**Location:** `lib/modules/storage/providers/s3.ex:199` and `:209`.

The read stage lists bucket keys; it never reads or HEADs the object it wrote.
Listing and object reading are different capabilities. The wizard's success
message promises readable storage and creation permanently selects it.

**Confirmed scenario:** the fake bucket accepts list/PUT/DELETE but denies
HEAD/GET for objects. `S3.test_connection/1` returns `:ok`, whereas
`S3.file_exists?/2` immediately fails with access denied. Subsequent download
and presigned access cannot work with those credentials.

**Fix:** GET the uniquely named probe object and verify its content before
deleting it. Give read failures their own message. Also avoid making whole-bucket
listing the sole read test for keys scoped to an object prefix.

## 9. BUG - MEDIUM: generic updates bypass the owned-bucket connection guard

**Location:** `lib/modules/storage/storage.ex:479`,
`lib/modules/storage/web/bucket_form.ex:49`,
`lib/modules/storage/schemas/bucket.ex:293`.

Creation uses the owner-aware changeset, but generic updates use
`Bucket.changeset/2`, which neither verifies connection ownership nor applies the
personal endpoint policy. The site bucket form also loads any bucket UUID,
including owned ones excluded from its listing. Its connection picker is
system-scoped, so that route is inappropriate for editing an owned bucket.

**Confirmed scenario:** create an owned bucket with a valid personal connection,
then update its `integration_uuid` to a system connection using
`Storage.update_bucket/2`. The update succeeds and the database CHECK accepts
it. Runtime correctly refuses the foreign credentials, leaving the previously
usable bucket broken. This does **not** demonstrate credential disclosure.

**Fix:** reject owned buckets in site bucket edit/toggle/delete handlers and
apply the owned rules to any supported generic update of an owned bucket. Keep
runtime owner-scoped credential resolution as the independent second guard.

## Additional improvement

**IMPROVEMENT - MEDIUM:** bound the creation probe and keep it off the LiveView
event process (`lib/phoenix_kit_web/live/components/library_settings.ex:127`,
`lib/modules/storage/libraries.ex:689`). Test is async, but Create repeats the
same network probe synchronously. ExAws has retries and per-request timeouts;
there is no total deadline around the storage probe, unlike
`PhoenixKit.Integrations.Probe`. A stalled endpoint can block further events
for that page through multiple request attempts. Use a hard deadline and an
async creation flow with an explicit pending state. This was identified by
control-flow/dependency inspection, not by contacting a stalled real endpoint.

## Already-known follow-ups

The handoff's global `buckets_available?/0` issue, untranslated endpoint errors,
legacy Tigris validation changes and lack of a browser/real-cloud check remain
open. They are not counted among the nine newly confirmed findings above.
The “first four” snapshot decision, absent owner FKs and quota deferral are
preserved by the suggested fixes.
