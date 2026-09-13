# PR #804 — Make folder listings and folder actions link-aware in Storage and the Media browser

**Author:** mdon (`main`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge, security-focused)

## Verdict

The storage half is sound: every new write path either checks scope itself
(`move_file_between_folders/4` on the target, `move_file_to_folder/3` on both
ends) or refuses a folder that never held the file
(`remove_file_from_folder/2` → `{:error, :not_in_folder}`), and the 2026-09-12
tests cover the link/re-home/unlink matrix. The media-browser half replaced the
per-file gate "the file's **home** is in scope" with "the file **appears** in the
viewed folder" for every action at once. That is right for actions on the
appearance (trash from here, move from here, download) and **wrong for the
two actions that mutate the file record itself** — permanent deletion and
rotation — which reach every folder holding the file, the owner's included.
Both fixed here; nothing else needed changing.

## Summary of the PR

- `Storage.folder_contents_query/1`: a folder's listing is its home files plus
  the files linked into it (`FolderLink`), matching `count_folder_contents/1`.
- `move_file_between_folders/4`: a move from a folder acts on the appearance —
  a linked file has its link re-pointed, a homed file moves as before.
- `remove_file_from_folder/2`: trash from a folder unlinks a linked file,
  re-homes a homed file that another live folder links, trashes otherwise.
- `attach_file_to_folder/2`: the upload path links a content duplicate instead
  of moving its home out of the folder that owned it.
- `trash_folder/2`: re-homes files linked outside the subtree instead of
  trashing them (same rule `delete_folder_completely/2` already applied).
- `account_gate/1` halts with a `:warning` flash instead of `:error` (the
  flash component renders all three kinds; all six callers updated).

## Verified

- **Scope on the new storage functions.** `move_file_between_folders/4` checks
  `within_scope?(target)` for the link case and delegates the home case to
  `move_file_to_folder/3` (source and target checked). `attach_file_to_folder/2`
  and `remove_file_from_folder/2` have no scope arg by design; their only
  callers gate first (`within_scope?(folder_uuid, scope)` on upload,
  `removable_here?/3` in the browser).
- **`removable_here?/3` cannot be pointed at an arbitrary in-scope file.** In
  a folder view it requires the file to be homed in, or linked into, the
  viewed folder, and the viewed folder is scope-checked on navigation
  (`media_browser.ex:628`, `:1190`).
- **`folder_link/2` is a read**; `relink/3` runs in a transaction and rolls
  back if the target attach fails.
- **Flash kind.** `Core.Flash` accepts `:info | :warning | :error`; the
  `:warning` halt renders as `alert-warning`. `git grep` finds no remaining
  3-tuple `{:halt, message, target}` caller.
- **Merge into the active-role work** (`auth.ex` touched by both): clean
  merge, `mix compile --warnings-as-errors` and `gettext.extract
  --check-up-to-date` pass, the media-browser and storage scope suites pass
  (99 tests; the one failure is the pre-existing sidebar-toggle test from
  #803, unrelated).

## BUG - MEDIUM — permanent deletion from a folder's trash view no longer requires the file's home to be in scope

`handle_event("delete_file")` (`media_browser.ex:2102`) gated the permanent
branch on `removable_here?/3` only. A file whose home is in **another scope**
but which is linked into the viewed folder — exactly what the PR's own upload
path now creates for a content duplicate another user uploaded first — showed
up in this folder's trash once its owner trashed it, and "Delete permanently"
ran `Storage.delete_file_completely/1` on it: the owner's record and bytes,
gone, from a browser that only ever held a link. The bulk path
(`delete_selected`, `:1998`) still required `within_scope?(file.folder_uuid,
scope)`; the single-file path was the only one that dropped it.

**Fixed:** the permanent branch additionally requires
`Storage.within_scope?(file.folder_uuid, scope)`; a linked file in this
folder's trash falls through to `remove_file_from_folder/2`, i.e. it is
unlinked, which is what "remove from this folder" should mean for a file this
folder never owned.

## IMPROVEMENT - MEDIUM — rotation was gated on the appearance, not the home

`handle_event("rotate_file")` (`:2079`) writes `metadata.rotation` on the
file, so the rotation shows in every folder holding it, the owner's included.
Gating it on `removable_here?/3` let a browser rotate a file merely linked in
from outside its scope. **Fixed:** rotation requires the file's home in
scope, as before the PR.

## NITPICK

- **No component-level regression test.** Core's only in-suite MediaBrowser
  host (`/admin/media`) mounts unscoped, and `live_isolated/3` provides no
  router, so a scoped host would have to be built for the test. The
  storage-level scope guarantees are covered by `scope_test.exs`; the two
  browser gates above are covered by reading. Worth a scoped test host when
  the browser next changes.
- **Cross-scope links are created by content de-duplication** (pre-existing;
  #804 only changed *move* to *link*): a user uploading bytes identical to a
  file homed in another user's folder gets a link to that file in their own
  folder, and now sees it listed. That is the intended de-dup behaviour, but
  it is why the two gates above matter — the link is the only thing the
  second user should be able to act on.
