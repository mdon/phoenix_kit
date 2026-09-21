# PR #847: Fix trashed files staying visible after trash, restore, or delete

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`3502c093`), not yet released; every finding below is fixed post-merge
**Date**: 2026-09-21

## Goal

Trashing, restoring or permanently deleting a file broadcast nothing, so a
page that had the file loaded kept showing it. The PR adds three events on
the files topic (`:phoenix_kit_file_trashed | _restored | _deleted`), sent by
`trash_file/1`, `restore_file/1`, `delete_file_completely/1` and per file by
`trash_folder/2` / `restore_folder/2`. `MediaBrowser` forwards them and drops
the card, `FeaturedImage` gains `send_update(..., refresh: true)`, and
`FileController.get_servable_file/2` refuses a trashed file's variants except
to a holder of the `"media"` permission (the Trash tab renders its thumbnails
through the same signed route).

## Verified

- The folder sweeps capture the affected uuids with `select:` inside the
  transaction and broadcast **after** it commits, so no subscriber reloads a
  row that is not yet visible, and a rolled-back sweep broadcasts nothing.
- `delete_folder_completely/2` removes its files through
  `delete_file_completely/1`, so folder deletion is covered by the new
  `:phoenix_kit_file_deleted` without a separate sweep.
- The `/file/...` route's pipeline runs `fetch_phoenix_kit_current_user`
  (the session-token loader), so `conn.assigns[:phoenix_kit_current_user]`
  carries the active role that `Scope.for_user/1` needs.
- The destructive bulk path is safe against the new stale-selection case
  (see the NITPICK below): `delete_selected` re-reads every selected file and
  permanently deletes only one whose `status` is still `"trashed"`.
- Tests on the combined tree (this PR, #850, #851 and the unreleased V200
  work): the PR's four test files plus the other two PRs' and V200's — 317
  tests, 0 failures.

## Findings

### BUG - HIGH: a trashed file served to a "media" holder is cached `public` — a shared cache then serves it to everyone

> **Fixed post-merge.** `FileController.cache_mode/3` now answers `:private`
> for any trashed file, first and whatever the version or freshness, and both
> header writers turn it into `private, no-store` — so the local, proxied and
> redirected responses, and a 304, all carry it. Regression test:
> `test/integration/phoenix_kit_web/controllers/trashed_file_cache_test.exs`,
> served end to end from real stored bytes (the PR's own authz tests use
> file rows with no stored bytes, so `show/2` 404s before any cache header is
> written — which is how this passed review). Verified to fail with the
> clause removed. The public-bucket redirect in the note below is **not**
> changed and stays with the tile routes on the follow-up.

`get_servable_file/2` now makes the response to one URL depend on **who**
asks: a `"media"` holder gets the bytes, anyone else a 404. But the response
the holder gets still carries the cache headers of an ordinary file —
`put_variant_cache_headers/3` knows nothing about trash:

- a versioned URL → `public, max-age=31536000, immutable`
- an unversioned one → `public, max-age=86400` (or `public, no-cache`)

The URL itself is not per-user: the token is 4 hex characters of
`MD5(uuid:variant + secret_key_base)`, the same for every caller. So on a
host fronted by a CDN or a caching reverse proxy — which the storage README
explicitly contemplates ("If you front files with a CDN…") — the first
authorized request stores the trashed file's bytes under a public key, and
every later request for that URL, anonymous included, is answered from the
cache without reaching the gate.

Worse, the request that poisons the cache is the ordinary one: an admin
opening the Trash tab fetches **every** trashed thumbnail through this route.
Trashing a file and then looking at the trash is enough to publish its
thumbnails on the CDN for a year.

**Fix:** when `get_servable_file/2` admits a trashed file, serve it
`private, no-store` (and do not redirect to a public bucket URL for it —
see the note). The simplest place is a trashed branch in `cache_mode/3`, or
a `put_resp_header("cache-control", "private, no-store")` right where
`trashed_if_authorized/2` returns `{:ok, file}`, carried through to the
header writers. A test should assert the header on the authorized response,
not only the 200/404 split.

*Note, same class:* on a **public** bucket `show/2` answers with a redirect
to the object's plain bucket URL, so a trashed file's bytes stay reachable
at that URL no matter what the route decides. That is the known limitation
the PR already lists for tiles, and the storage README lists for edits; it
belongs on the same follow-up.

### IMPROVEMENT - MEDIUM: two status-changing paths still broadcast nothing

The PR's premise is that every path that changes a file's trash state now
emits an event, and it names the folder sweeps as the ones that bypassed the
per-file functions. Two more do:

- `Reorganizer.restore_subtree_if_needed/1` (`reorganizer.ex:373`) —
  `update_all(set: [status: "active", trashed_at: nil])` over a restored
  folder's subtree. Open browsers keep hiding those files.
- `Storage.promote_out_of_subtree/3` (`storage.ex:~1512`) — during a
  permanent folder delete, a file with nowhere live to go is re-homed into
  a trashed folder and takes `status: "trashed"`. A browser showing it in
  the active view keeps showing it.

Both are rarer than the paths the PR covers (a reorganizer run; a permanent
delete that promotes a file into a trashed folder), but each leaves exactly
the stale card this PR set out to remove.

> **Fixed post-merge.** `promote_out_of_subtree/3` reports a file it trashes,
> and `delete_folder_completely/2` announces those as trashed; the
> reorganizer's subtree restore returns what it restored and announces it
> once the move's transaction has committed — never from inside it.

### IMPROVEMENT - MEDIUM: folder sweeps fan out one event per file

`trash_folder/2` / `restore_folder/2` broadcast once per affected file. A
folder of N files sends N messages to every subscribed LiveView, and each
`MediaBrowser` handles each one with a `send_update` that rewrites every list
it paints from (`remove_file_from_lists/2` walks `uploaded_files`, every
stack and every preview pile) and re-renders. For a folder of a few thousand
files that is a few thousand full list rewrites per open browser, in a burst.

A bulk event (`{:phoenix_kit_files_trashed, [uuid]}`) handled as one set
difference per list would keep the same semantics at one render.

> **Fixed post-merge** so: folder operations send one
> `{:phoenix_kit_files_trashed | _restored | _deleted, [uuid]}` each
> (`delete_folder_completely/2` included); single-file operations keep their
> per-file event. `MediaBrowser` handles a bulk event in one update, and
> `FeaturedImage`'s moduledoc example matches both shapes.

### IMPROVEMENT - MEDIUM: every trashed thumbnail costs two uncached permission queries

`authorize_trashed_read/1` builds `Scope.for_user(user)` per request, which
runs `Roles.get_user_role_records/1` and loads the user's permissions — both
plain queries, no cache. The file route's pipeline assigns the user but not
a scope, so nothing can be reused. A Trash tab of 50 thumbnails is 50 image
requests doing ~100 extra queries on top of the session lookup each already
does. Only trashed files pay it, so this is a Trash-tab cost rather than a
site-wide one; worth either assigning the scope in that pipeline or caching
the "media" answer per user for the request burst.

> **Fixed post-merge** the second way: `authorize_trashed_read/1` caches its
> answer for 5 seconds per user and active role (`:trashed_file_access`, a
> `PhoenixKit.Cache` started by the supervisor). The TTL bounds how long a
> revoked "media" keeps admitting trashed thumbnails. Without the cache
> running (update mode, a bare test) the answer is computed, never assumed.

### NITPICK: a removed card stays in the bulk selection

`remove_file_from_lists/2` drops the file from every painted list but not
from `selected_files`. With the file selected in one tab and restored (or
trashed) in another, the selection counter still counts it, and "Delete
selected" reports "2 item(s) permanently deleted" while deleting one — the
status guard skips the restored file correctly, so only the numbers are
wrong. Dropping the uuid from `selected_files` in the same helper fixes both.

> **Fixed post-merge** exactly so.

### Pre-existing, noticed in passing

`restore_folder/2` restores **every** file in the subtree, including files
that were trashed individually *after* the folder was — the reorganizer's
own copy of this logic fixed that by matching on the folder's `trashed_at`
(its comment calls it H1 and tracks the `Storage` side as a follow-up). This
PR edited that exact query to add `select:`, and now also broadcasts
`restored` for those files. Worth doing the `trashed_at` match while the
function is open.

> **Fixed post-merge.** `trash_folder/2` no longer re-stamps a row already in
> the trash, and `restore_folder/2` restores only the rows carrying the
> folder's own `trashed_at` — the reorganizer's rule, now `Storage`'s too. A
> file trashed on its own before or after the folder stays trashed, and a
> file that was never trashed is no longer announced as restored.
