# PR #813 — Host-placed uploads: parent-folder convention, avatar/branding placement, media selector scope

**Author:** timujinne (`docs/folder-conventions-for-modules`) · **Merged:** 2026-09-15 · **Reviewed:** 2026-09-15 (post-merge)

## Verdict

The feature is sound and well tested for the happy path. One real crash path
(a stale hook answer) and one lifecycle problem (the hook ran in `mount`) were
fixed post-merge. The hook dispatch was deduplicated. Released in 2.23.2.

## Summary of the PR

- `PhoenixKit.UploadsParentFolder` — `config :phoenix_kit, :uploads_parent_folder,
  {Mod, :fun}` answers a parent folder for core's own uploads (`:avatar`,
  `:branding`). `place/4` attaches a stored file to it.
- `Auth.update_user_avatar/4` places the avatar; the user form and the two
  branding settings pages pass the answer to `MediaSelectorModal` as
  `scope_folder_id`.
- The standalone `/admin/media/selector` page accepts `?scope_folder=` and
  attaches uploads to it; `MediaSelectorHelper.media_selector_url/2` gains
  `:scope_folder`.
- `AnnotationComposer` places annotation attachments through
  `config :phoenix_kit_comments, :attachments_parent_folder`.
- Storage moduledoc documents the folder convention for module packages.

## Findings

### BUG - MEDIUM — A stale or malformed hook answer crashed the upload (fixed)

`resolve/3` accepted any binary. `Storage.attach_file_to_folder/2` writes a
root file's `folder_uuid` through a bare `Ecto.Changeset.change/2`, with no
`foreign_key_constraint`, so a uuid naming no folder raised
`Ecto.ConstraintError`, and a non-uuid string raised on dump. `place/4` had no
rescue. In `Auth.update_user_avatar/4` this fired after the file was stored and
before `avatar_file_uuid` was saved, so the caller crashed and the avatar was
lost. The same answer fed to `MediaSelectorModal` as `scope_folder_id` crashed
its upload consume. A trashed folder did not raise but silently received new
uploads (the standalone page already refused trashed folders; the hook did not).

**Fix:** `resolve_with/4` casts the answer and requires a live
(`trashed_at: nil`) folder, logging and falling back to the root otherwise.
`place` rescues around the attach, so placement never fails the upload.
The hook call also gained `catch :exit` (project rule for soft-failure paths:
a dead pool exits rather than raises). Tests cover non-uuid, missing folder,
trashed folder, exiting hook, and `update_user_avatar` with a stale answer.

### IMPROVEMENT - MEDIUM — Hook resolved in `mount` (fixed)

`Settings`, `Settings.Authorization` and `UserForm` resolved the hook in
`mount/3`: twice per page load (disconnected + connected), and on every view
of those pages even when nobody opens the selector. The convention the PR
documents has hosts lazily create their folder inside the hook, so viewing
the settings page created folders. Resolution now happens in the
`open_media_selector` handler. The modal is `:if`-rendered on the settings pages
and re-queries on every `show` update in the user form, so the scope arrives
with the open. A test asserts the hook is not consulted on mount.

### IMPROVEMENT - MEDIUM — Duplicated hook dispatch in `AnnotationComposer` (fixed)

`place_stored_file/3` copied `resolve/3`'s arity dispatch and re-fetched the
file with `Storage.get_file/1`, justified by a comment that "the consume
closure only has the uuid". `Storage.store_file/2` returns the `%File{}` in
both branches, so the re-fetch was redundant. It also silently dropped
attach errors. It now calls `UploadsParentFolder.place_with/5` with the
comments config key, inheriting validation and logging.

### IMPROVEMENT - MEDIUM — The hook also scopes browsing (documented, not changed)

`scope_folder_id` on `MediaSelectorModal` restricts **both** placement and the
browse query (`scope_files_by_folder/2`, folder subtree + links). So once a host
configures the hook, the logo/site-icon/background pickers only list files
under the branding folder, and the avatar picker only those under the avatar
folder. Existing logos at the root are no longer pickable, and a current avatar
living elsewhere is pre-selected but not shown. This may be the intent
("media selector scope"), and splitting placement from browsing would need a
new modal attr, so it is left as is. It is now stated in the
`UploadsParentFolder` moduledoc so a host knows before enabling the hook.

### NITPICK — Swallowed attach result on the standalone selector (fixed)

`MediaSelector.maybe_attach_to_scope_folder/2` discarded `{:error, _}`. It
now logs, matching the modal's `warn_on_folder_error/3`.

### NITPICK — Async test writing global app env (fixed)

`AnnotationComposerAttachmentsTest` was `async: true` while writing
`:phoenix_kit_comments` app env. Now `async: false`.

### NITPICK — Comment claimed a key phoenix_kit_comments does not read (fixed)

The composer said it used "the same config key as phoenix_kit_comments".
No branch of phoenix_kit_comments reads `:attachments_parent_folder`
(`git log --all -S`). The comment now points at the Storage moduledoc
convention instead.

### NITPICK — Actor semantics differ by call site (documented)

`UserForm` passes the admin as `actor_uuid` and the edited user as `subject`;
`Auth.update_user_avatar/4` passes the owner as both. Both are reasonable; the
moduledoc now says which is which.

### NITPICK — `data-scope-folder` on the modal root (left)

Added only so the test can observe the scope. Harmless in the admin DOM and
useful when debugging; left in place.

## Verified

- `parse_scope_folder/1` on the standalone page validates cast + live folder,
  and the undeclared param survives `UrlState` round-trips (tested).
- `MediaSelectorHelper` URL-building only appends a cast uuid.
- The six PR test files plus the new cases pass against a real database
  (34 tests, integration not excluded).
