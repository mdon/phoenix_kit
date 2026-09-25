# Storage libraries phase 2 (V203): recheck of Grok's review (2026-09-25)

Grok reviewed the 2.39.0 release candidate (V203 user libraries, private
serving, the profile tabs, #872, #863, #873). As with phase 1 it left its
fixes uncommitted and wrote no review notes. Claude read the whole diff,
checked each change against the code it touches, added one fix Grok's did not
cover, repaired a test #873 had left stale, and committed it all.

## Grok's findings, all confirmed

| Severity | Finding | Fix | Test |
|---|---|---|---|
| **BUG - HIGH** | A listing that named no library meant every library, private ones included. The orphan cleanup names none, and nothing in the site references a user library's files, so it would have queued them for deletion as unreferenced. They also showed on `/admin/media` and in host embeds. | `where_library(nil)` leaves private libraries out (`Libraries.exclude_private/1`); a user library is read by passing its uuid. `/admin/media` passes its system library explicitly. | `user_libraries_test.exs` "a user library's file is not site media and not an orphan" |
| **BUG - MEDIUM** | `/admin/media/:uuid` is gated by `media`, which opened any user-library file's detail page. | A private file's detail page needs `Libraries.can?(scope, file, :read)` (Owner/Admin and the library's members). | `user_libraries_ui_test.exs` "a media holder does not see or open another user's library" |
| **BUG - MEDIUM** | The media pickers (`MediaSelectorModal`, `/admin/media/selector`) listed user-library files. | `Libraries.exclude_private/1` on their queries. | same |
| **BUG - MEDIUM** | `get_public_url*` returned a public bucket's object URL for a private file: a permanent, unauthenticated link. | It returns the app's permanent token, which the file route refuses (fails closed); `authorized_url/4` is the way to show one. | `private_file_serving_test.exs` "a private file is not handed a bucket's object URL" |
| **BUG - MEDIUM** | A private file's deep-zoom tiles were `public, max-age=31536000, immutable`, so a shared cache could keep them long after the link expired. | `private, max-age=3600`, like `/file/...`. | "a private file's tiles are not kept by a shared cache" |
| **BUG - MEDIUM** | A viewer of a shared library could open its member list by sending `toggle_members`. | The event and the panel require the owner or a manager. | "a viewer cannot open the member list" |

## Added here

**BUG - HIGH: "Delete all orphaned" inside a user library.** Grok excluded
private libraries only when no library is named. Inside a user library the
browser names it, still offers the orphan view at the root, and every root
file there is "unreferenced", so one click deleted them all. Fixed in
`orphaned_files_query/0` itself: a private library's files are never orphans,
whatever library the caller names. Test: `user_libraries_test.exs` "inside a
user library nothing is an orphan".

**Stale test from #873.** `folder_tree_loading_test.exs` still asserted the
spinner's `hidden`/`inline-block` classes; #873 moved it to an opacity
cross-fade in a fixed box. The test failed on `main` before this recheck, and
now asserts what #873 renders.

## Changed at the maintainer's request

Orphan cleanup ("Move all orphaned to trash", `mix
phoenix_kit.cleanup_orphaned_files --delete`) moves files to the trash and
never deletes them (`DeleteOrphanedFileJob` calls `Storage.trash_file/1`;
the name is kept so jobs queued before the upgrade still run). Test:
`orphan_cleanup_trash_test.exs`.

## Not changed, noted

- An Owner/Admin opening a user-library file's detail page at
  `/admin/media/:uuid` is not audit-logged. Only opening the library at
  `/admin/libraries/<uuid>` is. Reaching the detail page needs the file's
  uuid.
- `/admin/media` now always names its library, so the browser's
  cross-library event guard runs there on every event: two small indexed
  queries per event.

## Gate

`mix precommit` clean; the full suite against the real database and
`mix prerelease` were rerun before publishing.
