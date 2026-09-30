# Media that shows each viewer only what is theirs

Status: built, 2026-09-30 (see "As built" at the end). Builds on `2026-09-22-storage-libraries.md` (V202–V206).
Decided with the maintainer the same day; the work order at the bottom is what is built.

## 1. The idea

There is one Media page, one browser, one library switcher. **What it shows depends on
who is looking.** If an app needs to give an end user access to Media, it grants the
`media` permission and Media shows that user their own stuff, never anyone else's.
Photos (the friendlier layer being built on top of Media) will sit on the same rules.

Today that is not true, and two things stand in the way:

1. **Media shows a whole library to any `media` holder.** The grid is not filtered by
   viewer: a holder who is not an admin sees every file of a site library, whoever
   uploaded it. The only per-viewer rule is `own_files_only`, which restricts *writes*
   for library contributors, not what is listed.
2. **`media` is also the key to the storage admin screens.** `@admin_view_permissions`
   maps Settings → Media (buckets, sizes, health) to `"media"`. Handing an end user
   `media` today hands them the bucket form and its credentials pickers.

User libraries also live on a second page (`/admin/libraries`) with its own sidebar
entry, because Media could not be trusted to keep them apart. Once Media filters by
viewer, that reason is gone.

## 2. The model

A viewer is one of three kinds, decided by the permissions they hold:

| Viewer | Holds | Media shows |
|---|---|---|
| **Everything** | Owner, Admin, or `media` + `media.view_all` | Every file of every site library. Another user's library is never listed: an Owner/Admin opens one from the admin metadata list, audited (unchanged). |
| **Own stuff** | `media` without `media.view_all` | In a site library: files they uploaded, the folders they created, the folders holding their files, and those folders' ancestors (so the path reads). In their own and shared user libraries: what their role allows (unchanged). |
| **Libraries only** | `storage`, no `media` | No site libraries. Their own and shared user libraries, in the same page. |

Everything else in the browser follows from the kind: counts, search, previews, trash,
orphans, downloads, the file detail page.

### New permissions (sub-permissions of the core `media` section)

- `media.view_all` — see other people's files in the site's libraries.
- `media.manage` — the storage administration screens (Settings → Media: buckets, sizes,
  profiles, health) and the site-wide actions (empty the trash, delete every orphan).

**Upgrade is invisible.** On the first boot after upgrading, every role that holds
`media` is granted both (once, flagged like the other auto-grants, so a later revocation
sticks). Roles created afterwards get neither by default. Core sections have no
sub-permissions today (they come from modules' `permission_metadata/0`), so
`Permissions` learns a small `@core_sub_permissions` map merged into the registry's.

### Folders for the "own stuff" viewer

A folder is visible when the viewer created it, **or** it is the home of one of their
files, **or** it is an ancestor of either. Everything else is absent, not greyed out.
The cost is that an ancestor's *name* is visible (a path like `Events / 2026`), which is
the same exposure a breadcrumb has anywhere. File counts, cover previews and "N files"
figures on a visible folder count only what the viewer may see.

## 3. Where the filter goes

One option, `:viewer_uuid`, added next to `:library_uuid` in the same places and carried
by the same helper (`lib_opts/1` in the browser). `nil` means unrestricted, which is
every existing caller, so nothing changes for them (Photos, pickers, modules).

**Storage functions** (each already takes `opts` and already calls `where_library/2`):
`list_files_in_scope/2`, `count_orphaned_files`, `list_trashed_files`/`count_trashed_files`,
`list_trashed_folders`/`count_trashed_folders`, `list_folders/3` (all three clauses),
`list_folder_tree/2`, `search_folders/4`, the folder cover-preview listing, plus one new
`Storage.viewer_folder_uuids/2` (a recursive CTE: created ∪ homes ∪ ancestors).

**Browser events.** The browser is driven by events that arrive with uuids from the
client. The existing `own_files_only` guard already refuses a *write* that names someone
else's file. It grows a second half: for a restricted viewer, any event that names a file
(open the viewer, select, download, detail) or a folder is refused unless the file is
theirs (or the folder is visible to them), and the site-wide actions (`empty_trash`,
`delete_all_orphaned`) need `media.manage`.

**Outside the browser** (and the same guard, by another door: a `?file=<uuid>` link that
missed the loaded listing used to open any file, of any library, in the viewer; it now opens
only a file of the library shown that the viewer may see).

**Outside the browser.** `MediaDetail` (same rule as the browser), the trashed-file
branch of `FileController` (today "any `media` holder", becomes "uploader, Owner/Admin or
`media.view_all`"), and `Libraries.can?/3` (`media` alone stays write-only for `:edit`).
Site library files stay publicly served by URL, as now: they are site assets.

## 4. One page

- `/admin/media` (site libraries, as now) and `/admin/media/my/<slug or uuid>` (the
  viewer's own and shared user libraries) are served by the same LiveView and the same
  switcher, grouped "Site" and "Mine". A separate path segment avoids a slug clash between
  a site library and someone's own.
- The page opens for `media`. A user library appears in the switcher when user libraries
  are on and the viewer also holds `storage` (which is what creating and sharing need).
- `/admin/libraries` stays, but only as the entry for people who hold `storage` without
  `media`, and for an Owner/Admin's audited list of other people's libraries. For any other
  holder of `media` it redirects into Media (old links and bookmarks keep working), and the
  sidebar's "Libraries" entry is shown only to those who do not have Media.
  *(Changed from the first draft, which retired it entirely: the permission gate resolves one
  key per view, and letting one page open for either of two keys meant changing the auth core
  for little gain.)*
- The profile's Media tab keeps creating and managing libraries; each library has an "Open"
  link to wherever its holder browses.
- Settings → Media → Libraries (the admin's metadata list) is unchanged.

## 5. Decided, and what I took as the default

Decided by the maintainer: Media is smart and shows each viewer only their own; Photos
builds on it; an app gives `media` when it needs Media.

Taken as defaults (say if you want any of them changed):

- `media.view_all` is auto-granted to existing `media` holders, so upgrading changes nothing.
- `media.manage` is a separate key, also auto-granted to existing holders; it is what keeps
  end users with `media` away from the bucket screens.
- Folder visibility is created ∪ homes ∪ ancestors (above).
- **Media pickers** (`MediaSelectorModal`, the featured-image picker and the modules that
  embed them) are **not** filtered in this change. They are used by editors authoring site
  content, most of whom hold no `media` at all and must keep seeing site media. Giving them
  the viewer rule needs its own decision (an opt-in `viewer` on the picker), so it is out of
  scope here and listed in §7.
- A restricted viewer's trash is their own files' trash; orphans (files in no folder) are
  likewise only theirs. They may empty their own trash and clear their own orphans (scoped by
  the viewer filter), so `media.manage` does not gate those, only the storage screens.
- A restricted viewer changes only folders they created (rename, colour, header, trash,
  delete, move), although they may see and upload into a folder that merely holds their files.

## 6. Risks, and how each is closed

| Risk | Closed by |
|---|---|
| A listing path is missed and leaks | The option is added at every `where_library/2` site (an inventory, §3), and a leak test per path: grid, search, folder tree, counts, trash, orphans, folder previews, a deep link, a shared link. |
| An event names someone else's file | The guard is generic over the event's params, not a list of event names; a test sends crafted events for each file-naming event. |
| Existing editors lose access | The one-time backfill; a test that a role holding `media` before the upgrade still sees everything after it. |
| End users reach the bucket screens | `media.manage` on those views; a test that `media` alone opens Media and not Settings → Media. |
| Photos or a module calls the browser and changes | `viewer_uuid` defaults to nil (unrestricted); nothing passes it but the Media page. |

## 7. Out of scope (recorded)

- Filtering the media pickers (§5).
- Per-folder sharing between users of a site library.
- Quotas (V207).

## 8. Work order

1. [x] **Permissions.** `@core_sub_permissions` (`media.view_all`, `media.manage`) merged
   into the sub-permission registry reads; one-time backfill to existing `media` holders;
   map the storage admin views to `media.manage`; tests incl. the upgrade case.
2. [x] **Storage.** `:viewer_uuid` through the listed functions, `viewer_folder_uuids/2`,
   `Storage.viewer_can_see_file?/2`; leak tests at the data layer.
3. [x] **Browser.** `viewer_uuid` assign + `lib_opts`; the guard's read half; site-wide
   actions behind `media.manage`; previews and counts; event tests.
4. [x] **Media page.** Load user libraries into the switcher, `/admin/media/my/…`, gate on
   `media` or `storage`, viewer kind from the scope; `MediaDetail` and `FileController`.
5. [x] **Narrow `/admin/libraries`.** Redirects for media holders, the sidebar rule, links from the profile tab.
6. [ ] **Docs, changelog, translations, precommit, full suite.**

## 9. As built

- `media.view_all` / `media.manage` are sub-permissions of the core `media` section
  (`Permissions` `@core_sub_permissions`), shown in the permissions matrix under Media, and
  backfilled once at boot to every role that held `media` (flag `media_sub_permissions_backfilled`).
  The test helper gives the Admin role both, as the boot sweep does in production.
- `Storage` `:viewer_uuid` on the file and folder listings, the tree, search, counts, trash and
  orphans (`viewer_folder_uuids/2`: created ∪ homes ∪ ancestors), plus `viewer_can_see_file?/2`
  and `viewer_can_see_folder?/3`.
- `MediaBrowser`: `viewer_uuid` assign (in `lib_opts/1`, so every read carries it), a first
  `handle_event` clause that refuses an event naming another's file or an invisible folder or
  changing a folder the viewer did not create, the `own_files_only` guard (the Media page sets
  it to the viewer for a site library) with empty-trash and orphan-clearing allowed because they
  are scoped, folder cover previews scoped, and the `?file=` deep link gated by library and viewer.
- `Libraries.can?/3` `:edit` on a site file needs `media.view_all` for a holder of `media`;
  `FileController.authorize_trashed_read/2` (new, per file) and `MediaDetail` follow the rule.
- Not done, as planned: the media pickers, per-folder sharing.
