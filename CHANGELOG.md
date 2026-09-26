## 2.41.0 - 2026-09-26

Storage profiles, variant sets and the reconciler (**V205**, phase 4 of
`dev_docs/plans/2026-09-22-storage-libraries.md`). Each library now says
where its files are kept and which sizes its uploads get. Nothing changes
for an install that never touches them: every library starts on the
seeded **Default** profile and variant set, built from the existing
buckets and settings.

### Upgrading

- Run `mix phoenix_kit.update` (migration **V205**). It adds the new
  tables and columns and seeds the Defaults; it copies, moves and resizes
  nothing. Files that were already under-replicated are marked for the
  reconciler, which then makes their missing copies by itself, throttled,
  on the `file_processing` queue. **Settings → Media → Health** shows what
  is left.
- Every bucket joins the Default profile, in today's read order (local
  first, then by priority). A disabled bucket stays disabled: `enabled` is
  still the emergency stop.
- The **Sync All** button on the Health page is gone; the reconciler does
  that work. A sync already queued before the upgrade just queues the
  reconciler.

### Added

- **Storage profiles: where a library's files are kept.** A profile lists
  buckets and gives each a role (primary is written and served, replica is
  served when no primary has the copy, backup is written but never
  served), what it stores (everything, originals only, or sizes and tiles
  only), a fixed write priority or the random pool, a serve order, and a
  status (read-only serves but gets no new files; draining has its files
  moved off). It also says how many copies an original and a derived file
  get, and how many copies an upload needs to succeed. Settings → Media →
  **Storage profiles**; a system library picks its profile on the
  Libraries tab.
- **Variant sets: which sizes a library's uploads get.** A set has its own
  sizes (names are unique per set, not site-wide) and says whether sizes
  and zoomable tiles are made. Every set has the standard sizes
  (thumbnail, small, medium, large, video_thumbnail), which cannot be
  deleted or renamed; small, medium and large keep the aspect ratio. The
  dimensions page is now **Variant sets**, a tab per set. A user may pick,
  for a library they own, a set an admin marked selectable.
- **The reconciler** (`Storage.Workers.ReconcileJob`) moves files to where
  their library's profile wants them, copying first and removing a copy
  only once the copies that stay are checked to be really there (never the
  last one); it deletes an object from a bucket only when nothing else
  there still needs it. It also makes missing sizes, remakes sizes whose
  spec changed, and removes sizes a set no longer has; a thumbnail with an
  annotation burned into it is never made over. It runs by itself,
  throttled, after any change and daily; a file it cannot finish is tried
  again ten minutes later. The **Health** page lists the files still
  waiting and can queue a pass.
- **A missing size is no longer served as the full original.** Until a
  size that is being made exists, the nearest smaller size the file has
  stands in, else a placeholder; neither is cached. A size that will not
  be made (the set makes none, the size is disabled) still serves the
  original, as before.
- `Storage.variant_for(file, min_width: 300, aspect: :preserve)` picks a
  size by purpose against the file's own set.
- `mix phoenix_kit.doctor` warns about a variant set missing a standard
  size.

### Changed

- **Variants and tiles are placed by the library's profile** as derived
  files, rather than onto exactly the original's buckets.
- `storage_redundancy_copies`, `storage_auto_generate_variants` and
  `storage_tile_generation_enabled` are now the Default profile's and the
  Default variant set's (`Storage.redundancy_copies/0`,
  `get_auto_generate_variants/0`, `tile_generation_enabled?/0` and their
  setters); the rows are kept in step for code that still reads them. The
  Configuration tab labels its three controls accordingly.
- A cross-user copy reuses another file's stored bytes only when both
  libraries use the same profile and variant set.
- Deleting an empty bucket takes it out of every storage profile; a new
  bucket joins the Default profile, as it joined the pool before.
- An upload whose write fails on one bucket tries the next eligible one
  before giving up a copy.

### Fixed

- **Dragging a file onto a folder no longer shows it in both.** A file
  attached somewhere (a featured image, a gallery) is linked as well as
  homed. Moving it used to re-point the link and leave the home, so the
  file appeared in the folder it was dropped on and the one it came from.
  A folder now holds a file once, as its home or through a link.
- **Trash can be left.** Restore is on the file menu, the row menu, the
  folder menu and the bulk bar. Dragging a trashed file into a folder
  restores it there. Restoring a file whose folder is also trashed puts
  it in the nearest folder that is still there, or at the root, instead
  of an active file inside a trashed folder where nothing lists it.
- **A failed upload no longer deletes bytes another file uses.** Keys are
  content-addressed, so a second upload of the same bytes writes the same
  key; undoing a failed one now happens under the key's lock and only when
  nothing else references the key or is still writing it.
- **Bucket usage counts small files.** Each file was rounded down to whole
  megabytes before summing, so files under 1 MB counted as nothing and a
  bucket's `max_size_mb` never tripped; a key shared by cross-user copies
  is now counted once.

### Removed

- **The Health page's manual sync** (progress bar, pause, stop): the
  reconciler does it. `SyncFilesJob` only queues the reconciler, for jobs
  already queued, and goes in the next release.
  `Storage.get_health_report/1` and `sync_under_replicated/1,3` are gone.

## 2.40.1 - 2026-09-25

### Fixed

- **`Storage.list_files(bucket_uuid: …)` no longer raises.** It filtered on
  a column files never had; it now lists the files with a copy in that
  bucket.
- **A bucket with a custom S3 endpoint (Backblaze B2, MinIO, Wasabi,
  Tigris) gets working public URLs.** `public_url` built an amazonaws.com
  address whatever the endpoint was. It now points at the endpoint, in the
  style its requests use: virtual-host (`bucket.host/key`) for Tigris, which
  refuses path style for newer buckets, path style for the rest. An endpoint
  may be typed with a scheme or a port (`http://minio.local:9000`), and an
  IPv6 one is bracketed. An endpoint that cannot be used (another scheme, a
  path, a zone id) is a form error, and never quietly falls back to AWS.
- **A public Cloudflare R2 bucket without a public domain is proxied.** Its
  S3 API host does not answer anonymous reads, so it has no public URL;
  set the bucket's CDN URL to its r2.dev or custom domain for direct links.
- **A bucket set to "signed" access is served by presigned URLs.** It used
  to fall through to a public redirect, and the bucket form could not even
  choose it: it now offers **Signed (short-lived link)**, so saving a
  signed bucket no longer turns it public. Each request gets a 5-minute
  signed URL (proxied when the provider cannot sign, or for an IPv6
  endpoint), and neither a private nor a signed bucket hands out a plain
  object URL.

### Changed

- **Page descriptions in the admin header are off by default (#875).** The
  one line a page could put after its title (and under the in-page title)
  is shown only when **Show page descriptions in the admin header** is on,
  under Settings → General. The breadcrumb and the title already say where
  you are. How a page builds its header trail is written down in
  `dev_docs/guides/2026-09-25-admin-header-trail.md`.

### Removed

- **The "Default Bucket" card on Settings → Media**, which always said
  "None": bucket selection never read that setting. Storage profiles (next
  phase of the storage plan) replace the idea.

## 2.40.0 - 2026-09-25

### Added

- **`PhoenixKit.Migrations.Adoption`** (#868, refs #862). A public,
  stability-committed API for module migration chains that adopt a
  core-baseline table. `verify_shape/3` checks the table's real shape
  (column type/nullability/default, indexes, constraints, sequences,
  functions) before the module writes its ownership marker, and reports
  every drifted or missing object in one pass; `format_drift/1` renders
  that report. `marker_conflict/5` refuses to overwrite another module's
  marker or an operator's own table comment, while treating core's
  pre-squash descriptive comments as safe to overwrite. It never writes
  anything. Recommended use (raise on drift by default, or log and adopt
  under an explicit per-host `:warn` opt-in) is in the moduledoc and the
  module table extraction guide.

### Changed

- **A user library's contributor changes only the files they uploaded.**
  The media browser refuses their change to anyone else's file, a folder
  trash, delete or move whose subtree holds one, a bulk action on a
  selection holding either, and emptying the trash; folder names and looks
  stay shared. Before, the browser had no per-file check.
- **A trashed user library can be restored** by its owner until it is
  purged, from a Trash section on the profile's Media tab
  (`Libraries.restore_library/2`). It gets a URL slug again, counts toward
  the per-user limit, and is refused while a live library has its name.
- **An Owner or Admin opening a user-library file's detail page** at
  `/admin/media/:uuid` is written to the audit log
  (`storage.library_opened`), like opening the library itself.
- **`phoenix_kit_templates` 0.2.0** (pin `~> 0.1.0` → `~> 0.2.0`). A host
  override's `html` part now HTML-escapes a bound `{{variable}}`; a variable
  that already holds markup must use `{{{variable}}}`. Core's own defaults are
  text-only, so core's messages don't change. Database templates keep their
  own `{{var}}` substitution. Check any hand-written or exported `html.html`
  override that uses `{{line_items_html}}` (or another markup variable).
- Dependency updates: `phoenix_live_reload` 1.7.0 (dev; pin `~> 1.6.1` →
  `~> 1.7`), `mdex` 0.14.0, `hackney` 4.8.1, `lazy_html` 0.1.13 (test).
- **Storage reads follow where a file actually is (V204, location-truth).**
  Reading, serving and checking a stored object go first to the buckets its
  location rows name, local first, then by priority. Only when none has it
  are the other enabled buckets tried, and a bucket found to hold it that
  way is recorded. Every writer now records where it stored: Tessera tiles
  and comment attachments did not. A variant is written to exactly the
  buckets its original is in; before, that list was capped at the
  redundancy setting and reordered.
- **Files stored before location-truth are located in the background.**
  `Storage.Workers.LocationBackfillJob` checks each enabled bucket once for
  every stored object not checked yet, records every bucket that has it,
  and remembers the check, a miss included (a new
  `phoenix_kit_file_location_checks` table), so a missing object is not
  asked about on every request. It queues itself shortly after boot and
  from the daily trash prune while any are left, runs one batch every few
  seconds, and Settings → Media → Health shows how many are left. Those
  files are served meanwhile.
- **One checksum for every upload path.** The upload API hashed files with
  MD5 while everything else used SHA-256, so the same file uploaded both
  ways was stored twice. It uses SHA-256 now, and
  `Storage.Workers.ChecksumBackfillJob` (queued like the location
  backfill) recomputes the MD5 checksums already stored from each file's
  bytes. A file whose uploader already has the same bytes is left as it is.
- **A bucket that still holds files cannot be deleted.** Deleting one used
  to drop its location rows silently and leave its objects behind. The
  settings page says to disable the bucket instead.
- **Bucket changes apply at once.** Adding, editing or removing a bucket
  used to take up to five minutes to reach file serving (a cache).

### Fixed

- **The media viewer lays itself out by the window's shape, not its width
  (#874).** A tall window that happened to be wide (a portrait monitor, a
  half-screen split) kept the side-by-side split and squeezed a landscape
  picture into a narrow column: at 1100×1500 the picture got 688×318 before,
  1031×477 now. A portrait window gets the stacked layout, with the picture
  pane sized to the picture and the popup hugging the two.

### Migration notes

- **V204** removes duplicate `phoenix_kit_file_locations` rows (keeping the
  oldest of each instance and bucket), adds a unique index on that pair and
  an index on `path`, and moves the location's bucket FK from
  `ON DELETE CASCADE` to `RESTRICT`. It adds
  `phoenix_kit_file_location_checks` and marks every instance that already
  has a location row as checked, so only the rest are probed.

## 2.39.0 - 2026-09-25

### Added

- **Storage libraries, phase 2 (migration V203): user libraries.** When an
  install turns them on (`storage_user_libraries_enabled`, off by default),
  a user with the `storage` permission uses the libraries they own or are
  a member of, and one with the new `storage.create_library` sub-permission
  creates them, up to `storage_user_library_limit` (default 10). A user
  library is private and has members: manager, contributor or viewer. The
  first one a user creates is their default. Trashing one frees its name
  at once; its files are purged, bytes included, after the trash retention
  period. New API on `Storage.Libraries`: `create_user_library/2`,
  `list_user_libraries/1`, `get_user_library/2`, members
  (`add_member/4`, `update_member_role/4`, `remove_member/3`),
  `trash_library/2`, `set_default_library/2`, `allows?/2`.
- **Where user libraries are managed and used.** Settings → Media →
  Libraries gains a **User libraries** card: turn them on, set how many
  each user may own and how long a private link lasts, and see every user
  library as metadata (owner, members, files, size, trash). Users manage
  their libraries and members on a new **Media** tab of their profile
  settings (`/profile/settings/media`). `/admin/libraries` lists and
  browses them, for holders of `storage`. It is meant for moderation and
  testing; `phoenix_kit_photos` is the end-user surface. An Owner or Admin
  also sees every other user's library there, below their own, and may open
  any of them; every opening is written to the audit log
  (`storage.library_opened`).
- **Private serving for user libraries.** A file in a private library is
  served only with a time-window token: an HMAC over the file, the variant
  and an expiry rounded up to a window (`storage_private_url_window_hours`,
  default 12), so a URL stays the same, and cacheable in the browser,
  within its window. Its permanent token is refused, an expired one is a
  403, a public bucket is proxied instead of redirected to, and the
  response is `private` (never kept by a shared cache). Core's media pages
  mint these URLs themselves; a module showing a user library's file calls
  the new `Storage.authorized_url/4`, which checks access first. Files in
  Media are served exactly as before.
- **Dedup is per library.** The same person may keep the same file in
  Media and in a library of their own; within one library it is still
  stored once. Files in Media keep the key they had.

### Changed

- **Orphan cleanup moves files to the trash instead of deleting them.**
  The media page's button is now **Move all orphaned to trash**, and
  `mix phoenix_kit.cleanup_orphaned_files --delete` does the same. An
  orphan is only a guess (nothing known references the file), so it can be
  restored from the trash until the daily prune deletes it after
  `trash_retention_days`.
- **Deleting a user no longer deletes the files they uploaded.** Their
  uploads in the site's libraries and in other people's stay, with no
  uploader. The libraries they own are trashed and purged. Before, the
  file rows went with the user and their bytes were left behind in the
  buckets. Deleting a user who had ever created a media folder no longer
  fails either.

- **Profile settings are split into tabs, one URL per tab:**
  `/profile/settings/account`, `/security`, `/sessions`, `/notifications`
  and `/integrations`. A tab shows only when it has something for the
  user; the bare `/profile/settings` opens Account. Personal integrations,
  until now the last section of one long page, are their own tab for
  holders of the `integrations` permission. Embedding the `UserSettings`
  component is unchanged.

### Fixed

- **A downloaded copy is named for what it is (#872).** Downloading three
  sizes of one picture used to save `photo.jpg`, `photo (1).jpg` and
  `photo (2).jpg`. Now each gets its own name, with the extension of the
  stored bytes: `photo-original.jpg`, `photo-large.jpg`,
  `photo-large-annotated.jpg`, and so on (`Storage.download_name/3`). The
  details page's download links add `?dl=1`, which makes the response an
  `attachment`, also when a bucket answers for it, so the click saves the
  file instead of opening it in a tab. Its list shows the picture's sizes
  and the annotated copies in separate groups, with every other variant
  after the standard sizes (review fix). A download link whose image was
  edited in the meantime stays a download (review fix).
- **A locale redirect can no longer turn a request into a 500 (#863).**
  The locale plug's redirect target is now checked whole, with Phoenix's
  own rules, and a segment it builds must be letters, digits, `-` or `_`.
  Before, an address like `/%2509-x/…` or `/zz/%09evil/shop` made the
  redirect raise. A target that fails the check renders in the default
  language instead.
- **The media folder tree no longer shifts on every click (#873).** The
  loading spinner sits in the icon's own box, shows only when a reply takes
  longer than 300 ms, and the tree and the file column keep their scrollbar
  space, so nothing jumps when a folder opens.
- **A user library stays out of the site's media (review).** `/admin/media`
  and the media pickers no longer list a user library's files, and the file
  detail page uses the same read check as the file info API, so holding
  `media` is not enough to open one. `get_public_url` no longer returns a
  public bucket's object URL for a private file. Deep-zoom tiles of a
  private file are cached `private`, the same as the file itself, so a
  shared cache cannot keep them after the link expires. Orphan cleanup
  leaves a user library's files alone, and so does "Delete all orphaned"
  inside a user library: nothing in the site references them, so they
  looked unreferenced and would have been deleted. A viewer of a shared
  library can no longer open its member list by sending the event.

### Migration notes

- **V203** adds `phoenix_kit_storage_library_members` and replaces five
  constraints in place: the uploader FK on `phoenix_kit_files` and the
  creator FK on `phoenix_kit_media_folders` become `ON DELETE SET NULL`,
  the files CHECK accepts a file with a library, and the library owner FK
  becomes `SET NULL` with a check that lets only a trashed user library
  lose its owner. Each is added `NOT VALID` and validated in its own
  statement, so the scans do not block writes. It also repeats V202's slug
  statements, which a database that ran an early build of V202 needs
  (#871); elsewhere they change nothing.

## 2.38.1 - 2026-09-24

### Added

- **`<.decimal_input bare>` (#867)** renders the control alone, with no
  wrapper, label, unit suffix, error list or full width, for a host that
  places it in a group of its own (a daisyUI `join` with a unit button, a
  table cell). It keeps the text and decimal keyboard, no autofill, the
  zero-clearing handlers and `input-error`. A `label` given to a bare
  control becomes its `aria-label`, unless the host passes one.

## 2.38.0 - 2026-09-23

### Added

- **Shared toolkits for modules (#860).** `PhoenixKit.Activity.log/3` (a
  module key, an action and options; it never raises) and
  `PhoenixKitWeb.Actor` (who is acting: the scope first, then the current
  user). `PhoenixKitWeb.Components.TreePicker` with `Utils.Tree` and
  `Utils.TreeQuery`. Per-record media folders (`Storage.ResourceFolders`,
  and the reorganizer's `ResourceSource`). The upload toolkit
  `PhoenixKitWeb.Attachments`. Per-user table columns (`Users.ViewPrefs`,
  `PhoenixKitWeb.TableColumns`). Modules that call `Activity.log/3` or
  `Actor` must feature-detect them while they keep the open `~> 2.0` core
  pin.
- **Migration V201:** `phoenix_kit_user_view_prefs`, one row per user and
  view.
- Edit forms can open on the language the page is being viewed in
  (`open_on: :viewing_language`).
- **Storage libraries, phase 1 (migration V202).** Every file, media
  folder and folder link now belongs to a library, and everything that
  exists is in one system library, Media. A writer that names no library,
  in core or in a module, keeps landing in Media, so nothing changes until
  a second library is created. Libraries are managed in a new **Settings →
  Media → Libraries** tab: create, rename and delete an empty one, with
  each library's file and folder counts and size. The Media page shows a
  library switcher only once there are two or more; with one, it says
  nothing about libraries. Media stays at `/admin/media`, and every other library gets a URL
  named after it (`/admin/media/library/brand-assets`). Each library keeps
  its own folders, and folder names are unique per
  library. New files in a library are stored under its own object-key
  prefix. Files and folders cannot cross from one library to another. New
  API: `PhoenixKit.Modules.Storage.Libraries`, a `library_uuid:` option on
  `Storage.store_file_in_buckets/7`, and a `library_uuid:` filter on the
  root-level listing, search, orphan and trash functions (`empty_trash/2`
  included). Plan: `dev_docs/plans/2026-09-22-storage-libraries.md`.

### Changed

- **fresco 0.13 (#866)**, with etcher 0.17.1 and tessera 0.3.8. On a mouse
  or in Firefox, the scroll wheel now zooms and pans the image viewer at the
  intended speed. On 0.12 it barely moved.

- **The column settings on the Users and website-access tables are saved
  per user (#860).** The old site-wide `user_table_columns` /
  `website_access_attempt_columns` values become the starting default for
  everyone. No screen edits them any more; delete those two settings rows
  to go back to the built-in columns. Modules that kept per-user columns in
  `custom_fields` move their own data when they adopt `TableColumns`.
- **A stored file is shown in place only if it is an image, video, audio,
  PDF or plain text (#860).** Everything else downloads, and every response
  carries `nosniff`. On a public bucket such a download is a one-hour
  signed bucket URL that makes the bucket answer `attachment` (#860
  review). The bytes still come from the bucket, not the app, but these
  downloads skip `cdn_url`. Media is unchanged.

### Fixed

- **The media page no longer takes seconds to load, or to open a folder,
  on sites with many catalogue items (#864).** The orphan count checked
  every file against every catalogue row with a JSON containment test.
  It now expands `media_order` and matches by equality: 8 s → 0.15 s on a
  live shop. While a folder click waits, the sidebar icon shows a spinner.
- **Rubbing out the last shape on an annotated image now updates its
  burned copy (#865).** Before, the burned copy kept the markup that had
  been erased. Closing the editor no longer burns and uploads the same
  drawing twice. A viewer open on the same picture elsewhere now switches
  to a new burned copy when one is stored, but not while its own editor
  is open.
- **Folder moves, trash and uploads (#860):**
  - Two concurrent moves can no longer commit a folder cycle, and a move
    can no longer deadlock with the reorganizer.
  - Trashing a folder is consistent with a concurrent move.
  - A re-uploaded trashed file no longer returns to the folder it was
    removed from.
- **Removing a file from a folder no longer crashes when a linked folder
  is trashed at the same moment (#860 review),** and the "file trashed"
  event now fires after the change commits.
- **`ResourceFolders.purge_named/1` refuses a folder name with no uuid in
  it (#860 review),** instead of deleting every folder with that name.
- **The upload summary in the media browser shows again.** The "N files
  uploaded" message was set on the browser component, where the page never
  displayed it. Uploading, into a second library, a file you already have in
  another one now says so instead of reporting a missing storage bucket.
- **A file name with a quote, a line break or non-ASCII characters no
  longer breaks the download header (#860 review).** A line break used to
  cause a 500.

### Migration notes

- **V202** adds `phoenix_kit_storage_libraries` and a NOT NULL
  `library_uuid` on `phoenix_kit_files`, `phoenix_kit_media_folders` and
  `phoenix_kit_media_folder_links`. The column's default is Media's fixed
  uuid (`00000000-0000-7000-8000-000000000001`), so existing rows are not
  rewritten. Validating the NOT NULL and the foreign keys scans each table
  once, without blocking writes. The three new indexes on
  `phoenix_kit_files` are plain builds, so uploads wait while they build;
  on a very large media table, run the update in a quiet window.

- A database that ran an unreleased build of V202 (a git dependency on
  `main` before the library URL slugs landed) has no
  `phoenix_kit_storage_libraries.slug` column. Set its marker back with
  `COMMENT ON TABLE phoenix_kit IS '201'` and run the update: V202 is
  re-runnable, adds the column and gives existing libraries their slugs.

- A database that ran an early build of the #860 branch, when its
  migration was numbered V200, reads as version 200 without the
  capture-date columns. Set its marker back with
  `COMMENT ON TABLE phoenix_kit IS '199'` and let V200 and V201 run.

## 2.37.5 - 2026-09-23

### Fixed

- **A non-ASCII first path segment no longer loops the browser forever
  (#861, fixes #849).** `/дордол` and similar URLs got a redirect back to
  the same URL: the locale redirects searched the percent-encoded request
  path for the decoded locale, found nothing, and redirected to the path
  unchanged. All three locale redirects (invalid locale, full dialect →
  base, default locale → clean URL) now swap the segment right after the
  mount prefix, never redirect to an unchanged path, and keep the query
  string. A crafted dialect segment that would build an unsafe target
  (`//evil.com-x`, a backslash, a control character) now renders under the
  default locale instead of raising a 500.
- **A dialect URL that can't be redirected keeps its language only if that
  language is enabled (#861 review).** Such a request rendered under any
  base the URL named, including an unknown `zz` or a disabled `fr`. It now
  keeps the base only if it is a predefined, enabled language, the same
  rule a bare `/fr/...` URL follows, and otherwise uses the default.

## 2.37.4 - 2026-09-22

### Changed

- **A zero in `<.decimal_input>` clears itself on focus (#859).** A field
  showing `0` (or `0,00`, `0.0`) empties when it gains focus, so typing `1`
  gives `1` rather than `10`. Leaving it empty puts the zero back; typed
  text stays. A host's own `onfocus`/`onblur`/`onkeydown` are chained after
  the component's inline handlers, not dropped.

### Fixed

- **The cleared zero survives LiveView patches (#859 review).** It was
  parked in a `data-` attribute, which LiveView strips from a focused input
  on every re-render, so a `phx-focus` handler or any update during focus
  left the field empty for good. It now lives in an element property.
- **Enter in a just-cleared zero field submits the zero, not `""` (#859
  review).** An `onkeydown` handler restores it before the implicit submit.
- **A `readonly` zero field is no longer blanked on focus (#859 review).**
- **Typing then erasing in a cleared zero field tells `phx-change` (#859
  review).** The restore now dispatches an `input` event, so the server
  stops holding `""` while the field shows `0`. An untouched focus/blur
  still fires nothing.

## 2.37.3 - 2026-09-22

### Added

- **The MediaBrowser featured star is a toggle on every image tile (#858).**
  With `:featured` set, grid and stack tiles carry a star in the top-left
  corner, styled like the ⋮ trigger: solid on the featured image (a click
  clears it), outline on the others (a click moves the pointer there). It
  sits outside the tile's click target, so it never also opens the viewer.
  In select mode, the trash, or `readonly`, only the featured tile keeps its
  star, as a plain badge.

### Fixed

- **Burning annotations sized the canvas by chrome and empty leaders
  (#858).** The burned picture's bounds were taken from each shape's box,
  and a dimension label group's box reached the overlay's origin through a
  0×0 leader — in live mode a landscape photo came back portrait, squeezed
  under a blank block. The bounds now come from the ink the copy keeps:
  sized leaves only, nothing that is or sits inside chrome (handles, hit
  areas, a draft still being drawn).
- **The featured star no longer hides under the select-mode checkbox (#858
  review).** Both sat in the tile's top-left corner at the same size; in
  select mode the passive badge now steps right of the checkbox.

## 2.37.2 - 2026-09-22

### Added

- **`PreviewCard` takes images by URL, not only as Storage files (#857).**
  An `:images` entry may be `%{src, name}`, with an optional `:thumb_src`
  for the jump strip, alongside the Storage `%{uuid, name}` form — for
  pictures a host serves itself (a document's page previews). Both kinds mix
  in one carousel. `PreviewCard.image_url/2` resolves an entry's URL for a
  variant.

### Fixed

- **`PreviewCard` image entries may be structs again (#857 review).** The
  alt text read `img[:name]`, which structs do not support; it now uses
  `Map.get/2`, so `:name` stays optional on maps and structs keep working.

## 2.37.1 - 2026-09-22

### Fixed

- **2.37.0 did not compile on Elixir 1.18 / OTP 28 (#856, #855).**
  `Storage.CaptureDate` kept its file-name date patterns as a list of `~r`
  sigils in a module attribute; on OTP 28 a compiled regex carries a
  reference that Elixir 1.18 cannot escape into a function body, so every
  host on that toolchain failed with `cannot inject attribute
  @filename_patterns`. The list is now built in a private function — same
  patterns, no behaviour change.

## 2.37.0 - 2026-09-22

### Added

- **Storage records when a photo or video was taken (V200).** Four columns
  on `phoenix_kit_files`: `taken_at` (the UTC instant), `taken_on` (the
  LOCAL date — what a library groups by, so a photo taken late on 31 July in
  California is a July photo although it is August in UTC), `taken_at_offset`
  and `taken_at_source`. The date comes from EXIF (`DateTimeOriginal`, else
  `DateTimeDigitized`, with their offset tags) or a video's container
  (QuickTime's creation date, else `creation_time`), else a date in the file
  name (`IMG_20180701_120000.jpg`, `PXL_…`, `2018-07-01 12.34.56.jpg`), else
  the upload time — so every image and video resolves to one.
  `PhoenixKit.Modules.Storage.CaptureDate` reads it; `ProcessFileJob`
  records it for new uploads from the bytes it already downloads, in the same
  guarded transaction as the dimensions. Adds
  `phoenix_kit_files_capture_date_index` on
  `(user_uuid, taken_on DESC, taken_at DESC)`, partial over a user's visible,
  processed images and videos, so an edited image's hidden backup and tile
  pyramids cost it nothing.
- **Dating files stored before V200.**
  `Storage.Workers.CaptureDateBackfillJob` walks the images and videos with
  no date in batches (`enqueue/0` for a background pass on the
  `file_processing` queue, `pending_count/0`), and
  `mix phoenix_kit.storage.backfill_capture_dates` runs a pass in the
  foreground with progress. A file whose bytes cannot be read is still dated,
  from its name or upload time; a pass visits each file once and cannot loop
  on one.

- **`MediaBrowser` has a view-only mode (#848).** `readonly` hides every
  write affordance (upload, new folder, rename, move, trash, select, rotate,
  the image editor, drag and drop) and refuses every mutating event
  server-side; a broadcast upload is refused where it lands. The nested
  viewer is read-only too — no annotating, rotating or editing details, and
  (post-merge review fix) no burn when the viewer closes. Navigation,
  search, sorting, the viewer and downloads keep working.

### Changed

- **A capture date is never downgraded.** An image edit keeps only the ICC
  profile, so an edited original carries no EXIF; re-processing one used to
  be harmless and now must not replace its EXIF date with a file name. Every
  automatic writer goes through `CaptureDate.replace?/2` — a date is replaced
  only by one from an equally strong or stronger source, and a `manual` date
  never — and an edited image is dated from its unedited backup
  (`original_file_uuid`), not its own bytes.

- **The media viewer opens on the burned copy (#853).** The picture with its
  markup rendered in — the thing people look at and right-click → Copy Image
  — is what the viewer shows first; the pencil switches to the live,
  editable layer, and turning it off burns what was drawn. The viewer opens
  on a new `burned_large` slot (fit inside 1920px); `burned` stays card-sized
  (800px) because a grid paints many of them. A burn happens once per change
  of the drawing, not once per visit: the client fingerprints a canonical
  form of the shapes, the burn endpoint keeps it in `metadata["burn"]` —
  merged into the row as it is now, so a rotation or title changed while a
  burn ran is not reverted — and it is handed back only while a burn is
  stored, so an image edit (which deletes the burns) does not stop the next
  one. The editor's zoom ladder starts at `small` and tops out at `large`, and
  the viewer stays light whatever daisyUI theme the admin uses, since the
  burn is composed on white.
- **Etcher 0.17.0 is the floor (#854).** `Etcher.Raster` now bakes a
  dimension's heads, every kind's label (sized against the picture) and
  `style.fill`; on 0.16 a baked annotated thumbnail was hollow, unlabelled
  shapes.
- **Every connected, authenticated LiveView mounted through a scope hook
  is tracked in Live sessions (#845).** That covers admin pages, feature
  modules, a host page using the scope mount, and the public auth session.
  The row is one per login (`session_id` is a SHA-256 of the session token,
  not the token itself), shared by every tab of that login, and removed when
  the last of them closes. It is node-local. A navigation that destroys the
  LiveView before the next one mounts looks like a disconnect and resets
  `connected_at` while only one tab is open. Anonymous visitors are not
  recorded on this path.

### Fixed

- **A trashed file no longer stays on screen (#847).** Trashing, restoring or
  permanently deleting a file — directly, or by trashing/restoring its
  folder — now broadcasts `{:phoenix_kit_file_trashed | _restored | _deleted,
  uuid}` on `Storage.subscribe_to_file_events/0`'s topic. `MediaBrowser`
  drops the card and closes a viewer open on it; `FeaturedImage` re-resolves
  on `send_update(FeaturedImage, id: id, refresh: true)`. A trashed file's
  variants are refused (404) by `/file/...` except to a holder of the
  `"media"` permission, whose Trash tab renders its thumbnails through that
  route — and that response is `private, no-store`, never `public`: the URL
  is the same for every caller, so a CDN or caching proxy would otherwise
  have kept the holder's copy and served it to anyone (post-merge review
  fix).
- **Admin tab permissions are kept per action (#850).** Two tabs naming the
  same LiveView on different `live_action`s no longer collide on one cached
  entry, where a tab's `priority` silently decided which key guarded both
  routes (a redirect loop for users holding the page's own key). An action
  with no tab of its own — `:show`/`:edit` of a LiveView whose tab is
  `:index` — is guarded by the module's tab permission when its tabs all
  agree on one; before the post-merge review fix it resolved to nothing and
  locked partial roles out of every record behind the list.
- **The Settings sidebar entry opens a page its viewer can use (#851).** It
  was shown to holders of any settings-related permission but always linked
  to General, gated on `"settings"` alone; it now links to the first
  settings subtab the viewer can open, and still to General for a
  `"settings"` holder whatever priority a module gives its own subtab.

- **A folder operation is announced once, not once per file.** Trashing,
  restoring or permanently deleting a folder sends one
  `{:phoenix_kit_files_trashed | _restored | _deleted, [uuid]}` for every
  file it swept up (single-file operations keep `{:phoenix_kit_file_*,
  uuid}`); a folder of thousands of files was thousands of messages and
  re-renders for every open browser. A host reacting to one file must match
  both shapes — see `FeaturedImage`'s moduledoc. A file a permanent folder
  delete re-homes into a trashed folder, and the files a media reorganize
  restores, are now announced too.
- **Restoring a folder restores only what trashing it trashed.** A file
  trashed on its own before or after the folder stays in the trash (it was
  restored along with the folder, and so were files never trashed at all).
- **Opening a trashed file's thumbnails costs one permission lookup per
  burst**, not two queries per image: the answer is cached for five seconds
  per user and active role.
- **The admin header and a `user_settings_path` override keep the visitor's
  language (#852).** The project title links to the host's own `/<locale>`
  home when its router serves one (else `/`), never to core's mount point;
  an override page gets the locale segment the default settings page would,
  and never `url_prefix`.
- **Every way into Settings lands on a page its viewer can open.** A visitor
  refused Settings → General who can open another settings subtab is taken
  there — from a settings page's section header, a bookmark or a typed URL,
  not only from the sidebar. Both sidebars and this redirect follow one rule
  (`TabHelpers.redirect_target/2`), and the user dashboard's sidebar now also
  keeps a parent's own landing page when it is reachable.
- **A rotated picture burns.** The burn recovered its scale from the screen
  X of two image points, which is 0 at a quarter turn and negative at a half
  turn, so a saved rotation made every burn a silent no-op and the viewer
  kept opening on the old copy. The mapping is now the full image→screen
  affine, and the burned pixels stay unrotated (the viewer reapplies the
  rotation). Stepping to the next or previous file burns on the way out, and
  the stand-in paints the variant the viewer opens on (`burned_large`, else
  `burned`, else `small`) instead of flashing the clean `small`.
- **A readonly viewer does not create annotation comments.** Reply stays on
  the tooltip of a locked shape; `annotation_reply` is refused when the
  viewer cannot annotate.
- **An untabbed action stays unmapped when a LiveView's tabs disagree.**
  Namespace inference (`PhoenixKit.Modules.Reports.Web` → `"reports"`) no
  longer authorizes a `:show` / `:edit` that neither tab named. Tabs that
  agree still guard those actions, and a tab registered for the whole module
  (no action) still guards every action no other tab names.
- **A trashed file's refusal is not cacheable, and neither are its tiles.**
  The 404 from `/file/...`, the file info endpoint and the unedited-original
  endpoint is `private, no-store`. Deep-zoom manifests and tiles use the same
  media-holder gate as `/file/...` and, when served, are `private, no-store`
  rather than a year-long public response.
- **A capture-date backfill does not lock in the wrong date.** An image edit
  that lands while a file is being dated leaves `taken_at` empty so the next
  pass reads the unedited backup, instead of storing the file name. A video
  whose stream `creation_time` is an unset epoch no longer hides the
  container's real instant. A cross-user copy keeps the donor's date, and
  `Storage.store_file/2` (comment attachments) records one from the bytes it
  stores.

**Upgrading:** run `mix phoenix_kit.update` for V200, then date the existing
library once with `mix phoenix_kit.storage.backfill_capture_dates` (or
`CaptureDateBackfillJob.enqueue()` from a running node). Video dates need
`ffprobe`; without it a video is dated from its file name or upload time,
the same way its dimensions and duration already degrade.

## 2.36.1 - 2026-09-21

### Fixed

- **The media browser's pagination no longer floats over the file list.**
  The list wrapper still carried `min-h-0` from before the content column
  became the single scroll area, so it shrank to the visible height and
  the "1 / N — Next" bar rendered mid-list on top of the rows (and the
  folder drop target covered only that first screenful).

## 2.36.0 - 2026-09-21

### Added

- **Annotations are burned into the picture when an editing session ends.**
  Turning Etcher off, or closing the viewer, composes the live overlay in
  the browser and stores that rendering. List rows read it from `thumbnail`;
  grid cards prefer `burned` (fit inside 800px) over the plain `small`. The
  editor's own ladder — `small`, `medium`, `large`, `original` — stays the
  picture as uploaded, so the live shapes are not drawn a second time on
  the next open. `POST /api/files/:file_uuid/burn` re-encodes the upload
  through `ImageProcessor.sanitize/3` and refuses a rendering whose
  `source_version` is no longer the file's original.

### Fixed

- **A baked annotated thumbnail draws the shape's label.** The words live
  in the `title` column; `Etcher.Raster` reads `metadata.title`. The bake
  now projects the column the same way the live viewer does, so a named
  text or callout shape is no longer an empty box.
- The burn is limited to the file's owner, an Owner/Admin (honouring the
  active role), or a holder of the media permission — the same people who
  can edit the picture. A second session-end while an upload is in flight
  keeps the composition taken while the overlay is still on screen.

## 2.35.0 - 2026-09-21

### Added

- **Right-click a row to open its `⋮` menu at the pointer.** Flag the row
  `data-row-menu-context` (`<.table_default_row data-row-menu-context>`, or
  `card_context_menu` on `table_default` for the card view) and the
  `table_row_menu` rendered inside it opens where the user clicked. Opt-in;
  omit the attribute to turn it off. A text field, a text selection inside
  the row, and a row whose menu is not rendered all keep the browser's own
  menu. The Menu key / Shift+F10 opens it beside the `⋮` trigger, and an
  Android long press does not also activate the row underneath. Per-row
  `navigate`/`href` items keep working, which `Core.ContextMenu`'s single
  shared menu cannot offer.
- **`sort_selector` takes `label`** — a visible "Sort by" before the control,
  off by default so existing toolbars keep their height.

### Changed

- **An open row menu closes when the page scrolls or resizes**, instead of
  staying fixed over a different row while still acting on its own.
- `Core.ContextMenu` and the row menu share one pointer-placement rule
  (`window.PhoenixKitMenus.pointerPosition`).

### Fixed

- **Generated sitemaps no longer ship in the Hex package.** `files: ~w(priv …)`
  takes whatever is on disk, gitignored or not, so 2.34.0 carried a test
  run's `priv/static/sitemaps/domains/site.example.com/sitemap.xml` and a
  fresh install served it at `/sitemap.xml` until regenerated.
  `priv/static/sitemap.xml` and `priv/static/sitemaps/` are now excluded.
- **A row menu patched while open shows the server's current items** — an
  action the server stopped offering ("Retry" once an extraction succeeds)
  could still be clicked from the stale copy. Keyboard focus stays on the
  item in the same slot across the swap.
- `bulk_select_scope`'s `swap` doc now states the target must hand `style`
  to the client (`JS.ignore_attributes(["style"])`), or a patch of the
  target alone un-hides it.

## 2.34.0 - 2026-09-20

### Added

- **Activity says what changed.** A module records a field diff under the
  reserved `"changes"` metadata key (`Activity.changes_key/0`):
  `%{"changes" => %{"sku" => %{"from" => "T-21", "to" => "T-22"}}}`. The
  detail page leads with a "What changed" before/after table and the list's
  Details column shows the change instead of the row's name. Legacy flat
  `field_from` / `field_to` pairs fold into the same shape, so rows already
  in the table read the same way. A `%{"uuid" => _, "label" => _}` reference
  renders as its label; `%{"changed" => true}` records a long value as
  changed without keeping either copy. New: `Activity.split_changes/1`,
  `change_side/2`, `humanize_metadata_key/1`.
- **`bulk_select_scope` takes `swap`** — a CSS selector for a toolbar outside
  the scope that is hidden while the scope holds a selection, so the action
  bar takes its place instead of pushing every row down under the pointer.
  Several scopes may name one toolbar; it stays hidden while any has a
  selection.

### Changed

- **The media viewer docks a shape's tooltip in the style panel**
  (`tooltip_dock={:panel}`) — nothing pops up over the photograph. Needs
  etcher 0.16, so the floor moves to `~> 0.16.0`; the CDN pins move to etcher
  0.16.0 and fresco 0.12.2.

### Fixed

- **A modal dismissed with Escape or a backdrop click no longer re-opens on
  the next patch.** Chromium dismisses a server-opened dialog without firing
  `close`, and `close()` is a no-op once morphdom has stripped `open`; the
  hook now pushes the close from `cancel` and restores the attribute first.
  In a stack, a child that already pushed its own close is not pushed a
  second time by its parent.
- **A photo rotated a quarter turn no longer opens stretched in the instant
  stand-in** — the element is fitted to the box it will occupy after the
  turn. The fit is measured after the stand-in is revealed: measured while
  hidden, the frame read 0 × 0 and the fit never ran on an open from the grid.
- **A resource link whose title template resolves to nothing** falls back to
  `<type> <short-uuid>` instead of rendering an empty link.

### i18n

- "What changed", "Before", "After" and "changed" translated in all seven
  locales. The merge had fuzzy-matched "changed" onto the imperative
  "Change"; rewritten by hand. The list's Details column translates the word
  too, rather than printing the English one.

## 2.33.0 - 2026-09-20

### Added

- **`PhoenixKitWeb.Components.FeaturedImage`** — a LiveComponent for one
  entity's main image (order/product image, logo, avatar): a thumbnail, an
  always-visible Change / Remove menu that works on touch screens, and the
  whole media-picker protocol behind it. It is controlled and writes nothing:
  the host handles `{FeaturedImage, id, {:set_featured, uuid | nil}}`,
  authorizes, persists and passes the new `uuid` back. `picker_scope` is
  `{:folder, uuid}`, `:lazy` (folder created on the first click) or `nil`.
  The picker renders through a portal, so the control is safe inside a host
  `<.form>`. Guide: "FeaturedImage Component" in the core-components guide.
- **`table_row_menu` takes `trigger_size`** (`"xs"` default, `"sm"`, `"md"`)
  for a touch-sized ⋮ trigger. The size class is replaced, not appended —
  `btn-xs` sorts after `btn-sm` in the built CSS and would win.

### Changed

- **A `preview_card` with no media shows a placeholder** instead of
  collapsing to a bare list of fields.

### Fixed

- **`FeaturedImage` refuses a system-managed file** (an edited image's hidden
  unedited original). The picker never lists one, but the chosen uuid comes
  from the client, and such a row is a live image that is never served.

## 2.32.1 - 2026-09-19

### Fixed

- **Failed file processing no longer fills the temp dir.** `ProcessFileJob`,
  `VariantGenerator` and the annotated thumbnail removed their temp files only
  when everything succeeded, so a file that cannot be rendered (an SVG on a
  host whose ImageMagick has no SVG delegate) left a `phoenix_kit_*` copy of
  its original behind on every attempt — and each request for the missing
  variant re-queues the job. One host collected over a thousand in two days.
  The temp files now go whatever the outcome; the private-bucket proxy cleans
  up the same way.

## 2.32.0 - 2026-09-19

Migrations: V198 (data only), V199 (`phoenix_kit_files.data`) — run
`mix phoenix_kit.update`.

### Added

- **Media files can carry a title, alt text and description per language.**
  V199 adds a `data` column to `phoenix_kit_files`; a file also gains an `alt` text,
  which it never had. Every language holds its own text and none is marked
  as primary, so changing the site's primary language converts nothing: each
  field resolves when it is read — the language asked for, then the current
  primary language, then any. `PhoenixKit.Modules.Storage.FileDetails` is the
  one read and write path: `Storage.translated_title/3`, `translated_alt/3`
  (`""` when there is none — never the file name) and
  `translated_description/3`; `Storage.update_file_details/3` re-reads the
  row and replaces one language's text only, so another language, a rotation
  or a tag saved in the meantime survives. The `metadata` title and
  description of a file saved earlier are read as its primary-language text
  — no backfill. Plan: `dev_docs/plans/2026-09-19-media-translations.md`.
- **The media editors edit that text in the language the page is shown in.**
  The admin language switcher is the content switcher: open
  `/et/admin/media/:uuid` (or the viewer sidebar on an Estonian page) and the
  title, alt text and description you save are the Estonian ones. No tabs.
  A small badge names the language being edited on a multi-language site,
  and the primary-language text shows as each empty field's placeholder —
  never as its value, so an untouched save stores nothing. Both editors —
  the detail page and the viewer sidebar — now save through
  `Storage.update_file_details/3`, and both gained the **Alt text** field
  (images only). The viewer reads the language from the page's own Gettext
  locale, so hosts embedding it pass nothing new. Eight new strings,
  translated in all seven locales.
- **The alt text reaches the pages.** `<.image_set>` and the page-builder
  `Image` component render a Storage file's own alt text, in the language the
  page is rendered in, when no `alt` is written on them — `alt=""` still marks
  a decorative image, and `<.image_set>` with pre-loaded `variants` looks
  nothing up (pass `alt`; `Storage.translated_alts/3` reads it for a whole
  list in one query, `translated_alt_by_uuid/3` for one). System-managed files
  are never read. `GET /api/files/:uuid/info` returns `title`, `alt` and
  `description`, in the language an optional `?locale=` names — never the
  session's. The MediaBrowser grid and both media pickers use the alt text on
  their thumbnails, keeping the file name where a file has none.

- **`PhoenixKit.Utils.Multilang.current_locale/0`** — the language the page
  being rendered is in, as the full dialect the request resolved to
  (`Languages.request_locale/0`, recorded wherever the Gettext locale is
  set), else the Gettext locale. For per-language *content*: Gettext's own
  locale is downgraded to a base code and cannot tell `en-GB` from `en-US`.
  Readable from a LiveComponent, which has no `@current_locale`.
- **`Storage.update_file_metadata/2`** — changes a file's `metadata` from the
  row as it is now, held `FOR UPDATE`. Both rotation writes use it.

### Changed

- `<.image_set>`'s `alt` now defaults to `nil` (look the file's alt text up)
  instead of `""`. A caller that relied on the default to mean "decorative"
  should write `alt=""`.

### Fixed

- **Saving a title on the media detail page or in the viewer sidebar no
  longer overwrites the rest of the file's `metadata`** with the copy the
  page loaded earlier — a rotation saved in between was lost. The reverse is
  fixed too: rotating an image (viewer or grid menu) no longer writes back
  the `metadata` it read, so a title or tags saved in between survive, and
  two quick rotate clicks add up.

The rest are fixes from the 2026-09-19 weekly review
(`dev_docs/pull_requests/2026/weekly-2026-09-19/CLAUDE_REVIEW.md`):

- **A broken host file-reference source no longer makes orphan cleanup delete
  the host's files.** A `:file_reference_sources` entry whose function raised,
  whose table was missing, or that was malformed was skipped with a warning —
  which dropped that source's `NOT EXISTS` guard, so every file only the host
  referenced read as an orphan and lost its row and its bytes. A source that
  cannot be built now **fails closed**: a `Logger.error/1` names it and no file
  is treated as orphaned until it is fixed. The shorthand's table is looked up
  through the search path, the way the query itself resolves it.
- **A Telegram group is never linked on its own.** A bot's username is public
  and anyone can add it to a group of theirs and run `/start@bot`, so in
  "Only me" mode the next Test linked a stranger's group and delivered the
  owner's notifications to it. `ChatLink` now hands captured groups back as
  candidates, held in the LiveView and never stored; the card lists them with a
  "Link" button and the owner confirms the ones they recognise. Three new
  strings, translated in all eight locales.
- **A parallel burst no longer bypasses the login rate limiter.** 2.31.0 made
  the check read the bucket and count the attempt only after the password
  verify, so every request in a burst saw an empty bucket. The check takes its
  slot atomically again, and a successful sign-in hands it back
  (`RateLimiter.record_successful_login/2`) — so ordinary sign-ins still never
  lock an account out. The IP bucket is checked first: a client refused for its
  network no longer spends the slots of the account it names.
  `record_failed_login/2` is deprecated and does nothing.
- **Requests the rate limiter refuses can no longer grow
  `phoenix_kit_login_attempts` without bound.** A refused request naming no
  account is stored under `"*"` — one row per network per hour — instead of one
  row per invented identifier.
- **The failed sign-in alert is sent once under a parallel burst.** The cooldown
  stamp is a compare-and-set in one statement; concurrent failures that all
  read "due" from a stale struct no longer each send a mail. The stamp also
  stopped bumping the account's `updated_at` and broadcasting `user_updated`.
- **V196 no longer aborts on a Google address longer than 160 characters.** The
  backfill copied `provider_email` (`varchar(255)`) into `google_email`
  (`varchar(160)`) verbatim; it now skips an address that does not fit and
  stores the rest trimmed and lower-cased, as the changeset does.
- **An image can be edited after any number of reverts.** A revert handed the
  backup's `unedited_…` keys back to the file and the next edit prefixed them
  again — 42 characters per cycle, until the key outgrew `varchar(255)` and the
  file could never be edited again. The prefix is replaced, not stacked.
- **A publish that raises no longer leaves the render and the private unedited
  copies in the bucket** under keys no row points at, a fresh set per retry.
- **Trashing a folder no longer moves a file into a folder that is itself in the
  trash**, where it stayed `active`, appeared in no trash listing, and was
  hard-deleted when that folder was emptied. It goes to the trash with its home
  and comes back with it. A permanent delete that has only a trashed folder to
  move the file to trashes it with that folder.
- **The settings history withholds secret-named keys, not only the restricted
  list.** A module's `…_api_key` or `…_token` written through the ordinary
  writers was withheld from the change broadcast and then recorded in plain
  text in a permanent `setting.changed` entry. The history now applies the same
  name test as `Settings.Events.secret_key?/2`, and **V198** withholds the
  values already recorded. Data only; `down/1` restores nothing, by design.
- **Translations follow a recompile.** The compile-time Gettext catalogue was
  cached in `:persistent_term` under a key that outlived the module, so an
  edited `.po` kept serving the old strings until the VM restarted. The cached
  term now carries the hash of the binary it was decoded from.
- **`mix phoenix_kit.update` no longer adds a second `default:` queue.** A queue
  whose limit is not a literal (`String.to_integer(System.get_env(…))`, a module
  attribute), or that shares a line with another, read as missing; the
  duplicate key parsed, and Oban then refused to boot. `queues: false` written
  on the `config` line itself is recognised as a web-only node.
- **`mix phoenix_kit.gen.migration` (and `update --no-start`) no longer writes a
  `down` that tears PhoenixKit down to the chain's floor.** The install
  migration's filename carries no version and scans as 1; when that guess is the
  starting version the generated `down` raises and says how to roll back on
  purpose.
- **MediaBrowser, controlled mode:** nav params with no `:file` key leave the
  viewer alone — a host wired by hand before `file` existed had the viewer close
  on the echo of the click that opened it — and the echo of a superseded step
  (held ArrowRight) no longer drags the viewer backwards. The moduledoc now
  documents the key.
- **The folder sidebar opens when the server opens it.** The chevron's
  client-side class change is sticky in LiveView and was re-applied over the
  server's render, leaving the sidebar collapsed after "New folder" and the UI
  inverted against the saved preference. `FolderExplorer` takes a `sidebar_rev`
  the host bumps on a server-side change.
- **Image editor:** the frame keeps an EXIF-turned source's aspect after a save,
  retry or revert, and a number field emptied mid-edit keeps its crop or area
  instead of deleting it and renumbering the ones below under the cursor.
- **The media viewer's title/description editor and rotation save honour the
  browser's scope.** `MediaCanvasViewer` takes a `write_scope`; a file merely
  linked into a scoped browser is no longer retitled or rotated for its owner.

## 2.31.1 - 2026-09-19

### Added

- **Breadcrumb level switchers in the admin header** (#835). A ▾ beside a
  breadcrumb segment that opens a searchable list of the other things on that
  level and switches to one — GitHub's repository switcher, for any trail: the
  other catalogues beside this one, the sibling categories beside this
  category. The header's breadcrumb is core's, so the component lives here and
  every page, core's own and a module package's, can reach it.
  - `PhoenixKitWeb.Components.Core.CrumbSwitcher.crumb_switcher/1` — the ▾, the
    panel (`PopoverPanel`: instant, Escape and a click away close it, a
    full-screen sheet on a phone), a heading, a search box and the list with the
    current row ticked. Every row is a real `navigate` or `patch` link, so
    middle-click and copy-link keep working.
  - `LayoutWrapper.app_layout` grows a `page_title_switcher` attr and honors a
    `:switcher` on any `page_crumbs` entry; `layouts/admin.html.heex` threads
    the new attr so plugin LiveViews can pass one. A page that passes neither
    renders exactly as before.
  - Two JS hooks. `ListFilter` filters the list on the client, ignoring case
    and accents (`kasitoo` finds `Käsitöö`); Enter opens the first match, but
    not an Enter that confirms an IME composition. It re-filters whenever its
    list re-renders, because the inline styles it sets are not the sticky kind
    LiveView re-applies after a patch — morphdom strips them, and an unfiltered
    list under a query that still reads `kitch` would open the wrong row.
    `CrumbSwitcher` does the open/close bookkeeping however the panel opened or
    closed: the search starts empty and takes focus, focus returns to the ▾ on
    close, `aria-expanded` follows the panel, and Tab stays inside it.
  - No new strings: the switcher reuses `Search...` and `No results.`, both
    already translated in all eight locales.

### Changed

- **The catalogue module is named "Catalogues" on the Modules page** (#835).
  The module took its pages' name, and the Modules page translates each
  module's `module_name/0` through core's catalogs, which knew only
  "Catalogue" — so every locale but English showed the new name in English.
  Both msgids are now registered and translated in all eight locales; the old
  one stays, because older catalogue releases still send it.

### Fixed

- **Gettext source references for the switcher's reused strings.** #835
  branched before 2.31.0's extract/merge round-trip, so `Search...` and
  `No results.` carried no reference to `crumb_switcher.ex` in the `.pot` or
  any `.po`. Nothing was mistranslated, but the next extract would have mixed a
  thousand-line reference diff into someone else's work. Round-trip re-run:
  0 new, 0 removed, 0 fuzzy, reference comments only.

## 2.31.0 - 2026-09-18

### Added

- **Failed sign-ins are recorded.** Until now a wrong password produced a flash
  and nothing else — no row, no activity entry, nothing the targeted account
  holder or the site owner could ever see. The only trace was Hammer's
  in-memory rate-limit counter, which is node-local, lost on restart, counts
  successful logins too, and says nothing at all until a bucket overflows.
  The case that motivates it: an attacker who guesses right on attempt 400
  triggers only the new-device email, which is indistinguishable from "I signed
  in from my new laptop" — the 399 failures before it are what tell those apart.
  - **V197 migration** — `phoenix_kit_login_attempts`. Rows are aggregated at
    write time on `(identifier, ip_network, outcome, bucket_start)`, where the
    bucket is the hour, so a sustained attack against one account from one
    network collapses to one row per hour with a rising `attempt_count` rather
    than thousands of rows. The write is a single `INSERT ... ON CONFLICT DO
    UPDATE` with no preceding read.
  - `PhoenixKit.Users.LoginAttempts` — `record/4`, `count_for_user_since/2`,
    `recent_for_user/2`, `stats/1`, `top_since/2`, `prune/1`. Every entry point
    swallows its own failures with both `rescue` and `catch :exit`: a security
    log that takes the login form down with it is worse than no security log.
  - Recorded on all three failing branches of the login form, with the outcome
    that matters most kept distinct — `"inactive"` means somebody had the
    correct password for a deactivated account. The HTTP response is unchanged
    on every branch, and the two that share the deliberately generic "Invalid
    email/username or password" flash do the same work, so neither the
    response nor the timing tells a real account from a fictitious one.
  - Settings `login_attempt_logging_enabled` (default **on**, unlike
    `new_login_alert_enabled`: it writes one bounded row, sends nothing, and
    the data is useless retroactively) and `login_attempt_retention_days`
    (default 90). Daily `PhoenixKit.Users.LoginAttemptsPruneWorker`, added to
    the generated crontab AND to the backfill list, so an existing host gets it
    on `mix phoenix_kit.update` instead of never pruning.
- **The new-login alert email reports recent failures.** "There were also 12
  failed sign-in attempts on your account in the last 24 hours." This is the
  line that separates "my new laptop" from "someone finally guessed it" — the
  email already reached the right person at the right moment and said nothing
  about it. Omitted entirely when the count is zero, rather than printing a 0.
- **A burst of failures warns the account holder.**
  `failed_login_alert_enabled` (default **off** — it sends mail) plus
  `failed_login_alert_threshold` (default 10 failures within an hour). Capped
  to one alert per account per 24 hours, so a sustained attack cannot be turned
  into a mail flood against the person being attacked; the cooldown stamp is
  written *before* the send, so a send that raises still burns it.
- **The account holder's own settings page lists recent failed attempts**,
  under Active Sessions — the two answer the same question from opposite
  sides. Described by device and network, never by the stored identifier.
  Hidden entirely when there is nothing to show.
- **`/admin/users/sessions` gained a failed sign-in panel** — attempts,
  distinct networks and distinct targeted accounts over the last 24 hours, plus
  the heaviest buckets. Attempts vs buckets is the distinction that matters:
  a large attempt count over few buckets is one concentrated attack, the
  reverse is a spray. The attacker-controlled identifier is shown here (it is
  what makes "someone is hammering `admin@`" visible) and is escaped by HEEx;
  a regression test asserts a `<script>` identifier renders as text. Each row
  also names the outcome, so `"inactive"` (correct password, deactivated
  account) is visible instead of looking like just another wrong password.
- **Authorization settings for the new keys**, on `/admin/settings/authorization`.
  `failed_login_alert_enabled` defaults off because it sends mail; without a
  control it was unreachable except by writing the settings table directly.
- **"Annotation tools" on `/profile/settings`: one button that puts the drawing
  tools back to how they ship** (PR #832). A person's annotation settings live
  in two places, and clearing one without the other leaves them half-fixed —
  the palette and ink the Etcher toolbar saves are on the user row
  (`etcher_colors`, `etcher_line_params`), while the background dots, connector
  anchors, toolbar layout, style-panel state and per-tool colours are Etcher's
  own `etcher:prefs` answers in the browser. The reset clears the row
  server-side and pushes `phoenix_kit:etcher-reset` on the same socket, which
  the new `EtcherReset` hook answers by removing the browser's copy. The
  annotations themselves are untouched. Rendered last on the page: a reset is
  what you reach for when something is wrong, not part of the daily settings.

### Fixed

- **A bucket that opened against no account stayed unattached for the rest of
  the hour** even after that identifier became a real user. `ON CONFLICT`
  only incremented the count and `last_at`, so the account holder never saw
  those attempts and the threshold alert undercounted them. The upsert now
  `COALESCE`s `user_uuid` from the incoming row.
- **Add-account (the multi-session password form) recorded nothing.** A wrong
  password, a rate-limited try, and a deactivated account with the right
  password now write the same three outcomes as the login form.
- **The threshold alert could fire when the insert had failed**, and a
  `custom_fields` stamp that failed still sent the email — so every later
  failure retried it. The alert now runs only after a successful write, and
  only after the cooldown stamp commits.
- **The add-account fallback clause was unreachable.** Dialyzer proves
  `MultiSession.add_account/3` returns only three reasons, so the defensive
  catch-all could never match — but deleting it would mean a fourth reason
  added later raises `FunctionClauseError` on the sign-in path. It is a map
  lookup now, which keeps the fallback reachable and the guarantee intact.
- **Null bytes in the identifier crashed the insert** (Postgres rejects
  `\\x00` even though it is valid UTF-8) and truncation used graphemes
  against a `varchar(160)` that counts codepoints. Both are normalized
  before write so an attacker-controlled identifier cannot skip recording.

- **The login rate limiter counted successful sign-ins.**
  `check_login_rate_limit/2` runs *before* the password is verified, and it
  incremented the bucket — so five ordinary logins inside the window locked the
  account out of the sixth, and the bucket a brute-force attempt fills was the
  same one legitimate use drained. The check now peeks; the new
  `RateLimiter.record_failed_login/2` fills the bucket, on the failure branch
  where the outcome is actually known. A correct password — even for a
  deactivated account — no longer counts against the limit.

### Changed

- **The Etcher floor is `~> 0.15.0`** (PR #833), with the jsDelivr pin in
  `phoenix_kit.js` moved to `v0.15.0` to match. 0.15 is where a thickness
  stopped meaning document pixels and started meaning a weight against a
  1000-pixel reference canvas, so an older Etcher renders a host's saved
  `etcher_line_params` at a different weight on every image — a floor, not a
  preference. The weight range is still 1–40, which is exactly what
  `MediaCanvasViewer`'s sanitizer clamps to, so a saved value keeps its meaning
  end to end and no host data needs migrating.
- Post-merge review of #832: the `EtcherReset` hook had landed *under* the
  `FolderDropUpload` banner in `phoenix_kit.js`, leaving that banner labelling
  the wrong hook; the reset's comment claimed a delete of an unsaved key
  answers `:not_found`, when `jsonb - key` is simply a no-op and `:not_found`
  means the user row is gone; and the hook shipped without a `test/js` case,
  which now covers the event name, the storage key (pinned against Etcher's own
  `_prefsKey`) and a storage that refuses to write.

- **`PhoenixKitWeb.Gettext` no longer compiles translations as function clauses.**
  `split_module_by: [:locale]` brought a clean compile of this file from ~58s
  to ~13s, but 13s still trips Elixir's ">10s" notice: each locale module is
  ~2.7k binary-matching clauses, which the Erlang compiler handles
  superlinearly, and wall-clock is the slowest of those modules. The backend
  now parses `priv/gettext` into a nested map at compile time and embeds it
  as a compressed binary (~0.3s for the file). Lookups go through `Map.get/2`
  and runtime interpolation; `Gettext.dgettext/3` and the extract-surface
  (`__gettext__/1`, `__mix_recompile__?`) are unchanged.
- **The backend reads `:priv`, `:interpolation` and `:default_domain` from the
  merged opts.** They were declared as bare defaults *before*
  `Application.compile_env(:phoenix_kit, PhoenixKitWeb.Gettext, [])` was folded
  in, so a host that configured `priv:` got a catalogue built from its own
  directory while `__gettext__(:priv)` still pointed `mix gettext.extract` and
  `mix gettext.merge` at `priv/gettext`, and a configured `interpolation:`
  module was ignored at runtime. `Gettext.Backend.__using__` derives all three
  from the merge; so does this backend now.
- **Plural forms come from each PO file's `Plural-Forms:` header again.** The
  first cut always called `Gettext.Plural.plural(locale, n)`, i.e. Gettext's
  built-in locale table, which silently ignored both a translator-authored
  header and `config :gettext, :plural_forms`. The compiler now stores
  `Gettext.Plural.plural_info/3` per locale/domain alongside the catalogue —
  the same resolution `Gettext.Compiler` performs. No shipped locale changes
  behaviour: the five headers we carry agree with the built-in table, and the
  other three have no header.
- **`PhoenixKitWeb.Gettext.warm_catalog/0`**, called from
  `PhoenixKit.Application.start/2`. Decoding the embedded catalogue costs ~20ms
  and `:persistent_term.put/2` scans every process; leaving it to the first
  `gettext` call put both on a random request instead of on boot.
- **Plural `Gettext.PluralFormError` now reports the PO source line**, and a
  missing plural form is logged at compile time the same way
  `Gettext.Compiler` does. `strip_meta: true` still keeps `source_line` on
  the message, so the dummy `line: 1` was unnecessary.

- **The new-login alert email timestamps the sign-in in the recipient's own
  timezone.** It rendered `2026-09-18 16:23 UTC` for every reader, which is
  the one thing nobody can check an unfamiliar sign-in against. It now uses
  the recipient's `user_timezone` (else the site's `time_zone`), formatted
  with the site's date/time settings and named — `2026-09-18 18:23 CEST`, or
  `UTC+05:30` where the preference is a legacy numeric offset rather than an
  IANA zone. DST is resolved for the instant shown, so the same account reads
  `CEST` in July and `CET` in January.
- **That email also says the device was unrecognized, and marks the location
  approximate.** "We noticed a new login to your account" became "…from an
  unrecognized device", and a resolved place now renders as
  `Paris, France (approximate)` — IP geolocation is city-accurate at best, and
  an unqualified city invites a reader to dismiss a real alert because it
  looks wrong. An unresolved location still degrades to a bare `Unknown`.
- The alert's `variables` are now built inside the recipient's locale, like
  the body they are substituted into. `Unknown` previously rendered in
  whatever locale the signing-in request happened to be served in.

### i18n

- **The annotation-reset copy — six new msgids — translated by hand in all
  seven locales**, grounded in each catalogue's own terms for *annotation* and
  *toolbar* (de *Anmerkung* / *Werkzeugleiste*, pl *adnotacja* / *pasek
  narzędzi*, ru *аннотация* / *панель инструментов*) and in its address form.
- **`Could not read the current figures` had never been extracted either**, and
  the merge that caught it carried **"Could not reach the storage endpoint"**
  onto it in all seven locales — a wrong sentence, served, where an empty
  msgstr would at least have fallen back to correct English. Rewritten by hand
  in all seven. `grep -rc fuzzy` is 0 across every translated catalogue and
  `--check-up-to-date` passes.

- **`mix gettext.extract --check-up-to-date` passes again.** The media
  viewer's `"Title & description"` heading (added in 2.30.0, from
  `media_canvas_viewer.html.heex`) had never been extracted, so it was in no
  `.pot` and no catalogue and rendered as English everywhere. The extract that
  caught it fuzzy-matched it onto **"Edit description"** in all seven
  translated locales — de *Beschreibung bearbeiten*, ru *Изменить описание* —
  and Gettext serves fuzzy entries, so that wording would have shipped.
  Rewritten by hand in all seven, following the catalogues' own convention of
  spelling out a UI `&` (*Titel und Beschreibung*, *Título y descripción*,
  *Pealkiri ja kirjeldus*, *Titre et description*, *Titolo e descrizione*,
  *Tytuł i opis*, *Название и описание*) while `&` is kept only inside a
  third-party product's literal menu path. `grep -rc fuzzy` is 0 again across
  every translated catalogue.
- The failed-sign-in copy — 14 new msgids, including two `ngettext` entries —
  translated by hand in all seven locales, with the three-form plurals written
  out for `pl` and `ru`.
- **A fuzzy carryover silently deleted `{{failed_attempts}}` from the
  new-login body in all seven catalogues.** The count would have rendered in
  English and vanished in every other language, with nothing failing. The
  placeholder was restored structurally (anchored to `{{browser_os}}`, not to
  each locale's wording) and a test now asserts the substitution survives
  translation. Two other carryovers were rewritten: `%{count} attempt` had
  arrived as ru *событие* ("event") and `Last seen` as *Последняя генерация*
  ("last generation").
- The new-login alert body and the new `%{location} (approximate)` string
  translated by hand in all seven locales, following each catalogue's own
  address form and device wording (de *von einem unbekannten Gerät*, fr
  *depuis un appareil non reconnu*, pl *z nierozpoznanego urządzenia*). The
  body's msgid change fuzzy-matched onto its own previous translation, which
  was corrected rather than accepted.

## 2.30.0 - 2026-09-18

### Added

- **`PhoenixKitWeb.Components.Core.PreviewCard`** (#827) — the catalogue's
  product card, generalised into core. `preview_card/1` renders a modal whose
  media area is ONE continuous swipeable carousel (images first, then attached
  files; a PDF inline from `sm` up, anything else as a tile with an Open
  action), a jump strip under it, the resource's filled fields and a compact
  file list. Slide switching is entirely client-side scroll-snap — the only
  server event left is the close. `preview_card_body/1` is the same content
  without the modal shell, for embedding the preview inline. The component is
  pure render: every DB-backed value (`images`, `files`, `fields`, `title`) is
  resolved by the caller, so it needs no database. The catalogue delegates to it
  in a follow-up once this releases.
- **`config :phoenix_kit, :file_reference_sources`** (#828) — orphan detection
  knew only about the references core itself ships with, so a host whose own
  tables point at files was one cleanup run away from losing them. A host can
  now register `{module, function}` / `{module, function, args}` entries
  returning `NOT EXISTS` dynamics over the file binding, with `{table, column}`
  and `{table, :jsonb_key, key}` shorthands for the common shapes. Every
  registered source is honoured by `find_orphaned_files/1`,
  `count_orphaned_files/1` **and** `file_orphaned?/1` — including the re-check
  `DeleteOrphanedFileJob` runs before it deletes anything. A source whose table
  is missing, or whose function raises, is skipped with a warning instead of
  failing the query.
- **Optional host-owned featured image in `MediaBrowser`** (#829) — an opt-in
  `featured` attr (`nil` by default, so every existing consumer is untouched)
  turns on a "Set as featured" / "Unset featured" action for image files in the
  grid, list and stack kebabs plus the modal viewer's sidebar, with a star badge
  on the current pointer. The browser never persists the choice: it relays
  `{MediaBrowser, id, {:set_featured, uuid | nil}}` to the host and moves its own
  badge ahead of the host's write, which the host can correct with a later
  `featured` assign.

### Fixed

- **Email templates stored in the database raised `KeyError` on every send**
  (#830). `Email.Content.resolve/5`'s two branches answered in different shapes:
  the database branch mapped `html` from the provider's `html_body` but took
  `text` from a `:text` key no provider has ever had — core's own
  `DefaultProvider` answers `%{subject:, html_body:, text_body:}`, and
  `phoenix_kit_emails` validates exactly those three on every render. On an
  install with the stock templates seeded that broke registration confirmation,
  password reset and email change, plus everything
  `Mailer.send_from_template/…` sends. It surfaced as a guest checkout bouncing
  the shopper to an empty cart: the confirmation email raised after the order had
  committed and took the checkout LiveView down with it. The branch is now
  tested, including a test pinning the fallback branch so a future change cannot
  quietly swap which shape wins.
- **A trashed image could still be made the featured one** (#829, post-merge
  review). The three kebab entries hide the action while the trash listing is up,
  but the viewer sidebar had no such gate — and a trash tile clicks straight
  through to the viewer — so a host could persist a pointer to a file already
  queued for deletion. The sidebar button now reads the file's own status, which
  also covers a file trashed in another session while the listing is stale.

### Changed

- `preview_card_body/1` no longer takes a required `:target` (#827, post-merge
  review). The body renders no event of its own — slide switching is
  client-side, and the Close button lives in the modal's action row — so inline
  embedders were being made to pass a value that did nothing.
- The `:file_reference_sources` documentation now states that core ANDs each
  returned expression onto the orphan query **verbatim** (#828, post-merge
  review). The prose had promised a `NOT EXISTS` wrapper that the code never
  applied, contradicting its own example; a host that believed it and returned a
  positive `EXISTS` would have inverted the query and marked exactly its
  referenced files as the orphans.
- `MediaBrowser`'s `:featured` docs now state that a host funnelling every
  `{MediaBrowser, _, _}` message into `handle_parent_info/2` loses the message to
  that function's catch-all (#829, post-merge review) — silently, with the star
  still flipping in the UI, rather than failing in any way the host would notice.

## 2.29.1 - 2026-09-17

### Added

- **`mix phoenix_kit.update --no-start`** — migrate the database without
  starting the host application. A column-adding release creates a deadlock on
  any host whose supervision tree queries at init: the newly compiled schema
  module selects a column the database has not got, so the `app.start` the full
  update needs brings the boot down with `ERROR 42703 (undefined_column)`, and
  the updater that would add the column never runs. (`update_mode: true` stands
  PhoenixKit's own supervisor down, but it has no say over the host's
  children.) The flag runs the two steps that need no application — generate
  the chain step-up migration (`phoenix_kit.gen.migration` reads the version off
  the migration filenames, never the database) and apply it with `ecto.migrate`,
  which starts the repo alone. Configuration repair, asset rebuild and module
  migrations are skipped and reported; re-run the full update once the host
  boots again.

### Changed

- **`mix phoenix_kit.status` names the way out** when the core schema is behind
  the code. Its bare `Next: mix phoenix_kit.update` walked hosts straight into
  the deadlock above; it now points at `--no-start` beside it. Core gap only —
  a module-only gap leaves `phoenix_kit_users` intact, which is what hosts
  actually query at boot.
- **`mix phoenix_kit.doctor` explains a 42703 boot failure** instead of
  surfacing it raw as an application bug, then re-raises unchanged so the exit
  status and stacktrace are untouched.

## 2.29.0 - 2026-09-17

### Added

- **Title and description in the media viewer's sidebar** (#825). The file's own
  words about itself lived only on the admin detail page; the viewer popup —
  where people actually look at the file — showed the technical row (type, MIME,
  size) and nothing human. A collapsible "Title & description" section now sits
  between the action buttons and that row: an inline editor in the contexts that
  already offer a road to the metadata editor (`details_path` / `edit_target`
  hosts), read-only elsewhere, and absent entirely when it is both empty and
  uneditable. It opens itself when there is something to see.
  - Writes go into the file's `metadata` JSONB under the same keys the detail
    page's editor uses, so the two surfaces read each other's edits, and they
    MERGE into the row's current metadata — rotation and tags survive a title
    edit. The write re-reads the row; the parent-passed map carries no metadata.
  - Seeding rides the mount read the rotation already did: one `Storage.get_file`
    for both, where there used to be one for rotation alone.

- **A user's Google address** (`google_email` on `phoenix_kit_users`, V196).
  Sharing something with a user through Google — a Drive file, a calendar
  invite — needs the address their Google account answers to, which is not
  always the address they registered with.
  - `PhoenixKit.Users.Auth.google_email/1` resolves it: the stored address,
    else the account email when that is itself `@gmail.com` /
    `@googlemail.com`, else `nil`. Nothing else is guessed — a share sent to
    an address with no Google account behind it is a share the user never
    receives.
  - Editable by the user on their settings page and by an admin on the user
    form, and filled in automatically the first time the user signs in with
    Google (never overwriting a value already there).
  - V196 backfills it from existing linked Google sign-ins, so those users
    start filled instead of waiting for their next sign-in.
  - It is not an identity: optional, not unique, and nothing authenticates
    against it. `email` stays the identity.

### Changed

- **Etcher pinned to 0.14.1** (#826) — `mix.lock` and the jsDelivr tag in
  `phoenix_kit.js` move together, per the pin discipline
  (`vendored_cdn_pins_test.exs`). Shaft labels now default to their line's
  colour, the dimension drops into a skippable label editor on release, the
  shaft breaks under the editor while typing instead of popping in at
  placement, and a label-prompted shape stays fresh so the label size chosen
  while typing becomes the tool's default. The `~> 0.14.0` requirement already
  admitted the patch, so `mix.exs` is unchanged.

### Fixed

- **The viewer's title/description editor accepted writes from hosts that never
  offered it** (#825 follow-up). The editability rule lived only in the
  template, so `save_media_details` wrote the shared file row for any sender —
  including an anonymous visitor of a readonly `MediaGallery` lightbox, which
  passes neither `details_path` nor `edit_target` and renders the section
  read-only. The handler now refuses that case outright, the same way the
  `can_annotate: false` clauses refuse annotation writes, and one predicate
  (`can_edit_media_meta?/2`) feeds both the template and the handler so they
  cannot drift.
- **The viewer metadata suite never ran** (#825 follow-up). Its `Storage.File`
  fixture omitted three required fields, and the setup returned the row under
  `:file`, a reserved ExUnit context key — so both DB tests died in `setup` and
  the merge-don't-replace guarantee they exist to prove was never checked.
  Fixed, with new tests covering the gate above.
- **The sidebar's save status could be wiped by a stale timer** (#825
  follow-up). A second Save inside the two-second auto-hide window left the
  first save's timer alive to clear the status the second one had just put up.
  Token-guarded now, like the rotation pill beside it.

- **Three translations were wrong in all seven locales.** A catalog merge had
  copied a near neighbour's translation onto new strings: "Channel" read as
  "Cancel" (`Отмена`, `Abbrechen`, `Annuler`, …) and "Could not save the
  linked chats" had lost the "linked chats" half. Fuzzy entries are served,
  so these shipped silently. (#822 follow-up)

## 2.28.2 - 2026-09-17

### Changed

- **Tessera 0.3.7** (#824). The deep-zoom viewer now picks its image size by
  device pixels, so hiDPI displays open on a sharp enough image. On a 4K
  monitor at 200% scaling, the viewer now loads the original instead of
  stretching `large`.

### Fixed

- **The viewer warms the neighbouring originals on hiDPI displays too**
  (#824). When deciding whether a neighbour's original is worth fetching in
  advance, the viewer now multiplies the column width by `devicePixelRatio`,
  matching Tessera 0.3.7. Before, a hiDPI screen stepped onto a multi-MB
  original nobody had fetched yet.
- **Two JS test files never ran in `mix precommit`.** `mix test.js` only picks
  up `*.test.cjs`, so it skipped `neighbor_prefetch_test.cjs` and
  `transport_cache_test.cjs`. Both are renamed. The Phoenix fallback-key test
  also pointed at the wrong `deps/` path, and that is fixed. (#824 review)
- **`swoosh` is back on 1.28.1.** The #824 merge had moved it back to 1.28.0
  in `mix.lock`. (#824 review)

## 2.28.1 - 2026-09-17

### Fixed

- **A redaction no longer leaves the unredacted image at its public bucket
  URL.** Before, the first edit of an image moved the original's rows to the
  hidden backup but left its objects where they were. On a public bucket,
  file URLs redirect to those objects, so any saved link still showed the
  unedited original and its variants.
  - The first edit now copies the unedited objects to private
    `unedited_<random>_*` keys and deletes the served keys once nothing
    references them.
  - A backup made by 2.28.0 moves on its next edit.
  - Responses a CDN or browser already cached can't be revoked. Purge on
    `[:phoenix_kit, :storage, :file_edited]` telemetry (see the storage
    README, "Editing images"). (#821 review)

## 2.28.0 - 2026-09-17

### Added

- **Image editor** (#821). Crop (drawn or by aspect preset), quarter turns,
  mirror/flip, straighten, brightness/contrast, and hide areas with blur,
  pixelate or a black box. It opens from the media browser's grid, list and
  stack menus, the viewer sidebar, and the media detail page (`?edit=image`).
  Details:
  - An edited image keeps its uuid, and its unedited original moves to a
    hidden system-managed backup. From the editor you can download (signed
    link), restore or delete that original.
  - Redaction coarsens the area before scaling it back, so it can't be
    undone. Edited images lose EXIF (GPS included), XMP, IPTC and comments.
  - `PhoenixKit.Modules.Storage.ImageEditing` is the API (`edit`, `revert`,
    `retry`, `save_copy`, `delete_unedited_original`). The media settings
    choose `keep_original` or `replace_original`.
  - `ApplyImageEditJob` renders from the unedited original and swaps the
    result in one transaction. `edit_revision` guards every step.
  - `GET /api/files/:uuid/unedited` serves the unedited original to editors,
    or with a one-hour token bound to the user.
- **V195 migration** — image-editing columns on `phoenix_kit_files` (`edits`,
  `edit_revision`, `edit_state`, `original_file_uuid`, `edited_from_uuid`)
  and an index on `phoenix_kit_file_instances.file_name`. (#821)
- **Versioned file URLs** — `?v=` names the served checksum. Only a versioned
  URL is cached as `immutable`; a different `v` redirects to the current one.
  An unversioned URL keeps for a day, or is revalidated once the file has been
  edited. Tiles are stored under their version. Build URLs with
  `URLSigner.signed_url(uuid, variant, version: instance)`. (#821)
- **Modules can declare their Oban queues** with the optional
  `oban_queues/0` callback (`name: limit` or `name: [limit: n, kind: ...]`).
  (#821)
  - The installer generates its queue list from the declarations.
  - The updater adds only missing queues and never changes a limit the host
    set.
  - The doctor, and a one-time log line after boot, report declared queues
    that aren't running.
- **`{:phoenix_kit_require, requirement}` on_mount hook** — checks the scope a
  session-level mount left (`:authenticated`, `:owner`, `:admin`,
  `{:module, key}`) without mounting again, so public and signed-in pages can
  share one `live_session`. The `ensure_*` hooks keep their behaviour.
  Stacking the kit's hooks no longer raises "hook :current_page already
  attached". (#821)
- **`Settings.subscribe/0`** — every committed settings change broadcasts
  `{:setting_changed, key, value}` (secrets as `:redacted`), and a delete
  broadcasts `{:setting_deleted, key}`. ⚠️ A `phoenix_kit:settings`
  subscriber whose `handle_info` has no catch-all clause will now receive
  messages it doesn't match. (#821)
- **`chart_lanes/1` and a public `ChartScale`** — HTML rows of bands that line
  up with `line_chart`'s x axis. `line_chart` gains an opt-in `hover` readout,
  still without JavaScript. (#821)
- **Locale routing contract** (`guides/locale-routing.md`):
  - The language lives in the URL, never in the session.
  - `LanguageSwitcher.locale_path/2` is public.
  - `goto_home` now works.
  - In development, the switcher warns once when a page shows a language its
    URL doesn't carry. (#821)
- **V193 migration** — composite partial indexes for the AI spend caps
  (`(endpoint_uuid, inserted_at)` and `(user_uuid, inserted_at)`, including
  `cost_cents`, for successful requests). (#821)
- **V194 migration** — withholds integration connection bodies (tokens)
  already copied into the settings history. (#821)

### Changed

- **Faster compile for `PhoenixKitWeb.Gettext`**: the backend now compiles one module per locale, in parallel (`split_module_by: [:locale]`). A clean phoenix_kit compile went from ~69s to ~20s, most of which went to this one file. Lookups through the backend are unchanged.

- Stored objects are deleted by reference, not by shared directory.
  `delete_file_completely/1` removes every key no remaining row references,
  checked and deleted under a per-path lock. It used to keep or leak whole
  directories. (#821)
- Auth pages set their own `page_title`, and the root layout no longer ships
  the `" · Phoenix Framework"` suffix. (#821)
- Tabs that share a permission key no longer log a re-registration warning
  per tab. (#821)
- `mix phoenix_kit.update` leaves a host's own `data-theme` script alone when
  updating the root layout. (#821)
- The sitemap falls back to the endpoint URL when `site_url` is empty.
  Placeholder hosts are never used, and localhost only on a dev server. (#821)
- The doctor probes for transaction poolers and reports how `/sitemap.xml` is
  served. (#821)
- Generated admin pages no longer assign `url_path`. (#821)

### Fixed

- A variant served in place of one not generated yet is no longer cached as
  `immutable` at the variant's permanent URL. Generation jobs are unique per
  file, and are enqueued inline instead of from a `Task`. (#821)
- A settings cache miss-fill can no longer re-cache a value a concurrent
  write just replaced. (#821)
- Integration connection bodies are no longer copied into settings history
  or broadcasts. (#821)
- `mix phoenix_kit.update` survives a boot-time `Registry.unregister_tab/1`
  call and a database pool that exits. (#821)
- The updater checks for a queue in this app's own Oban block, not the whole
  config file. (#821)
- Repair no longer misreports the V170 notification indexes or re-creates
  the deleted `billing_default_currency` / `shop_currency` seeds. (#821)
- Post-merge review of #821:
  - The image edit job no longer lets the uploader's file extension choose
    ImageMagick's coder. `x.mvg` uploaded as `image/png` was read as MVG.
  - A run Oban discards no longer fails a newer save's revision. That save
    now stays with its own run.
  - Retry re-renders the edit saved on the row, not the stale one a second
    tab showed, which could undo a newer redaction.
  - `open_image_editor` in `MediaBrowser` now checks the uuid, the
    `only_file_type` lock and system-managed files. It also stops building
    the editor scope on every render.
  - A non-string `?v=` is treated as a stale version instead of a 500.
  - The doctor read `site_url` in update mode, so it always reported it
    unset.
  - A pooler-looking config with no pooling detected warns again, because an
    idle PgBouncer can hide transaction pooling from the probe.
  - The switcher's session-locale warning now reaches hosts in dev. It used
    to be compiled out of every dependency build. It also no longer flags
    default-language host pages outside the mount.
  - `Install.Common` DB checks catch `:exit`.
  - Settings history fails closed when it can't tell whether a row is
    secret.
  - The magic-link registration title is translated.
  - The image-editing test suites actually run on ImageMagick 6. They probed
    for `magick` and "skipped" from `setup`, which ExUnit ignores.

## 2.27.2 - 2026-09-17

### Fixed

- **Form language tabs drop the country qualifier** (`Multilang.build_language_tabs/0`). With one dialect per language enabled, the tabs now read `English` / `German` instead of `English (United States)` / `German (Germany)`, matching the nav dropdowns. The qualifier comes back only when two dialects of the same language are enabled (e.g. `en-US` + `en-GB`).

## 2.27.1 - 2026-09-17

### Fixed

- **IPv6 clients are grouped by their `/64`** (`IpAddress.network/1`).
  Every address in a `/64` belongs to one client, and the OS rotates a
  temporary address inside it daily:
  - per-IP rate limits (login, registration, magic link, password reset,
    confirmation resend, QR login, referral codes) now count per `/64`, so a
    fresh address per request no longer resets the limit
  - the session fingerprint no longer logs "changed IP" for a rotated
    address, and login alerts reuse the known-device row instead of adding
    one per rotation (Active Sessions matches by the same key)
  - loopback (`::1`), unspecified (`::`), and link-local (`fe80::/10`) stay
    per-address; well-known NAT64 (`64:ff9b::/96`) and IPv4-compatible
    (`::a.b.c.d`) unmap to the embedded IPv4, same as `::ffff:a.b.c.d`
  - known-device reuse hits the unique `(user, ip, ua)` index first and only
    scans same-UA rows by `/64` when grouping is coarser than the address
- `IpAddress.extract_ip_address/1` printed IPv6 as decimal groups
  (`"8193:3512:1:0:0:0:0:1"`); it now prints standard hex (`"2001:db8:1::1"`).

## 2.27.0 - 2026-09-16

### Added

- **Etcher 0.14 tools in the media viewer** — `:highlighter` and `:arrow`
  join the toolbar, and label font size is a per-user pref (clamped
  6–200px, whole pixels). Pins move to `etcher ~> 0.14.0`, a fresco
  `~> 0.12.0` alternative, and tessera 0.3.6. (#820)
- **V192 migration** — `phoenix_kit_annotations_kind_check` allows
  `'arrow'`. `down/1` refuses while arrow annotations exist. A new test reads
  the viewer's tool list, so a tool the schema can't persist fails CI. (#820)
- **The media viewer's file is in the URL** (`?file=<uuid>`) for url-synced
  browsers: a refresh reopens the viewer on that file, and Back closes it.
  Opening, stepping and closing the viewer skip the listing reload. (#820)

### Changed

- The media viewer opens faster (#820):
  - it opens on the `small` variant the grid already cached
  - an instant stand-in shows the card's bitmap while the server replies
  - grid cards warm their viewer variants on hover
  - the open viewer warms its neighbours' variants
  - the user row is read once per open instead of three times
- The folder sidebar collapses and expands client-side before the server
  round trip. (#820)
- The upload drawer closes itself once files are accepted. (#820)
- OS drag-drop uploads find their upload input from any nesting depth. (#820)

### Fixed

- Post-merge review of #820:
  - A `?file=` uuid missing from the loaded listing is now held to the
    browser's `scope_folder_id`, its `only_file_type` lock and the
    system-managed filter. Before, a scoped picker opened any file in the
    install by uuid. A malformed uuid no longer crash-loops the mount.
  - V192 stamps version `192` (it stamped `191`, and `190` on rollback, left
    over from its pre-merge number). A new test checks every migration's
    version comment.

## 2.26.1 - 2026-09-16

### Fixed

- `PhoenixKit.Utils.Number.parse_decimal/2` and `format_decimal/1` no longer
  return a whole number in exponent form: `"10"` used to parse to `1E+1`,
  which is `Decimal.equal?/2` to `Decimal.new("10")` but not `==` to it, and
  printed as `1E+1` through `to_string/1` and Jason. Trailing fraction zeros
  are still stripped (`"2.500"` → `2.5`). (#819)

## 2.26.0 - 2026-09-16

### Added

- **`<.decimal_input>`** (`PhoenixKitWeb.Components.Core.DecimalInput`) — a
  form control for quantities, prices and measurements, where a comma and a
  dot must both work and nothing may be rounded. It renders
  `type="text" inputmode="decimal"` in place of a browser number control,
  whose separator follows the page locale and whose `step` blocks submits.
  It takes an optional `unit` suffix, and the text a person typed survives a
  re-render unchanged. Otherwise it matches `<.input>`: FormField or raw
  name/value, label, translated errors, `class` / `wrapper_class`. (#818)
- **`PhoenixKit.Utils.Number.parse_decimal/2`** (plus `parse_decimal!/2` and
  `format_decimal/1`) — turns typed text into a normalized `Decimal`. A comma
  or a dot is the decimal point, and space / dot / comma grouping is accepted
  only between 3-digit groups. It takes `:min` / `:max` and never clamps.
  Exponents, `NaN`, hex and values of 10¹² or more are refused, and input
  over 64 bytes is rejected before any parsing. It returns
  `{:error, :empty | :invalid | :below_min | :above_max}`. (#818)

### Fixed

- Post-merge review of #818: space grouping is now held to the same 3-digit
  rule as dot/comma grouping (`"12 34"` and `"1,234 567"` were silently
  merged into `1234` and `1.234567`), and a negative zero is returned
  unsigned so the field never shows `-0`.

## 2.25.0 - 2026-09-16

### Added

- **Who added a user** — `phoenix_kit_users.created_by_uuid` (migration
  **V191**: self-referencing foreign key, `ON DELETE SET NULL`, indexed),
  shown as "Added By" on the admin user details page. Backfilled from the
  `user.created` activity entries the admin form has always logged, as far
  back as activity retention kept them. Set only by the new
  `Auth.admin_create_user/2`; never cast from params, so a public sign-up
  cannot claim an admin added it.

### Fixed

- **Admin "Create User" left the admin on a refilled form.** Anything that
  raised after the insert (the confirmation mailer is the unguarded step)
  crashed the LiveView; form recovery
  refilled every field, and a second submit reported the email as taken. The
  email send is now rescued (a failed send shows a warning flash instead of
  claiming it was sent), and a successful create navigates to the new user's
  page instead of the users list.
- **Admin user creation no longer counts against the registration rate
  limits.** The admin form went through the anonymous sign-up limiter, so an
  admin adding more than ten users an hour was refused — and used up the
  public sign-up budget of their own IP.

## 2.24.0 - 2026-09-16

### Added

- **Media reorganizer** (#815) — moves every module's legacy media folders to
  where the host's `attachments_parent_folder` / `attachments_folder_name`
  hooks now put new ones.
  - `mix phoenix_kit.media.reorganize` — dry-run by default (prints a
    per-`{source, kind}` summary table plus details); `--apply` writes,
    `--source <module_key>` (repeatable) narrows the run, `--pending-days`
    sets the stale-pending-folder threshold (default 7). Options are
    validated before the app starts; an unknown or disabled `--source` key
    is an error. Exits 1 when `--apply` leaves any action `:failed` or
    `:conflict`.
  - `PhoenixKit.Modules.Storage.Reorganizer` engine — each action runs in its
    own transaction against a `FOR UPDATE` re-read of the folder, re-verifies
    the plan-time file/link counts before and after the write, and never
    halts the run on a raising source, a failed action or a naming conflict.
    Nothing is hard-deleted: `:trash` only soft-deletes a folder still empty
    at apply time. Moving a trashed folder restores the subtree trashed with
    it. `on_conflict: :suffix` picks a free `"name (N)"`.
  - `PhoenixKit.Modules.Storage.Reorganizer.Source` behaviour — the full
    contract for module implementations (hook failures, claims, duplicates,
    pointer back-fill, stale pending folders, query cost) lives in its
    moduledoc. Actions are plain maps validated by `Reorganizer.Action`, so a
    module never compiles against core's action struct; unknown keys are
    dropped with one warning.
  - New optional `PhoenixKit.Module` callback `media_reorganizer/0`
    (default `nil`), collected from enabled modules by
    `ModuleRegistry.all_media_reorganizers/0`.

### Fixed

- **Reorganizer summary no longer hides a back-fill's rename or restore.** A
  move carrying `after_move` always reports outcome `:backfilled`, and the
  `renamed` / `restored` columns were derived from that single outcome, so a
  back-filled action that also renamed or un-trashed its folder counted in
  neither. Applied actions now carry an engine-internal `changes` list
  (`:moved` / `:renamed` / `:restored`) that the summary and the details
  section read.

## 2.23.3 - 2026-09-15

### Added

- **`mix package.clean`** deletes the `phoenix_kit-*.tar` tarballs that
  `mix hex.build` / `mix hex.publish` leave in the project root (64 of them,
  199 MB, had piled up). It runs as the last `mix prerelease` step; run it by
  hand after a bare `mix hex.publish`. The `.gitignore` entry for them, a
  leftover `phoenix_module_template-*.tar` from the template repo, now names
  `phoenix_kit-*.tar`.

- **`mix precommit` now compiles the test tree** via a new `test.compile`
  alias, run between `deps.unlock --check-unused` and `quality.ci`. No
  existing gate step ever *compiled* `test/**/*_test.exs`: `format` and
  `credo` only parse them, `compile` and `dialyzer` see `elixirc_paths`
  (which covers `test/support`, not the `.exs` test files), and ExUnit is
  the only thing that compiles those — so a test file that is valid syntax
  but fails to compile (a duplicate `describe` name, for example, which
  ExUnit rejects at `defmodule` time) passed every step and only surfaced on
  the next `mix test`. The alias compiles every test file with
  `Kernel.ParallelCompiler.compile/1` in a `MIX_ENV=test` subprocess,
  deliberately without `test_helper.exs`: no `ExUnit.start`, no database
  probe, no migration, zero tests run, so it cannot go red from the
  environment — only from a genuine compile error in `test/`. `mix test`
  itself is still not part of `precommit`; see AGENTS.md "CI/CD".

### Fixed

- **Stored originals keep their extension when copied out for processing.**
  `Storage.retrieve_file/1` — and `Manager.retrieve_file/2` without a
  `:destination_path` — wrote the temp copy as `phoenix_kit_<random>`, with no
  extension. ImageMagick identifies some formats by extension alone, ICO
  among them, so `ProcessFileJob` failed every variant of an `.ico` upload
  with `identify: no decode delegate for this image format` and the job was
  discarded, even where ImageMagick reads ICO. The temp copy now carries the
  stored original's extension, as `Manager.replicate_to_buckets/3` already
  did. `AnnotationThumbnail` reads its source through the same call (#817).
  Only a media extension (image, video, audio, PDF — `Manager.temp_extension/1`)
  is kept: the extension is the uploader's filename, and it also selects the
  ImageMagick coders that have no magic bytes (MVG, MSL, TXT), which an
  extensionless copy never reached — a `.mvg` uploaded as `image/png` is
  stored as an image and would have been handed to `identify` as MVG.
- **A missing `pdftoppm`, `pdfinfo`, `identify` or `ffmpeg` is reported as not
  installed.** `System.cmd/3` raises `ErlangError` with `:enoent` in
  `original` and `reason: nil`; `PdfProcessor` and `System.Dependencies`
  checked `reason`, so the not-installed branch never ran — a host without
  poppler logged `pdftoppm error: nil` for every PDF, and
  `check_imagemagick/0` / `check_ffmpeg/0` returned
  `{:error, "Error checking …: nil"}` instead of `{:error, :not_installed}`.
- **PDF uploads are processed again on hosts that have poppler.**
  `ProcessFileJob` merged pdfinfo's string-keyed fields (`"page_count"`,
  `"author"`, …) into the atom-keyed `%{status: "active"}` update, and
  `Ecto.Changeset.cast/3` rejects a mixed-key map — so every PDF job raised
  `Ecto.CastError` on the metadata step and was discarded after three
  attempts, before any preview variant was rendered. Without poppler
  `extract_metadata/1` returns `%{}` and the merge happened to be clean, which
  is why the crash only showed up once the tool was installed. The fields now
  go into the file's `:metadata` map (`PdfProcessor.file_attrs/2`) (#816),
  filling only keys it doesn't already hold — `"title"` is also the
  user-editable title the media detail page saves there, and a re-processed
  PDF must not replace it with the document's own Title.

## 2.23.2 - 2026-09-15

### Added

- **Hosts can choose the folder core's own uploads land in** (#813).
  `config :phoenix_kit, :uploads_parent_folder, {Mod, :fun}` is called as
  `fun(kind, actor_uuid, subject)` (or `fun(kind, actor_uuid)`) with `kind`
  `:avatar` or `:branding` and returns `{:ok, folder_uuid}` or `nil` for the
  storage root (the default). `Auth.update_user_avatar/4` places the stored
  avatar there; the user form's avatar picker and the logo / site-icon /
  auth-background pickers on `/admin/settings` and
  `/admin/settings/authorization` pass the answer to `MediaSelectorModal` as
  `scope_folder_id`. Note that `scope_folder_id` also scopes browsing, so once
  the hook is configured those pickers list only files under the returned
  folder. An answer that is not a live folder (not a UUID, no such folder, or
  trashed), or a hook that raises or exits, falls back to the root.
- **The standalone media selector accepts `?scope_folder=<uuid>`** (#813) and
  attaches uploads made from it to that folder; a malformed, missing or
  trashed folder is ignored. `MediaSelectorHelper.media_selector_url/2` takes
  a matching `:scope_folder` option.
- **Annotation-comment attachments can be placed by the host** (#813) through
  `config :phoenix_kit_comments, :attachments_parent_folder`, called with
  `:annotation_attachment` and `%{resource_type: "file", resource_uuid: uuid}`.
- **Storage moduledoc: folder conventions for module packages** (#813) — the
  parent-folder and folder-name hooks, the lookup order for an object's
  folder, and leaving re-parenting to the host.

### Fixed

- The upload placement hook is consulted when a picker opens, not in
  `mount/3`, so viewing a settings page or the user form no longer runs a
  host hook (which may create a folder) twice per load.
- A hook answering a folder that no longer exists no longer crashes
  `Auth.update_user_avatar/4` after the file was stored, nor the picker's
  upload.
- The standalone media selector logs a failed scope-folder attach instead of
  discarding it.

## 2.23.1 - 2026-09-13

### Changed

- **A module whose database schema is newer than its code is now reported
  as "ahead of code", not "up to date"** (#806).
  `PhoenixKit.Migrations.Modules.classify/2` returns a new `:ahead_of_code`
  status for `installed > target` (a rollback, or a dependency pinned
  backwards), with a matching `Modules.ahead_of_code/1` filter.
  `mix phoenix_kit.status` shows it in red with a new
  `{:modules_ahead_of_code, names}` next action; `mix phoenix_kit.doctor`
  warns; `mix phoenix_kit.update` names it instead of printing "up to date".
  When another module is genuinely behind, `update` is still the next action
  and the ahead module is listed as an extra reason. Note:
  `mix phoenix_kit.status --exit-code` exits non-zero for this state, as it
  does for every non-Ready action, so a deploy gated on it fails after a
  code rollback past a module migration.
- **Apple Sign-In and billing-provider secrets are encrypted at rest**
  (#807). `oauth_apple_private_key`, `billing_stripe_secret_key`,
  `billing_stripe_webhook_secret`, `billing_stripe_api_key`,
  `billing_paypal_client_secret`, `billing_paypal_webhook_secret`,
  `billing_razorpay_key_secret`, `billing_razorpay_webhook_secret` and
  `billing_everypay_api_secret` join `restricted_setting_keys/0`, so writes
  through `Settings.update_setting/2` store `enc:v1:` ciphertext and
  `Settings.get_setting/2` decrypts. phoenix_kit_billing reads every one of
  them through `get_setting/2` and needs no change. Existing plaintext values
  keep reading correctly and are encrypted on the next save or
  `mix phoenix_kit.integrations.rotate_key`. The public identifiers (Stripe
  publishable key, PayPal client/webhook ID, Razorpay key ID, EveryPay
  username/account) stay unencrypted. A new test-support perimeter scan
  asserts that every secret-shaped setting key core references or seeds is
  restricted.

### Fixed

- **Settings batch reads now actually fill cache misses from the database**
  (#810). `Settings.get_settings_cached/2` and `get_json_settings_cached/2`
  looked for a missing key in `Cache.get_multiple/3`'s result, but that
  function returns every requested key and substitutes the default on a
  miss, so a miss was never detected. A cold or expired cache read as `nil`
  for every key without querying the database. This affected every
  `get_settings_cached/2` caller, including phoenix_kit_web_analytics and
  phoenix_kit_publishing. Misses are now detected with a sentinel. A
  restricted key that fails to decrypt is answered but not cached, so the
  next read retries, matching the boot warmer. A JSON read of a row with no
  JSON value now caches `nil` instead of "not found".
- **Activity feed order is stable when timestamps tie** (#809).
  `Activity.list/1` and `Activity.recent/1` sorted by `inserted_at` alone,
  so rows with the same timestamp (every pre-V185 whole-second row) could
  come back in any order. They now add `uuid` as a tiebreak.
- **A blocked role-permissions click shows a translated reason** (#805). The
  Roles page flashed the raw error atom (`owner_immutable`). The message
  mapping moved from `PermissionsMatrix` to
  `Permissions.edit_role_permissions_error_message/1`, and both pages use it.
- **The OAuth "Test Credentials" button now actually tests the credentials.**
  It compared each field to `""` and nothing else, so a 9-character Google
  client secret — or a field containing only a space — read as "properly
  formatted" while Google itself answered the same values with 401
  `invalid_client`. For Google, the button now POSTs the current client
  ID/secret to `oauth2.googleapis.com/token` with a deliberately invalid
  authorization code and reads Google's own verdict: `invalid_client` means
  the credentials are wrong; `invalid_grant` means they are right (only the
  fake code was rejected, as expected) — this "right credentials" leg
  follows from Google's documented error definitions and was not itself
  exercised against a real registered app, and falls back to inconclusive
  if Google ever answers a correct pair with anything else. No
  `redirect_uri` is sent — this used to send an RFC 2606 `.invalid`
  placeholder, which fails Google's "Host TLDs must belong to the public
  suffix list" redirect-URI rule and came back `invalid_request` regardless
  of the credentials, making the check permanently inconclusive; a
  placeholder on a real public-suffix host was not affected (verified
  live with fabricated credentials: `example.com`/`localhost` and no
  `redirect_uri` all answered the same `invalid_client`). A third outcome
  — could not reach Google, or a response that isn't cleanly one of the two
  verdicts above — is reported as inconclusive (a distinct `:inconclusive`
  result, shown as a warning rather than an error flash), never folded into
  either a pass or a fail. GitHub and Facebook keep the previous
  format-only check (now actually enforcing it — see below) rather than an
  unverified live check against their token endpoints.
- **A short or blank-looking OAuth secret is now rejected on save**, not just
  by the button. `PhoenixKit.Users.OAuthConfig.validate_secret_format/2`
  rejects a value that is only whitespace or implausibly short (under 16
  characters — real secrets from all three providers are at least 24) before
  `PhoenixKitWeb.Live.Settings.Authorization` persists it; the generic
  settings schema (`PhoenixKit.Settings.Setting`) is deliberately left alone,
  since a Google-secret-shaped format check does not belong in a schema
  shared by every setting in the app. A secret already saved before this fix
  does not retroactively block saving an unrelated field. A secret with
  leading/trailing whitespace (a copy-paste artifact) is now trimmed before
  it is persisted or tested, instead of being saved and sent to the
  provider padded.
- **OAuth test-result messages are now translated.** The success message was
  never wrapped in `gettext` — a translated button produced an English
  response, and the wording ("...properly formatted. Initiate OAuth flow to
  test actual connection.") was easy to mistake for "this works" at a glance.
  All three providers' messages, on all three (now honest) outcomes, are
  gettext-wrapped, along with the adjacent "Reload Config" flash and the
  "Test Credentials" button name repeated in the on-page setup instructions.
- **Post-merge review fixes (#808, #807).** The nine new OAuth msgids had
  never been extracted, so every locale still rendered them in English. They
  are now extracted and translated into de/es/et/fr/it/pl/ru. The Google
  credential check no longer logs an exit/throw reason verbatim (a
  `GenServer.call` exit reason embeds the call's arguments), matching the
  `rescue` branch's rule. The secret-key perimeter test no longer runs under
  `DataCase`, which had silently excluded it on database-less runs.

## 2.23.0 - 2026-09-13

### Added

- **Active role: users act as one role at a time, per session** (opt-in,
  `role_switcher_enabled`, default off). A user holding two or more switchable
  roles acts as exactly one of them, and `Scope.for_user/1` narrows
  `cached_roles` and `cached_permissions` to that role plus the always-on roles
  — an Admin acting as "Seller" has no admin access until they switch back.
  Owner and Admin are always switchable; User is always on; custom roles are
  switchable unless listed in `role_switcher_always_on_roles`. The choice is
  stored **on the session token** (`phoenix_kit_users_tokens.active_role_uuid`,
  V190): Admin on one machine and Seller on another at the same time, a role
  of its own for an impersonation session, a fresh start for every sign-in and
  every added multi-session account. It reaches `for_user/1` through
  `%User{active_role_uuid: _}`, a virtual field only the session-token loader
  fills, so every scope rebuild — plugs, LiveView mounts, the role-change
  refresh (now reloading through the session token), sibling packages —
  narrows without changes. A stored role the user no longer holds is ignored.
  New: `PhoenixKit.Users.ActiveRole`, `Scope.active_role/1`,
  `Scope.held_roles/1`, `Scope.narrowed?/1`, `Scope.switchable_roles/1`,
  `Scope.for_user(user, narrow: false)`, `Roles.get_user_role_records/1`,
  `Roles.get_role_records_for_users/1`, `Permissions.get_permissions_for_roles/1`;
  settings `role_switcher_enabled`, `role_switcher_location`,
  `role_switcher_always_on_roles`. Design and review record:
  `dev_docs/plans/2026-09-13-active-role.md`.
- **Role order** — `phoenix_kit_user_roles.position` (V190; seeded Owner,
  Admin, User, then custom roles by creation). Reordered on
  `/admin/users/roles` by dragging or with the arrows (`Roles.reorder_roles/1`,
  `Roles.move_role/2`); `Roles.list_roles/0`, `list_roles_paginated/1`,
  `get_custom_roles/0` and `get_user_role_records/1` follow it. It decides the
  **default role** of every new session — the first switchable role the user
  holds — and the order the switcher lists roles in.
- **Switching the active role** — `PUT /users/session/role` (`role_uuid`,
  optional `return_to`) through `ActiveRole.switch/3`: refused unless the
  switcher is on and the role is one of the user's switchable roles, written
  to that session's token only, logged as `session.role_switched`, and
  broadcast so every open LiveView of the user rebuilds its scope from its own
  token and leaves pages the new role cannot reach ("This page is not
  available in the role you switched to."). `return_to` is followed only when
  the new scope can mount it — admin-area paths are resolved through the
  router to their LiveView and asked the mount gate's own question, every
  role alike.
- **Removing a role signs out the sessions acting as it**
  (`Sessions.revoke_user_sessions_in_role/2`, from `Roles.remove_role/3` and
  `sync_user_roles/3`): the person starts over in whatever they still hold.
  Sessions in another role keep going and refresh in place.
- **The role switcher UI** — `PhoenixKitWeb.Components.Core.RoleSwitcher`. A
  "Role" section under Language in both account dropdowns
  (`AdminNav.admin_user_dropdown/1`, `UserDashboardNav.user_dropdown/1`), and
  with `role_switcher_location` set to `"header"` a compact control in the
  admin and dashboard headers from `sm` up, the menu section taking over on
  phones. Renders only for a narrowed scope — an impersonation session
  included; the switchable roles ride on the scope
  (`Scope.switchable_roles/1`), so it costs no query per page. The
  multi-session account list labels each account with the role its session is
  acting as.
- **Sessions lists show the role each session acts as** — `Sessions.*` rows
  carry `active_role`; `/admin/users/sessions` and the user's own devices list
  render it beside the device.
- **A "Roles" tab on `/admin/settings/users`** for the `role_switcher_*`
  settings: the on/off switch, the switcher location, and which custom roles
  are always on (Owner, Admin and User are fixed and not offered). Guide:
  `dev_docs/guides/2026-09-13-active-role.md`.

### Changed

- **`Roles.list_roles/0` and `list_roles_paginated/1` order by role order**
  (`position`, then name) instead of system-roles-first-then-name. The seeded
  order is the same for an untouched install.

### Fixed

- **Permanently deleting from a folder's trash view no longer destroys a file
  merely linked in from another scope** (post-#804 review): the single-file
  delete now requires the file's home in scope, like the bulk delete always
  did; a linked file in this folder's trash is unlinked instead. Rotation,
  which is written on the file, again requires the file's home in scope
  rather than only its appearance in the viewed folder.
- **The parked "Wrong email? Change it" form asks for the password when
  email confirmation is not enforced.** With `require_email_confirmation` off
  an unconfirmed account is fully usable, so the password-less path (2.22.7)
  would have let a stolen session re-address a live account. Confirmation
  enforced keeps the password-less path.
- **A stolen copy of the session cookie survived a password change** on the
  submitting browser's token, which 2.22.18 exempted from the disconnect so
  the re-login could go out. `Session.create` now disconnects that token five
  seconds after the new one is issued (`Sessions.disconnect_tokens_later/2`).
- **The LiveView scope refresh handed a deactivated user a fresh scope.**
  `reload_session_user/2` now passes through `ensure_active_user/1` like every
  other token/user resolution.
- **An Admin acting as another role could still impersonate.** The
  impersonation authority now reads the root session's roles in effect, so it
  follows the active role even for a hand-crafted POST. Targets are still
  judged by their real roles.
- **"You cannot edit your own role" ignored roles you hold but are not acting
  as.** `Permissions.can_edit_role_permissions?/2` now checks
  `Scope.held_roles/1`.
- **A role or permission change emptied the header's account switcher** until
  the next full page load: the LiveView scope refresh rebuilt the scope
  without the multi-session fields. They are now carried over.
- **The time-zone alert replaced the whole `custom_fields` map** from the
  socket's user struct, silently restoring stale values of every other key a
  concurrent tab had changed. It now merges its one key atomically
  (`Auth.merge_user_custom_fields/3`).

## 2.22.24 - 2026-09-12

### Changed

- **Etcher pinned to 0.13.2** (#803) — `mix.lock` and the `ETCHER_CDN` tag in
  `priv/static/assets/phoenix_kit.js` move together. Both media-viewer embeds
  (the lightbox and the `viewer_only` page) pass the new
  `panel_offset={%{top: 56}}`, so Etcher's style-panel chevron anchors below
  the viewer's details button instead of sharing its row.
- **The media viewer's sidebar toggle sits on the viewer/sidebar seam** (#803)
  on desktop with the sidebar expanded, hosted in a zero-width column between
  the panels (the viewer clips and the sidebar scrolls, so neither can hold it).
  Collapsed and stacked-mobile layouts keep the in-viewer button. The prev/next
  arrows gained 16px of inset from the image edge.

### Fixed

- **The `:fresco`, `:tessera` and `:etcher` requirements now stop at the pinned
  minor** (#802) — the same patch-less-`~>` bug 2.22.21 fixed for `:leaf`:
  `~> 0.10`, `~> 0.3` and `~> 0.9` each meant `< 1.0.0`, letting a host float
  the Elixir half past the exact jsDelivr tag core serves the browser half
  from. `vendored_cdn_pins_test.exs` now holds every pinned sibling's ceiling
  to its pinned minor. Resolution is unchanged.
- **The `:etcher` floor is raised to 0.13.2.** Core's markup passes
  `panel_offset` (Etcher 0.13.2) and `connectors={:off}` (0.12.2), and
  `phoenix_kit.js` bridges `etcher:tooltip-action` (0.13.0), but the
  requirement still admitted 0.9.0. A host whose lock held etcher 0.12.x kept
  it through `mix deps.update phoenix_kit`: the attrs were silently dropped
  (connector anchors reappeared on the lightbox) and the 0.13.2 bundle ran
  against a 0.12 server half. Such a host now gets a resolver error naming
  etcher instead.

## 2.22.23 - 2026-09-12

### Fixed

- **The inactive account rows in the user dropdown still sat a few pixels right
  of everything else.** The row that switches accounts is a `<button>`, which
  inherits the user-agent `text-align: center`, and the email inside it is
  `flex-1` — so an email shorter than its column centred itself and drifted
  right of the active row, which is a `<div>` and starts at the text edge. The
  effect scaled with how much slack the email had, which is why it survived the
  structural alignment fix in 2.22.22. The button now carries `text-start`.

## 2.22.22 - 2026-09-12

### Fixed

- **The account switcher in the user dropdown is aligned and legible again**
  (both `AdminNav.admin_user_dropdown/1` and `UserDashboardNav.user_dropdown/1`,
  which carried byte-identical markup and so carried identical bugs).
  - **"Add account" wore a gear icon** — `icon_settings`, the same glyph as the
    Settings row above it, reading as a second settings entry rather than an
    action. It is now `icon_user_add`.
  - **The active and inactive rows were built differently and did not line up.**
    The active row put its padding on the `li`'s direct child; the inactive row
    split it across a wrapper and a `<button>` two levels deeper, so daisyUI's
    own menu-child padding landed on each differently and the emails drifted a
    pad's width apart. The wrapper is now the only `li > *` and carries the
    `!p-0` reset (the idiom the in-menu language list already used), with every
    bit of spacing on an inner row that is structurally identical in both
    branches.
  - **The role badge on the active row was invisible** — `badge-ghost` renders
    as `base-200` and the row's own background was `base-200`, so the current
    account's role read as bare text while every other row showed a chip.
  - **Role badges now share a right edge**: the active row reserves width for
    its check mark, the inactive rows gained a matching spacer.
  - **Rows no longer change width with their remove button.** The trailing slot
    is a fixed width rendered on every row as soon as any account is removable
    (empty on the active and root rows), so the email column stops stepping in
    and out down the list. The literal `✕` character became `icon_x_thin`, and
    the button gained an `aria-label` naming the account it removes.
  - The active account now takes the `bg-primary` treatment the active language
    row above it already used, instead of a grey highlight — one active style
    per menu.

## 2.22.21 - 2026-09-11

### Changed

- **Leaf pinned to 0.8.0** (#801) — `mix.lock` and the `LEAF_CDN` constant in
  `priv/static/assets/phoenix_kit.js` move together to `leaf@v0.8.0`, bringing
  the atomic-chip editing batch: hand-typed preserved tags chip when the cursor
  leaves the line, chips are click-selectable (Backspace deletes, Enter opens a
  paragraph after, arrows step the caret out), and Ctrl+Backspace/Ctrl+Delete
  word deletion works in hybrid source blocks. Riding along: a wiki link can be
  typed in a row that already holds a markdown link, and the toolbar heading
  button edits the source in hybrid mode so it survives leaving the line.

### Fixed

- **The `:leaf` requirement now has the ceiling its comment always claimed.**
  Every alternative was patch-less — and `~> 0.5` means `>= 0.5.0 and < 1.0.0`,
  not "the 0.5 line", so that one alternative swallowed the whole 0.x range and
  made the `or ~> 0.6 or ~> 0.7 or ~> 0.8` enumeration after it inert. This
  matters more than for an ordinary dep: core serves leaf's browser half from an
  exact jsDelivr tag while Hex resolves the Elixir half, so an open ceiling let
  a host float the server half past the frozen bundle the day leaf 0.9 shipped —
  the silent cross-version editor the pin exists to prevent. The requirement is
  now `~> 0.4.1 or ~> 0.5.0 or ~> 0.6.0 or ~> 0.7.0 or ~> 0.8.0`
  (`>= 0.4.1 and < 0.9.0`); resolution is unchanged at leaf 0.8.0 and `mix.lock`
  did not move. `leaf_bundle_pin_test.exs` gained a test that rejects the next
  minor above the CDN pin, which the old floor-only check could never catch.

## 2.22.20 - 2026-09-11

### Fixed

- **Changing your password no longer signs you out of the tab that submitted
  the form.** The session-revocation fix in 2.22.18 broadcasts LiveView's
  `"disconnect"` (a page reload) for every token it deletes. The settings form
  still needs that socket: `phx-trigger-action` POSTs the re-login, and a
  reload here lands on a remember-me cookie pointing at a token that was just
  deleted. Other devices still close immediately; the submitting browser is
  skipped via `update_user_password/4`'s `:except_token`.

## 2.22.19 - 2026-09-11

### Security

- **The three endpoints that send mail to anyone who asks are no longer
  throttled per address alone.** Magic link, password reset and confirmation
  resend each counted hits per email address, while login and registration
  already counted per IP too. An address bucket cannot see a spray: ten
  thousand addresses take one hit each, no bucket ever fires, and the install
  sends ten thousand emails — mailbox flooding for the people named, and
  sender-reputation and mailer-quota damage for the operator. Each endpoint now
  has three buckets:

  - **per address** (unchanged, 3 per 5 minutes) — stops one person being
    hammered;
  - **per IP** (new, 10 per 5 minutes) — stops a spray from one host;
  - **per install** (new, 300 per hour) — the total the site will send at all,
    whoever asks and from wherever. A botnet with a fresh address and a fresh
    IP per request walks through the first two; only this bounds the mail bill.

  The site-wide cap is charged **last**, by requests the narrower two already
  allowed. Charged first, an attacker hammering a single address — refused, and
  sending nothing — would drain the allowance for everybody else, which is the
  one way a site-wide limit becomes an attack in itself. It trips loudly (a
  logged error naming the setting to raise), and is meant as a circuit breaker:
  raise it before anything that sends a crowd to the forgot-password form at
  once, such as a forced credential rotation. `nil` switches it off. All of it
  is tunable under `config :phoenix_kit, PhoenixKit.Users.RateLimiter`.

  Public pages capture the visitor's address during mount, which is the only
  point a LiveView can read connect info — captured anywhere else the bucket
  silently keys on nothing.

## 2.22.18 - 2026-09-11

### Security

- **Revoking a session now actually closes the tab it belongs to.** Every path
  that drops session tokens — "Sign out this device", "sign out everywhere",
  deactivating a user, an admin password reset, a password change, the
  external-proof confirmation — deleted the row and left any already-connected
  LiveView running. A socket keeps its assigns, an authenticated scope
  included, and goes on serving events until it re-mounts, so the account an
  operator had just cut off kept working in an open tab. Two defects stacked:
  the only function that broadcast the disconnect had no callers, and the
  broadcast itself resolved `PhoenixKitWeb.Endpoint` — a module that ships in
  this library but that nothing starts inside a host app, so it raised "no
  :pubsub_server configured", was swallowed by a rescue, and disconnected
  nothing anywhere. Disconnects now go to the host's endpoint (via
  `PhoenixKit.Config.get_parent_endpoint/0`) and are part of the token drain
  itself, so a future revocation path cannot forget them.

### Fixed

- **The user detail page names the account type and the organization.** "Basic
  Information" showed an "Account Type" row only for organization accounts, so
  the answer for everyone else lived in the summary card — not where you look
  first. A person account linked to an organization showed the organization's
  raw uuid; it now renders the organization's name as a link to it, the same
  way the summary card already did.

- **The account switcher no longer forgets accounts when the browser's session
  cookie goes away.** The multi-account stack lived only in the Plug session,
  which on a stock `mix phx.new` endpoint is a browser-session cookie — so at
  browser restart the remember-me cookie restored the one identity it holds and
  every account the user had added silently disappeared, with no error and
  nothing in the activity log. Added accounts are now mirrored into a second
  persistent cookie and the whole stack comes back with the remembered login.
  The mirror is written only for a browser that already holds a remember-me
  cookie (a deliberately session-only login stays session-only), is bound to the
  root token it was created under (so a stale mirror cannot attach itself to the
  next person who signs in on a shared computer), drops tokens that no longer
  resolve to an active user, and is cleared on logout, on a fresh login, and
  when `multi_session_enabled` is turned off. An impersonation is never
  mirrored: "sign in as this user" still ends with the browser session.

## 2.22.17 - 2026-09-11

### Added

- **An installed dashboards module can own the `/admin` landing page.** When
  one is present, enabled, and a dashboard is bound to the home place, it
  renders there instead of the built-in overview — live, so binding or
  unbinding one updates the page without a reload. Nothing changes on an
  install without that module.
- **Users can pick where they land after signing in.** A new "Start page"
  picker in profile settings lists the visitor's own visible, top-level admin
  tabs; the choice is honored on every login/magic-link/OAuth sign-in, after
  an explicit return-to destination and before the site's configured default.

### Fixed

- **`update_user_start_page/2` now delegates its local-path check to
  `Routes.local_path?/1`** instead of a private re-implementation that missed
  the ASCII control-character case documented as load-bearing elsewhere in
  the codebase. The stored preference was already re-validated by the real
  guard at redirect time, so this was not a live open redirect, but it closes
  a second, drifting copy of a security-critical check (PR #800 review).

## 2.22.16 - 2026-09-10

### Changed

- **Leaf bumped to 0.7.0.** Widens the `~> 0.4.1 or ~> 0.5 or ~> 0.6` requirement
  to also admit `~> 0.7`, and moves the `LEAF_CDN` pin in `phoenix_kit.js` to
  `leaf@v0.7.0` in lockstep with the resolved `mix.lock` version. Brings wiki-link
  chips to hybrid source mode and an announced (rather than silent) flush
  conflict in the collaboration layer.

## 2.22.15 - 2026-09-09

### Changed

- **Permanent user deletion moved off the Users list, and gets a real
  confirmation screen.** The "Delete" action is no longer offered from
  the list's row menu (table or card view) — it's a one-way, everything-
  related action that now belongs only on the user's own page, renamed
  "Permanently Delete" there. Confirming it now shows `Auth.
  preview_user_deletion/1`'s real, per-user counts (session tokens, role
  assignments, OAuth connections, billing profiles, shopping carts, admin
  notes — and what would be anonymized: orders, posts, comments, support
  tickets, email logs, files) instead of the same generic six-item bullet
  list for every user regardless of whether any of it actually applied.

## 2.22.14 - 2026-09-09

### Fixed

- **A boolean custom field on the user's own `/profile/settings` page had
  no checkbox at all.** The self-service custom-fields form had no
  `"boolean"` clause, so a boolean field fell through to the generic
  text-input default — the account holder saw (and could freely retype)
  the raw `"true"`/`"false"` value instead of a checkbox. The admin edit
  form already had a checkbox for this type; the profile page now does
  too.

### Changed

- **A boolean custom field on the admin edit form no longer shows two
  redundant labels.** The generic "Label / Type" header above every field
  plus the checkbox's own generic "Enable this option" label meant a field
  named e.g. "Approved for Wood Matrix" rendered as "Approved for Wood
  Matrix / Boolean" followed by an unrelated "[ ] Enable this option".
  A boolean field now renders as a single checkbox labeled with the
  field's own label, matching how a checkbox is normally presented.

## 2.22.13 - 2026-09-09

### Changed

- **"New login" alerts no longer fire on an IP change alone.**
  `LoginAlerts` treated a login as an unrecognized "new device" whenever
  the exact `(ip_address, user_agent_hash)` pair had no matching history
  row — so a user with a non-static IP (most residential/mobile
  connections) got a "we noticed a new login" email on a large fraction
  of logins from a browser they'd used many times before, training people
  to ignore it. The email/in-app alert now fires only when the browser/OS
  itself (`user_agent_hash`, regardless of IP) hasn't been seen for the
  account before; an IP-only change on an already-recognized browser
  updates the device record and activity log silently, same as it
  already does for the account's first-ever login. The per-`(ip, ua)`
  device history itself is unchanged — still used to enrich the
  self-service Active Sessions list.

## 2.22.12 - 2026-09-09

### Fixed

- **A successful geolocation lookup crashed registration mid-signup.**
  `registration_country` is a 2-char column by design (ISO 3166-1
  alpha-2), but `Geolocation.lookup_location/1` only ever fetched and
  returned the full country name (e.g. "United States"), and
  `register_user_with_geolocation/2` wrote that straight into the column.
  This had gone unnoticed because geolocation never actually succeeded in
  production before the 2.22.10/2.22.11 IP fixes — once it started
  resolving real visitor IPs, every successful lookup raised an unhandled
  Postgres `string_data_right_truncation` and killed the registration
  LiveView mid-signup. `Geolocation` now also fetches the ISO alpha-2 code
  from both providers, and only a genuine 2-letter code is written to
  `registration_country`.
- **`registration_country`'s changeset validation didn't match its own
  column.** It allowed up to 100 characters — copied from
  `registration_region`/`registration_city` — instead of the 2 the column
  actually holds, so an oversized value reached Postgres as "valid" and
  only failed at the SQL layer instead of a normal `{:error, changeset}`.
  Now validated at `max: 2`, matching the column, as defense-in-depth for
  any caller.
- Admin UI locations (`user_details`'s and the Users list's "City, Region,
  Country" text) now expand the stored ISO code back to a full country
  name via `PhoenixKit.Utils.CountryData.country_name/1` for display.

## 2.22.11 - 2026-09-09

### Fixed

- **The IP address behind session-hijack detection and "new device" login
  alerts could be spoofed with a plain HTTP header.**
  `SessionFingerprint.get_ip_address/1` trusted `x-forwarded-for` /
  `x-real-ip` unconditionally — with no check that the request actually
  came through a trusted reverse proxy — and took the FIRST
  `x-forwarded-for` entry, which is exactly the part a client controls. An
  attacker replaying a stolen session token could forge that header to
  match the victim's original login IP and defeat the "IP changed, force
  re-auth" hijack check, or spoof the location shown in a "new login"
  alert email. It now delegates to the already-proxy-aware
  `IpAddress.client_address/1`, which trusts a forwarded header only when
  `conn.remote_ip` is itself a loopback/private address, and only the LAST
  entry — the one a proxy appends, not the one a client sent.

## 2.22.10 - 2026-09-09

### Fixed

- **Registration IP/geolocation tracking silently recorded "unknown" for
  every self-registered user.** `register_user_with_geolocation/2` guarded
  on `is_binary(ip_address)` alone, and the socket/conn IP extractors return
  the literal string `"unknown"` — never `nil` — when they can't tell the
  visitor's address. That literal string satisfied the guard and got
  written to `registration_ip` as if it were a real IP, then rendered
  verbatim in the admin UI instead of "No data." Self-registration,
  magic-link registration, and OAuth registration all funnel through this
  one function, so all three are fixed at once.
- **IP tracking now reads the visitor's real address behind a reverse
  proxy, everywhere it's tracked.** `IpAddress.extract_from_socket/1` and
  `extract_from_conn/1` — used for registration, login, magic link,
  sessions, multi-session, live sessions, dashboard presence, the referral
  gate, and the admin user form — used to read the raw TCP peer, which
  behind nginx (or in a container) is the proxy's own address for every
  visitor. They now delegate to the already-proxy-aware
  `client_address_from_socket/1` / `client_address/1`, which read
  `x-forwarded-for` / `x-real-ip` when the peer is a loopback or private
  address.
- Documented that `track_registration_geolocation` requires the host
  endpoint's LiveView socket to declare `:peer_data` in `connect_info` —
  `mix phoenix_kit.install` doesn't (and can't) set this up automatically,
  and without it the setting silently does nothing.

## 2.22.9 - 2026-09-09

### Added

- **`<.load_more>` forwards extra HTML/`phx-*` attributes to its button.**
  A page rendering more than one `<.load_more>` list can now attach
  `phx-value-*` so a single shared `handle_event` clause can tell which
  list's button was clicked, instead of minting a distinct `on_load_more`
  event name per list.

## 2.22.8 - 2026-09-09

### Changed

- **The parked "wrong email?" fix-up form no longer asks for the current
  password.** It reused the same `apply_user_email/3` path Profile
  Settings uses for a confirmed user's email change, but there is no
  live/confirmed account yet for a hijacked session to protect at that
  point — just a pending signup fixing a typo before its first
  confirmation. New `Auth.apply_unconfirmed_user_email/2` is
  pattern-matched on `confirmed_at: nil` so it structurally cannot be
  reused once an account is confirmed.
- **A confirmation resend now says what actually happened.** The handler
  ran the rate-limit check, the account lookup, and the send inside a
  `with` whose result was never inspected, so hitting the 3-per-5-minutes
  resend limit (or a genuine mailer failure) still flashed "we've sent a
  new confirmation link" with nothing to explain why no mail showed up.
  The parked (authenticated) branch now flashes the real outcome —
  success, a clear rate-limit notice, or a retry message with the actual
  reason logged server-side. The anonymous branch is unchanged: it always
  shows the same vague message regardless of outcome, which is what
  avoids turning the endpoint into an account-enumeration oracle for a
  signed-out visitor.
- **The "new login" security alert no longer fires on an account's own
  signup.** Registration ends by logging the new user in through the same
  path every other login uses, and a brand-new account has no device
  history yet — so with `new_login_alert_enabled` on, every signup
  immediately triggered a "we noticed a new login to your account" email
  about the login it had just performed to finish registering.
  `LoginAlerts` now checks whether the account has *any* known device on
  record before alerting; a true first device is still recorded (so an
  actual second device correctly reads as new) and still logged to the
  activity feed, but skips the email and in-app notification.

## 2.22.7 - 2026-09-08

### Changed

- **Reworked the parked "confirm your email" screen** (`/users/confirm` for
  an already-logged-in, unconfirmed user). The card now says what actually
  happened and when ("Sent 3m ago", backed by a real read of the
  confirmation token's `inserted_at` — there was previously no record shown
  at all); the email field is a plain read-only display instead of a
  disabled-looking, falsely-required `<input>`; the resend button reads
  "Resend email" instead of the truncation-prone "Resend confirmation
  instructions"; and the "Wrong email? Change it" password re-entry now
  explains itself instead of looking arbitrary to an already-authenticated
  visitor.
- **The Register / Log in links on that same screen were nonsensical for a
  parked, already-authenticated visitor** — clicking either just bounced
  back to the same confirmation gate. They're now a single **Log out**
  link while parked, matching the pattern already used on the referral-gate
  screen; the anonymous "resend instructions" form (no session) keeps
  Register / Log in.

### Added

- `PhoenixKit.Users.Auth.get_last_confirmation_sent_at/1` — the `inserted_at`
  of a user's most recent live confirmation-email token, `nil` if none is on
  record. Backs the "Sent X ago" wording above.

## 2.22.6 - 2026-09-08

### Changed

- **Integrations encryption's legacy-key warning no longer logs on every
  boot by default.** Any install still on the `secret_key_base`-derived
  fallback (every install before the dedicated-key feature existed) got a
  `Logger.warning` on every single restart with no way to quiet it short of
  configuring a dedicated key. `PhoenixKit.boot/1` now only emits it when
  `config :phoenix_kit, integration_encryption_warn_on_boot: true` is set
  (default `false`). `mix phoenix_kit.doctor` and the admin-only system page
  still surface the same diagnosis on demand, unconditionally — only the
  unsolicited boot-time push is now opt-in.

## 2.22.5 - 2026-09-08

### Changed

- **"Email Sending" settings page renamed to "Emails Transactional."**
  Labels and copy only — the route stays `/admin/settings/email-sending`
  so existing links and bookmarks keep working.
- **Send Profiles promoted to its own top-level "Emails Bulk" Settings
  tab** (`/admin/settings/emails-bulk`), a sibling of Emails Transactional
  rather than a subtab nested under it — bulk/marketing sending config is
  a distinct concern from the always-needed transactional setup. Stays in
  core: it's live infrastructure Newsletters' delivery worker depends on
  today, not something `phoenix_kit_emails` itself consumes.
- **Website access: dropped the environment banner, the presets, and the
  visitor notice** (#797). The admin header's automatic `[dev]` tag
  already tells a dev/staging box apart from production on every page, so
  the banner and the notice repeated that signal; the presets picked
  between values every feature already lets you set directly. "Hide from
  search engines" keeps its `X-Robots-Tag` header, now its own plug step
  instead of riding inside the removed notice's callback.

## 2.22.4 - 2026-09-08

### Added

- **Active / Disabled / Not Installed tabs on the admin Modules page.** The
  page previously listed every accessible module in one grid regardless of
  its on/off state. Toggling a module now moves it live between tabs (no
  reload), and each tab shows a running count badge.

### Changed

- **Storage and Notifications no longer appear on the admin Modules page.**
  Both are core capabilities, not real install/uninstall toggles — Storage
  has always been unconditionally enabled (`enable_system`/`disable_system`
  are no-ops) and Notifications is a settings kill-switch already exposed on
  `/admin/settings/users`. Listing them alongside genuinely optional modules
  (Languages, Crawlers, Sitemap, external packages) misrepresented them as
  removable features. Their permission keys, admin tabs, and Settings pages
  are unchanged — only the redundant Modules-page card was removed.
- **`phoenix_kit_hello_world` no longer appears in "Not Installed" packages.**
  It's a starter template for building a new module, not a real feature to
  install.

### Fixed

- **The not-yet-installed "Og" package card showed "Og" instead of "OG".**
  `PhoenixKit.KnownPackages`' key-to-name humanizer capitalized every word
  instead of upper-casing known acronyms; it now special-cases them.
- **`billing_default_currency` dead setting removed (V189).** Seeded by V135,
  read by nothing (confirmed by a full grep across `phoenix_kit`,
  `phoenix_kit_billing`, and `phoenix_kit_ecommerce`), and actively
  disagreeing with the real base currency (the `is_default` row of
  `phoenix_kit_currencies`) — worse than merely unread. Follows V184's
  `shop_currency` removal shape exactly; `down/1` restores V135's exact seed
  statement without clobbering a hand-recreated value. (#796)

## 2.22.3 - 2026-09-08

### Added

- **`PhoenixKit.TestSupport.PostgresPreflight`** — a shared, classified
  PostgreSQL connection check for a package's `test_helper.exs`. Replaces the
  `psql -lqt` listing that ran as the shell user over a unix socket and
  answered the wrong question: it said nothing about whether the *configured*
  role could reach the database over TCP, so a wrong `PGUSER` did not surface
  as "wrong `PGUSER`" — it queued through the SQL sandbox and died minutes
  later as a pool-checkout timeout that read like a flaky test. Ships in
  `lib/` (not `test/support/`) so sibling packages depending on `phoenix_kit`
  through Hex can call it too; never call it from application code.

### Fixed

- **`phoenix_kit_user_connections`' three `unique_constraint/3` declarations
  were inert.** `phoenix_kit_user_follows_unique_idx`,
  `phoenix_kit_user_blocks_unique_idx` and
  `phoenix_kit_user_connections_requester_recipient_uidx` have always been
  named in the module's schemas, but the indexes backing them never existed —
  a database violation is what `unique_constraint/3` translates into a
  changeset error, and with no index there was no violation. Two users
  clicking "connect" on each other at the same moment both passed
  `request_connection/2`'s read-then-write pre-check and both inserted,
  leaving a duplicate relationship that a later auto-accept could turn into a
  live pending request between two already-connected users, or into two
  "accepted" rows that made `get_accepted_connection/2` raise
  `Ecto.MultipleResultsError`. V188 removes any duplicates the race already
  produced (favoring an accepted row over a pending one) and creates the
  three indexes — an expression index on `LEAST`/`GREATEST` of the pair for
  the undirected `phoenix_kit_user_connections` table, ordered-pair indexes
  for the directed follows/blocks tables — so the existing
  `unique_constraint/3` calls start enforcing what they always claimed to.

## 2.22.2 - 2026-09-08

### Added

- **Rows-per-page selector on the Users admin tabs.** Users, Sessions, Live
  Sessions, Roles and the media picker each get a daisyUI `<select>` next to
  the page links (`<.page_size_selector>`, a sibling of `<.pagination>` in
  `PhoenixKitWeb.Components.Core.Pagination`). The choice lives in the URL as
  `?per_page=` — validated against an allowlist, invalid values fall back to
  the tab's default — so a size survives reload and is shareable; picking a
  new size lands on page 1.
- **Roles is paginated** (25 per page by default). It used to render every
  role on one page; the summary cards now count the whole table rather than
  the rows on screen.
- **"Auto" page size (opt-in pilot on the Users tab).** `<.page_size_selector
  auto_fit>` offers an Auto option backed by a small `PageSizeAutoFit` JS hook
  that measures the table's top offset and one row against the viewport and
  picks the largest allowed size that fits, re-fitting on resize. Off by
  default; `?fit=true` in the URL.

### Changed

- Users, Sessions, Live Sessions and the media picker share the core
  `<.pagination_controls>` instead of four hand-rolled `join` blocks with
  their own page-range helpers.
- `<.pagination_info>` is translated ("Showing … of … results" / "No results"
  were hardcoded English) and takes a `noun_plural` attr so a caller can name
  what is counted — Sessions passes `gettext("sessions")`, keeping the line it
  had before switching to the shared component.
- Sessions now filters and pages in SQL (`Sessions.list_sessions_paginated/1`)
  instead of loading every session token and slicing the list in memory.
  Live Sessions keeps the in-memory slice: Presence is an ETS-backed
  GenServer, there is no table to push LIMIT/OFFSET down to.

### Fixed

- The **Integrations** sidebar tab still pointed at
  `/admin/settings/integrations/website`, the path 2.21.3 renamed to
  `/admin/settings/integrations`. That URL does not 404 as the rename note
  expected — it matches `/admin/settings/integrations/:uuid` with
  `uuid = "website"`, so `Repo.get/2` raises `Ecto.Query.CastError` and
  LiveView returns a 400 reload response, which loops. The two README route
  lists and `AGENTS.md`'s owner-scope note were stale from the same rename
  and are corrected alongside it.

## 2.22.1 - 2026-09-08

### Added

- Tabs on the Media settings page (`/admin/settings/media`) — Buckets /
  Configuration / Quick Actions, the same `<.nav_tabs>` treatment already
  applied to Email Sending and Sitemap. The ImageMagick/FFmpeg dependency
  warnings stay above the tab strip since they apply regardless of which
  tab is open.
- **Public "Edit link" API** — `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`
  is now a documented public API: a host LiveView or a module's own public
  controller/LiveView calls it to declare a public page's matching admin
  edit target. The label argument now also accepts a keyword list
  (`label:`, `permission:`), gating the link on a specific module's
  `Scope.has_module_access?/2` in addition to the existing admin-area check,
  while every existing string-label call site keeps working unchanged. A new
  `PhoenixKitWeb.Components.Core.AdminEditLink.admin_edit_link/1` component
  (`<.admin_edit_link .../>`) renders the link — as a standalone button or a
  `:menu_item` for dropdowns — and renders nothing when there is no URL, so
  hosts can drop one line into their public layout unconditionally. See the
  "Edit link on public pages" section in `guides/integration.md`.

## 2.22.0 - 2026-09-08

### Added

- The parked `/users/confirm` page (where a logged-in but unconfirmed user
  lands) now has a "Wrong email? Change it" option — a compact version of
  Profile Settings' change-email form (current password + new address).
  Confirming the new address both changes the account's email and confirms
  it in one step, so a typo'd signup email no longer strands the account.
  The confirmation link points at a new, purpose-built page
  (`/users/confirm/change-email/:token`) rather than the normal
  `/profile/settings/confirm-email/:token` — that page requires a confirmed
  account to reach, which would have made the fix for "I'm unconfirmed"
  depend on already being confirmed.

### Fixed

- The parked page's "Resend confirmation instructions" flash message said
  "If your email is in our system and it has not been confirmed yet..." even
  though the visitor was already logged in as that exact account — the
  enumeration-safe hedge (correct for the public, logged-out resend form)
  read as a wrong answer once you're signed in. A logged-in unconfirmed user
  now gets a direct message naming their own address, and the (previously
  editable) email field on that form is now read-only and its value ignored
  server-side — editing it could otherwise be used to probe whether an
  arbitrary address is registered.

## 2.21.5 - 2026-09-08

### Changed

- The "Development site" preset (Website Access settings) no longer switches
  on the visitor notice bar — the admin header's automatic "[dev]" tag
  (added in 2.21.3) already tells an admin apart from production, so the
  preset only needs the password gate and hiding from search engines now.
  The notice feature itself is unchanged and still available for hosts that
  want a visitor-facing banner for any reason (maintenance, under
  construction, or their own dev-site text). Existing installs that already
  applied the old preset keep their notice switched on until turned off by
  hand on Settings → Website Access → Notice.

### Fixed

- Flash notifications could get stuck on screen indefinitely instead of
  auto-dismissing. `@flash` is one Phoenix assign covering all three kinds
  (info/warning/error), so putting or clearing a *different* kind's flash —
  or the same kind with unchanged text — marks the whole assign dirty and
  re-diffs every currently-shown flash node, not just the one that actually
  changed. The `FlashAutoDismiss` hook's `updated()` callback (added in
  2.21.0 to fix a related issue) treated every such patch as "a new message
  landed" and unconditionally restarted the dismiss timer, so a flash on a
  page where anything else touched flash state could sit on screen forever.
  It now fingerprints the message text and only restarts the timer when it
  actually changed.

## 2.21.4 - 2026-09-07

### Fixed

- The "igniter dependency is missing" message that `mix phoenix_kit.update`
  (and the other Igniter-backed tasks) prints for an unsupported `MIX_ENV`
  (e.g. `prod`) told the operator to add
  `{:igniter, "~> 0.7", only: [:dev, :test]}` — the exact fix the message had
  just explained would not work, since that scoping excludes the very
  environment the task is running in. It now explains that these tasks
  generate/apply code and genuinely need igniter loaded wherever they run,
  and offers the two real options: run the task from dev/CI and ship the
  generated files, or broaden the host's own igniter dependency's `only:` to
  include that environment.

## 2.21.3 - 2026-09-07

### Added

- A quiet "[dev]" tag next to the project title in the admin header,
  automatic whenever `PhoenixKit.WebsiteAccess.environment().looks_like_dev?`
  is true (non-`prod` mix env, or a dev/staging/test/local/sandbox/preview
  word in the hostname or configured site URL) — no setting to remember to
  flip. Replaces the old workflow of switching on the general-purpose Notice
  bar (a fixed bar across the bottom of every page) just to signal "this
  isn't the production site"; that feature is unchanged and still available
  for actual visitor announcements.

### Changed

- **Breaking:** the website-wide Integrations settings page moved from
  `/admin/settings/integrations/website` to `/admin/settings/integrations`.
  The `/website` segment only ever existed to disambiguate it from the
  personal per-user integrations page, which shared the same base path; that
  page has since moved to `/profile/settings/integrations`, so the
  disambiguation segment is no longer needed. Any bookmarked or linked
  `/website` URL will 404.

## 2.21.2 - 2026-09-07

### Added

- Non-destructive avatar cropping, Apple Photos style — picking a new avatar
  opens a drag/wheel/slider crop editor before anything persists; the crop
  geometry (`x`, `y`, `zoom`, aspect ratio) is stored alongside the original
  upload rather than baked into re-encoded pixels, so re-cropping never loses
  quality.

### Fixed

- Multi-domain sitemaps could list the same home URL twice (once bare, once
  with the full cross-domain hreflang set) when a locale-prefixed clone route
  had no `canonical_path` of its own, and a single-language canonical group
  on a non-primary domain could carry a self-only hreflang pair that the
  page's own `<head>` never backed up.
- The storage orphan-file check now recognizes catalogue-owned tables:
  `phoenix_kit_cat_items`, `phoenix_kit_cat_categories`, and
  `phoenix_kit_cat_catalogues` store image references inside a JSONB `data`
  column rather than dedicated FK columns, so a plain join was missing them
  and could queue a live catalogue image for deletion. `phoenix_kit_cat_pdfs`
  references its file through a real FK with `ON DELETE RESTRICT`; a PDF
  still in use could have its file data deleted and then crash the cleanup
  job on the FK violation — that table is now guarded too.
- A stale avatar crop could outlive the file it was framed for — replacing
  an avatar without submitting a new crop now clears the old geometry
  instead of stretching the old aspect ratio onto the new image.
- Landscape avatars rendered soft: crop-variant selection compared needed
  pixels against the image's width instead of its short side, which is what
  actually bounds sharpness under cover-fit.

## 2.21.1 - 2026-09-07

### Fixed

- **Languages settings page's breadcrumb fix from 2.21.0 was incomplete**
  — the `page_section`/`page_section_path` assigns were added to `mount/3`
  but never threaded into the template's `app_layout` call, so the
  breadcrumb still showed bare "Languages" instead of "Settings /
  Languages".
- Media settings page's subtitle was a full paragraph that didn't fit in
  the header on any but the widest screens, truncating to unreadable
  fragments. Shortened to match the length of every other Settings page's
  subtitle.
- **Two mistranslated strings from 2.21.0's gettext round-trip**: the
  Sitemap tab label "Sources" had been auto-fuzzy-matched to unrelated
  "Success" translations in Russian, French, German, Spanish, Italian,
  Polish, and Estonian; the Email Sending tab label "Local Dev Mailbox"
  was fuzzy-matched correctly but never had its fuzzy flag verified and
  cleared. Both fixed with real translations.

## 2.21.0 - 2026-09-07

### Added

- Tabs on the Email Sending and Sitemap settings pages — same treatment
  as the rest of Settings: Sender Identity / Transport / Local Dev
  Mailbox / Default Integration / Test Send / Send Profiles for Email
  Sending, and Sources / Configuration / Quick Actions / Advanced for
  Sitemap.

### Fixed

- **Settings breadcrumb regressions on several pages that don't call
  `LayoutWrapper.app_layout` from a per-page `.ex`/`.heex` pair the same
  way the rest of Settings does** — Media (`/admin/settings/media` and
  its Dimensions/Health/bucket/dimension sub-pages) and Sitemap
  (`/admin/settings/sitemap`) both linked their breadcrumb's second
  segment to "Modules" → `/admin/modules` instead of "Settings" →
  `/admin/settings`, even though both live under the Settings sidebar
  group — the wrong link, not just a mislabeled one. Media's page title
  was also shortened from "Media Settings" to "Media" to match the
  sidebar and stop the breadcrumb truncating to unreadable fragments on
  narrower screens.
- **Languages settings page had no breadcrumb section at all**, showing
  bare "Languages" instead of "Settings / Languages" like every sibling
  page.
- Renamed "Website Integrations" back to plain "Integrations" now that
  the personal "My Integrations" page (the reason for the "Website"
  qualifier) lives under Profile Settings instead of colliding with this
  one.
- "Main countries" label capitalization on the Organization settings
  page's Main Countries tab (was inconsistent with the other tab
  labels).
- Drag-and-drop reordering on touch devices (iPad) for the Main
  Countries list — SortableJS's fallback drag mode needs
  `touch-action: none` on the drag handle, which nothing in the
  codebase set; added it globally to `.pk-drag-handle`, plus a larger
  touch target for this specific handle.
- Flash notifications no longer auto-dismissed after their timeout — the
  `FlashAutoDismiss` hook only started its timer in `mounted()`, which
  LiveView doesn't call again when it patches an existing flash node in
  place. Added the missing `updated()` lifecycle callback.
- VAT/Tax ID on the Organization settings page is optional again (format
  is still validated when a value is given) — most jurisdictions don't
  require every company to register for VAT/a tax ID below a threshold.
  Registration Number is now required instead, since every incorporated
  company gets one.
- The "Main Page" field under General → Site Address is now labeled
  "Signed-Out Landing Page" with a clearer explanation of what it
  actually controls (where a signed-out visitor lands, including right
  after logging out).

## 2.20.0 - 2026-09-07

### Added

- **Multiple bank accounts** — the Organization settings page's Bank
  Accounts card now supports more than one account (a EUR operating
  account and a USD reserve account, say), each with a label, bank name,
  IBAN, SWIFT/BIC, and a "primary" flag, via a proper add/edit/delete UI.
  Previously there was room for exactly one. `phoenix_kit_billing`'s
  integration point is unaffected — it now reads the primary account.
- **Country-aware Company Information fields** — the State/Province field
  is a real dropdown for the 224 countries with subdivision data (US: 50
  states + DC + territories; Canada: 13 provinces/territories; and 222
  others), falling back to free text only for the 26 without. The tax-ID
  field is labeled and validated correctly per country instead of always
  saying "VAT Number": **EIN** for the US, **Business Number (BN)** for
  Canada, **VAT Number** for EU members, generic **Tax ID** elsewhere. The
  postal-code field says **ZIP Code** for the US and **Postal Code**
  everywhere else, both with real format validation.
- Tabs on the Authorization, Users, Crawlers, Website Access, and
  Organization settings pages — same treatment as General settings' tabs
  in 2.19.0, each page's sections behind a strip instead of one long
  scroll.

### Fixed

- The bank accounts list could not actually be saved: `value_json` is an
  Ecto `:map` column that silently rejects a bare JSON array, so every
  save looked successful (the flash fired) while quietly never
  persisting past a single legacy account on reload. Fixed by wrapping
  the list the same way Custom User Fields already does
  (`%{"accounts" => [...]}`).
- `CountryData.get_subdivision_label("CA")` had a stale doctest claiming
  "Province"; the real value from `beamlab_countries` is "Provinces and
  territories".

||||||| parent of 8fbfa12992 (Make the public-page Edit link a documented API with a component and a permission gate)
## 2.19.0 - 2026-09-07

### Changed

- **Personal integrations moved off Settings, onto the profile page** — "My
  Integrations" was a Settings sub-sub-tab three levels deep (Settings ›
  Integrations › My Integrations), and holding only the personal
  `integrations` permission made the whole Settings section appear in a
  regular user's sidebar just for that one page, despite it being per-user
  data rather than a site-wide setting. It now lives at
  `/profile/settings/integrations`, reached from a new **Integrations**
  section on the Profile Settings page (connection summary + a "Manage
  Integrations" link). The Settings sidebar's "Integrations" grouping tab is
  gone; "Website Integrations" is now a plain flat Settings subtab like
  Users/Authorization, gated on `integrations_system` alone. Hosts linking
  directly to the old `/admin/settings/integrations` path need to update to
  `/profile/settings/integrations`.

### Added

- Tabs on the General settings page (Site Identity, Site Address, Features,
  Content Editor, Date & Time) instead of one long scroll — one form, one
  Save button underneath all of them.

### Fixed

- Settings breadcrumbs are consistent across every subtab now: "Settings /
  <Name>", matching the sidebar label exactly. Most subtabs previously
  hardcoded their own breadcrumb title directly in the template (ignoring
  the `page_title` their own `mount/3` set) and none showed a "Settings /"
  parent crumb, so titles drifted from the sidebar's labels (e.g.
  "Authorization Settings" vs. sidebar "Authorization") and General showed
  bare "Settings" with no subtab name at all. Nested pages (Send Profiles,
  the integration forms) now show their full breadcrumb trail.

## 2.18.1 - 2026-09-07

### Fixed

- Login page heading hierarchy — the bold heading said "Welcome back" and the
  subtext said "Sign in to %{project_title}", backwards for a visitor who
  isn't authenticated yet. Swapped which string gets which styling.
- Removed duplicate in-body page headings on the General, Users, and
  Authorization settings pages, and on the profile settings page
  (`/profile/settings`) — each repeated the page title already shown in the
  top breadcrumb bar.
- Removed hardcoded Comments, Referrals, Customer Support, and Connections
  cards from the admin Modules page — each of those modules was extracted
  into its own hex package that auto-registers via `PhoenixKit.Module` and
  already renders through the generic external-module card loop, so
  installing any of them showed a duplicate card. The generic card now
  covers everything the hardcoded ones did via each package's
  `module_stats/0`.

## 2.18.0 - 2026-09-07

### Added

- **Website access** — one settings page (`/admin/settings/website-access`) for every
  way of controlling who sees the site, with independently switchable features and
  presets (Maintenance, Under construction, Development site, Live) that bundle them:
  - **Password gate** — a blank page with one field at `<prefix>/access`, before
    anyone sees anything. Unlock is a session epoch (rotated on password change,
    switch-on, or "ask everyone again"), never password-derived. Every try is
    recorded with a verdict (correct, case, close, unrelated, empty, locked, link)
    and, by default, what was typed — narrowable to near-misses or nothing. Optional
    per-address lockout under a per-address advisory lock. An access link unlocks
    only on the button's POST, never on the link's own GET, so a preview fetcher
    can't burn it. Logged-in users pass by default.
  - **Redirect to production** — public GET/HEAD to the same path and query on the
    production URL, never for logged-in users, the kit's own pages, or back to this
    host; everyone or crawlers only.
  - **Visitor notice** — an escaped bar injected after `<body>` on HTML 200s
    (byte-safe), editable live from the settings page.
  - **Site closed** — maintenance is now part of core: heading, message, a
    from/until window, a status line, a preview, and a visitor 503 page that counts
    down to the end. `PhoenixKit.Modules.Maintenance` keeps its name and API.
  - **Hide from search engines** — the crawlers noindex switch, plus
    `X-Robots-Tag` on every response in the chain.
  - **Allowed addresses** — pass the gate and the redirect; editing the list
    relocks already-open sessions.
  - **Environment panel** — release/mix, `MIX_ENV`, host, site URL — suggests a
    preset, never switches anything on. Header badges (lock, wrench, arrow) show
    while a feature is on and link to its settings.

  `PhoenixKitWeb.Plugs.WebsiteAccess` runs the chain in the host's browser
  pipeline: allowed-address bookkeeping → notice/robots → redirect → gate →
  maintenance. Every `on_mount` hook in `Users.Auth` checks the gate first. New
  migration **V187** adds `phoenix_kit_access_attempts`. Core's `<.checkbox>`
  gained `variant="toggle"`; `Routes.prefix_base/0` was added for root-mounted
  kits.

### Fixed

- The settings cache warmer could run before the host's endpoint was up. Under
  the legacy encryption tier the endpoint's `secret_key_base` **is** the key, so
  a restricted value failed to decrypt at boot and the failure was cached as
  `nil` until that key's next write — any host reading an OAuth secret or AWS
  key through `get_setting_cached/2` right after a restart hit this. The warm
  map now leaves an undecryptable key out instead of caching `nil` for it, and a
  cache miss caused by a decrypt failure is answered `nil` without being cached.
- A password-gate redirect-target test asserted a maintenance schedule starting
  exactly 60 seconds in the past, which sits on the validator's own tolerance
  boundary and failed deterministically once clock drift pushed it a hair past
  `-60`.
- The gate's `?to=` redirect-target check reimplemented local-path validation
  with its own regex instead of `Routes.local_path?/1`; it now calls the shared
  guard, with the gate's own rules layered on top.

## 2.17.0 - 2026-09-06

### Changed

- **`Mailer.send_from_template/4` no longer depends on the email templates
  table.** It is core's generic host-facing send API, and it resolved names
  from the database alone — answering `{:error, :template_not_found}` when
  there was no row. That table is being retired, and `phoenix_kit_billing`
  reaches through this function for its invoice, receipt, credit-note and
  payment-confirmation emails, so dropping the table with this path untouched
  would have stopped those emails **silently**, with an error shape the caller
  already tolerates.

  It now resolves through `PhoenixKit.Email.Content`, in order: an active
  database template, then a host override file for the recipient's locale, then
  the caller's own `:defaults`.

  **Nothing changes for an install that has a row** — the database layer still
  wins, exactly as it does for the auth emails. This ships ahead of the schema
  move on purpose, so no caller is ever in a window where its emails depend on
  a path that no longer works.

  Three new options:

  | Option | Effect |
  |---|---|
  | `:defaults` | content to fall back to — a `%{subject:, text:, html:}` map, or a zero-arity function returning one. Prefer the function for `gettext/1` content: it is evaluated inside the recipient's locale |
  | `:locale` | render in this locale instead of the one resolved from the recipient (a bare address carries no preference, so that falls through to the site's content language) |
  | `:paths` | host override roots to search, overriding the configured ones |

  A host or module that calls this function should add `:defaults` before the
  table is retired. Until then, adding them changes nothing.

- `PhoenixKit.Email.Content.resolve/5` accepts `:locale`, for callers whose
  recipient is a bare address rather than a user, and treats an explicit `nil`
  `:paths` as "use the configured roots".

### Fixed

- `{:error, :template_inactive}` is documented as no longer returned by
  `send_from_template/4`, and never was:
  `get_active_template_by_name/1` already filters on `status == "active"`, so
  the branch that returned it was unreachable.

## 2.16.0 - 2026-09-06

### Added

- **Outbound messages are rendered in the recipient's language.** Every auth
  email had been going out in English no matter who received it. Five call
  sites in `UserNotifier` and one in `Mailer` used the two-arity
  `render_template/2`, whose locale defaults to `"en"` — so a template
  translated into all seven locales was only ever read in one of them, and the
  translations sat in the database unread. Only
  `Mailer.send_from_template/4` passed a locale.

  `PhoenixKit.Utils.RecipientLocale` is now the single answer to "whose
  language is this message in": `for_rendering/1` returns the recipient's full
  dialect and never `nil`, falling back to the site content language and then
  `"en"`; `base/1` returns the base code or `nil` for Gettext, which reads
  `nil` as "leave the current locale alone". It keeps the dialect rather than
  narrowing it, since template resolution tries `"en-GB"` before `"en"` and
  pre-truncating would discard a dialect-specific translation. The preference
  comes from `custom_fields["preferred_locale"]`, written by the language
  switcher.

- **Message templates can be customized by the host, as files.**
  `PhoenixKit.Email.Content` resolves every auth email across three layers: an
  active database template (unchanged, and still winning — see below), then a
  host override file for the recipient's locale, then core's own translated
  default. Parts resolve independently, so a host that overrides only the body
  keeps core's translated subject.

  An override is a file in the host's own repo, version-controlled and
  reviewable. The template's **name is a directory**; the files inside it are
  named for the part they supply:

      <host>/priv/phoenix_kit_templates/
      └── new_login_alert/
          ├── text.txt          # <part>.<ext>
          └── text.de.txt       # <part>.<locale>.<ext>

  Lookup runs most- to least-specific — `text.de-AT.txt` → `text.de.txt` →
  `text.txt` → core's default — so a single-language host writes one file and
  is done. Roots come from `config :phoenix_kit, template_paths:`, defaulting
  to the host application's `priv/phoenix_kit_templates`.

- **New dependency: `phoenix_kit_templates`.** A leaf package with no runtime
  dependencies of its own, which is what lets core depend on it rather than
  feature-detect it through a behaviour. `mix deps.get` after upgrading.

- **The new-login alert finally carries a link.** It had been telling readers
  to change their password immediately while giving them nothing to click — on
  the one email that reaches a genuinely compromised account.

- **Three templates that were looked up but never existed.**
  `new_login_alert` and `magic_link_registration` were both resolved by name
  and had no seeded template, so they always fell through to a hardcoded
  English string. Both now exist, as does `organization_invitation`, which had
  never been templated at all.

### Changed

- ⚠️ **Auth email wording changes for hosts with no database template.** Those
  installs were receiving the hardcoded English fallbacks; they now receive
  core's Gettext defaults in the recipient's language. This is the point of
  the release, but it is visible — someone will notice their confirmation
  email reads differently. **Hosts with customized database templates see
  nothing change**: that layer still wins, deliberately, and will keep winning
  until an export task ships and operators have moved their edits to files.
  Removing it now would silently revert every customized message.

- **Notification text is translated.** `Notifications.Render` held 21
  hardcoded English literals — the text of every notification reaching the
  inbox, Telegram, the email channel and any future push. `Channel`'s own
  moduledoc had named the hole: the envelope carried `:locale` "but the core's
  built-in rendering is English today". It no longer is. `render/2` installs
  the recipient's locale for the lookup; a `nil` locale still means "leave the
  current locale alone", which is what the admin inbox wants — it renders in
  the viewer's language, not a recipient's.

  Three strings that concatenated a detail onto a translated stem ("Your email
  was changed" + " to x") became two complete msgids each. A suffix cannot be
  reordered, and several languages need the detail somewhere other than the
  end.

- 38 new msgids, translated into all seven locales. Five of them arrived from
  `gettext.merge` carrying a translation matched from a *different* msgid —
  `"New notification."` had inherited the translation of "My notifications" in
  every locale, and `"Confirm your account"` had inherited "Confirm **my**
  account". Gettext compiles and serves fuzzy entries, so all five were
  rewritten by hand.

### Fixed

- **Batch settings writes could deadlock.** The settings history added in this
  release reads each key `FOR UPDATE` inside the write's transaction, and the
  batch path took those locks in `Enum.reduce` order over a map. Erlang map iteration is not a stable total
  order — a map of 32 keys or fewer is a flatmap iterated in term order, a
  larger one is a hashmap iterated in hash order, and the same two keys come
  out reversed between them. Two concurrent `update_settings_batch/2` calls
  sharing keys, one small and one large, would take them in opposite orders
  and deadlock. Keys are now sorted before the reduce, so every batch acquires
  in the same order whatever its size.

- **`ModuleRegistry.not_installed_packages/0` advertised an installed
  package.** It derived "installed" from module discovery alone, which only
  finds packages implementing the `PhoenixKit.Module` behaviour — so an
  infrastructure dependency that implements none looked absent, and the admin
  Modules page would have offered `phoenix_kit_templates` as available to
  install while it was already a transitive dependency of core. It now also
  consults loaded applications; neither check subsumes the other.

- The notification delivery and digest workers each carried their own
  identical private copy of the recipient-locale resolution, and a third was
  about to be written. All three now share one.

## 2.15.1 - 2026-09-05

### Added

- **A B2B site can stop asking whether an account is personal.** With
  organization accounts on, the signup page has always shown a Personal /
  Organization picker — a dead question on a site where every account is a
  company. A new **Account types on the signup page** setting
  (`registration_account_type`, on `/admin/settings/users` beside the feature
  switch) takes three values:

  | Mode | Signup page |
  |---|---|
  | `"choice"` | the picker, as before — the default, and what every existing install keeps |
  | `"person"` | no picker; organizations exist, but only an admin creates them |
  | `"organization"` | no picker; Organization Name required, and staff join by invitation |

  `Auth.registration_account_type/0` collapses this with the master switch, so
  one call answers "what may this form create?" — it returns `"person"`
  whenever organization accounts are off.

  The magic-link completion form honours the same policy: it has no picker, so
  it grows the Organization Name field (and drops first/last name, which an
  organization has neither of) exactly in `"organization"` mode.

### Fixed

- **The account type was never enforced server-side.** `registration_changeset/3`
  casts `account_type` and `organization_name` straight from the payload, and a
  `phx-submit` payload is whatever the client sends — so a forged
  `user[account_type]=organization` created an organization account on a site
  with organization accounts **switched off entirely**, where the picker had
  never been rendered. Both public forms now pipe their params through
  `Auth.enforce_registration_account_type/2` inside their field allowlist, the
  same arrangement that makes `remember_me_enabled` hold at the cookie writer.
  In `"choice"` mode an unknown string normalises to `"person"` rather than
  reaching the insert and coming back as a CHECK-constraint 500.

- **An organization invitation no longer offers "Organization".** A visitor
  registering from an invitation link saw the full picker, and choosing
  Organization created a *second* organization — which cannot hold an
  `organization_uuid`, so the invitation could never be redeemed. The
  invitation now pins the signup to a person account, on the page and in the
  payload.

## 2.15.0 - 2026-09-05

The deprecated user dashboard stops being routed by default, and the admin area
gets a name of its own — one that a host can change without giving up
translation.

⚠️ **Two behaviour changes for existing hosts**, both covered below:
`:user_dashboard_enabled` now defaults to `false`, so `/dashboard` stops routing
for anyone who never wrote the key; and a host already running a renamed
`:admin_path` that matches a preset will see its header wording change to match
the URL. Neither deletes anything — one config line restores either.

### Added

- **The admin area can be called something else, and stay translated.**
  Ten built-in names — Admin Panel, Dashboard, Backoffice, Console, Control
  Panel, Workspace, Portal, My Account, Management, Studio — each a real
  `gettext/1` msgid translated into all seven shipped locales. A host picks
  one and a German visitor still reads "Arbeitsbereich" where an English one
  reads "Workspace":

      config :phoenix_kit, admin_panel_label: :workspace

  **Unset, the name is derived from `:admin_path`**, so renaming the URL renames
  the wording with it and the two cannot drift:

      config :phoenix_kit, admin_path: "/backoffice"
      # URL /backoffice, header "Backoffice" — one key, both aligned

  `-` and `_` are equivalent in the segment, and a segment matching no preset
  (`/x7q`, or any deliberately obscure rename) keeps the translated "Admin
  Panel" rather than inventing a label out of the URL.

  A free-text string still works — `admin_panel_label: "Acme HQ"` — as the
  escape hatch for a brand name no preset covers. ⚠️ It is **not** translated:
  one string, shown to every visitor in every language. That is exactly why the
  presets exist, and why neither form is an operator field on
  `/admin/settings`: `config.exs` puts the tradeoff at the point of the
  decision, and keeps the wording next to `:admin_path`, which is compile-time
  config for the same reason.

  Resolution is `PhoenixKit.Config.admin_panel_label/0` → `{:preset, atom}` or
  `{:custom, binary}`, rendered by the new
  `PhoenixKitWeb.Components.Core.AdminLabel`. Both the header chip and the
  account-menu admin entry go through it, so they cannot disagree. Unlike
  `:admin_path`, an unrecognised value here **falls back rather than raising** —
  this is cosmetic, and a typo must not take the admin area down in production
  — but it logs once, naming the valid presets, so the fallback is not silent.
- **`mix phoenix_kit.install` / `.update` write the naming options into the
  host's `config/config.exs`, commented out.** A closed vocabulary of atoms is
  not something a developer can guess, and neither of the places it was first
  written down reaches them: the settings page is read by operators who cannot
  act on it, and a CHANGELOG is read once. The block puts the whole list — each
  preset, what it reads as, and the `admin_path` it pairs with — in the file
  they open to make the change.

  Every line is a comment, so the block is inert: it cannot execute, cannot
  conflict, and does not care where in the file it lands, which is what makes
  appending it after `import_config` safe. A test asserts that property
  directly, and a second walks `admin_label_presets/0` so a preset added
  without its comment entry fails the suite instead of raising partway through
  somebody's install. Idempotent on a marker, and skipped entirely once the
  host has an uncommented `admin_panel_label:` — at that point they have made
  the choice the block exists to explain.

  With the list living there, the settings-page description shortened to point
  at it rather than reciting ten names to an audience that cannot use them.

### Changed

- **The "Admin Panel" settings field says where the label appears and how to
  change the wording.** The checkbox now reads *Show the "Admin Panel" label in
  the admin header* rather than leaving the location to the description, and
  the description no longer repeats it. It also no longer says the wording
  "has no setting" — it lists the built-in names and points at `admin_panel_label`,
  and notes that renaming the URL with `admin_path` picks the matching name on
  its own. Both strings translated in all seven shipped locales.
- **`:user_dashboard_enabled` now defaults to `false` — the user dashboard is
  retired from core's defaults.** `/dashboard`, `/dashboard/settings` and the
  confirm-email compat redirects are no longer routed unless a host asks for
  them. Its job has moved into `/admin`, which shows each visitor the sections
  their permissions allow and greets a permission-less visitor rather than
  bouncing them (`PhoenixKitWeb.Users.Auth.landing_view?/1`). Together with the
  widget change below, nothing in core links to `/dashboard` any more.

  ⚠️ **Breaking for a host that never wrote the key** — it took the old default
  without choosing it, and `/dashboard` stops routing on the next compile.
  `mix phoenix_kit.update` now says so, and says the one line that keeps it.

  **Nothing has been deleted.** The LiveViews, the layout, the sidebar, the tab
  machinery and the route macros are all still there, so this is a switch and
  not a removal:

      config :phoenix_kit, user_dashboard_enabled: true

  restores the routes unchanged. That is only true because of the next item.
- **`user_dashboard_enabled` is now tracked by `__mix_recompile__?/0`.** It is
  read at macro-expansion time by the route macros, exactly like `admin_path`,
  so the compiler had no idea the host router depended on it — and it was not
  in the recompile check. A host flipping the flag would have kept serving a
  router compiled against the old value until something unrelated forced a
  recompile. The setting only became worth having as a real switch once the
  default flipped, which is what surfaced this.
- **`/dashboard` is no longer a reserved `admin_path` segment while the user
  dashboard is off.** `@admin_path_collisions` refused it unconditionally
  because core declared a route tree there; with `user_dashboard_enabled: false`
  nothing occupies it, so `config :phoenix_kit, admin_path: "/dashboard"` is now
  legal — the rename a host retiring the user dashboard is most likely to want.
  Turning the dashboard back on puts the segment back in the list and the next
  compile raises, rather than letting whichever tree the router declared first
  silently win.
- **The deprecation notices split by what the host actually configured.**
  `mix phoenix_kit.install` no longer warns about a dashboard a fresh install
  does not have. `mix phoenix_kit.update` prints the deprecation heads-up only
  to a host that switched the dashboard **on**, the new default-changed notice
  to a host that never wrote the key, and nothing to a host that chose `false`
  — via the new `PhoenixKit.Config.user_dashboard_configured?/0`, which
  distinguishes "took the default" from "chose false" (`user_dashboard_enabled?/0`
  answers `false` to both).
- **The session widget's user-facing entry now leads to the admin area, not the
  deprecated user dashboard.** `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1`
  — the avatar dropdown a host embeds in its own header — rendered a "Dashboard"
  item pointing at `/dashboard` for every signed-in visitor, and was the one
  place in core that did **not** gate that link on
  `PhoenixKit.Config.user_dashboard_enabled?/0`. Every other call site does
  (`auth_router.ex`, both route macros in `integration.ex`,
  `NotificationsBell.default_link/1`, the `AdminNav` divider), so a host that
  compiled the dashboard out was left with a menu entry that 404s.

  Every signed-in visitor now gets exactly **one** entry leading to
  `Routes.path("/admin")`, which is the page core declares unconditionally and
  admits every authenticated visitor to — `PhoenixKitWeb.Users.Auth.landing_view?/1`
  exempts the index from the admin-area gate, and it shows a permission-less
  visitor the welcome block and nothing else. An admin-area holder sees it as
  "Admin Panel" with a shield; everybody else sees "My Account" with a house.
  The two are mutually exclusive and take their wording from one private
  `admin_entry_label/1`, so the pair cannot drift.

  Because the destination is built with `Routes.path("/admin")`, it picks up a
  renamed admin segment (`config :phoenix_kit, admin_path: "/myaccount"`) for
  free. Note that `admin_path: "/dashboard"` is still refused — `dashboard` is
  on `@admin_path_collisions` for as long as core declares the `/dashboard`
  route family.

  The `:dashboard` key in the `:authenticated_links` attr keeps its name and
  its place in the default list, so a host passing an explicit list needs no
  edit; only where it points has changed. Wording stays `gettext/1` on both
  arms rather than becoming an operator-typed setting, for the reason
  `LayoutWrapper` already gives for the "Admin Panel" chip: a stored string
  would serve one language's wording to every locale. `"My Account"` is
  translated in all seven shipped locales.
- **The context-switch fallback redirect points at `/admin`.**
  `PhoenixKitWeb.Controllers.ContextController` string-built
  `"#{url_prefix}/dashboard"` for requests arriving with no usable referer —
  the same dead destination, reached by exactly the visitors who got there by
  accident. It now goes through `Routes.path("/admin")`, so it also honours a
  renamed admin segment instead of concatenating the URL prefix by hand.

### Fixed

- **Menu links no longer emit a locale segment the router immediately redirects
  away from.** `user_dropdown/1` passed `@current_locale` straight into
  `Routes.path/2` and `Routes.user_settings_path/1`. That assign is the
  **gettext dialect** (`"en-US"`); URLs are served on the **base** code
  (`"en"`), as `PhoenixKitWeb.Users.Auth.validate_and_set_locale/2` documents.
  `Routes.path/2` takes `:locale` verbatim, so a visitor on `/en/profile/settings`
  was offered `/en-US/…` links — which route, then bounce through a redirect to
  `/en/…`. Worse, `default_locale?/1` compares against the base default, so
  `"en-US" != "en"` also defeated prefixless-primary and produced a locale
  segment where there should have been none. Both links now go through the
  normalising helpers (`Routes.locale_aware_path/2` /
  `locale_aware_user_settings_path/1`) that the multi-session forms three lines
  below were already using. Same slip fixed in the modules page's "Configure"
  link for crawler settings.
- **The dropdown's active-item highlight survives a renamed admin segment.**
  `active_path?/2` compared the real request path against the `/admin` written
  in the markup without canonicalising, so under `admin_path: "/myaccount"`
  nothing ever highlighted. It now folds the configured segment back through
  `Routes.canonical_admin_path/1` first.

## 2.14.2 - 2026-09-05

PR #783 — annotations stop requiring a file to anchor to — plus the two fixes
from its review.

### Added

- **An annotation anchors to a TARGET, not necessarily a file** (#783, V183).
  Every row pointed at `phoenix_kit_files` through a `NOT NULL file_uuid`,
  which is right for the media viewer and wrong for a whiteboard with no image
  — the projects module was minting a solid-white PNG per board just to have
  something to draw over. `target_type` + `target_uuid` (Etcher's own
  vocabulary) are now the anchor: a `"file"` target still carries its file in
  both columns, so every file-side feature keeps its hard FK, and any other
  target carries no file at all. A CHECK pins the two shapes and the changeset
  mirrors it, so a bad shape is a changeset error rather than a constraint
  exception. Existing rows are backfilled and unchanged in meaning.

  ⚠️ `down/1` **deletes non-file annotations** — they have no home in the old
  shape. Back the table up first if a rollback is not final.

- **Modal drawers and a client-side close guard** (#783). `<.modal placement={:end}>`
  is a full-height sheet sliding in from the edge for tall forms;
  `close_guard={:input}` makes Esc and the backdrop no-ops from the first
  keystroke in a submittable form inside it, before the server has heard of the
  edit — the round trip plus any `phx-debounce` window would otherwise let a
  quick Esc discard what was just typed. Never latched: once the server
  re-renders, `closeable` is the only authority again.

- **`<.nav_tabs>` gains a `:trailing` slot** and the admin header a page
  toolbar beside the title (#783).

### Fixed

- **`PkUrlMirror` accepted network-path references and fragments** (#783). The
  root-relative check took `//host` and `/\host` — same-origin-looking,
  other-origin-going — and any fragment, which the comparison against
  pathname + search never sees, so `/p#x` re-fired on every update. Same guard
  shape as `Routes.local_path?/1`; control characters refused too.

- **`target_type` was only validated in the Etcher adapter** (review of #783).
  The adapter checked the format before building attrs; the changeset did not.
  The adapter is not the sole writer — `Annotations.create/1` is public and is
  the path a board takes — so a `target_type` over 32 characters reached
  `character varying(32)` and came back as a raw Postgres error, the exact
  failure `validate_target/1` exists to prevent one field over. The regex moved
  onto the changeset and the adapter now reads it from
  `Annotation.target_type_format/0`, so the two answers cannot drift.

- **V183 checked constraint existence with `::regclass`** (review of #783),
  which the prefix rules forbid — the cast raises rather than answering false
  when the relation is absent, aborting the whole transaction. Replaced with
  the mandated name-based `pg_class` + `pg_namespace` JOIN, as V180 does. It
  could not bite (V135 creates the table at the migration floor), but V183 is
  the newest migration and therefore the template the next one is copied from.
  Amended in place rather than superseded, since V183 has never shipped.

## 2.14.1 - 2026-09-05

Fixes found by running 2.14.0 against a real install: a dashboard statistic
that could only ever report the wrong number, two timezone consumers left
behind when the picker moved to IANA identifiers, and every statistic on the
dashboard becoming a link to the list behind it.

### Added

- **`TimeZone.offset_seconds/2` and `TimeZone.day_start/2`.** The first gives
  the offset for either kind of stored value — a legacy `"2"` or an IANA id
  resolved at an instant, since `Europe/Warsaw` has no single answer. The
  second gives the UTC instant at which the current day began somewhere, for
  "how many X today" where *today* is the operator's day. Both are what the two
  fixes below needed and neither had.

- **Every number on the admin dashboard is now a link to the report behind it.**
  A statistic you cannot drill into is a dead end: seeing "29 Active Sessions"
  and having no way to ask *which 29* is what sent one operator to the Live
  Sessions page to reconcile it by hand. All sixteen cards across Platform
  Statistics, Active Sessions, Real-Time Activity and the user-status row now
  navigate to a filtered list.

  Five of them had no report to point at, so the filters came first rather than
  linking at a list that could not contain the counted rows:

  - `Auth.list_users_paginated/1` gains `:status` (`active` / `inactive`) and
    `:confirmation` (`confirmed` / `pending`), deep-linkable as `?status=` and
    `?confirmation=` and surfaced as two dropdowns on `/admin/users` — a filter
    with no visible control would leave a visitor arriving from a card looking
    at a filtered list with nothing on screen saying why.
  - `Sessions.list_active_sessions/1` takes a scope — `:active` (the default,
    so existing callers are unchanged), `:today` and `:expired` — deep-linkable
    as `?scope=` with a matching selector on `/admin/users/sessions`.

  The predicates are deliberately identical to the ones
  `Roles.get_extended_stats/0` and `Sessions.get_session_stats/0` count with,
  and a test file asserts each card's number against its own link's result
  rather than either in isolation. Unknown values (`?status=nonsense` from a
  hand-edited URL) fall back to unfiltered rather than to an empty list, which
  would read as "you have no users".

  `StatCard` and `HeroStatCard` gain an optional `navigate` attr; without it
  they render exactly as before.

### Fixed

- **"Unique Users" counted session rows, not people.** `get_session_stats/0`
  asked for `Repo.aggregate(query, :count, :user_uuid, distinct: true)`, but
  `aggregate/4`'s last argument is REPO options — `:prefix`, `:timeout` — and
  `Ecto.Repo.Queryable.query_for_aggregate/3` builds the select from the field
  alone and never sees them. `distinct: true` was accepted and silently
  ignored, so the card reported one "unique user" per session row and was equal
  to "Active Sessions" by construction. Reported from a live install showing 29
  unique users against 2 registered accounts.

- **"Active Sessions / Currently logged in" invited exactly that confusion.**
  The number counts session tokens inside the 60-day validity window across
  every device, so one person who has signed in 29 times over two months is 29
  — while the Live Sessions page, which reads Presence, correctly showed one.
  The subtitle now reads "Unexpired sign-ins, not live connections".

- **"Today's Sessions" counted UTC's day, not the operator's.** `get_session_stats/0`
  took midnight from `DateTime.utc_now()` and ignored the `time_zone` setting
  entirely, so on any site east of UTC every sign-in after 21:00 local (UTC+3)
  fell into "yesterday" — the card read 0 while somebody was signed in. Both it
  and the new `:today` session scope now start the day in the configured zone.

- **`Utils.Date.offset_to_seconds/1` returned 0 for every named timezone.** It
  was `Float.parse/1`, which cannot read `"Europe/Warsaw"` — and since the
  timezone picker moved to IANA ids, that is what the setting holds on any site
  that has touched it. Every caller was therefore computing in UTC without
  saying so. It now delegates to the new `TimeZone.offset_seconds/2`.

  ⚠️ **This one reaches outside core.** Three call sites in module packages take
  that number as gospel and were silently off by the site's whole offset:
  `phoenix_kit_bookings`' `site_offset_seconds/0` (availability windows),
  `phoenix_kit_calendar`'s `window_bounds/3` (timed events near midnight fall
  out of the day the grid puts them in) and its `tz_differs?/2` (two different
  named zones compared equal, so "show in their timezone" saw no difference).
  The first two are corrected by this delegation; `tz_differs?/2` should move to
  `TimeZone.effectively_same?/2`, which answers the question it is actually
  asking.

## 2.14.0 - 2026-09-05

The admin area stops being nailed to `/admin`, the deprecated user dashboard
stops being promoted from core's own defaults, and the admin sidebar gains a
collapsed icon rail with hover flyouts.

### Security

- **`mint` 1.9.3 → 1.10.0**, clearing two advisories the release gate refused
  to publish over: EEF-CVE-2026-82728 (HIGH — unbounded HTTP/1 status-line and
  chunk-extension buffering, memory-exhaustion DoS) and EEF-CVE-2026-82729
  (MEDIUM — quadratic chunk-size parsing in `Mint.HTTP1.Parse`, CPU-exhaustion
  DoS). Transitive, via `finch`, `swoosh` and `tz`; every constraint on it
  already allowed 1.10.0, so this is a lockfile move with no API change.

### Added

- **The admin area's URL segment is configurable.**

      config :phoenix_kit, admin_path: "/backoffice"

  moves the whole admin surface inside the mount prefix — `/phoenix_kit/backoffice/users`
  — for hosts that would rather not show end users a URL that reads as somebody
  else's admin panel. Independent of `:url_prefix`, which names the mount
  itself. Compile-time, so it belongs in `config.exs`; `phoenix_kit_routes()`
  folds it into `__mix_recompile__?/0`, so changing it re-expands the host
  router instead of leaving it serving the old segment. Default `"/admin"`
  produces a byte-identical route table, so an existing install is untouched.

  **`/admin` remains the canonical name in code.** Nothing in core or in a
  module package is written against the configured value — call sites keep
  saying `Routes.path("/admin/users")`. The substitution lives in two inverse
  functions: `Routes.apply_admin_segment/1` when a URL is emitted (reached from
  `Routes.path/2`, `Routes.admin_path/2`, and the router's own route table),
  and `Routes.canonical_admin_path/1` when one is read back (tab active state,
  the admin nav parser, `LayoutWrapper.admin_page?/1`, the language switcher).
  A module package therefore needs **no changes at all** to honour a rename:
  its tabs are declared with relative paths and its links go through
  `Routes.path/1`.

  The route table is rewritten once, on the assembled AST of
  `phoenix_kit_admin_routes/1` — the single point where core's own table,
  `:admin_dashboard_tabs` entries, plugin views and a package's `admin_routes/0`
  all converge. So the rewrite reaches packages compiled long before the option
  existed, and cannot be forgotten by the next route added to the table.

  The value is validated (exactly one lowercase path segment, and not one of
  the segments core already declares — `users`, `profile`, `dashboard`, `api`,
  …) and raises rather than producing a router that compiles and then 404s.

- **The admin sidebar collapses to icons.** A toggle at the foot of the menu
  narrows it to a 5rem icon rail; the label of each item moves to a hover
  tooltip, group headings and subtab lists fold away, and the choice is
  remembered per browser. Desktop only — below `lg` the sidebar is an overlay
  drawer that is already absent until summoned, so narrowing it buys nothing
  and costs the labels.

  **Entirely client-side, and deliberately so.** The sidebar is a *function
  component*, not a LiveView: there is no `handle_event/3` owner for a
  `phx-click`, and giving one to every admin page (or bolting a global
  `attach_hook` onto the admin `on_mount` chain) is a lot of machinery for a
  display preference. It is also a per-browser density choice, like the theme,
  so it lives in `localStorage` beside it rather than in a settings row — and a
  client toggle costs no round trip and gives morphdom nothing to fight over,
  since the DOM is identical either way and only `<html>` changes.

  That makes the first paint the whole problem, which is why the stamp is a
  synchronous inline `<script>` rendered immediately above the sidebar rather
  than a hook in `phoenix_kit.js`: it has to run before the menu is parsed or a
  viewer who chose compact gets a frame of the full-width sidebar on every
  load, and it must not depend on the host having re-run
  `mix phoenix_kit.update` to refresh its vendored bundle. Same shape, and the
  same one-instance guard, as `PhoenixKitWeb.Components.ThemeBootstrap`.

  **Hovering a rail icon opens a flyout** naming that entry and listing its
  children. It is rendered for every navigable top-level entry, not only the
  active one: `subtab_display` defaults to `:when_active`, so the inline subtab
  list exists only for the section you are already in — precisely the browsing
  an icon rail otherwise loses.

  Built on the `popover` API, which earns its place three times over. The top
  layer escapes the sidebar's own `overflow-y: auto` clipping — an absolutely
  positioned panel is cut off at the rail's edge, which is what would have made
  a plain CSS flyout (and the hover tooltip this replaces) unusable.
  Light-dismiss and Esc come free. And only one `popover="auto"` can be open,
  so moving between icons closes the previous flyout with no bookkeeping.
  Positioned against the viewport on open, clamped so a section near the bottom
  of a long menu does not open past the fold.

  Touch is handled rather than assumed: with no hover available, a tap on a
  rail icon opens its flyout instead of navigating, so a touch user on a wide
  screen (a convertible laptop, a tablet in landscape — the rail is `lg`-only)
  can still reach a subtab. Keyboard works because the panel sits immediately
  after its link in the DOM: the top layer changes painting, not the tree, so
  Tab walks straight into it.

  The collapsed rail **marks where you are with a right-edge bar over a light
  primary tint**, rather than the filled block the expanded menu uses — at 5rem
  a solid primary slab is most of the row and reads as a state rather than a
  marker. The tint is `color-mix`-based and preceded by a plain `transparent`
  declaration, so a browser without `color-mix` keeps the bar-only rendering
  rather than the block. Two cases both get it:
  the entry that IS the current page, and the section that merely contains it.
  The second needed new information — expanded, that highlight sits on the
  active subtab, and compact mode hides the subtab list, so the parent now
  states the fact (`data-pk-branch-active`) and the rail's CSS paints it. The
  flyout keeps the ordinary filled highlight; it is a wide panel with text,
  where the block is right.

  Accessibility: labels are visually hidden (`clip-path`), never
  `display: none`, so every link keeps its accessible name and the collapsed
  menu still reads correctly to a screen reader. The toggle carries
  `aria-expanded` and swaps its own `aria-label` with the state.

- **The "Admin Panel" label in the admin header can be turned off.** New
  `show_admin_panel_label` setting (Site Identity, `/admin/settings`), on by
  default — the row is absent on every existing install and
  `get_boolean_setting/2` answers `true`, so nothing changes until an operator
  says so. Off renders just `Project name / Page`.

  **A switch rather than a title field, deliberately.** The obvious version —
  let the operator type their own label — cannot work here: the wording is
  `gettext("Admin Panel")`, already translated in all seven shipped locales,
  and an operator-typed string is one language. A German operator's "Adminbereich"
  would be served to English and Russian visitors too. `project_title` gets away
  with being a plain string because a project name is a brand; "Admin Panel" is
  a common noun phrase. So the setting controls whether the translated string
  renders, not what it says.

  The label also stays subject to the permission gate it already had: it is
  hidden for a visitor holding no admin rights whatever the setting says, since
  `/admin` is the landing every authenticated user can reach and telling
  someone with no sidebar that they are in the "Admin Panel" is the one claim
  on the page that would be false. `<LayoutWrapper.app_layout>` gains a
  matching `show_admin_panel_label` attr — `nil` reads the setting — so the
  header stays renderable, and testable, without a database.

  Unrelated and unchanged: the browser tab still reads `<project> Admin`
  (override it with the existing `default_tab_title` setting), and
  `config :phoenix_kit, project_title_suffix:` still applies only to the user
  dashboard layout, never to the admin header.

- **`Routes.admin_area_path?/1` is now public** — "does this REAL URL land in
  the admin area?", asked of the shape a `?return_to=`, a saved setting or an
  HTTP referer actually has: mount prefix on, locale segment optional. An audit
  of the 39 `phoenix_kit_*` packages found the gap it fills. Of 897 `"/admin"`
  literals across 32 of them, all but one are canonical inputs that the
  emit/read pair already handles — but `phoenix_kit_entities` allowlists a
  client-supplied `_live_referer` with `String.contains?(path, "/admin/")`,
  because core exposed nothing better. That hand-rolled form claims
  `/administrators`, claims a host's own page at `/shop/admin`, and silently
  matches nothing once the admin area is renamed. Pair it with `local_path?/1`
  when the path came from a client — that is the one that rejects `//evil.com`
  and ASCII control characters. Behaviour is unchanged; only the visibility and
  the docs are new.

### Fixed

- **The custom-admin-pages guide taught hosts to hardcode `/admin`.** Its
  worked example used a plain `<.link navigate="/admin/blog/new">`, which
  ignores `url_prefix` (so it was already broken on every install that changed
  the mount) and now `admin_path` too. Switched to `<.pk_link>`, with the
  import the example was missing.
- **`/admin` prefix tests were not segment-aware.** `Routes`' internal
  `admin_path?/1` and the language switcher's admin branch used
  `String.starts_with?(path, "/admin")` / `String.contains?(path, "/admin")`,
  which also claimed `/administrators` and a host page at `/shop/admin`. Both
  now compare whole segments. Cosmetic before — a link built through the wrong
  branch still resolved — but not once a rewrite started acting on the match:
  `/administrators` would have become `/backofficeistrators`.

### Changed

- **The default notification click-through no longer points at the deprecated
  user dashboard.** `notification_default_link` — the catch-all destination for
  a notification carrying no `notification_link` of its own — shipped with
  `/dashboard` as its built-in default, prefilled in the "Default notification
  link" field on `/admin/settings` and described there as the page "every
  signed-in user can reach". That page is deprecated
  (`PhoenixKit.Install.Deprecations.user_dashboard_warning/0`; `phoenix_kit.install`,
  `.update` and `.doctor` have been announcing its removal), and a host can
  compile it out today with `user_dashboard_enabled: false` — so core was
  steering every new install toward a surface it is asking them to leave, and
  the field was the one place an operator would read that recommendation as
  official. The default is now `/admin`, which core declares unconditionally and
  admits **every** authenticated visitor to: `PhoenixKitWeb.Users.Auth.landing_view?/1`
  exempts the admin index from the admin-area gate, so a recipient holding no
  permissions is greeted rather than bounced. That is the same page
  `PhoenixKit.Utils.Routes.safe_destination/2` already terminates on for exactly
  this reason. Hosts that saved `/dashboard` into the settings row while it was
  the prefilled value are unaffected — that value is still honoured, still
  guarded against `user_dashboard_enabled: false`, and can be cleared or
  repointed from the same field.
- **`mix phoenix_kit.gen.user.dashboard` now carries the deprecation notice** it
  generates into. The task writes a page onto the deprecated user-dashboard
  surface, and a host that only ever runs generators never saw the heads-up that
  `install` and `update` print. It is now emitted as an Igniter warning on every
  run and summarised under `--help`, which points at `mix phoenix_kit.gen.admin.page`
  for new work. Advisory only — nothing generated changes, and existing pages
  keep working.
- Documentation examples for `<.pk_link>` / `<.pk_link_button>` and the URL-prefix
  section of `CLAUDE.md` used `/dashboard` as their canonical path; they now use
  `/admin`, so the snippet a developer copies is not the deprecated one.

## 2.13.19 - 2026-09-02

Checkbox alignment (PR #779) and a Git Hooks doctor check that tests the
property it actually cares about (PR #778), plus the post-merge review fixes
for #779
(`dev_docs/pull_requests/2026/779-checkbox-first-line-centering/CLAUDE_REVIEW.md`)
and the catalogue sweep that closes 2.13.18's translation backlog.

### Fixed

- **Described checkboxes sat 2px below their own label.** `<.checkbox>` nudged
  the box down with a fixed `mt-0.5` whenever a `<:description>` was present.
  That constant was tuned for `checkbox-sm`; the default box is 24px and the
  label's line is `leading-6` — also 24px — so the nudge was pure error, and
  `checkbox-xs` was off by a different amount again. The input now sits in a
  `h-6` flex wrapper that centers **any** checkbox size against the first text
  line, and picks up `shrink-0` for every caller instead of only the ones that
  remembered to pass it. The three storage-settings checkboxes that were
  hand-compensating with `class="mt-0.5 flex-shrink-0"` drop their nudges.
- **The notification-preferences form kept a hand-rolled copy of that bug.**
  `Live.Components.UserSettings` built its own `<label>` + `<input>` + text
  block with an `mt-1` nudge on a `checkbox-sm` — 4px of the same error, and
  exactly what `<.checkbox>` exists to prevent. Converted to the component,
  with the description slot guarded by `:if` so preference types without one
  still center. Post-merge review of #779.
- **`mix phoenix_kit.doctor` reported a working Git Hooks setup as broken.**
  The check compared `core.hooksPath` against the literal string `.githooks`,
  so pointing it at any other directory produced a warning — with a "fix" that
  told the reader to point somewhere unrelated to why. It now checks the
  property git actually uses: whether the configured directory holds an
  executable `pre-commit`. `.githooks` is only this checkout's convention.

### i18n

- **Every catalogue is complete again — and 175 entries were serving the wrong
  string.** The de/es/fr/it/pl `default` catalogues each carried 212
  untranslated msgids (the backlog 2.13.18 recorded); all 212 are now
  translated by hand in all five, so all seven translated locales sit at 0
  untranslated across `default`, `errors` and `phoenix_kit`.
- **Cleared every `fuzzy` flag, which was not cosmetic.** Elixir Gettext
  *compiles and serves* fuzzy entries — the flag is only a translator hint —
  so 33 entries per Western locale (and 5 in ru/et) were shipping a
  translation gettext had carried over from a different msgid: "Add a country"
  rendered as *Add account*, "Search countries…" as *Search files…*, "Bedrock
  error %{status}" as *Brevo error*, "Crawler Settings" as *Legal settings*,
  "Verification" as *Notifications*, "Check your timezone" as *Check your
  inbox*. All 175 rewritten against the msgid they actually belong to.
  `en` had one too — "Sign in to request access." was served as *Sign in as
  user*; emptied, so it falls back to the msgid as every other `en` entry
  does, and its 41 inert flags went with it. `grep -c fuzzy` is now 0 across
  `priv/gettext`, which makes a non-zero count a real signal again.
- Line references re-extracted and merged (`mix gettext.extract` +
  `mix gettext.merge`, reported as *0 new, 0 removed, 0 reworded* for every
  locale) after 2.13.18's digest changes shifted them.

## 2.13.18 - 2026-08-31

Dialog layering, component-scoped pushes and an image-quality sweep (PR #777),
plus the post-merge review fixes for each
(`dev_docs/pull_requests/2026/777-pkdialog-esc-layering-component-routing/CLAUDE_REVIEW.md`)
and the igniter-recovery work on the install/update tasks.

### Fixed

- **Esc closed both popups when one dialog was stacked inside another.**
  Chromium groups the close watchers of dialogs whose `showModal()` ran
  without user activation - which is every dialog LiveView opens from a patch
  - so a single Esc fired `cancel` on the whole stack. `PkDialog` now keeps
  the outer dialog open and relays the request to the deepest stacked child in
  its own semantics; `preventDefault` alone was not enough, since Chromium
  stops the grouped chain at the first prevented watcher and the child's own
  cancel then never fired. Openness is matched with `:modal`, not the `open`
  attribute, which morphdom can strip between a patch and the next sync.
- **A component-owned modal's close event landed on the host LiveView.**
  `pushEventTo` with an element resolves the target from that element's
  `phx-target`, which a `<dialog>` does not carry, so the push fell through to
  the LiveView: the item selector's stacked details popup never closed on Esc,
  and the selector itself only "closed" because the misrouted event hit the
  host. Both `PkDialog` and `InfiniteScroll`'s load-more sentinel (useless
  inside a LiveComponent for the same reason) now push to the owning
  component by numeric CID, through one shared helper that stops its search at
  a nested LiveView root - a component on the far side of one belongs to a
  different view, and its CID means nothing to the pushing socket.
- **A stacked close could strand a dialog the server never heard about.** The
  parent marks the child it closed so the child's own `close` handler does not
  double-push - but that handler is exactly what was observed not to run in
  this stack, and the boolean marker then suppressed the child's *next*
  genuine close for the life of the element (the server kept believing it was
  open, and re-opened it on the following patch). The marker is now a
  timestamp with a one-second window, so a stamp whose event never arrives
  expires instead.
- **Tab matching broke on a query-carrying `current_path`.** Pages that
  publish their full URL into `:url_path` (so the language switcher can
  rebuild locale links without dropping state) handed `Tab.matches_path?/2` a
  path with `?…` attached, which no exact or prefix rule could match.
  `normalize_path/1` strips the query and the fragment; matching is about the
  path. `AdminNav.parse_admin_path/1` - the sidebar's own matcher, and the
  reason a highlighted tab could sit above an unhighlighted sidebar item -
  stripped only the query, and its `?tab=` extraction turned `?tab=files#top`
  into the tab `"files#top"`. Both now cut on `?` and `#`.
- **Card-size image slots served the smallest variant.** `resolve_url/2`
  preferred the 150px thumbnail over an 800px medium whenever `small` was
  missing, and an explicit `:medium` request preferred the thumbnail outright
  - the untyped clauses had the ordering inverted relative to the
  `file_type: "image"` clauses they mirror. The media selector's grid also
  asked for the default `:small` tier and stretched a 150px thumbnail across
  an aspect-square tile; it now asks for `:card`, as the media browser's own
  grid already did.
- **Digest notifications rendered in the server's locale, not the
  recipient's.** The digest strings were built with
  `Gettext.dgettext/3` - invisible to `mix gettext.extract`, so they had never
  been translated - and are now `gettext/2` calls that extract normally. That
  alone would not have reached anyone: `gettext/2` resolves the locale from
  the calling process, and an Oban worker starts on the default one, so the
  new translations would have rendered in English for every recipient. Both
  digest surfaces (the channel envelope, which already resolved the
  recipient's locale for the channel, and the persisted in-app inbox row) now
  build their text inside `Gettext.with_locale/3`. `%{label}` stays English:
  type labels are runtime registry data that extraction cannot see.

- **The installer's post-install steps never ran on the recommended entry
  point.** `mix igniter.install phoenix_kit` - the command this task's own
  help recommends - composes installers through
  `Igniter.Mix.Task.configure_and_run/3`, which invokes the task's `igniter/1`
  callback and nothing else. Everything parked in
  `Mix.Tasks.PhoenixKit.Install.run/1` after `super(argv)` was therefore dead
  code on that path: the interactive `mix ecto.migrate` prompt, the asset
  rebuild, and the database connectivity check. Hosts saw
  `• mix ecto.migrate` in the closing notice and were never offered the
  migration, and their assets were never rebuilt after the CSS/JS integration
  wrote to `app.css` and `app.js`. Those steps now ship as a queued
  `mix phoenix_kit.post_install` task (`Igniter.add_task/3`), which runs after
  changes are committed on **both** entry points - and is correctly skipped
  on `--dry-run`, where the old code would have migrated anyway. `run/1` no
  longer duplicates the work.
- **Two "PhoenixKit ready!" banners.** Igniter runs queued tasks before
  printing notices, so a successful migration announced readiness moments
  before the closing notice did. The migration path now reports what it did
  (and the resolved sign-up path) and leaves the banner to the notice, whose
  `mix ecto.migrate` step is marked as applying only if the prompt was
  skipped.

- **The daisyUI version warning accused healthy installs of a rendering bug.**
  `PhoenixKit.Install.DaisyUI.outdated_warning/1` fired below 5.6.0 but its
  copy described the pre-5.1 failure mode (phantom right-edge strip, ~15px
  content shift around modals), so every host in the 5.1-5.5 band - including
  a freshly scaffolded `mix phx.new` app, which vendors 5.5.19 - was told its
  modals were broken when they were not. New `severity/1` splits the two
  bands: `:broken` below `gutter_fix_version/0` (5.1.0, where daisyUI made
  the modal scrollbar gutter conditional) keeps the bug report; `:behind`
  gets an advisory heads-up that says nothing is broken. Unparseable versions
  take the benign branch. `mix phoenix_kit.doctor` makes the same split.
  The floor stays 5.6.0 - it is the release that finished the modal gutter
  fix (`scrollbar-gutter: auto`), not merely a recent tag.
- **Installer notices rendered as orphan `*` bullets.** Igniter renders each
  notice as a `* ` bullet, so the four notices whose heredoc opened with a
  blank line printed a bare `*` with the body pushed to the next line: the
  layout recompile notice, the CSS integration notice, the migration-ready
  notice, and the closing "PhoenixKit ready! Next:" block. All now trim, the
  way the Oban notice already did.
- **`PhoenixKit V2.13.17` read as a migration version.** A capital `V` prefix
  means a migration version in this codebase (`V181`), and the package
  version carried one on the line directly above `Target version: V181`.
  Lowercased.
- **Dropping igniter crashed the igniter tasks instead of explaining
  itself.** Igniter is an optional dependency, so `mix phoenix_kit.install`,
  `.update`, `.gen.admin.page` and `.gen.user.dashboard` are wrapped in a
  compile-time `Code.ensure_loaded?(Igniter.Mix.Task)` guard whose `else`
  branch prints the "add `{:igniter, "~> 0.7", only: [:dev, :test]}`"
  guidance. That branch is chosen when PhoenixKit is compiled into the host's
  `_build`, and PhoenixKit is not recompiled when the host's own dependency
  list changes - so a project that installed while igniter was on the path
  and later dropped it kept a beam that had taken the igniter branch, and got
  `** (UndefinedFunctionError) function Igniter.Mix.Task.help_requested?/1 is
  undefined` from the generated `run/1`. New
  `PhoenixKit.Install.MissingIgniter.ensure_available!/1` re-asks the question
  at the top of each task's `run/1`, so the guidance is printed whether the
  compiled branch was right or has since become a lie.

### Added

- **The igniter-backed tasks now offer to add the dependency instead of only
  naming it.** With igniter genuinely absent,
  `PhoenixKit.Install.MissingIgniter` prints what is missing and asks to write
  `{:igniter, "~> 0.7", only: [:dev, :test]}` into the host's `deps/0`
  (auto-accepted under `--yes`/`-y`), then shells out to `mix deps.get` - a
  fresh OS process, since the running one evaluated `mix.exs` at boot and
  cannot see the new dep. It stops there and names the one command to re-run:
  PhoenixKit itself has to recompile to pick the other side of its
  `Code.ensure_loaded?(Igniter.Mix.Task)` guard, which cannot happen inside a
  run that is already executing the wrong side. Declining, a MIX_ENV where
  `only: [:dev, :test]` would not help, an unrecognised `deps/0` (anything but
  the list shape the generators emit - it never guesses), or a failed fetch
  all fall back to the manual instructions, each carrying only the part that
  is still true - a declined prompt is not re-told what it just declined, and
  a failed fetch is not told to add a line that is already written.
- **The opposite staleness is diagnosed too.** A host that installed
  PhoenixKit *without* igniter and added it afterwards keeps the compiled
  stand-in task, so following its own advice appeared to change nothing.
  `stand_in_run/2` now notices that igniter is loadable and asks for
  `mix deps.compile phoenix_kit --force` rather than repeating the
  instructions the host already followed.

### i18n

- Russian and Estonian catalogues are complete again (ru: 82 untranslated →
  0), including the newly extractable digest strings. The refresh added 57
  msgids overall; de/es/fr/it/pl carry them untranslated (160 → 212) and fall
  back to the msgid, so nothing renders empty - those five still want a
  dedicated sweep.

### Changed

- **The install warning glyph is reserved for things that need attention.**
  The rate-limiter and Oban "configuration added" notices used `⚠️` (and, for
  Oban, `IMPORTANT: Restart your server`) for what is a routine config write
  - on a fresh install there is no server running, and the closing steps tell
  you to start one. They now use their modules' neutral glyphs with the
  restart advice as a parenthetical, correct on both the install and update
  paths. `⚠️` is left to the daisyUI and dashboard-deprecation advisories.

## 2.13.17 - 2026-08-30

Toolchain and test-fidelity release: PRs #773-#776, plus the post-merge review
findings for each (`dev_docs/pull_requests/2026/77{3,4,5,6}-*/CLAUDE_REVIEW.md`).

### Fixed

- **`mix format --check-formatted` was failing on Elixir 1.19.** A reformat of
  `phoenix_kit_doctor_test.exs` pinned one assertion to Elixir 1.18.4's
  line-breaking, which 1.19 undoes - so `mix quality.ci`, `mix precommit` and
  the CI format step were all red on `main` for anyone on 1.19, which
  `elixir: "~> 1.18"` admits. The assertion is now decomposed below the
  break threshold, so no formatter version has a decision to make: verified
  idempotent and byte-identical under 1.19.5 and 1.20.0-rc.6.
- **`.formatter.exs` excluded nothing.** The key was `exclude:`; Mix reads
  `:excludes` (plural, added in Elixir 1.19). `priv/templates` was skipped only
  because no `:inputs` pattern happened to reach it. Corrected to `excludes:` -
  note this filters `:inputs` expansion only, so `.claude/hooks/format-edited-file.sh`
  still needs its own explicit skip for `mix format <path>`.
- **The destructive orphaned-FK doctor test no longer needs superuser** (#774),
  and now proves the branch it was written for. Planting the orphan behind a
  re-added `NOT VALID` constraint routed it to `classify_fk_check/6`'s
  `:validate` clause - which predates the widening fix - instead of the
  `:validated` -> `:existing_orphan` clause that used to discard real orphans;
  the assertion could not tell them apart. It now defers the FK's referential
  check (`ALTER CONSTRAINT ... DEFERRABLE INITIALLY DEFERRED`, plain
  table-owner DDL) so the constraint stays validated, and asserts both
  `convalidated` and the `:existing_orphan` wording.

### Changed

- **The git-guard hook fails closed, and says why** (#773). A missing `jq`,
  malformed JSON, or an absent `.tool_input.command` all used to leave the
  command empty and fall through to `exit 0`. They now block - and, unlike the
  merged version, write a reason to stderr, where a `PreToolUse` hook's exit 2
  actually surfaces it; a missing `jq` is named explicitly, since otherwise it
  silently blocks every Bash call in the session. `git push` with plain
  `--force` is still blocked; `--force-with-lease` no longer is.
- **Format-on-save is scoped to the edited file** (#775). The `Write|Edit`
  hook ran bare `mix format`, rewriting every file in the tree that differed
  from canonical form and mixing that collateral diff into `git status`.
  `.claude/hooks/format-edited-file.sh` formats only the file from the hook
  payload, skips `priv/templates`, and refuses anything outside
  `$CLAUDE_PROJECT_DIR` (realpath + `commonpath`, not a prefix compare).
- **Leaf pinned to 0.6.1** (#776) - lock and the `LEAF_CDN` constant together.
  Conflict reporting on a refused flush (`{:leaf_conflict, ...}` broadcast,
  `@leaf_collab.conflict`, honest `flush_now/1`), `Room.stop/1` and
  `idle_after:` for self-tidying rooms, wiki links following on click in hybrid
  mode, `Leaf.Collab.leave/1`, and the lists-and-checkboxes selection fixes.

## 2.13.16 - 2026-08-30

### Added

- **`<.context_menu>` — right-click and touch-and-hold menus.** New
  `PhoenixKitWeb.Components.Core.ContextMenu` plus a `ContextMenu` JS hook. One
  menu element serves every row it matches: a tree of five hundred nodes renders
  one hidden `<ul>`, not five hundred. On right-click the hook finds the row
  under the pointer, copies its identifier onto each item's `phx-value-*`, and
  opens the menu there — so opening costs no server round-trip and the event
  that fires afterwards still names the right target. Items are
  `TableRowMenu`'s, so a context menu and a `⋮` row menu look identical.
  `value_name` takes a list when a menu's items were written against handlers
  that spell the param differently. Overflow flips the menu to the other side of
  the pointer rather than sliding it, then clamps; the menu is portaled to
  `<body>` while open so `position: fixed` escapes `<dialog>` and `transform`ed
  ancestors. Touch gets a 450ms hold (cancelled by a 10px move) with the
  following click swallowed, and Android's native `contextmenu` de-duplicated.
  Several menus on one page resolve by **deepest match**, not DOM order; `within`
  confines a menu to one region.
- **`<.folder_explorer>` rows are context-menu ready.** Every folder row and leaf
  row carries `data-context-kind` (`"folder"` / `"item"`), `data-context-value`
  and `data-context-label`, so a consumer gets right-click menus by declaring
  the menus alone — no flag, no slot. They sit on the folder's row `<div>` and
  the leaf `<li>`, never on a folder's wrapping `<li>`, so a right-click on a
  nested row resolves to that row rather than its ancestor folder. Consumers
  that declare no menu pay three attributes per row and keep the browser's own
  menu.

Post-merge review of #772 and of `585973ca` (ContextMenu, pushed without a PR)
— see `dev_docs/pull_requests/2026/772-form-field-label-parity/CLAUDE_REVIEW.md`.

### Fixed (post-merge review)

- **Form labels now match `<.input>` exactly, and the four bare `<.label>`
  call sites keep their bottom gap.** #772 removed `fieldset-legend` from
  `FormFieldLabel` on the premise that it shrank and muted those labels. It
  does neither — daisyUI's `.fieldset-legend` sets no `font-size` at all; what
  it sets is `color: var(--color-base-content)` (overriding `.label`'s
  60%-alpha muting) and `padding-block: 0.5rem`. Removing it was still right,
  because that padding was the *only* bottom gap the callers that pass no
  class had (`registration`, `magic_link_registration`, `send_profile_form`
  ×2), and they lost it. `mb-2` now lives in the component, as it does in
  `<.input>`.
- **`<.translatable_field>` labels are the same size as the `<.input>` labels
  beside them.** The 0.75rem came from the component's own `fieldset` wrapper,
  not from `fieldset-legend`, so #772's compensating `text-sm` was a 12px→14px
  bump against a 16px neighbour. Dropping `fieldset` from the wrapper makes the
  span byte-identical to Input's — now pinned by a test that renders both and
  compares.
- **`Mentions.mention_input/1` tracks `<.translatable_field>` again.** The two
  were byte-identical before #772 and render side by side in the same forms.
- **The required marker on `<.select>`/`<.textarea>` matches `<.input>`'s** —
  a non-bold sibling span rather than a bold one nested inside the label span.
- **`ContextMenu`: a long press interrupted by a LiveView patch no longer
  strands a menu in `<body>`** — `destroyed()` cancels the pending timer.
- **`ContextMenu`: `within` honours every matching container**, not just the
  first one `document.querySelector` happened to return.
- **`ContextMenu`: a right-click on empty space closes the open menu** instead
  of leaving it under the browser's native one; the native-menu grace window
  no longer suppresses a right-click when no menu is showing.
- **`ContextMenu`: the post-long-press click is swallowed even if the menu
  closed in between** (Escape, a scroll, an Android URL-bar resize) — the
  swallower was registered and removed with the menu, so the release click
  used to activate the row underneath. The backstop timer is tracked, so
  overlapping presses no longer clear each other's flag.
- **`ContextMenu` docs:** the `MediaDragDrop` collision warning said a
  non-overlapping `selector` avoids it. Rows resolve via `Element.closest/1`,
  so containment collides too — and FolderExplorer is exactly that shape. The
  warning now states the real rule and the workaround that works
  (`long_press={false}`). Not reachable in core: nothing in `lib/` declares a
  `<.context_menu>` yet.

Repo-wide review sweep (no single PR): six areas audited, the verified
defects fixed, the larger items recorded below under "Known / deferred".

### Fixed

**Auth & sessions**

- **Organization invitations are email-bound again.** `accept_invitation_by_uuid/2`
  checked existence, status and expiry but never that the invitation was
  addressed to the accepting user, and `decline_invitation_by_uuid` took no
  user at all — the uuid arrives from a client event, so any signed-in user
  who learned one could join (or cancel) somebody else's invitation. Both now
  return `{:error, :not_invitee}` on a mismatch (case-insensitive); the decline
  API is now `decline_invitation_by_uuid/2`. Registration via an invite link
  only stashes the auto-accept when the registered address IS the invited one.
- **Confirming an account through a verified OAuth email or a magic link now
  closes the pre-hijack window.** Both paths called `admin_confirm_user/1`,
  which only stamps `confirmed_at` — an attacker who pre-registered the
  victim's address kept a working password and live sessions on the row the
  victim was just handed. New `Auth.confirm_user_from_external_proof/1`
  confirms, deletes every token and rotates the stored password hash in one
  transaction; the rightful owner sets a password via "forgot password".
- **Logout no longer 500s** when the browser holds no session stack (stale
  tab / double-click on the unauthenticated `DELETE /users/log-out`) or when a
  secondary account is active but the root token no longer resolves (revoked,
  role change, expiry) — both are now a full logout.
- **Admin user form: editing an email to an already-taken address returns a
  changeset error instead of crashing the LiveView.** `validate_email: false`
  skipped `unique_constraint` along with the pre-flight uniqueness query.
- **Magic-link request page is no longer an account-existence oracle** — the
  registered and unregistered branches used different flash copy.
- **A non-last Owner can be deactivated again.** `status_changeset/2` rejected
  `is_active: false` for every Owner, contradicting the context's
  last-owner-under-lock guard that deliberately allows revoking a compromised
  non-last Owner.
- **`MultiSession.add_account/3` now passes the client IP**, so the per-IP
  login bucket applies to it as it does on the main login form.
- **Magic-link consumption is atomic** (`delete_all` by uuid, branch on the
  row count) — a concurrent replay yields `{:error, :invalid_token}` instead of
  `Ecto.StaleEntryError`. OAuth accounts with no email (GitHub allows it) now
  fail with `{:error, :provider_email_missing}` rather than a
  `FunctionClauseError` inside the transaction.

**Integrations, settings, cache**

- **`Cache.clear_by_prefix/2` no longer crashes a cache started without
  `ttl:`** — its fold matched only 3-tuples, but TTL-less entries are
  `{key, value}`; the `FunctionClauseError` killed the GenServer and dropped
  its `:named_table`.
- **`Encryption.decrypt_fields/1` never returns `enc:v1:` ciphertext as a live
  credential.** With no key resolving (encryption disabled, key store
  unreachable) the map path passed encrypted values through untouched; they
  are now dropped and logged, matching the existing wrong-key behaviour.
- **OAuth token refresh treats a failed persist as an error.** The save result
  was discarded, so a failed UPDATE still returned `{:ok, token}` and — for
  IdPs that rotate refresh tokens — left the burned old refresh token in the
  row.
- **`Settings.get_json_settings_cached/2` fills cache misses from the
  database** instead of returning `nil` for every absent/expired key (the same
  bug `get_settings_cached/2` was patched for).
- **`Integrations.get_integration/1` by uuid only resolves
  `module: "integrations"` rows** — any JSONB settings row's uuid used to
  decrypt-as-integration.
- **Removed the legacy `:cache_settings` ETS table** — it received every
  decrypted setting on warm and was never read or invalidated.
- **File key-store preflight opens its probe with `:exclusive`**, so a planted
  symlink at `<key>.preflight` can no longer truncate the real key.

**Notifications, activity, jobs**

- **External-channel delivery reaches every recipient of a fan-out.** The
  `DeliveryWorker` unique key was `{source_uuid, channel}`, so when one
  activity was routed to N recipients only the first job was inserted within
  the 300 s window. `recipient_uuid` is now part of the key.
- **`Notifications.prune/1` also ages out standalone rows** (`create/1`,
  `create_many/2`, digest summaries) — the delete joined on the activity entry,
  so rows with `activity_uuid: nil` accumulated forever.
- **`Activity.log/1`, `Notifications.maybe_create_from_activity/1` and the
  delivery enqueue `catch :exit`** as well as rescuing — a dead pool exits
  rather than raises, and the business action that logged the activity was
  crashing on a DB blip.
- **`DigestWorker` survives one user's exit** — previously an Oban retry
  re-sent every digest already delivered to earlier users in the sweep.
- **`ScheduledJobs` marks a job failed on `exit`/`throw`** instead of leaving
  the row in `processing` until the stale reclaim and skipping the rest of the
  sweep.
- **`activity_retention_days` of `0` or negative falls back to 90** instead of
  crashing both prune workers daily with a `FunctionClauseError`.

**Built-in modules**

- **Sitemap: an anonymous miss can no longer trigger a full regeneration
  storm.** Any `GET /sitemaps/<unknown>` used to run `Generator.generate_all/1`
  (every source, every language) and then 404 — N bogus filenames meant N
  concurrent full regenerations. Misses within 5 minutes of a full generation
  now 404 directly, and on-demand generation is single-flight
  (`:global.trans`; concurrent callers get a 503 with `Retry-After`).
- **Sitemap scheduler goes through `Oban.insert/1` and `Oban.Repo`** instead
  of the host repo — `Oban.Job` carries no `@schema_prefix`, so on a prefixed
  install jobs landed in `public.oban_jobs`, a table no Oban instance polls.
- **Scheduled sitemap chain survives a skipped or failed run.** A scheduled job
  that returned early (base URL briefly empty) or errored never rescheduled, so
  regeneration silently stopped until the next boot.
- **Video processing parses `ffprobe` output by key** (`stream=…:format=
  duration`) instead of positionally — WebM/MKV carry duration on the format,
  not the stream, so the old `[w, h, d] =` match crashed and the file never
  became active.
- **`SyncFilesJob` is unique** across `available/scheduled/executing`; the
  LiveView's `persistent_term` guard was node-local and only set once the job
  started, so two clicks before pickup ran two concurrent syncs.
- **Bucket form connection test uses `start_async/3`** — the linked
  `Task.async` took the form down on an HTTP-pool exit.

**Admin UI**

- **`remove_member` on the user-details page only accepts a member of the
  organization being viewed**; any uuid used to be detached, and a bogus one
  crashed the LiveView.
- **Activity index no longer runs the paginated query twice per mount.**
- **Authorization settings and the markdown editor map event params through
  literal allowlists** instead of `String.to_existing_atom/1`.
- **MediaSelector's `return_to` goes through `Routes.local_path?/1`**, the one
  redirect guard (rejects control characters), instead of a local copy.

**Install & migrations**

- **`mix phoenix_kit.update -y` fails when `ecto.migrate` fails** instead of
  printing a warning and exiting 0 with the schema still behind.
- **`mix phoenix_kit.gen.admin.page` refuses to touch a non-literal
  `admin_dashboard_tabs`** (a variable, `base ++ […]`, a helper call) — it used
  to replace the whole value, dropping every page the host had registered.
- **The migrator raises on a version-lookup query error** instead of folding
  it into "fresh install" and replaying the whole chain onto a current
  database.
- **`DbConnectionCheck` rescues/catches** an unstarted repo and reports the
  friendly "cannot connect" message instead of a stack trace.
- **Asset rebuild reports `:rebuild_failed`** when every build command fails;
  `mix phoenix_kit.assets.rebuild` no longer prints "✅ completed" over it.
  `MigrationStrategy` says when the DB was unreachable rather than reporting
  "installed (V00)".

### Known / deferred (recorded, not fixed here)

- Storage: `Manager.public_url/2` issues an S3 `HEAD` per bucket on every
  `<.image>` render (resolve from `FileLocation` rows instead); orphan
  detection hardcodes `table_schema = 'public'` and runs a `LIKE '%uuid%'`
  scan per file on every MediaBrowser mount; `Manager.delete_file/2` reports
  success if any bucket returned `:ok` (Local returns `:ok` for `enoent`).
- Settings: no cross-node invalidation (`Settings.Events.broadcast_setting_changed/2`
  has no callers); read-then-put race can cache a stale value for one TTL.
- Install: supervisor-order rewrite can emit an unparseable `application.ex`
  (trailing commas); `gen.migration` mis-detects the version after
  `consolidate_wrappers`; `modernize_layouts` is a stub that reports success;
  V179/V180 `down/1` can fail on a raw FK violation after a local
  manufacturer delete.
- Auth: reset-password submit does not re-verify the token (upstream
  phx.gen.auth behaviour); `count_remaining_owners/1` in `delete_user` does
  not take the last-owner advisory lock.
- Maintenance: an unparseable schedule `end` value is stored as "no end".

## 2.13.15 - 2026-08-29

### Fixed

- **Repair no longer reports two composite-key PRIMARY KEYs as missing.**
  `phoenix_kit_shop_product_slugs_pkey` and
  `phoenix_kit_shop_category_slugs_pkey` were hand-declared alongside V171 as
  `kind: :index`, but on the catalog they are PRIMARY KEY constraints on a
  composite natural key `(lang, value)` — and the index a `p`/`u` constraint
  owns is deliberately never listed among bare indexes, so the check could
  never match anything. Both read `:missing` on every run, on every install,
  no matter how many times repair ran. They are now declared as constraints.
  Separately, `Probe` keeps constraint-backed index rows in a new
  `constraint_backed_indexes` map instead of dropping them, and a
  `kind: :index` lookup falls back to it — so a manifest entry with the wrong
  `kind` degrades to a shape comparison rather than a permanent phantom. (#762)
- **`mix phoenix_kit.update`'s supervisor-ordering check reads the staged
  edit, not stale disk.** It decided "order is correct" from a fresh
  `File.read!` of `application.ex`, but two earlier steps in the same run
  stage their `application.ex` edits in the Igniter buffer, which is not
  flushed to disk until the run ends. The check could see neither
  `PhoenixKit.Supervisor` nor `Oban`, conclude there was nothing to verify,
  and pass an install whose buffer was genuinely misordered. It now reads the
  same buffer the subsequent fix does. (#763)
- **`Integrations.add_connection/4` rejects unregistered provider keys.** The
  provider arrives from a tamperable client event; an unknown key made
  `Providers.get/1` return `nil`, which made the scope check default to
  `[:system]` and pass trivially, birthing a connection row for a provider
  that was never installed. Unknown keys now return
  `{:error, :unknown_provider}`. (#765)
- **A module registered after the provider cache was warmed now contributes
  its providers.** `Providers.all/0` caches built-in plus external providers
  in `persistent_term` with no expiry, and `ModuleRegistry.all_modules/0`
  answers `[]` until the registry has started — so a module arriving later
  (the parent app's `rescan/0`, a runtime `register/1`, a dev hot-reload)
  stayed invisible to the provider list for the life of the VM.
  `Providers.clear_cache/0` existed for exactly this and nothing outside the
  test suite ever called it. The registry now calls it whenever the module set
  actually changes. This was survivable while an unknown key merely fell back
  to a `[:system]` default; with the `add_connection/4` guard above it meant a
  legitimately installed provider could not be connected at all until a
  restart. (post-merge review of #765)

### Added

- **A repository-level guard against running the test suite on a live
  database.** `config/test.exs` honors `PGDATABASE` so the suite can target an
  already-provisioned database on a role without `CREATEDB` — which also means
  a shell that leaks `myapp_dev` into every process turns a bare `mix test`
  into a silent migrate-and-seed of the real thing. `test_helper.exs` now
  refuses, before anything opens a connection, a database name ending in
  `_dev`, `_development`, `_prod`, `_production` or `_staging`, plus any exact
  name listed in `PHOENIX_KIT_TEST_DB_DENYLIST`. It deliberately does not
  require a `_test` suffix: an arbitrary scratch name is the case
  `PGDATABASE` support exists for and passes through untouched. (#764)
- **Coverage for rotating a restricted setting that is still plaintext.**
  Every existing rotation test seeded through the encrypting write path, so
  none could tell "rotation handles a restricted setting" apart from
  "rotation handles one that was already encrypted". The real row this
  protects — an `oauth_google_client_secret` written before encryption
  shipped — is genuinely plaintext, and the new test asserts both that
  rotation encrypts it and that the live OAuth credential read path still
  hands back the original secret. (#766)

## 2.13.14 - 2026-08-28

### Added

- **`<.folder_explorer>` can show what is in the folders.** It rendered a tree
  of folders and nothing else, which suits MediaBrowser — its files live in a
  grid beside the tree — but not a consumer whose leaves *are* the point. A new
  `items` attr (`%{folder_uuid => [item]}`, with `"root"` for the top level) and
  an `:item` slot interleave leaves with folders the way Obsidian and Finder do.
  Each item needs an `:id`, which becomes `data-draggable-file`, so leaves are
  draggable on the same terms as folders with no work from the consumer. A
  folder holding only leaves now gets a chevron. Empty by default: the
  folders-only tree is unchanged.
- **`show_rename` and `enable_drag` are settable on `<.folder_explorer>`.** Both
  existed on the recursive node and neither was plumbed through the public
  component, so a consumer could not turn off an affordance it had no handler
  for. Defaults are unchanged.

### Fixed

- **`<.folder_explorer>` no longer raises on a folder without a colour.** It
  read `folder.color` directly, which is fine for `PhoenixKit.Media.Folder` and
  a `KeyError` for any other consumer's folder struct — taking the page down the
  moment such a consumer had one folder. Read through `folder_color/1`
  (`Map.get/2`) everywhere.
- **`myself` is optional on `<.folder_explorer>`.** It was `required: true`, and
  every control targets it, which made the component effectively
  LiveComponent-only. Pass `myself={nil}` from a plain LiveView: HEEx omits a
  nil attribute, so the events arrive at the LiveView. Documented rather than
  discovered.
- **Corrected a stale comment in `MediaDragDrop`** claiming folder drags are
  refused by trash targets. V119 added recursive folder trash and the comment
  was left behind; the code accepts files, folders and batches. It cost a
  consumer an afternoon of believing it.

## 2.13.13 - 2026-08-28

### Added

- **Integrations encryption key store** — a rotated secret from
  `mix phoenix_kit.integrations.rotate_key` now survives past the terminal
  it was printed in. `PhoenixKit.Integrations.KeyStore` (file/S3/chain
  backends) persists it, verified by a write-then-read-back check before
  rotation touches any data; `mix phoenix_kit.doctor` and the admin
  Integrations settings page report the same key verdict as the boot-time
  warning, from one shared `Encryption.key_report/0`. (#756)
- **Restricted setting values are encrypted at rest** —
  `oauth_google_client_secret`, `oauth_github_client_secret`,
  `oauth_facebook_app_secret`, `aws_access_key_id`, and
  `aws_secret_access_key` are now written through the same encryption used
  for integration credentials, and decrypted on every read path (including
  the boot-time settings cache warmer). (#759)
- **`config.exs`/`application.ex` splices verify before they're adopted** —
  every regex-based install/update splice (Oban wiring, boot hook, Ueberauth
  fix, dev-mailer guard) now parses the candidate output and confirms the
  intended change actually landed in the right place before writing it;
  otherwise the original content is kept and a manual-fallback message is
  printed. Along the way, fixed a buffer-vs-disk bug that could silently
  discard an earlier install/update step's edit to the same file, an
  unanchored `plugins:`/`crontab:` regex that could match a neighbouring
  app's config, and an unconditional leading comma that could corrupt a
  crontab already ending in one. (#758)
- `<.line_chart>` / `<.sparkline>` gained a `y_invert` attr so rank-like
  data (search position, leaderboard) plots "1 is best, at the top" without
  the caller negating its own values; `table_default.ex`'s `card_media_class`
  attr frames the `:card_media` slot; `<.translatable_field>` forwards
  `phx-hook`/`data-*`/`aria-*` to its underlying input via a new `debounce`-
  configurable `:rest` global attr. (#760)

### Fixed

- **Key rotation silently stranded restricted settings.** The key rotation
  added by #756 only re-encrypted `module: "integrations"` rows; the
  restricted setting values #759 added (same PR cycle) are stored with
  `module: nil` and share the same encryption key, so a routine rotation
  left them under the old key — reads then failed closed (logged, dropped)
  the moment the app restarted onto the new key, taking OAuth login and AWS
  config dark with no warning from the rotation task. `KeyRotation` now
  rotates both row shapes in the same pass.
- The admin dashboard's rotating greeting re-rolled the instant the
  websocket connected (LiveView calls `mount/3` twice per page load), so
  the greeting visibly changed on nearly every visit instead of staying put
  for the page load. (#761)
- The language switcher stacked locale prefixes (`/en/fr/...`) instead of
  replacing one — three drifted copies of the URL builder in `AdminNav`,
  `LayoutWrapper`, and `UserDashboardNav` are now one
  `Routes.locale_switch_path/3`. (#761)
- Bumped the Leaf JS bundle to 0.6.0, with a test holding the CDN pin and
  the Hex lock together. (#761)

## 2.13.12 - 2026-08-27

### Fixed

- **A module tab colliding with a host admin page, or with another
  module's tab, compiled to two `live` declarations at the same path** —
  Phoenix kept the first, the second was dead code, discoverable only by
  chance via the compiler's "this clause cannot match" warning. Host pages
  now always win; ties between modules keep whichever was discovered
  first. (#753)
- The same collision was still possible between two modules'
  `user_dashboard_tabs` — the sibling route family `compile_module_user_routes/1`
  builds, which #753 didn't cover. Fixed with the same dedup logic.
- **"Test Connection" stamped a provider with no way to actually check a
  connection as `"connected"`**, with a fabricated `connected_at`
  timestamp — a check that never ran was indistinguishable from one that
  passed. Such providers now report `:unverified`, threaded through to a
  distinct "Not tested — this provider has no connection check" warning
  (not the green "verified" a real pass gets, not the red "failed" a real
  failure gets) on both the system and personal integration forms. (#754)

### Added

- `mix phoenix_kit.doctor` check 13, **Schema-Declared Relations Without a
  DB FK** — cross-references every `belongs_to` PhoenixKit's own schemas
  declare against `pg_constraint`, reporting (advisory, not a failure) any
  relation with no matching database foreign key. Complements check 12,
  which only ever examines a relationship that already has a declared FK
  constraint. (#755)

## 2.13.11 - 2026-08-25

Every install migrating through V180 crashed outright — a bare
`LOCK TABLE` statement outside a transaction block, `25P01
no_active_sql_transaction`. Not only apps using the catalogue module: the
table V180 locks is created unconditionally by the chain (V149, and the
V135 floor), so **every** release from 2.13.4 through 2.13.10 is affected.
Upgrade straight to this one.

### Fixed

- **V180 (`enforce_one_current_supplier_per_pair/2`) crashed every
  install with `Postgrex.Error: LOCK TABLE can only be used in
  transaction blocks`.** Migration wrappers carry `@disable_ddl_transaction
  true` (core convention — every generated wrapper does this so a long DDL
  statement isn't held inside one giant transaction), so each top-level
  `execute/1` auto-commits on its own and a bare `LOCK TABLE` has no
  transaction to hold. Even accepted, the lock would have released at its
  own commit — before the `UPDATE` and `CREATE UNIQUE INDEX` it existed to
  protect, leaving the concurrent-writer race it was written to close still
  open. Lock, dedupe `UPDATE`, and `CREATE UNIQUE INDEX` now run inside one
  `DO $$` block, same shape V170 already used for
  `phoenix_kit_notifications_dedupe_unseen_idx`. Recovery for an install
  that hit the crash: block 1 of V180 (the manufacturer/supplier
  federation columns) already committed, and the version comment still
  reads `'179'`, so a plain re-run (`mix ecto.migrate` /
  `mix phoenix_kit.update`) completes it — every block-1 statement is
  `IF NOT EXISTS`-guarded.
- **V180's dedupe wrote `updated_at` off by the session's UTC offset.**
  `now() AT TIME ZONE 'utc'` is the right idiom for core's `timestamp
  without time zone` columns, but `phoenix_kit_cat_item_supplier_info`
  declares `TIMESTAMPTZ` (V149): the expression yields a UTC wall clock
  that the assignment then re-reads in the session time zone, so a host on
  `America/New_York` stamped the closed rows four hours in the future. Bare
  `now()` now, as V170's dedupe already used. Only rows this migration
  closes were affected.

### Added

- **Static chain check: no `LOCK TABLE` outside a `DO $$` block.**
  `lock_table_guard_test.exs` already asserted that every `LOCK TABLE` sits
  behind a table-existence guard, but it only ever looked *inside* `DO $$`
  bodies — a bare top-level one was invisible to it, which is how V180
  shipped. Nothing else in the suite can catch this class either:
  `PhoenixKit.Migration.Runner` carries no `@disable_ddl_transaction`, so
  `ensure_current/2` (and therefore `test_helper.exs`, and the full-chain
  prefix test) runs migrations inside a transaction — the one condition
  under which a bare `LOCK TABLE` succeeds.

## 2.13.10 - 2026-08-25

A live install's default (dev-parity) logging wrote OAuth/AWS setting
secrets straight into `/var/log/elixir.log` in cleartext, on two independent
paths — closes the second half of the DOM leak fixed in 2.13.9. Doctor's
orphaned-FK check also grows from 4 hardcoded relationships to every foreign
key constraint on the schema (#751).

### Fixed

- **Saving a Settings/Authorization credential (`oauth_google_client_secret`
  and friends) logged the real value.** `Phoenix.LiveView.Logger` writes a
  `"HANDLE EVENT ... Parameters: ..."` line for every `handle_event`, filtered
  only by `config :phoenix, :filter_parameters` (Phoenix's own default:
  `password`/`token`) — a value the settings form's field names
  (`oauth_google_client_secret`, `billing_stripe_secret_key`, ...) never
  matched. `PhoenixKit.boot/1` now installs `secret`/`api_key` into that list
  itself (merging into `{:keep, [...]}` mode; replacing an already-compiled
  filter with a fresh one carrying Phoenix's own default plus these — found,
  by a destructive test, that Phoenix pre-compiles this on every boot
  regardless of host config, so "leave an already-configured filter alone"
  meant "leave every real host alone"). Also merges in every
  `PhoenixKit.Settings.restricted_setting_keys/0` entry by exact name —
  `aws_access_key_id` names neither half of a keypair by the generic
  words above, so it only gets caught by being on that list. No host
  action required — every app already calls `boot/1` via
  `phoenix_kit.install`/`update`.
- **Every write to `phoenix_kit_settings` was logged with its raw value at
  Ecto's default `:debug` SQL log level** (`UPDATE ... SET value = $1 ...
  [<secret>, ...]`) — the table stores every setting's value in the same
  generic columns, secret or not, and Ecto's SQL logger has no notion of the
  schema (no `redact:` field option reaches it). `Queries.insert_setting/1`
  and `update_setting/1` now pass `log: false`.
- **`mix phoenix_kit.doctor`'s orphaned-FK check covered 4 of 70+ foreign key
  relationships** — a hardcoded 4-pair list, checked and printed `PASS`, which
  read as "everything is fine" but only ever meant "the four pairs we
  happened to list are fine". Two real orphans on a live site sat outside
  those four and were invisible the whole time. Now discovers every
  single-column FK constraint straight from `pg_constraint` (self-maintaining
  — a future migration's constraint is covered without touching this file),
  reports coverage explicitly in every result line ("checked N of M foreign
  key constraints" — zero coverage can never read as `PASS` again, whatever
  caused it), classifies orphans behind an already-`VALID` constraint
  (previously silently discarded), gives a per-constraint probe a 5s time
  budget so one huge table can't hang the whole run, and gives a
  probe-failure-only result its own `:warn` tier instead of the same `:fail`
  red as confirmed data damage. Multi-column FKs are enumerated but not
  probed (reported as "not supported by this check, verify manually").

## 2.13.9 - 2026-08-24

Timezones move from a bare offset to full IANA identifiers, so DST is
tracked instead of frozen at whatever the account's offset was when it was
set; saved integration secrets stop round-tripping into the setup form;
Estonian and Russian translations get another pass (#748, #749, #750).

### Added

- **`phoenix_kit_users.user_timezone` now holds IANA identifiers**
  (`Europe/Helsinki`) instead of a bare offset (`"2"`), so a summer-set
  timezone no longer reads an hour behind once winter DST kicks in.
  `PhoenixKit.Utils.TimeZone` still reads existing offset rows as fixed
  offsets — nothing is migrated in place, only the column widens
  (V181). New `/profile/settings` page for setting it (#750).

### Fixed

- **The "you haven't set a timezone" banner fired for almost every signed-in
  user.** It compared the account's blank preference against the site
  default using identifier-only equality, but a fresh/unmigrated install's
  site default is the legacy offset `"0"`, which can never match an IANA id.
  Added `TimeZone.effectively_same?/2`, which compares effective UTC offsets
  when either side is a legacy offset (#750, post-merge review).
- **A hand-edited `user_settings_path` override could resolve to
  `/users/log-out`**, turning a "Settings" link into a silent sign-out.
  `Routes.user_settings_path/1` now runs the override through the same
  `usable_candidate?/1` guard as `main_page_path/0` (post-merge review).
- Media viewer forced a 1:1 aspect ratio regardless of the actual image;
  settings page content could overflow its container (#750).
- **Saved integration secrets (API keys, bot tokens) were decrypted and
  rendered straight into the setup form's `value=` attribute on every edit.**
  The field now renders empty with an "already configured" placeholder
  instead of the credential; submitting it blank still keeps the existing
  secret rather than wiping it (#748).

### i18n

- Estonian translation gaps filled; a batch of Russian strings that were
  fuzzy-matched onto the wrong English source corrected (#749).

## 2.13.8 - 2026-08-24

Authentication and session flash messages now go through gettext, so a
non-English visitor is no longer greeted in English after signing in
(#747).

### Changed

- **Auth, session, OAuth, magic-link, registration, confirmation, and
  password-reset flashes resolve through gettext.** Named `%{}` bindings
  replace `#{}` interpolation so the strings extract. `Users.Auth` now
  `use`s Gettext itself (`:verified_routes` does not pull the macros in).
  One pre-existing `Gettext.dgettext/3` runtime call is a macro, so
  extract can see it. Estonian translations are filled in; other locales
  stay on the English msgid until they are translated (#747).

### Fixed

- **Inline magic-link errors were still English on an otherwise-translated
  page.** The flash half of `error_state/3` was wrapped; the alert rendered
  next to it was not. `MagicLink`'s `:error` assign (never a flash) was
  the same gap. Both now go through gettext (#747).
- **The two Ueberauth-missing OAuth flashes survived only in `et.po`.**
  `mix gettext.extract --merge` treated them as orphans and deleted them.
  They now live in `default.pot` as well, which is the path the catalog
  header names for a string that cannot be compiled-extracted (#747).

### i18n

- Estonian translations for the auth/session flashes this release
  introduces, including the five leftover inline errors. Fuzzy matches
  from extract (e.g. "Please enter a valid email address" ← "Please
  enter a name") were replaced, not kept (#747).

## 2.13.7 - 2026-08-22

### Fixed

- **`mix igniter.install phoenix_kit` no longer writes `config :phoenix_kit,
  PhoenixKit.Mailer` above `import Config` in `config/runtime.exs`.** On a
  stock Phoenix 1.7+ app (simple `dev.exs` plus a `runtime.exs` that calls
  `System.get_env` — every `mix phx.new` tree) the installer preferred
  `runtime.exs` and inserted the Local adapter at line 1, before the
  `import Config` that defines `config/3`. The next boot then died with
  `undefined function config/3 (there is no such import)`. The Local
  adapter now lands in `config/dev.exs` on that layout. When the installer
  does write `runtime.exs` (no simple `dev.exs`), the block is placed after
  `import Config` and wrapped in `if config_env() == :dev`.
  `mix phoenix_kit.update` relocates any `config` calls that already sit
  above `import Config` and wraps the unguarded 2.13.6 Local adapter in
  `if config_env() == :dev`, so a host that hit this on 2.13.6 boots again
  after upgrading without overriding production mailer config.

## 2.13.6 - 2026-08-22

The second `nav_tabs` adoption wave: daisyUI's underline look, and link
keys that no longer double-prefix module Paths helpers (#746).

### Added

- **`variant={:border}`** — daisyUI 5's `tabs-border` underline look, the
  convention on show-page and settings strips. Unlike `:boxed` there is
  no frame to shed, so no bg/padding overrides ride along (#746).

### Changed

- **`:navigate` and `:patch` now pass through verbatim**, matching
  `Phoenix.Component.link/1`. They used to run through `Routes.path/1`,
  which double-prefixed URLs already built by a module's Paths helpers.
  `:path` is unchanged: it still applies the helper, because its callers
  have always passed unprefixed paths. The two keys are the same link
  *kind* with different prefix rules — not interchangeable spellings
  (#746). Callers that passed unprefixed values to `:navigate` / `:patch`
  against 2.13.5 need to prefix them at the call site (one consumer:
  `phoenix_kit_user_connections`).

## 2.13.5 - 2026-08-21

`nav_tabs` becomes the strip the rest of the ecosystem can actually adopt:
patch links, an unframed variant, nil-tolerant badges, and the daisyUI 5
`tabs-box` class (#744). Companion PRs in seven modules migrate onto it.

### Added

- **`nav_tabs` link keys now mirror `Phoenix.Component.link/1`.** `:navigate`
  for a full LiveView navigation, `:patch` to stay in the current LiveView
  (query-param tabs need this — a navigate remounts and drops socket state).
  `:path` is a permanent alias for `:navigate`, so existing callers do not
  change. Two link keys on one tab raise; a `nil` value counts as absent
  (#744).
- **`variant={:plain}`** drops the daisyUI frame (`tabs-box`) so a strip
  nested in an already-framed container is not double-boxed. `class` can
  only add, which is why callers had been hand-rolling instead (#744).
- **`:badge_class`** lets a tab keep its own badge tone (a pending-requests
  count stays `badge-warning` whether or not it is the active tab) (#744).
- **`tablist_class/2` and `tab_class/2`** are public so tab-*styled* markup
  that is not a tab strip can share one daisyUI definition. The next class
  rename should be a change here, not another sweep (#744).

### Changed

- **`tabs-boxed` → `tabs-box`.** daisyUI 5 renamed the class; the old name
  styled nothing (#744).
- **Optional tab keys treat `nil` as absent**, so `badge: if(n > 0, do: n)`
  renders no badge rather than an empty pill. Zero still renders (#744).
- **`live_sessions`' filter row** uses `<.nav_tabs>`. Its handler now
  matches on `%{"tab" => _}` instead of `%{"type" => _}` — the URL query
  key stays `type` (#744).

### Fixed

- **`import PhoenixKitWeb.Components.Core.NavTabs` is now explicit
  (`only:`)** so a later helper on that module does not silently join
  every LiveView's namespace. `tab_class` / `tablist_class` are the
  intended additions; the same file already documents this failure mode
  on `EmailStatusBadge` (post-merge follow-up for #744).

## 2.13.4 - 2026-08-21

Catalogue manufacturer/supplier links become CRM-federated (V178–V180), and
the Authorization settings page no longer leaks OAuth secrets via the DOM or
application logs (#742, #743).

### Added

- **V178: `phoenix_kit_cat_manufacturers.crm_company_uuid`** — a soft,
  nullable cross-reference onto a CRM party (no FK — optional-module
  boundary), plus partial unique indexes on both `cat_manufacturers` and
  `cat_suppliers`' `crm_company_uuid` so each stays one-to-one against a CRM
  party (#743).
- **V179: `phoenix_kit_cat_items.manufacturer_uuid` becomes a federated
  reference** — a manufacturer can now be a CRM party, not only a local
  `phoenix_kit_cat_manufacturers` row. Adds `manufacturer_source`
  (`local`/`crm_company`) and `manufacturer_name_snapshot` (a tombstone shown
  only when the reference resolves to nothing), and drops
  `phoenix_kit_cat_items_manufacturer_uuid_fkey` — integrity moves to the
  application, as it already had for the item↔supplier junction since V149
  (#743).
- **V180: `phoenix_kit_cat_manufacturer_suppliers` becomes federated on both
  sides** — adds `manufacturer_source`/`supplier_source` and drops both of
  the join table's foreign keys (which carried `ON DELETE CASCADE`). Also
  adds a partial unique index so one item can no longer carry two *open*
  price rows for the same supplier at once; pre-existing duplicates are
  closed (not deleted) during the upgrade (#743).

### Fixed

- **The Authorization settings page (`/admin/settings/authorization`) no
  longer renders real OAuth client secrets into the DOM.** The three secret
  inputs previously round-tripped the real Google/GitHub/Facebook secret
  through `value=`, which meant editing *any other field* re-submitted it as
  part of the full-form `validate_settings` event and Phoenix's own LiveView
  telemetry logger wrote it to the application log. Inputs now always render
  blank with a "secret already configured" placeholder; a blank submission no
  longer wipes the stored secret (#742).

### ⚠️ Upgrade note

If you use `phoenix_kit_catalogue`: upgrade it to a version that includes its
own explicit cleanup of `phoenix_kit_cat_manufacturer_suppliers` links
(`phoenix_kit_catalogue` PR #75) before or alongside this release. V180 drops
the `ON DELETE CASCADE` that used to clear those links automatically when a
local supplier/manufacturer was deleted; an older `phoenix_kit_catalogue`
will silently leave orphaned (but harmless and recoverable) join rows behind
until it's upgraded.

## 2.13.3 - 2026-08-20

Closes an OAuth/AWS secret-value leak on the General and Users settings
pages (#741), plus a post-merge fix for a reset-to-defaults gap the same PR
left open.

### Fixed

- **OAuth login secrets and AWS credentials no longer load into the
  General/Users settings LiveViews** — both mounted with
  `Settings.list_all_settings/0`, holding the real `oauth_*_client_secret`
  and `aws_access_key_id`/`aws_secret_access_key` values in socket state
  even though only the Authorization page renders them. Replaced with
  `Settings.list_public_settings/0`, an explicit allow list
  (`@public_setting_keys`) rather than a blacklist of `list_all_settings/0`
  — a new setting that isn't classified on either list now fails a test
  instead of silently defaulting to exposed (#741).
- **General settings' "Reset to Defaults" no longer overwrites those same
  restricted keys** — the reset handler still called `update_settings/1`
  with the full, unfiltered defaults map (including the 5 restricted keys),
  so clicking Reset silently wiped live OAuth client secrets and AWS
  credentials — `aws_access_key_id`/`aws_secret_access_key` can default to
  the host's real configured credentials, not a placeholder. The confirm
  dialog never mentioned this. Reset now filters through the same allow
  list used at mount (post-merge fix for #741).

## 2.13.2 - 2026-08-19

A catalogue attribute-sets table, an OAuth registration crash fix, and a
sitemap/noindex decoupling flag (#737, #739, #740).

### Added

- **V177: `phoenix_kit_cat_item_attribute_sets`** — the catalogue's item ↔
  attribute-set join backing the attribute-sets rework, with a reserved
  per-attachment `data` JSONB for upcoming per-item value selection (#737).
- **`crawlers_sitemap_exempt_from_no_index`** setting — lets an operator keep
  the sitemap publishing its real URLs while `crawlers_no_index` is active,
  without touching the `noindex` robots meta directive. Off by default, so
  existing installs keep today's lockstep behavior (#740).

### Fixed

- **`Ecto.CastError` on OAuth registration with geolocation tracking
  enabled** — `register_user_with_geolocation/2` merged a string key onto
  atom-keyed `attrs` from the OAuth path, producing a mixed-key map that
  `Ecto.Changeset.cast/3` rejects outright. `attrs` is now normalized to
  string keys before the merge (#739).

## 2.13.1 - 2026-08-18

FK validation, auth-page SEO, an S3-compatible object-storage integration
provider, and a tracked pre-commit hook (#733, #734, #735, #736).

### Added

- **V176 validates existing `NOT VALID` user foreign keys in place** and
  never deletes or nulls a row — a name-matched re-probe after `VALIDATE`
  guards against shape-only false positives. `mix phoenix_kit.doctor`'s
  orphaned-FK probe now fails closed on a probe error instead of reporting a
  pass (#733).
- **Canonical/hreflang tags on the stable auth pages** (login, registration,
  magic-link registration request) via a new `PhoenixKitWeb.Users.AuthSeo`
  helper (#734).
- **`object_storage` integration provider (S3-compatible)** — registers with
  `PhoenixKit.Integrations`, with URL/bucket/region validators covering
  AWS/Backblaze/Cloudflare/China-partition endpoint shapes. This is the
  provider-side half of the bucket `integration_uuid` credential source added
  in 2.13.0 — no admin-UI picker yet (#735).
- **`.githooks/pre-commit`** is now tracked in the repo (`git config
  core.hooksPath .githooks` to enable) and `mix phoenix_kit.doctor` reports
  its status under "Git Hooks" — scoped to a checkout of phoenix_kit itself,
  since the hook is a contributor convention, not something installed into a
  consuming host app (#736).

### Fixed

- **`.githooks/pre-commit` now runs the same steps as `mix precommit`**, in
  the same order (`compile --warnings-as-errors --all-warnings`,
  `deps.unlock --check-unused`, `quality.ci`, `test.js`), instead of a
  weaker, format-mutating `mix quality` that could leave the working tree
  dirty immediately after a hook-approved commit (post-#736 review fix).

## 2.13.0 - 2026-08-18

Storage bucket credentials are now encrypted at rest, with an alternative
credential source for cloud buckets (#732).

### Added

- **`phoenix_kit_buckets.integration_uuid`** — a cloud bucket (S3/B2/R2) may
  now point at a `PhoenixKit.Integrations` connection instead of storing
  `access_key_id`/`secret_access_key` directly. Mutually exclusive with the
  bucket's own credentials — `Bucket.changeset/2` rejects setting both in the
  same change rather than letting one silently win. Not yet wired up to any
  admin UI or a registered `object_storage` integration provider — usable via
  the context API today, a follow-up PR is expected to add the picker (#732).
- **`PhoenixKit.Integrations.Encryption.encrypt_value/1` and `decrypt_value/1`**
  — single-value encrypt/decrypt for callers with one bare field to protect
  (e.g. an Ecto schema field) rather than a full `encrypt_fields/1`-shaped map.
  Same cipher, key derivation, and `enc:v1:` prefix (#732).

### Changed

- **`secret_access_key` on storage buckets is now encrypted at rest**, decrypted
  only at the point of use (`Providers.S3.resolve_credentials/1`) — general
  accessors like `Storage.get_bucket/1` return it as stored. A row written
  before encryption existed stays plaintext until the next save of the bucket
  for any reason (no bulk backfill). `access_key_id` is left as-is — it is a
  credentials identifier, not a secret (#732).
- **`phoenix_kit_buckets.secret_access_key` widened from `varchar(255)` to
  `text`** (migration V175) — the encrypted encoding runs ~1.6x the plaintext
  length, which overflowed the old column past a ~158-char secret (#732).

## 2.12.1 - 2026-08-17

Two defects in the sitemap domain-mode code that landed with 2.12.0, found by
reviewing that release's own follow-up commits after it shipped (#731).

### Fixed

- **Duplicate `<loc>` on the primary sitemap domain.** When the primary
  domain hosts a language that is NOT the site default, and the site default
  has no domain of its own, the default language's unprefixed home page
  re-hosted onto exactly the URL the primary's own language already
  occupied — the same URL twice in one file. The host's own language now
  wins its URL and the colliding domainless entry is dropped (#731).
- **One junk element in `sitemap_non_page_pipelines` emptied the whole
  router-discovery source, silently.** A hand-edited settings value like
  `["phoenix_kit_api", 1]` raised inside `safe_to_atom/1`, which `collect/1`'s
  rescue swallowed — removing every discovered route from the sitemap with
  nothing in the log. Junk elements are now ignored while the good ones still
  apply; this also hardens `sitemap_protected_pipelines`, which shares the
  same helper (#731).

## 2.12.0 - 2026-08-17

Every mapped sitemap domain gets its own static pages, with the review
follow-ups needed to ship it safely (#730).

### Added

- **A mapped sitemap domain now gets its own static pages** (home page and
  any other `sitemap_static_routes` / `sitemap_custom_urls` entry) — a
  language with a domain of its own serves these prefix-free from that host,
  but `Sources.Static` previously emitted them for the default language
  only, so every non-primary domain's sitemap was missing its own home page
  while still listing its products. The prefixed URL this collects is an
  intermediate for `DomainMode` to re-host, not a published one — it never
  reaches the legacy/index set served to unmapped hosts (#730).
- **`sitemap_non_page_pipelines` setting** — an escape hatch for the
  JSON-pipeline route exclusion added in 2.11.0: unlike
  `sitemap_protected_pipelines`, this one *replaces* the default pipeline
  list rather than extending it, so a host that serves real pages through a
  pipeline literally named `:api` can take it off the list. Saving `[]`
  turns pipeline-based exclusion off entirely (#730).

### Fixed

- **`Sitemap.regenerate/1` accepted an unconfigured `site_url`** and would
  have written host-less `<loc>` entries instead of failing — it now returns
  `{:error, :base_url_not_configured}`, matching the guard
  `SchedulerWorker` already had for scheduled regeneration (#730).

## 2.11.0 - 2026-08-17

Sitemap round-out (domainless-language URLs, a real `regenerate/1`, JSON-pipeline
route exclusion), independent integrations encryption keys with rotation, and a
media-annotation comment fix, with etcher bumped to 0.13.1 (#725, #726, #727,
#728, #729).

### Added

- **Integrations encryption key rotation.** `mix phoenix_kit.integrations.rotate_key`
  re-encrypts (or, for a still-plaintext row from before this release, encrypts for
  the first time) every stored integration credential under the currently
  configured key, and the encryption key can now be decoupled from
  `secret_key_base` via a dedicated config, with an admin-UI warning when a host is
  still relying on the legacy shared-key fallback (#728).
- **`sitemap_router_discovery` now excludes JSON-pipeline routes**, not just
  `^/api`-path routes — a route piped through `:api` or `:phoenix_kit_api` is
  recognized as non-page regardless of where it's mounted (a module's own API
  prefix, or a host's infrastructure endpoint like Caddy's on-demand-TLS ask
  hook) (#727).

### Fixed

- **Domain-mode sitemap dropped every URL for a language with no domain of its
  own.** Domainless languages now fall back into the primary domain's file with
  their locale-prefixed path intact, computed the same way as a mapped
  language's alternates (#725).
- **`Sitemap.regenerate/1` returned a "not implemented" placeholder** instead of
  actually regenerating the sitemap; wired to the same `Generator` call the
  sitemap controller already uses (#726).
- **Master comment on a labelled annotation shape repeated the shape's label**
  as the comment body, even though the sidebar already renders the label as the
  thread's heading — post-merge review found the described fallback for older
  `phoenix_kit_comments` releases didn't actually work (the new
  `allow_empty_content` flag doesn't exist in any released version, so the
  bodiless-content attempt always failed and **Reply silently did nothing** for
  every labelled shape); fixed by retrying with the label as content on that
  specific failure, so the flow works today and upgrades transparently once
  `phoenix_kit_comments` ships real support for the flag (#729).
- **etcher bumped to 0.13.1** — the annotation tooltip anchored above the shape
  element, which for a labelled shape is exactly where the label floats,
  covering it; the anchor box is now the shape unioned with its label and badge
  (#729).

## 2.10.0 - 2026-08-17

Locale resolution gets smarter about dialect/bare-code mismatches, hosts
running multiple domains gain a request-scoped default-language override, and
sitemaps can now be generated, cached, and served per domain (#722, #723,
#724).

### Added

- **Multilang dialect/bare-code resolution.** Reading translatable content no
  longer requires an exact locale-code match — a bare code (`"en"`) resolves
  against a full-dialect record (`"en-US"`) and vice versa, and a same-base
  sibling is used as a deterministic, primary-preferring fallback when the
  requested code has no data of its own. `PhoenixKitWeb.Users.Auth` gained
  `resolve_active_dialect/1` (resolves a base code to the host's actually
  *enabled* dialect) and `put_gettext_locale/1` (de-duplicating the
  `Gettext.put_locale/2` pair previously repeated at 7 call sites); LiveView
  navigation to a full-dialect URL segment (`/en-GB/...`) is now honored the
  same way the HTTP plug already honored it (#722).
- **`PhoenixKit.Modules.Languages.put_request_default_language/1` /
  `request_default_language/0`.** A `Process`-scoped override that
  `get_default_language/0` consults before falling back to the configured
  `is_default` language, for multi-domain hosts that want a different
  default language per request. `pass nil` or `""` to clear it. Explicitly
  process-scoped — not inherited by `Task`/Oban (#723).
- **`PhoenixKitWeb.Integration.extra_on_mount/0`**, read from
  `config :phoenix_kit, :extra_live_session_on_mount`, prepended to the
  `on_mount` list of every `live_session` PhoenixKit generates (public,
  admin, authenticated dashboard, deprecated user-dashboard, maintenance),
  so a host can hook `put_request_default_language/1` into its own
  domain-resolution logic on the LiveView socket path (#723).
- **Per-domain sitemap generation, storage, cache, and serving.** A host app
  can map several domains to distinct languages (one domain = one canonical
  language); `PhoenixKit.Modules.Sitemap.DomainMode` builds a per-host
  `sitemap.xml`/`sitemaps/*` set by re-hosting each language's
  already-collected entries and computing cross-domain hreflang alternates
  once per canonical group. Host strings are validated/normalized once and
  re-validated in `FileStorage` as defense in depth; `Cache.invalidate/0` and
  `cleanup_stale_domain_dirs/0` sweep per-host directories so stale/renamed
  domains don't linger (#724).

### Fixed

Post-merge review of #722/#723/#724 found and fixed the following before
release:

- **`same_base?/2` collapsed genuinely distinct sibling dialects** (e.g.
  independently-maintained `en-US` and `en-GB` content), not just
  bare/dialect naming-drift of the *same* language slot. Saving a secondary
  dialect tab could silently overwrite the primary language's data, or
  promoting a dialect to primary could delete an unrelated sibling as a
  false "ghost." Narrowed the equivalence to same-string or literal
  bare-code-of-the-other only.
- **Request-scoped language override lost to a same-base dialect earlier in
  the configured list.** An exact-code override (e.g. `"fr-CA"`) could
  resolve to a different, earlier-listed dialect of the same base (`"fr-FR"`)
  on any host with 2+ enabled dialects sharing a base, because the lookup
  OR'd "exact match" and "base match" into one `Enum.find/2` pass instead of
  trying exact matches first.
- **`put_request_default_language("")` silently forced English** instead of
  behaving like "no override" (its documented behavior for `nil` and for any
  unknown/disabled code) — a naive host plug computing the override from an
  unmapped host (`Map.get(domain_map, host, "")`) would trip this on every
  unmapped domain.
- **Domain-mode sitemap generation force-collected in index mode**,
  bypassing `enabled?/0` and leaking a disabled source's URLs into the
  public, crawlable per-domain files — even though those same URLs were
  correctly absent from `/sitemap.xml` and every per-module file. Index-mode
  domain-file collection now honors `enabled?/0` exactly like the legacy
  per-module path; flat mode's existing, separately-documented force-collect
  behavior is unchanged.

## 2.9.0 - 2026-08-17

Media file-type integrity gets defended at the write boundary and repaired
for rows already corrupted, and the media viewer's shape annotations grow a
real discussion flow (#721).

### Added

- **Annotation discussions.** Drawing a shape on the media viewer's canvas
  no longer opens a composer — every kind saves silently, with labels typed
  through Etcher's inline editor. The tooltip gets three header buttons
  (Etcher 0.13's `tooltipActions`): **Reply** lazily creates the shape's
  master comment (content = label, author = shape creator, backdated to the
  shape's creation) and opens a body-only popup that threads under it;
  **Edit** reopens Etcher's inline label editor; **View** scrolls the
  sidebar to the shape's thread. Shapes show a live comment-count badge that
  refreshes on create/delete via the existing comments PubSub relay.
- **`Storage.store_file_in_buckets/7` `:mime_type` opt.** Callers can now
  pass the browser-observed mime (`client_type` / `content_type`) so it's
  stored verbatim instead of guessed from the extension; all core upload
  call sites (`UploadController`, `MediaBrowser`, `MediaSelectorModal`,
  `MediaSelector`) now pass it.
- **`Storage.display_file_type/1`.** Reconciles a stored row's `file_type`
  against its own mime/filename evidence for display, so a row misclassified
  before this release (e.g. a `.mov` stored as `"image"`) renders correctly
  without needing the repair migration to have run.
- **V174 migration** — repairs media rows corrupted by two now-fixed writer
  defects: blank/octet-stream mimes with a known audio extension get the
  real audio mime (files and file instances), and generic `file_type` values
  contradicted by the mime are reclassified. System types (`"tile"`) and
  rows without evidence are left untouched; the migration is idempotent and
  its `down/1` is deliberately a no-op (there's no record of the pre-repair
  values to restore).

### Fixed

- **Upload paths could poison `file_type` for every downstream surface.**
  The storage write boundary now cross-checks a caller's claimed `file_type`
  against the mime/filename evidence and corrects a contradicted generic
  claim, so one careless call site (e.g. an external module hardcoding
  `"image"`) can no longer break the thumbnail grid, type filters, and
  variant processing for every file it uploads.
- **`determine_mime_type/1` had no audio entries.** Every `.mp3`/`.m4a`/
  `.wav` guessed from an extension landed as `application/octet-stream` and
  was served that way. Now routed through `MIME.type/1` with an audio
  fallback map for the extensions it still answers octet-stream for.
- **Etcher label text silently vanished on reload.** `annotation_unchanged?`
  compared geometry/style/kind only, so a label typed into Etcher's inline
  editor (the only way text/callout/dimension shapes collect text since
  Etcher 0.12) changed nothing the comparison looked at and the write was
  skipped.
- **Committing a shape label crashed the LiveView.** The sync path read a
  curated map (as `load_annotations_for/1` produces it) as if it were the
  `Annotation` schema struct.
- **Deleting a sidebar comment killed the whole LiveView**, which read as
  "the page refreshed and the media modal closed" — the `Embed` macro now
  handles the `{:comments_updated, ...}` message the comments component
  reports to the host process.
- **The media viewer's connector anchors are now hard-disabled** (`connectors={:off}`)
  instead of following a shared saved preference that could follow a user in
  from boards, where the anchors point at nothing.
- **Lightbox video/audio sizing.** Video fills the column via
  `object-contain` instead of floating as a tiny box at its intrinsic size;
  the audio player is centered with a max width instead of stretching full
  width.
- **`default.pot` extraction drift + missing translations.** The composer's
  copy change ("Reply to this annotation") had never been extracted;
  re-extracted and translated into de/es/et/fr/it/pl/ru.

### Dependencies

- **etcher 0.13.0** (was 0.12.1) — adds `tooltipActions` and the hard
  `connectors={:off}` layer option.

## 2.8.1 - 2026-08-16

### Added

- **UploadGuard.** `Core.FileUpload` now blocks accidental tab close/refresh
  while a file is mid-upload — the browser's native `beforeunload` dialog
  fires instead of silently losing an in-flight transfer (LiveView uploads
  aren't resumed). Applies to both the drag-drop and button variants (#720).

### Changed

- **`Core.FileUpload` static strings are translatable.** "Cancel upload",
  "Drag files here or click to browse", "Drop your files to upload", and
  "Maximum file size: …" now go through `gettext`; the `label` attr defaults
  to a translated "Upload Files" instead of a hardcoded string (#720).

### Fixed

- **`default.pot` extraction drift.** `Core.ColumnSettings`' "Columns" and
  "Shown" labels (added in 2.8.0) had never been extracted, leaving them
  untranslated in every non-English locale. Re-extracted and translated into
  de/es/et/fr/it/pl/ru.

## 2.8.0 - 2026-08-16

The admin header becomes a real breadcrumb for drill-down pages, and
catalogue's live column editor lands in core as a reusable modal. UrlState
stops leaking router path params into every patched query (#719).

### Added

- **`page_crumbs` on `app_layout`.** Extra `%{label, path | patch}` crumbs
  between `page_section` and the page title for pages nested deeper than
  one level. The last crumb stays visible below `sm`; earlier crumbs and
  the section drop first, so a drilled page reads `… / parent / page`
  instead of the bare title (#719).

- **`Core.ColumnSettings`** (`<.column_settings_modal>`). Live
  column-configuration modal: Shown list (SortableGrid drag-reorder,
  remove) beside Available (click to add), Reset + Close, no Apply
  step. Labels accept strings or 0-arity functions. The consumer owns
  the catalog, selection, and persistence (#719).

- **`table_row_menu_link` `patch` attr.** Same-LiveView navigation for
  menus that drill via `push_patch` (#719).

### Changed

- **Admin header progressive collapse.** Below `lg` the site name and
  "Admin Panel" give way to a home-linked `…`; below `sm` the trail
  truncates from the left rather than collapsing to the page title
  (#719).

### Fixed

- **UrlState extras come from the URI query string**, not LiveView's
  merged params map. A `/:uuid` segment was being re-encoded into every
  patched URL (`?q=oak` became `?q=oak&uuid=<uuid>`). `decode/2`'s spec
  now admits `:not_mounted_at_router` (#719).

- **ColumnSettings Shown list is actually sortable.** Rows use the
  `sortable-item` class SortableGrid reads; a custom `.col-item` was
  silently ignored. Drag starts on `.pk-drag-handle` only (post-merge
  review of #719).

- **`page_crumbs` accept `patch:`** for same-LiveView drill trails,
  matching the row-menu attr the PR already added (post-merge review
  of #719).

- **`column_settings_modal` is imported** with the other list-UI
  primitives (post-merge review of #719).

## 2.7.0 - 2026-08-15

Catalogue gets reusable, translatable attribute groups; list tables grow a
comfortable density between compact and cards; uploads say what is happening
after the bar hits 100%. Chain moves V172 → **V173** (#718).

### Added

- **V173 — catalogue attribute groups.** Four tables (groups / attributes /
  values / item assignments) for `phoenix_kit_catalogue`: a group owns
  ordered attributes, each attribute owns ordered values with an explicit
  `is_default`, and items link through a join table. One-group-per-item is
  a droppable `UNIQUE (item_uuid)` index, so multi-group later is not a
  data migration. Definition-tree FKs are `RESTRICT`; a group any item still
  references can only be archived. ExpectedSchema entries were emitted from
  a migrated database and `chain_hash` restamped (#718).

- **`Core.TreeTable`** (`<.tree_name_cell>`). File-explorer name cell —
  depth indent, disclosure chevron, optional type icon — that composes
  into `<.table_default>` rows instead of replacing the table. The consumer
  owns the walk and the expanded set (#718).

- **Comfortable view mode** on `<.table_default>` and the `TableCardView`
  hook. The same table with roomier cell padding (`pk-comfy`), sitting
  between compact rows and cards, and the default when nothing is stored
  (#718).

- **Live upload transfer stats.** The `UploadStats` JS hook computes
  transferred bytes, sliding-window speed, and ETA from the patched
  `data-progress` attribute, then flips to a ticking "Processing on
  server…" clock at 100%. Wired through `<.upload_entry_stats>` on both
  `<.file_upload>` variants, the media selector, and MediaBrowser
  (#718).

### Changed

- **FolderExplorer wrapper `class` attr.** The hardcoded `hidden lg:block`
  is now overridable so embeds outside MediaBrowser can pick their own
  breakpoint (#718).

- **Drag handles stay visible.** A muted grip that strengthens on hover
  replaces `opacity-0` + `group-hover/row` — an affordance you cannot see
  is one nobody discovers (#718).

- **Multilang tabs drop the "Content Language" header** by default
  (`show_header` / `show_info` remain as an opt-in). The tab strip itself
  stretches full width (#718).

- **Media picker names its purpose.** Callers pass a `title` (Select
  Avatar, Select Cover Image, …); a locked picker without one derives a
  type-aware heading. Search hides below ten files on a locked picker,
  empty libraries get a type-aware empty state, a dry search offers
  Clear search, and double-click confirms in single mode (#718).

- **MediaBrowser upload drain is two-phase.** Pending stores queue through
  `send_update_after` so a "Processing on server…" row paints before each
  store, and the batch flash waits until the queue is empty (#718).

### Fixed

- **Media picker grid sat flush against the search bar.** The browse
  wrapper's `display:contents` swallowed the parent's `space-y-4`
  (#718).

- **V173 rollback uses plain `DROP TABLE`s** in dependency order. CASCADE
  could have taken out FKs or views a parent app hung off these tables
  (#718).

- **`tree_name_cell` is imported** with the other list-UI primitives, so
  a `use PhoenixKitWeb, :html` caller does not need a manual import
  (post-merge review of #718).

- **Uncontrolled tables first-paint comfortable**, matching the JS hook's
  default, instead of flashing compact until `localStorage` is read
  (post-merge review of #718).

- **Long tree-cell names truncate** inside the flex row instead of
  overflowing the cell (post-merge review of #718).

## 2.6.0 - 2026-08-14

The built-in SEO module becomes **Crawlers** and grows into the one page where an
operator decides who may read the site; the theme system becomes one generated
controller plus a pre-paint bootstrap that hosts can brand from config; shop
slugs get a uniqueness bucket that matches the URL the resolver actually serves;
scheduled jobs stop double-firing; and every vendored CDN pin is now held to its
lock. Chain moves V170 → **V172** (#714, #715, #716).

### Added

- **Crawlers module** (`PhoenixKit.Modules.Crawlers`, settings at
  `/admin/settings/crawlers`, permission key `crawlers`). Per-bot-group access
  toggles over a curated registry — search engines, AI training scrapers, AI
  assistants, SEO tool crawlers, web archives — all default-allowed, so enabling
  the module changes nothing until the operator decides otherwise (#714).

- **Generated `robots.txt`.** The settings page renders the complete file the
  toggles describe, for copy-paste. Core still deliberately does not serve it:
  `robots.txt` is host policy and `Plug.Static` answers before the router (#714).

- **`llms.txt`**, served at the site root and under the kit prefix (same reasoning
  as `/sitemap.xml`), 404ing while the module is disabled. Heading from the project
  title, body from an operator-edited setting (#714).

- **Search-engine verification metas** (`google-site-verification`,
  `msvalidate.01`). Pasting a whole `<meta>` tag extracts the content value (#714).

- **`PhoenixKitWeb.Components.Core.CrawlerMetas`** — a head component that reads its
  own settings, so it renders in ANY root layout. Most installs render the head in
  the host app's root layout, where core's assigns never arrive, and the previous
  assign-based noindex meta silently reached no page on those installs. Core's two
  shells use it; hosts embed one line (#714).

- **`PhoenixKitWeb.Plugs.CrawlerBlocker`** — default-off, honestly advisory 403 for
  user-agents of blocked groups, wired into the kit page pipeline. Policy-file
  scopes skip it on purpose: `robots.txt` and `llms.txt` must stay fetchable by the
  bots they are about (#714).

- **Doctor check "Crawler Visibility"** — warns on noindex left ON for a
  production-looking host, and on a staging-looking host left indexable (#714).

- **`PhoenixKit.Conformance.ComponentAssigns`** — a static check that a HEEx function
  component never reads an assign it neither declares nor assigns itself. The
  compiler validates call sites, never callee bodies, which let a `KeyError` behind
  an `:if={...}` guard ship for four releases (#714).

- **Host-branded themes from config** (`:theme_definitions`). Override a built-in
  palette or define a named theme (`:label`, `:base`, optional `:extends` /
  `:variables`); one validation pass feeds both the CSS and the JS embeds.
  Injection-hardened at both sinks (#716).

- **One theme controller script** (`ThemeControllerScript`) replaces the three
  drifted copies (dashboard inline, admin inline, static `phoenix_kit_themes.js`).
  Pre-paint `ThemeBootstrap` stamps the saved choice — and now ships the palettes
  next to the stamp — so a dark-OS visitor is not painted `color-scheme: dark`
  over light variables. Picker modes `:auto | :dropdown | :toggle`; a light/dark
  pair renders one persistent `aria-pressed` toggle (#716).

- **`PhoenixKit.Utils.Pagination`** — `parse_page/1` and `total_pages/2` (floored
  at 1). The unfloored `ceil` copies fed `1..0` decreasing ranges on empty lists
  (#716).

- **`<button variant="error">` (and info/success/warning).** Status colours are
  first-class variants; appending `btn-error` through `class` collided with the
  variant's own colour and stylesheet order decided who won (#716).

### Changed

- **V172 renames the SEO module to Crawlers.** Settings rows
  (`seo_module_enabled`/`seo_no_index` → `crawlers_*`) are renamed with a dedupe
  guard where the old row's value wins — it is what the running site was honouring —
  and roles granted `seo` gain `crawlers`. The old `seo` permission rows are kept
  deliberately: the repair manifest still lists the V135 `seo` seed, so deleting
  them would set `mix phoenix_kit.repair` and this migration fighting over the same
  row. A deprecated `PhoenixKit.Modules.SEO` shim keeps host callers compiling, and
  frees the `seo` module key for the external `phoenix_kit_seo` package (#714).

- **V171 gives shop slugs a uniqueness bucket of (base language, value).** The
  V52-era expression index on the alphabetically-first key's value under- and
  over-enforced at once: other languages were unconstrained, so collisions surfaced
  far from the save that caused them, while `{"en":"hat"}` and `{"de":"hat"}`
  collided though they can never shadow each other in a URL. Trigger-maintained
  projection tables now enforce the bucket the resolver reads, and their pkeys give
  `phoenix_kit_ecommerce` a real `unique_constraint` to name — a collision comes back
  as a changeset error on `:slug` instead of a raw `Postgrex.Error` (#714).

- **Scheduled jobs are claimed before they run.** The plain `SELECT` let two
  overlapping sweeps — core's cron worker and a host calling the public function, or
  two nodes — both see the same rows and both fire the handler, which host handlers
  are not required to survive. A row is now claimed with a CAS into a new
  `processing` status and only the winner executes; a sweep that dies holds its claim
  until a reclaim window returns the row to `pending` (or to `failed` once attempts
  are spent). Both terminal marks are CAS'd, so a late mark from a slow sweep cannot
  stomp a row that has already been requeued (#714).

- **Every vendored CDN pin is held to the version the lock resolves.** #709 fixed
  leaf's pin and pinned it with a leaf-only test; the three sibling pins in the same
  file had all drifted — etcher by three minors, so none of the 0.12.0 tldraw-parity
  work reached any host. The test is generalized to every `gh/` pin, resolves the
  expected version from `Application.spec/2`, and fails when a pin appears for a
  repo it does not cover (#715).

- **Admin theme picker honours `:dashboard_themes`.** Hardcoding `:all` meant a
  host's narrowed list governed only the user dashboard (#716).

- **Removed unused `ThemeConfig` helpers** (`get_theme/0`,
  `theme_data_attributes/0`, `modern_css_variables/0`, the slider maps). They
  had no remaining in-repo callers; a host still calling them will not compile
  (#716).

- **Route-pattern tabs hide themselves from navigation.** `admin_dashboard_tabs`
  entries whose path carries `:param` or `*splat` segments are routes, not nav —
  they rendered a literal `:uuid` in the sidebar unless every host remembered
  `visible: false`. Detection is per-segment, so `https://`, ports, and `mailto:`
  are unaffected; `visible: true` is the opt-out. Nil-scope callers no longer
  receive `visible: false` tabs unfiltered (#716).

### Fixed

- **A maintenance broadcast killed admins' LiveViews.** The on_mount hook returned
  `{:cont, ...}` for an admin — maintenance never blocks them, so there was nothing
  left to do — which handed `{:maintenance_status_changed, _}` to the LiveView's own
  `handle_info`. Any view without a clause for it (most of them) died in
  `FunctionClauseError` the moment a toggle broadcast, or the hook's own
  end-of-window timer, fired while an admin had the page open (#714).

- **V171's dedup counted slug entries instead of owner rows.** A single row carrying
  two spellings of one language at the same value (`{"en":"hat","en-GB":"hat"}`)
  projects — via the trigger's `SELECT DISTINCT` — to one projection row, so it is
  not a collision. Counting entries made it one: an `active` row in that shape
  aborted the upgrade with `shared by 2 live rows`, naming a second row the operator
  would never find, and a non-live one had a spelling silently rewritten to `hat-2`,
  giving the row two public URLs where it had one. Both loops now count
  `DISTINCT uuid`, and a row that does lose a bucket moves all its spellings to the
  one candidate (post-merge review of #714).

- **`V172.down/1` deleted every `crawlers` permission grant**, though its comment
  promised only the copies `up/1` made. After the upgrade `crawlers` is a first-class
  key in the admin matrix, so a rollback discarded grants an operator had added to
  roles that never held `seo` — and re-running `up/1` could not restore them. The
  delete is now qualified by a surviving `seo` grant for the same role (post-merge
  review of #714).

- **Empty Crawlers string settings failed their first write.** The three optional
  slots (Google/Bing verification, llms.txt extra) were not in `@optional_settings`,
  so the first write of an empty value — with no row yet — failed validation and a
  form saving both slots half-applied: the non-empty one landed, the empty one
  errored, and the flash reported failure (#714).

- **Three doc sites named V170 as the rename migration; it is V172.** V170 is a real,
  unrelated migration, so the stale numbers from an in-flight renumber pointed anyone
  debugging a half-renamed settings table at the wrong file (post-merge review
  of #714).

- **`:crawlers_verifications` was assigned on every LiveView navigation and read by
  nothing.** `CrawlerMetas` reads its own settings, which is the whole point of it;
  the assign-based path it replaced was kept and extended, costing two unguarded
  settings reads per navigation for a value with no reader. Removed;
  `:crawlers_no_index` stays as the published signal for host templates (post-merge
  review of #714).

- **`crawlers_no_index?/0` in the sitemap generator guarded `rescue` but not
  `catch :exit`.** An unreachable database raises on an unowned checkout but *exits*
  on a dead pool (post-merge review of #714).

- **Host `:theme_definitions` never appeared in the default picker.**
  `dropdown_themes(:all)` was the compile-time catalogue only, so a branded
  theme landed in CSS / labels / `system_pair` and not in the picker until the
  host also listed it in `:dashboard_themes` (post-merge review of #716).

- **ThemeBootstrap stamped `phoenix-dark` without shipping the palettes.**
  Standalone admin and every host layout the installer injects into painted
  `color-scheme: dark` over daisyUI's light variables until a later body
  `<style>` arrived. The custom-theme CSS now travels with the stamp
  (post-merge review of #716).

- **Dropdown options had no `data-phx-theme`.** The toggle used the stock
  Phoenix contract; the options put the name only in `JS.dispatch` detail.
  phx.new 1.8's script reads `dataset.phxTheme` and falls back to `"system"`,
  so every dropdown click reset the theme on a host that kept that script
  (post-merge review of #716).

- **`mix phoenix_kit.update` skipped the bootstrap on every phx.new 1.8 host.**
  Any `phx:theme` substring was treated as "already done"; that script's
  `"system"` path *removes* `data-theme`. Those layouts now get the bootstrap
  just before `</head>`, after the stock script (post-merge review of #716).

- **Pagination extract missed `media_selector.ex` and
  `Auth.list_users_paginated/1`.** Same unfloored empty-list `1..0` range the
  helper exists to stop (post-merge review of #716).

- **Referral 0.4 backfill used `function_exported?/3` without
  `Code.ensure_loaded?/1`.** Under a release the new `signup_use_exists?`
  looked missing and the users the feature exists to admit stayed parked
  (post-merge review of #716).

- **Accounts that redeemed a code before the satisfied-stamp existed were
  parked at the referral wall.** The gate now asks the installed module and
  stamps on a hit, so each account pays the query at most once (#716).

## 2.5.0 - 2026-08-14

Ten findings from a high-effort review of the recently merged notifications,
fingerprint-logging and JS-compiler work, two of which needed schema support.
Chain moves V169 → **V170**.

### Fixed

- **Two concurrent upserts for the same dedupe key both inserted.** Parallel
  Oban workers or two nodes both read `nil` from `find_collapsible/2` and both
  created a row, so the user got two unseen notifications for one logical key —
  pinned to the top by the unseen-first ordering — and later refreshes folded
  into only one of them, leaving the stale twin until it was dismissed by hand.
  V170's partial UNIQUE index turns the second insert into a constraint
  violation that `insert_collapsible/3` retries as a collapse (#713).

- **`upsert_inapp/3` ignored the `notifications_enabled` kill switch.** It is a
  host-facing entry point, and "off" that quietly did not apply to the newest
  creation path was not off. Returns `{:ok, :skipped}` like `create/1` (#713).

- **Caller metadata could clobber reserved keys.** Metadata now merges *first*
  and reserved keys stamp on top, so a passed-through map can no longer
  overwrite `dedupe_key` — which silently disabled collapsing — or the display
  keys. Caller keys are normalised to strings, so `%{notification_text: …}`
  cannot coexist with the string key and win by adapter ordering (#713).

- **`find_collapsible/2` lacked `catch :exit`.** A dead pool *exits* rather than
  raising, bypassing `rescue` and crashing the caller its comment promised it
  would not — the soft-failure rule this project applies everywhere else. Both
  clauses log now, so a permanent query bug degrading upsert into
  insert-always is diagnosable rather than silent (#713).

- **The inbox ignored `:notification_updated`.** The bell handled it, the inbox
  did not, so an open inbox showed stale rows at exactly the moment an upsert
  refreshed one. A scrape test now holds the whitelist to *every* event the
  library broadcasts, so the next event added fails the test until the inbox
  handles it (#713).

- **One fingerprint mismatch logged three lines, two of them wrong.** The #705
  dedup had only landed in `fetch_phoenix_kit_current_user`; the scope plug still
  carried the old `"(scope)"` warning and an `:error`-level "possible hijacking"
  line for requests that were then served normally — and the shipped
  `:phoenix_kit_admin_only` pipeline runs both plugs. Verification now runs at
  most once per request, with the verdict cached in `conn.private` and shared
  (#713).

- **`session_label` could never match the sessions UI.** The log used a
  truncated sha256 while the UI shows hex of the raw token's first 4 bytes, so
  the promised log↔UI correlation failed every time. Both derivations are now
  the same one, held together by a test (#713).

### Migrations

- **V170** adds two indexes to `phoenix_kit_notifications`:

  - `phoenix_kit_notifications_dedupe_unseen_idx` — **partial UNIQUE** on
    `(recipient_uuid, metadata->>'dedupe_key')` over undismissed, unseen, keyed
    rows. Serves `find_collapsible/2`'s exact predicate *and* is the uniqueness
    backstop above. Rows without a dedupe key — everything the fan-out path
    creates — are outside the predicate and unaffected.
  - `phoenix_kit_notifications_recipient_unseen_first_idx` — matches
    `order_unseen_first/1`'s ORDER BY term-for-term, so the bell's
    `recent_for_user` and the inbox pages come off an index again instead of
    walking a recipient's whole undismissed backlog on every mount.

  Existing duplicates are **dismissed, not deleted** — all but the newest unseen
  row per `(recipient, key)`, the same "newest wins" choice `find_collapsible/2`
  makes. The fold and the index creation share one `SHARE ROW EXCLUSIVE` lock so
  a concurrent insert cannot re-introduce a duplicate in the gap between them.

## 2.4.0 - 2026-08-14

Slug uniqueness gets both halves it was missing — a changeset helper and the
indexes to back it — plus anonymous entity submissions, and an activity log that
is no longer readable by every dashboard-holder. Chain moves V166 → **V169**.

### Added

- **`PhoenixKit.Utils.Slug.put_slug/3`** — the changeset glue between
  `slugify/2` and `ensure_unique/2` that core never owned, so it was hand-rolled
  **14 times across 8 packages** and each copy got a different subset right. It
  distinguishes the three states `get_change(:slug)` conflates: an explicit slug
  wins, an explicitly blanked one regenerates, and *no slug in the changeset*
  means unchanged — which is what every edit form sends, and why saving one
  used to move a live URL. Suffixes `-2`, `-3` … until free, excludes the row
  itself on update, honours a schema prefix, and takes `:scope` for per-owner
  uniqueness. The probe is an allocator, not an integrity boundary — callers
  still declare `unique_constraint/3`, which is what makes it true (#711).

  Adopters must pin **`{:phoenix_kit, "~> 2.4"}`**: `~> 2.0` resolves to a core
  without this function, and the failure lands in the consumer's app.

- **`PhoenixKit.Activity.full_log_access?/1` and `own_entry?/2`** — the shared
  definition of "may read the whole audit log" and "is this entry mine",
  deliberately in one place so the list and the detail page cannot drift (#712).

### Fixed

- **`/admin/activity` crashed on any entry whose metadata held a map.** A
  field-change diff (`%{"qty" => %{"from" => 1, "to" => 2}}`) was interpolated
  straight into the template, raising `Protocol.UndefinedError` for
  `String.Chars` on a Map. Rendered as `1 → 2` now, via
  `Activity.humanize_metadata_value/1`; legacy rows that stored an `inspect`-ed
  Decimal are unwrapped to the number rather than leaking Elixir syntax (#712).

- **The full activity log was visible to every holder of the `dashboard`
  permission.** It is now administrators-only — Admin, Owner, or a `"*"`
  superadmin role; everyone else sees only entries they authored. Enforced
  server-side in the query (the pagination total is scoped too, so it cannot
  leak the existence of hidden entries), and the detail page answers *not found*
  rather than confirming another user's record exists. "Own" means **actor**,
  not target (#712).

- **Anonymous public entity submissions failed on a freshly migrated database.**
  `phoenix_kit_entity_data.created_by_uuid` was NOT NULL while the public entity
  form is deliberately unauthenticated, so every submission raised a
  `not_null_violation` out of an unauthenticated controller. **V169** relaxes the
  column, resolving a split where long-lived installs already measured
  `is_nullable = YES` and fresh ones `NO`. Auto-filling the first Owner was
  implemented first and rejected: it puts a named person in front of every
  anonymous submission and files it in their audit trail (#711, #706).

- **Eleven `foreign_key_constraint/2` declarations could never match.** Ecto
  matches by name and this chain names most foreign keys `fk_<table>_<column>`,
  not the `<table>_<column>_fkey` the bare declaration derives — so violations
  escaped as raw `Ecto.ConstraintError` 500s across storage, admin notes, OAuth
  providers, role assignments and role permissions. Names were taken from a
  migrated database rather than read off the chain, because a renamed column can
  leave a constraint carrying its old name. A new test pins the rule so the next
  schema cannot repeat it (#711).

- **`ensure_unique/2` overflowed a `:max_length` the caller had already
  applied** — `slugify(title, max_length: 20)` plus `-2` is 22 characters, which
  silently defeats an SEO cap and *raises* against `varchar(n)`. It now trims the
  base per candidate, since `-10` needs one more character than `-9` (#711).

- **`V169.down/1` locked a table it never checked existed.** `up/1` guards its
  `phoenix_kit_entity_data` work on table existence; `down/1` reached straight
  for `LOCK TABLE`, which has no `IF EXISTS` form — so rolling back on an install
  without the entity tables aborted with `relation does not exist`, having had
  nothing to undo. Found in post-merge review; `lock_table_guard_test.exs` now
  pins the rule for every `LOCK TABLE` in the chain.

### Migrations

- **V167** — `phoenix_kit_posts_slug_index` becomes unique. It had been a plain
  btree since V135 while its sibling `post_tags.slug` was unique, so `Post`'s
  `unique_constraint(:slug)` had no index to translate and `get_post_by_slug/2`
  (which fetches with `one()`) raised `Ecto.MultipleResultsError` on any shared
  URL. Existing duplicates are suffixed by the same rule `ensure_unique/2`
  applies at runtime, keeping a reachable post over a draft and then the oldest;
  **two live posts on one slug raises instead**, because which one keeps the URL
  is the operator's call.

- **V168** — the remaining two. `phoenix_kit_tickets` had a plain btree;
  `phoenix_kit_post_groups` had no slug index at all while `PostGroup` named a
  composite `[:user_uuid, :slug]` index that existed nowhere. Post-group slugs
  are unique **per user**, so that index is scoped to the owner.

- **V169** — the nullable creator column and the duplicate `prompt_uuid` foreign
  key described above. The **legacy** `phoenix_kit_ai_requests_prompt_uuid_fkey`
  is the survivor, since it is what the installed base carries and what Ecto
  derives by default, so no live database is renamed.

  The `DROP` before each `CREATE UNIQUE INDEX` is load-bearing:
  `CREATE UNIQUE INDEX IF NOT EXISTS` matches on **name**, so building a unique
  index over a non-unique one of the same name skips with a notice and reports
  success while uniqueness stays unenforced.

## 2.3.0 - 2026-08-13

Localized country selects with operator-chosen pinning, two new integration
providers, and a scheduled-jobs sweep that no longer dies at `:debug`. No schema
change — the chain stays at V166.

### Added

- **Country selects follow the active locale, and an operator can pin the
  countries they actually serve.** `countries_for_select/1`,
  `eu_countries_for_select/1` and `get_country_name/2` take `:locale` (defaulting
  to the active Gettext locale, dialects reduced to their base — `ru-RU` → `ru`)
  and `:priority` (alpha-2 codes pinned to the top, defaulting to the new
  `country_select_priority` setting). Names come from
  `BeamLabCountries.Translations` and a locale with no data falls back per
  country, so a host only ever loses the translation, never the entry. Sorting
  moves to the localized name with NFD accent folding — a deliberate
  approximation, not collation; locales that give diacritics their own alphabet
  position (Estonian's Ü, Swedish's Å/Ä/Ö) are sorted into the base letter's
  block instead. Both functions still work with no arguments (#708).

- **A "Main countries" card on Admin → Settings → Organization** to choose that
  pinned list: drag to reorder, keyboard move buttons alongside (SortableJS is a
  CDN fetch a strict CSP can block, and dragging has no keyboard path), a
  searchable picker, and a suggestion derived from the organization's own
  country by great-circle distance rather than from a constant baked into the
  library. Nothing is pinned until an operator stores a list (#708).

- **GitHub and Amazon Bedrock integration providers.** GitHub takes a
  fine-grained read-only PAT, validated against `/rate_limit`. Bedrock takes a
  long-term API key (plain Bearer, no SigV4) plus a region, validated with a new
  `:amazon_bedrock` strategy that lists foundation models in that region — the
  cheapest call proving the key, the region and `bedrock:CallWithBearerToken` at
  once. Bedrock declares `:ai_completions`; both carry step-by-step setup
  instructions (#707).

- **`mix phoenix_kit.doctor` gained "Oban Cron Queues"** — reports crontab
  entries whose queue this node does not run, resolving queues the way
  `Oban.Plugins.Cron` does and staying quiet where a warning would be wrong
  (`queues: false`, `queues: []`, `testing: :inline | :manual`). Its warning says
  what taking the advice will do: configuring the queue releases the whole
  backlog at once (#710).

- `aws_ses` "Test connection" now reports the account id and which management
  APIs the key may use (SES/SQS/SNS), via the same `CredentialsVerifier` sweep
  the Emails settings page runs. Strictly additive — the send-quota probe remains
  the verdict, and enrichment failing can never downgrade it (#707).

### Fixed

- **The scheduled-jobs sweep died before doing any work, at `:debug`.**
  `ProcessScheduledJobsWorker.perform/1` logged `job.id`, but `ScheduledJob`'s
  key is `:uuid`. `Logger.debug` defers evaluation, so at `:info` the
  interpolation never ran and the mistake stayed invisible; at `:debug` it raised
  `KeyError` before reaching `process_pending_jobs/0`, and with `max_attempts: 1`
  Oban discarded the sweep rather than retrying. A host running debug logging
  published nothing at all, silently, for as long as it ran (#710).

- **Upgrading never added the `scheduled_jobs` queue.** The crontab entry entered
  the generated config on 2025-12-28 without it; the fresh-install block was
  fixed in 1.7.63 but the upgrade path had no helper for that queue, so hosts
  installed in between were never repaired — one was found 15 days in with 21,337
  jobs stuck in `available`, growing ~1,440/day, because Pruner deletes terminal
  states only. `ensure_scheduled_jobs_queue/2` fills the gap (#710).

- **Every `ensure_*_queue` helper now shares one hardened implementation.** The
  six that predated `scheduled_jobs` each hand-rolled the same string surgery on
  the host's `queues:` list and reproduced the same defects — worse than the
  missing queue, because a bad insert *corrupts* `config.exs`: `queues: [\n]`
  wrote `queues: [,`, a nested `default: [limit: 10]` swallowed the insert into
  an option Oban rejects at boot, and an Oban block with no `queues:` of its own
  let the scan walk into a neighbouring application's config. Their unanchored
  guards were also satisfied by a key merely *ending* in the queue's name, so a
  host's own `push_notifications: 5` silently suppressed the real
  `notifications` queue.

- **The cron migration claimed to replace the old posts worker and did not.** The
  replacement literal named `PhoenixKit.Posts.Workers.PublishScheduledPostsJob`,
  a module in no repo — the real one is `PhoenixKitPosts.Workers.…`. The guard
  matched, the replace found nothing, and being `cond`'s first clause it shadowed
  every later case, so the core worker was never added either: an upgrading host
  kept the old entry, gained nothing, and was told the opposite. Hosts running
  both entries are now told to remove one rather than silently given a duplicate
  (#710).

- **The editor bundle is pinned to the leaf release we actually resolve.** The
  CDN tag still served v0.3.2 while hex resolved 0.5.1 — almost everything leaf
  adds is a server↔client contract, so the stale bundle rendered an identical
  editor and quietly stopped implementing what the server expected. A test now
  compares the pin against `Application.spec(:leaf, :vsn)` so the two cannot
  drift again (#709).

- The Organization settings page no longer builds country labels by
  concatenating a nilable flag, which would have raised `ArgumentError` in
  `load_settings/1` and taken the whole page down. Every current
  `beamlab_countries` row carries a flag; this stops depending on that.

- **Role rows are no longer a deadlock hotspot.** Every insert into
  `phoenix_kit_user_role_assignments` makes PostgreSQL take a `FOR KEY SHARE`
  lock on the referenced `phoenix_kit_user_roles` row to validate the foreign
  key — and two paths were taking a conflicting plain `FOR UPDATE` on those
  same rows: `Roles.ensure_first_user_is_owner/1` (the Owner row, on *every*
  registration) and `Permissions.lock_role_for_update/2` (the target role row,
  on every grant/revoke/`set_permissions`). Assigning a role therefore blocked
  on unrelated permission edits, and two transactions each holding one role row
  and then referencing the other's deadlocked outright (`40P01`). Both sites now
  use `FOR NO KEY UPDATE`: neither mutates the role's key, so the guard still
  excludes the writers it exists to exclude while leaving FK checks free.

- **Registration no longer serializes app-wide.** `ensure_first_user_is_owner/1`
  held that Owner-row lock on every single registration, so all registrations
  queued behind one row for the life of the install. Once an active Owner
  exists the answer can never flip back to "you are the first user", so the
  count is now read unlocked and the lock is taken only while no Owner exists.
  A missing Owner role row also rolls back cleanly instead of raising.

- Silenced `DBConnection.OwnershipError` in `PhoenixKit.Settings` reads. It is
  the Ecto-sandbox spelling of `repo_available?() == false`, which this module
  already answers with a silent `nil`; it cannot occur outside a sandboxed
  repo, so no production logging changes. It was emitting ~960 lines per
  `mix test` run and burying real failures.

- Fixed a call to the nonexistent `PhoenixKit.repo/0` in the notifications
  inbox-grouping test (`RepoHelper.repo/0`), which had never run.

### i18n

- New msgids for the Main countries card (`et`, `ru`, `en`) (#708).

## 2.2.0 - 2026-08-11

Notification collapsing, an honest fingerprint log, and a compile-time warning
for a silent JS-hook misconfiguration. No schema change — the chain stays at
V166.

### Added

- **`Notifications.upsert_inapp/3`** (#704) — the GitHub-style collapsing
  entry. A repeat event refreshes the row already standing for the same key
  ("3 new comments on earlier chapters") instead of posting another beside it.
  Only **unseen** rows collapse: once someone has read a notification the next
  event is news again and gets its own row, so nothing new can be hidden inside
  something already dealt with. Broadcasts `{:notification_updated, n}` for a
  refresh and `{:notification_created, n}` for a new row, so an open bell keeps
  up without the caller broadcasting anything. Doing this before meant querying
  the schema directly and re-broadcasting by hand — one host that tried it
  schemalessly stringified `metadata` into the jsonb column and 500'd that
  user's bell.

  `create_inapp/2` now also carries `:dedupe_key` and merges a caller's
  `:metadata`; both were dropped silently before.

- **A compile-time warning when installed modules ship JS hooks the host will
  never load** (#703). `js_sources/0` is consumed only by the
  `:phoenix_kit_js_sources` compiler; a host without it in `:compilers` got no
  bundle, no error and no warning, while the module's templates went on
  rendering `phx-hook` names the LiveSocket had never heard of.
  `phoenix_kit_boards` shipped that state twice before anyone traced it. Silent
  when the compiler is present and when nothing declares a bundle.

### Changed

- **The session-fingerprint log says something worth reading** (#705). A
  user-agent change with an unchanged IP is `:info`, not `:warning` — browsers
  rewrite their UA roughly monthly, for every user, and one reporting app
  carried 765 of these in a single log. Every line now names its session (a
  truncated SHA-256 of the token; the raw token is a bearer credential and
  never reaches the log), and the duplicate line in `PhoenixKitWeb.Users.Auth`
  that said only `"for token"`, naming no token, is gone.

- **A mismatch is logged at the level its consequence earns.** Strict mode
  refuses *every* fingerprint mismatch, so under strict mode all of them log at
  `:error` and say `access denied`; otherwise the request is served and the
  line takes its own severity. Logging "possible hijacking attempt" at `:error`
  and then serving the request is what taught people the log was noise — and
  the inverse was just as bad: a strict-mode host logging someone out over a
  browser update recorded it at `:info`, below the default threshold, so there
  was no record at all.

### Fixed

- **`upsert_inapp/3` could silently stop collapsing forever.** When the row
  vanished between the read and the write, the replacement was posted without
  its dedupe key, so it could never be found again and every later event for
  that key opened a new row.

- **`upsert_inapp/3` could lose an event to a row the user had just dealt
  with.** The `update_all` filtered on `uuid` alone, so a comment dismissed or
  read between the read and the write was refreshed anyway: the update reported
  success and the event ended up recorded only on a row that would never be
  shown again. The unseen/undismissed guard now appears in the write as well as
  the read.

- **The JS-hook warning no longer breaks the build.** It was emitted with
  `IO.warn/1`, which registers a compiler diagnostic — so on any host building
  with `--warnings-as-errors` it failed the compile on upgrade, over a mix.exs
  condition that was not a regression in the host's own code.

## 2.1.0 - 2026-08-11

Notification reads sort unseen first. No schema change — the chain stays at V166.

### Changed

- **A user's notifications now sort unseen-before-seen, newest-first within
  each group** (#702), in both `Notifications.list_for_user/2` and
  `recent_for_user/2`. Plain newest-first interleaved the two, so reading a
  notification left it exactly where it was and anything still outstanding
  ended up scattered among things already dealt with. It mattered most in the
  bell: the dropdown shows ten, so an already-read notification could push an
  unread one off the bottom entirely — the badge counted something opening the
  bell did not show.

  `admin_list/1` is deliberately unchanged. "Seen" belongs to the recipient,
  and an admin scanning everybody's notifications is reading a chronological
  record, not working an inbox.

- **Notification ordering is now total.** `inserted_at` is second-granularity,
  so a fan-out writing many rows inside one second tied every one of them, and
  a tie under `LIMIT`/`OFFSET` lets Postgres return a row on two pages or on
  neither. `uuid` is now the final sort key on all three paginated reads; the
  keys are UUIDv7, so descending on it agrees with newest-first.

### Fixed

- **The notifications inbox rendered duplicate day headers.** `grouped/1`
  chunked rows into day buckets on the day alone, which was correct only while
  the list was globally chronological. Under the new order the day sequence
  restarts at the seen block, so an inbox holding read and unread rows across
  more than one day showed "Today" twice, a week of history apart. Sections are
  now keyed on `{unread?, day}` and the unread run is labelled `Unread · <day>`,
  so the outstanding work is named rather than inferred from row tint.

## 2.0.1 - 2026-08-10

Closes the "reports a problem, then exits 0" gaps across `status`, `doctor` and
`update`, and adopts `locale_slug` 0.2.0 so Cyrillic slugs beyond Russian stop
coming back empty. No schema change — the chain stays at V166.

### Added

- **`mix phoenix_kit.status --exit-code`** (#701). The report is identical on
  stdout whether an install is clean or has a module sitting four versions
  behind, so a deploy script had nothing to gate on. Opt-in, because the default
  is load-bearing the other way: pipelines that run the task purely for its log
  line must not start failing on an upgrade. It **fails closed** — an install
  whose core marker reads `Ready` while the module list was never queried exits
  `1`, since the two reads are independent and a connection dropping between them
  produces exactly the silent pass the flag exists to remove.
- **`mix phoenix_kit.doctor` gains a "Module Schema Versions" check** (#701).
  Core's version marker says nothing about a module that owns its own migration
  chain, so an install could pass `status`, pass `doctor`, and still run code
  against tables several versions behind — surfacing as an undefined-column 500
  on that module's admin page, with no visible connection to the upgrade that
  caused it. Fails on a module that is behind; warns, rather than passing, when a
  version cannot be read at all.
- **`mix phoenix_kit.doctor --exit-code`** (#701 post-merge review). Doctor
  printed `N failures` and `Fix the FAIL items above before running migrations.`
  and then exited `0` — including for the new module-version check, whose whole
  purpose is to catch an install nothing else reports on. `status` and `repair`
  both gate; doctor was the only one of the three that could not. Opt-in, same
  reasoning as above. Warnings deliberately do not gate: several fire on healthy
  installs (a pool capped by `update_mode`, an unlocatable `application.ex`), and
  gating on them would put the flag straight back to a signal nobody can act on.

### Changed

- **`locale_slug` adopted at `~> 0.2.0`** (#701). 0.1.0's Cyrillic layer only
  really covered Russian, and against core's `fallback: :empty` passing the
  *correct* locale reproduced the bug the dependency exists to fix:
  `slugify("Київ", locale: "uk")` and `slugify("България", locale: "bg")` both
  returned `""`, which callers read as "not generated yet" and regenerate
  forever. 0.2.0 returns `kyiv` and `bulgaria`. Cyrillic output is the only thing
  that moves — German, Estonian, Greek, `script: :native` and plain accented
  Latin are byte-identical. Stored slugs are never rewritten. The pin stays
  three-segment on purpose: a revised romanization table changes slugs that are
  persisted in URLs and compared for uniqueness, so adopting a minor is a
  deliberate release decision, not something `mix deps.update` should do.
- **`mix phoenix_kit.repair`'s footer groups findings by kind and by table**
  (#701). A severity count does not say what a run is *about*. A few hundred
  findings on a long-lived database become readable the moment they are grouped —
  on one real install the new footer showed 97 of 265 findings concentrated in
  five warehouse tables, the one fact that makes the report actionable, and
  previously reachable only by reading every line.
- **The "comment ahead of schema" message no longer overstates the damage**
  (#701). `highest_fully_present_version/1` is a `take_while`: it stops at the
  first version with a missing object and never looks higher. Reporting that as
  "objects since N..comment are missing or diverged" claimed a range the check
  had not examined — on a real install the headline read **V35..V166** when all
  that had been established was that V35 was incomplete. The message now names
  the boundary and states plainly what it does not mean.

### Fixed

- **Module schema migrations were skipped when the migrate step aborted** (#701).
  A pending core migration raised *before* `run_module_migrations/1`, so no module
  migration file was ever written — and the error message listed `mix ecto.migrate`
  **first**, which applied the core chain, exited 0, and left the module's tables
  where they were. The files are now written before the raise (including when the
  operator answers "no" at the prompt, which the note says plainly), and the
  advice leads with `mix phoenix_kit.update --yes`.
- **`mix phoenix_kit.repair`'s by-table breakdown invented tables out of index
  names** (#701 post-merge review). The table was parsed as "the segment between
  the first `:` and the first following `.` or `:`", which four of the manifest's
  eight object classes satisfy without carrying a table at all —
  `index:idx_calendar_events_owner_starts_at` was tallied as a table of that
  name. Against the manifest that is 616 index ids (plus 6 sequences, 3
  extensions, 2 functions) inventing single-finding rows, versus 161 real tables.
  Since missing tables come with their missing indexes, the `+N more tables` tail
  was inflated worst on exactly the runs where an operator is trying to judge how
  widespread the damage is — the number the feature was added to provide. Only
  the four table-scoped classes now contribute; deriving a table from an index
  *name* would be guessing, and those findings stay visible under `by kind`.
- **The reworded "comment ahead of schema" message named a version that has
  nothing to be missing** (#701 post-merge review). It derived the first gap as
  `lower + 1`, but `highest_fully_present_version/1` returns the *`since` of the
  last consecutive present bucket*, not an ordinal — its own doctest answers `114`
  for a list whose first absent version is `137`, which rendered as "V115 is the
  first version whose objects are not all present". Reachable in practice: the
  bucket list is only contiguous from the migration floor up, and 28 chain
  versions introduce no manifest object. The first genuinely absent bucket is now
  read from the presence list.
- **`mix phoenix_kit.doctor`'s module check dropped unreadable modules when
  another module was behind** (#701 post-merge review). Its `cond` tested
  "behind" before "unreadable", so a run with both reported only the first and
  the unreadable module vanished from the report entirely — the one condition an
  operator cannot discover any other way, and the reason `StatusReport.next_action/3`
  and the status tree both surface it first. Both are now reported; the severity
  stays `:fail`.
- **The doctor moduledoc's "Checks Performed" list was five checks stale**
  (#701 post-merge review) — missing UUID Primary Keys, User Dashboard, Sitemap
  Discoverability, Demo Auth Pages and the new Module Schema Versions. Rebuilt
  against the order `run/1` actually executes.

## 2.0.0 - 2026-08-10

### ⚠️ Upgrade requirement — databases below V135 must stop at 1.7.236 first

**The migration chain is squashed** (#689). `V01`..`V134` are replaced by a
single `V135` baseline, and V135 is now the chain's **floor**: this release no
longer carries the migration modules below it.

- **At V135 or above** (any install kept current through 1.7.x): nothing to do.
  Upgrade normally.
- **Below V135**: `mix ecto.migrate` raises `PhoenixKit.Migrations.BelowFloorError`
  and refuses, rather than migrating. Install **1.7.236** — the migration bridge,
  the last release carrying the full pre-squash chain — run its migrations until
  the reported version is at least V135, and only then upgrade to this release.
  The error message names the bridge and the procedure.

Check where you are with `mix phoenix_kit.status` **before** upgrading.

**This is why the version is 2.0.0.** Refusing a below-floor install rather than
migrating it is a breaking upgrade contract, and a major version is what stops a
host from being carried across the floor by a routine `mix deps.update`: a
`{:phoenix_kit, "~> 1.7"}` requirement does not resolve to 2.0, so reaching this
release is now a deliberate act with a chance to read this section first.

### Feature modules need a widened pin before you move to `~> 2.0`

`phoenix_kit_*` packages pin core at `~> 1.7.x`, which does not accept 2.0. So
`{:phoenix_kit, "~> 2.0"}` alongside a module that has not yet widened its
requirement is an unsatisfiable dependency: `mix deps.get` fails and names the
conflict. Each module needs a widened requirement and a patch release; none of
them call migration internals, so the change is the pin itself.

**If you stay on `{:phoenix_kit, "~> 1.7"}`, nothing changes for you** — that
requirement does not resolve to 2.0, which is the same property that protects
below-floor installs. Move your own pin to `~> 2.0` once the modules you use have
released theirs; until then the failure is a resolver error at `mix deps.get`
time, not a broken build.

Nothing is rolled back through this release either: a below-floor install cannot
`down` through it.

### Added

- **Verify-and-repair for the schema** (#689). `mix phoenix_kit.repair` compares a
  live database against a generated manifest of what the chain should have
  produced (`PhoenixKit.Migrations.ExpectedSchema`) and can restore what is
  missing; `mix phoenix_kit.repair_uuid` is the maintenance-window path for uuid
  primary-key damage, building its unique index `CONCURRENTLY`. Both report
  before they write, and `mix phoenix_kit.doctor` grew checks that use the same
  manifest.
- **`PhoenixKit.Migrations.BelowFloorError`** (#689) — the explicit refusal
  described above, carrying the database's version, the floor, and the bridge
  release to install. Names 1.7.236 rather than "the last 1.7.x" (#690).
- **`dev_mailbox_enabled` setting and its toggle** (#697) on
  `/admin/settings/email-sending` — the section appears only when the resolved
  transport is the local mailbox, and switching it on states the consequence.
- **`PhoenixKit.Mailer.resolved_send_path/0`** (#697) — the one answer to "where
  will this message actually go": `{:integration, uuid}` or
  `{:mailer, module, adapter}`.
- **Upload rate limiting** (#697) — `RateLimiter.check_upload_rate_limit/1`,
  30/min keyed on the **uploading** account (never the attributed owner, which
  would hand an admin a fresh window per victim uuid).
- **`mix prerelease`** (#690) — the release gate: locked deps, a production
  compile, `quality.ci`, `deps.audit`, `hex.audit`, docs, `hex.build`, and
  `mix phoenix_kit.release_check` (CHANGELOG heading, migration/version sync,
  clean tree, branch, tag collision). It catches release-metadata drift that
  `mix precommit` structurally cannot.

- **Cross-module `@` mentions and `#` record links** (#692). `PhoenixKit.Mentions`
  — typing `@` offers people, `#` offers records from every installed module. The
  mention is stored as a self-contained token carrying its own label, so it
  survives copy-paste, export, edit history and a module being uninstalled, and
  degrades to readable text rather than a broken link. Titles are re-resolved per
  viewer at render: a reader who may not open a record never sees a title
  refreshed after the fact, and visibility fails CLOSED for any resource type
  whose module declares no check. Adds `phoenix_kit_mentions` and
  `phoenix_kit_access_requests` (**V165**), the `<.mention_text>` component,
  `use PhoenixKit.Mentions.Live` for the write side, and `mentions` opt-in
  attributes on `<.textarea>` and the multilang textarea. Settings:
  `mentions_enabled` (default on), `mentions_redact_titles` (default off).
- **Frozen comment attribution** (#692, **V166**). `author_display_name`,
  `attribution_mode`, `attributed_project_uuid` and `attributed_label` on
  `phoenix_kit_comments`: a name resolved at render time re-signs every comment
  its author ever wrote, so what the reader was shown is pinned at write.
  `user_uuid` is never cleared — posting as a project changes what the public
  sees and nothing else.
- **`Notifications.fan_out_from_activity/2`** (#692) — routes one committed
  activity entry to many recipients through the same prefs/channel/digest
  machinery, without inserting extra feed rows.
- **`before_user_delete/1` module hook** (#692) — runs for every discovered
  module before a user row is deleted, while their related rows still exist.
  Best-effort: a hook that raises or throws is logged and never aborts the
  deletion.
- **`ImageProcessor.sanitize/3`** (#692) — re-encodes an untrusted upload to
  known-good bytes (detected-and-allowlisted decoder, first frame only, metadata
  stripped, local resource ceilings, declared-pixel-count refusal). A primitive:
  no core upload path calls it yet.
- **User-dashboard route auto-discovery** (#692) — an external module's
  `user_dashboard_tabs/0` entry carrying a `live_view` now gets its route
  generated, mirroring the admin-tab path.

### Changed

- **⚠️ Local dev-mailbox delivery is now opt-in** (#697, issue #687). A stock
  `mix phx.new` app puts `Swoosh.Adapters.Local` in `dev.exs` and forwards
  `/dev/mailbox` with **no authentication** — and PhoenixKit sends password-reset,
  magic-link, confirmation, email-change and invitation mail through it, each
  carrying a single-use token that exists nowhere else (only its SHA-256 hash is
  stored). Anyone who could reach the dev server could read those links.

  New setting `dev_mailbox_enabled`, default **off**. While it is off and the
  resolved transport is the local mailbox, mail is **not** handed to the adapter:
  recipient, subject and body go to the server log, and the call returns
  `{:ok, %{suppressed: true, …}}` so auth flows still succeed. The gate sits
  before the tracking pipeline, so a suppressed message is not recorded as sent.
  Turn it on for a closed environment at `/admin/settings/email-sending`, or
  configure a send integration there.

  **The cost, named:** an upgraded dev install stops filling `/dev/mailbox` until
  someone flips the switch. Every suppressed send says so in the log, the
  development notice changes visibly, and the settings page carries a banner.
- **⚠️ `GET /api/files/:uuid/info` now requires authentication** (#697) and
  answers only for a file the caller owns, or to an Owner/Admin — with an
  identical `not_found` for a foreign and a missing file, so it is no longer an
  existence oracle. This is documented host API: a caller using it anonymously,
  such as a public gallery front-end, must now authenticate.
- **`Config.mailer_local?/0` resolves the way `deliver_email/2` actually sends**
  (#697, issue #687). It read `config :phoenix_kit, PhoenixKit.Mailer` alone, so
  it was wrong in both directions: `false` on a delegation-mode host whose real
  mailer is Local, and `true` on a host with the installer-written Local block
  that delegates to a real mailer. New `PhoenixKit.Mailer.resolved_send_path/0`
  is the single source — default send integration → delegated host mailer →
  built-in — and anything asking "does mail land in the local mailbox?" must go
  through it rather than a raw config read.
- **The development notice no longer links to `/dev/mailbox`** (#697). It was
  rendered to anonymous visitors on the login, registration, forgot-password and
  magic-link pages — a signpost for a developer and a map for everyone else. The
  copy now reflects the gate's state instead.
- **Slug generation moved onto the `locale_slug` package** (#693) — a new required
  runtime dependency, pure Elixir with no dependencies of its own.
  `PhoenixKit.Utils.Slug` keeps its public shape (`slugify/2`, `transliterate/1`,
  `ensure_unique/2`) and delegates the rule. The hand-rolled table could not
  express a locale, and produced `gro-e-fu-ball` for `Größe Fußball`, `caf` for
  `Café`, `n-c-d-t-st` for `Ünïcödé Tëst`, and an **empty** slug for any
  Cyrillic-only title whose caller forgot `transliterate: true` — which callers
  read as "no slug yet" and regenerated forever. Romanization is now always on
  (`:transliterate` is accepted and ignored), `:locale` and `:max_length` are new
  options, and Greek is covered.

  ⚠️ **Stored slugs are not rewritten and existing URLs are unaffected**, but a
  caller that *re-derives* a slug from a title to look up a row now derives a
  different string. This is not confined to Cyrillic content — see the accented
  Latin examples above.

  ⚠️ **`Slug.transliterate/1` now lower-cases its result.** The old table had only
  lowercase Cyrillic keys, so it left case alone and half-mapped uppercase input
  (`Кашпо` → `Кashpo`). Core's only caller downcases first; external callers that
  need the original casing must keep their own copy.
- **`locale_slug` pinned `~> 0.1.0`** (#693 post-merge review), not `~> 0.1`. The
  looser form admits every 0.x, and the exposure is not the API but the OUTPUT: a
  revised romanization table changes the slug a host derives from the same title,
  and slugs are persisted in URLs. Adopting a new minor should be a deliberate
  PhoenixKit release, not a `mix deps.update` side effect.
- **One canonical `User.display_name/1`, and no more published email addresses**
  (#692). Half a dozen private copies of the name chain ended `|| user.email`,
  which is how a public issue board came to print commenters' full addresses next
  to their words. The chain is now organization name → first+last → username →
  the email's **local part** → `"User"`, with every rung trimmed and rejected when
  blank. Never the full address.

### Fixed

- **`admin_update_user_password/3` wrote the password hash for any caller**
  (#690). The rank rule lived only in the admin edit form, which asks
  `can_manage_user_credentials?/2` to hide the UI and refuse the event — the
  context function itself asked nothing. The actor was already threaded through
  `context` for the audit row, so it now authorizes as well as audits: an actor
  present and out of rank is refused, and an absent actor stays the system path
  for seeds, migrations and mix tasks. Not reachable through the shipped UI at
  the time — this closed the second caller before it existed. See also the
  `custom_fields` bypass below, which was the second caller.
- **`POST /api/upload` and `GET /api/files/:uuid/info` required no
  authentication** (#697). Both live in a scope that fetches a user but never
  requires one. Upload took the file owner from `params["user_uuid"]` with the
  check never written, so an anonymous client could attribute a 100 MB upload —
  and the variant-processing job it enqueues — to any account. File-info handed
  out freshly-signed capability URLs for any file uuid to anyone, defeating the
  signing scheme, and its 200/404 split was a file-existence oracle. Upload now
  authorizes before touching the body (401 when unauthenticated, the `user_uuid`
  override honored only for an Owner/Admin, otherwise attributed to the
  uploader) and is rate-limited at 30/min per account.
- **`update_user_status/3` and `toggle_user_confirmation/2` wrote for a malformed
  actor** (#696). Both ended in a catch-all that performed the *unchecked* write.
  That branch exists for callers with no actor — seeds, mix tasks, and
  `Users.Referrals` expiring an account — but it also swallowed an `:actor` that
  was present and the wrong shape: a map decoded from JSON by a host controller,
  a bare uuid string. `toggle_user_confirmation/2` is the serious one, since its
  unchecked path clears `confirmed_at` and locks the target out of every
  confirmation-gated page. Both now use the three-branch shape from
  `admin_update_user_password/3`. An explicit `actor: nil` still takes the system
  path, identically in all three.
- **A never-analyzed table was sized as 0 rows** (#695). `reltuples = -1`
  (PostgreSQL ≥ 14: never vacuumed or analyzed — a `pg_restore`, a
  `CREATE TABLE AS`, logical replication, autovacuum off) was collapsed to `0`,
  so V163's size guard read "small enough, proceed" for a table nobody had ever
  measured. A restored 200k-row table took `ACCESS EXCLUSIVE` for a full rewrite
  mid-deploy — the exact event the guard exists to prevent. `estimated_rows/3`
  now answers `:unknown`, V163 defers on it, and `mix phoenix_kit.repair_uuid`
  prints "size unknown — never analyzed" rather than "~0 rows" to whoever is
  sizing a maintenance window.
- **`mix phoenix_kit.repair --adopt` stamped over a corrupt version comment**
  (#695). `Repair.Probe` collapsed "no comment" and "unreadable comment" into the
  same `nil`, so the operator was told the comment was *missing* while the table
  said `v164`, and adopt overwrote it — destroying the only record of what the
  last person believed. Unreadable is now its own state and refuses instead.
- **One flaky catalog read could abort V164 mid-run** (#695). Its post-ADD
  verification moved to a probe that *raises*, where the check it replaced
  returned false; V164 has no `rescue` and runs with `@disable_ddl_transaction`,
  so a single failed read on one of ~70 constraints aborted with earlier repairs
  already committed and the version comment never stamped, replaying the whole
  version next time. A probe failure is now one `{:failed, …}` summary line.
- **`comments_fk_on_delete/1` read a constraint by name alone** (#695), so a
  CHECK or a foreign key on a different column owning `fk_comments_user_uuid`
  answered for the real one — an impostor's `confdeltype` of `'n'` read as
  "already SET NULL, nothing to do" and the genuinely missing foreign key was
  never created.
- **`mix phoenix_kit.status --verbose` crashed on an unreadable version comment**
  (#695) — the non-verbose path reported the state correctly and the same run
  then died with `CaseClauseError` immediately after printing a correct tree.
- **A comment-less database reported itself as version 1** (#694). A database
  that is current but has lost its `phoenix_kit` version comment — the
  half-installed or adopted state — resolved to version 1, which is below the
  floor, so `mix phoenix_kit.update` answered "install the 1.7.x bridge first":
  the one instruction the migrator refuses to give, because replaying the
  pre-squash chain over a possibly-current database backfills still-NULL tracked
  columns with invented uuids and then deletes the rows that match no user. The
  state is now distinct from both a real version and "not installed", and routes
  to `doctor` + restamp. `mix phoenix_kit.status` reports it instead of crashing.
- **`mix phoenix_kit.repair` crashed on the anomaly it exists to diagnose**
  (#694). `Repair.Probe.read_comment/2` used `String.to_integer/1` eleven lines
  below a docstring promising it never raises, so the exact hand-edits the
  migrator documents (`'v164'`, `' 164'`) ended the run in a bare
  `** (ArgumentError) argument error`.
- **`ensure_uuid_v7_function/1` aborted migrations on DBA-owned functions**
  (#690). Its `insufficient_privilege` rescue was dead code in migration
  context: `Ecto.Migration.execute/1` only *queues* the statement, so the error
  arrives at flush time where no rescue can reach it. That is the topology
  `PhoenixKit.Migration`'s own moduledoc tells a DBA to adopt, and the helper
  runs on every delta upgrade. The un-ownable case is now excluded before the
  statement is queued, via `pg_has_role` — so a function owned by a role the
  migrating role belongs to is still refreshed.
- **V164 warned "reconcile by hand" about the foreign key it then repairs**
  (#690), and **verified that key by name alone** (#694) — a CHECK constraint
  owning the same name read as present, the guarded ADD failed with 42710 into
  an `EXCEPTION WHEN OTHERS`, and the outcome was reported `:created` with no
  foreign key. `contype = 'f'` is now part of the test.
- **V163's size guard is checked before castability** (#694). `castable?/3` is a
  full-table scan, so asking it first made the deferral path pay an unbounded
  sequential scan on exactly the tables the size limit exists to keep out of
  `mix ecto.migrate`.
- **V165 recorded the schema version as `163`** (#692 post-merge review). Every
  other migration in the chain stamps its own number going up; V165's `up/1`
  stamped two behind, so an install migrated to exactly 165 reported 163 — behind
  where it started — and the next `ensure_current/2` re-ran V164 and V165. A full
  run to head hid it, because V166 stamps immediately afterwards.
- **The `@` mention typeahead no longer issues ~128 queries per keystroke**
  (#692 recheck). `Mentions.Users.search/2` over-fetched and then called
  `Scope.for_user/1` per candidate (roles + permissions each), so a full page of
  results paid two round trips per row. The admin-area rule is now one SQL
  `EXISTS` for Owner/Admin and one for any `role_permissions` grant, with the
  `limit` applied in the database.
- **Access requests no longer accept free-form type/uuid payloads unthrottled**
  (#692 recheck). `AccessRequests.request/4` now requires a type registered in
  `ResourceLinks.handlers/0`, a castable uuid, and a per-account rate limit
  (10 / 10 minutes) — the partial unique index only stops repeats for the *same*
  resource.
- **`ExpectedSchema` knew nothing of V165/V166 objects** (#692 recheck). The
  schema manifest was still stamped at V164, so `release_check` blocked the
  release and `repair`/`verify` would have been blind to the two new tables and
  the comment-attribution columns. V165/V166 objects are now hand-declared
  (same post-generation path as V164) and `chain_hash` restamped over the 32
  shipped files.
- **A record's NAME could inject a markdown link into every mention of it**
  (#692 post-merge review). `to_markdown/2` escapes the value it splices into
  `[text](url)` on the reasoning that the token grammar refuses `]` — true of the
  author's stored label, false of the live resolved title, which is the record's
  current name and unconstrained. Renaming a record to
  `Evil](https://evil.example)` turned every markdown-rendered mention of it, for
  every reader, into a link to the attacker's URL. `]` is now escaped, and the
  destination uses the CommonMark angle form so a `)` in a handler-supplied path
  cannot close it either.
- **`<.mention_text>` told hosts to `use PhoenixKit.Mentions.RequestAccess`**
  (#692 post-merge review), which does not exist — the module is
  `PhoenixKit.Mentions.Live`, and it needs `<.access_request_dialog>` rendered
  alongside it or the click sets an assign nothing reads.
- **The credential rank rule was bypassable through `custom_fields`** (#691).
  `Auth.update_user_fields/2` routes a `custom_fields` key whose name matches a
  profile field out of the JSONB column and writes it to the schema — including
  `:email`, with no confirmation-token flow. The admin user form handed it
  `params["custom_fields"]` verbatim, so the `Map.drop` that protects the profile
  params never saw it: an actor holding only the `users` permission could point an
  Owner's address at their own inbox and then take the account through the public
  password-reset page. The form now filters those names out of `custom_fields`
  unconditionally, `admin_update_user_password/3` enforces the rank rule in the
  context rather than trusting its callers, and the refusal no longer reaches a
  clause that expects a changeset (which crashed the LiveView after the profile
  write had already committed).
- **A present-but-malformed `:admin_user` no longer takes the unchecked system
  path** (#691). Only an *absent* actor is a seed/migration/mix-task caller; a
  value of the wrong shape is a caller that meant to supply one, and is refused.
- **The credential refusal path no longer raises instead of refusing** (#691
  post-merge review). `admin_update_user_password/3` takes its target unguarded
  and `can_manage_user_credentials?/2` answers `false` for a non-`%User{}`, so a
  host passing a JSON-decoded map as the *target* reached a refusal branch that
  pattern-matched `%User{}` and interpolated `user.uuid` — `FunctionClauseError`
  and `KeyError` respectively, where the pre-#691 code returned
  `{:error, :insufficient_permissions}`. A fail-closed guard that crashes has
  failed differently, not safely.
- **The form's filter no longer keeps a second hand-maintained copy of the
  field whitelist** (#691 post-merge review). It read a literal list that
  duplicated the one inside `update_user_fields/2`; adding a profile field to the
  context and forgetting the copy would have re-opened the bypass for that field,
  silently and with the existing tests still green. Both now read
  `Auth.updatable_profile_fields/0`, and a new test poisons `custom_fields` with
  every name in it, so coverage grows with the list.

### Changed

- **`Auth.updatable_profile_fields/0`** (#691 post-merge review) — new public
  reader for the fields `update_user_fields/2` writes to the schema, so callers
  filtering untrusted params read the rule instead of restating it.
  `update_user_fields/2`'s docs now state outright that it does not authorize and
  that `:email` / `:username` are credentials.
- **`StatusReport.next_action/3` gained `{:fix_version_comment, message}`**
  (#694 post-merge review) — the state existed in the function but not in the
  `action()` type, so dialyzer proved the consumer clause unreachable and
  `mix precommit` failed. The comment-less guard also now fails **closed**: it
  required an affirmative "the comment reads 1" only after review, having
  previously fallen through to the destructive advice whenever the confirming
  query could not answer.
- **The admin form logs the identity fields it strips from `custom_fields`**
  (#691 post-merge review). The page renders a real input for every one of those
  names, so such a key on the wire means a client composed its own payload — a
  stronger signal than the rank refusal the context already logs, and it was
  being discarded without a word.

## 1.7.236 - 2026-08-08

### Added

- **V163 repairs `phoenix_kit_*` tables whose `uuid` column is not a proper
  primary key** (#688). A production database reached a state the chain claims is
  impossible: `phoenix_kit_email_events` with `uuid` as `character varying(255)`,
  nullable, no default, and **no primary key at all**, while 149 other tables were
  correct. Three migrations each missed it for a different reason — V40's guard
  tests column *existence* rather than *type*, so an older release's Ecto
  `:string` column made V40 skip the table wholesale (backfill, `NOT NULL` and
  index included) despite the table being listed in `@tables_to_migrate`; V56's
  `ensure_all_uuid_columns_native_type/2` was added seventeen days *after* V56
  shipped, and a recorded version never re-runs; V74 then dropped the legacy
  bigint `id` but could not promote a wrong-typed nullable column to primary key,
  and never verified its own documented post-condition. V163 is therefore
  **catalog-driven** — it asks PostgreSQL which tables are actually broken instead
  of consulting a list the table was missing from every time, including the list
  in the migration written to repair its class of problem.
- **`mix phoenix_kit.repair_uuid`** (#688) — the maintenance-window path for
  tables V163 defers. Runs outside a transaction, so it builds the unique index
  `CONCURRENTLY` and attaches it, holding the exclusive lock only for the attach.
  Supports `--dry-run` and `--prefix`.
- **`mix phoenix_kit.doctor` gains a "UUID Primary Keys" check** (#688). The
  existing type check could not see a *missing key*, which is what the varchar
  column actually cost. Its remedy is also corrected: the single `ALTER` it used
  to suggest restores the type but not the `NOT NULL`, the default or the key,
  leaving anyone who followed it literally still broken.

### Fixed

- **V163's per-table isolation could never have fired** (#688).
  `Ecto.Migration.execute/1` *queues* a command, so the statements were flushed
  after `up/1` returned — outside the `rescue` that exists to keep one table's
  failure from aborting the rest of the run. A locked table would still have taken
  down every repair after it *and* skipped the version marker, the worst outcome
  available. `flush/0` runs the pending commands in scope, so the rescue actually
  catches. The concurrent index name is also derived from the catalog name rather
  than parsed back out of the quoted qualified string, which would corrupt any
  name containing a dot or a quote.
- **V163's row-count guard now covers every repair class, not just the type
  rewrite** (#688 post-merge review). The guard deferred a table only when
  `rewrite_needed?/1` was true, so a table that was already `uuid`-typed but had
  **no primary key** skipped it at any size — and then took a full-table `DELETE`
  self-join, a `SET NOT NULL` scan and a unique-index build, all under `ACCESS
  EXCLUSIVE`, during `mix ecto.migrate`. That is exactly the pool-exhaustion
  outage the two-million-row limit exists to prevent, on exactly the class of
  table that prompted the migration.
- **An interrupted `CREATE UNIQUE INDEX CONCURRENTLY` no longer strands
  `mix phoenix_kit.repair_uuid`** (#688 post-merge review). `CONCURRENTLY` leaves
  an `INVALID` index behind when interrupted; `IF NOT EXISTS` then skipped the
  rebuild on the retry and `ADD PRIMARY KEY USING INDEX` failed on the invalid
  index, permanently. The concurrent path now drops any leftover index first
  (`CONCURRENTLY`, schema-qualified per the chain's `DROP INDEX` rule).
- **`mix phoenix_kit.repair_uuid <table>` no longer answers a named table with the
  global all-clear** (#688 post-merge review). A typo, a mismatched `--prefix`, or
  an already-repaired table produced an empty list and printed "✓ Every
  phoenix_kit table has a proper uuid primary key" — an assertion about every
  table, made after checking none. V163's log tells operators to run this command
  with a table name, so the two cases are now distinct.
- **The de-duplicating `DELETE` announces itself** (#688 post-merge review). It is
  the only destructive statement in V163, and neither caller reported how many
  rows it would remove — `--dry-run` printed the SQL, which does not answer that.
  `UUIDIntegrity.duplicate_rows/2` counts them before any DDL runs, and both
  callers log the count.

## 1.7.235 - 2026-08-07

### Security

- **Credential management on the admin user form now answers to rank, not to a
  permission** (#686). `/admin/users/edit/:id` gated the password field on
  `Scope.can_access_admin_area?/1` — true for **any** holder of a single
  permission — while the comment above it said "Admin/Owner only", and nothing
  else in the path checked rank. New `Auth.can_manage_user_credentials?/2`
  decides by role and rank (your own account is yours; the actor must be
  Owner/Admin; an Owner or Admin target may be managed only by an Owner), and it
  gates the password field, the reset-mail button and the **email** field —
  owning the address a reset link is delivered to takes an account just as
  surely as setting the password does. `username` is dropped with them, since
  `get_user_by_email_or_username_and_password/3` accepts it as a sign-in route.
  Every event refuses independently of the template.
- **Deactivation now revokes sessions instead of merely denying them** (#686).
  `update_user_status/3` flipped `is_active` and left the token rows valid for
  their full 60-day life; it now deletes the user's session tokens.
- **Activation, deactivation and email-confirmation toggling are rank-checked in
  the context** (#686). `update_user_status/3` and `toggle_user_confirmation/2`
  take an `:actor` and enforce `Auth.can_manage_user_status?/2`; omitting the
  actor is the system path (`Referrals`). The rule lived only in the edit
  form's markup, so the user-list and user-detail pages reached both functions
  ungated — a role holding only `users` could switch off an Admin, and
  *unconfirming* an account locks it out of the eleven gates that honour
  `require_email_confirmation`.
- **Deleting a user answers to that same rank rule** (#686 post-merge review).
  `can_delete_user?/2` refused only an *Admin* target and never checked the
  actor's role at all, deferring that to a page gate that admits any single
  permission holder. Because an Owner holds only the `Owner` role, an Admin —
  or a `users`-permission role — could delete any Owner who was not the last
  one. It now routes through the same authority check; the self and last-Owner
  rules keep their own messages.
- **Multi-session resolves the root account through the active-user filter**
  (#686). `root_user/1` and `root_authenticated?/1` used a bare token lookup, so
  a deactivated Owner/Admin holding a live cookie could still reach
  `POST /users/session/impersonate/:uuid`. The same filter was added to
  `PhoenixKitWeb.Users.Session`, the OAuth scope resolver and the maintenance
  plug.
- **A deactivated account is refused at the shared sign-in funnel** (#686).
  `log_in_user/3` checks `is_active` itself — the password controller did, but
  magic-link verification, QR-login completion and the OAuth callback called it
  directly and did not.
- **Stored XSS in the auth-page branding settings** (#686).
  `AuthPageWrapper.bg_style_tag/1` built a `<style>` element by string
  concatenation and emitted it with `raw/1`; a `<style>` body is raw character
  data, so `</style>` in the background-colour value closed the element. The
  value is free text on `/admin/settings/authorization` (key `settings`, held by
  Manager as well as Admin) and is served to every **anonymous** visitor of the
  login, registration and reset pages. New `PhoenixKit.Utils.CssValue` is an
  allowlist that fails to `""`, applied on read (neutralising anything already
  stored), in the one function that assembles the stylesheet, and on write.
- **OAuth no longer attaches an external identity on email string equality**
  (#686). `find_or_create_user/3` looked the callback address up locally and, on
  a hit, confirmed that account and issued a session — no verification claim
  read, no prior link required. Resolution is now ordered by the proof each case
  carries: an existing `(provider, provider_uid)` link is decisive and consults
  no email; a pre-existing local account requires the provider's own assertion
  (Google/OIDC `email_verified`, GitHub per-address `verified`, Facebook
  `verified`); a new account is created but auto-confirmed only on an assertion.
  GitHub's strategy is now configured with `default_scope: "user:email"`, without
  which the token cannot read `/user/emails` and the claim is never present.

### Added

- `oauth_require_verified_email` setting (default `"true"`, #686) with a
  checkbox on the authorization settings page — lets a deployment lift the
  verified-address requirement deliberately rather than by accident.

### Fixed

- **A new OAuth account that is left unconfirmed is now sent the confirmation
  mail** (#686 post-merge review). Nothing on the OAuth path ever sent it —
  `Auth.register_user/2` does not, and only the registration controller did — so
  an account the provider did not vouch for was signed in with "Successfully
  signed in!" and then bounced off every gate honouring
  `require_email_confirmation`, with an empty inbox.
- **The confirm/unconfirm menu entry is gated like its status twin** (#686
  post-merge review). Only the status button was hidden for an out-of-rank
  target, so the confirmation button next to it advertised an action the server
  now refuses.
- **The new per-row rank guard no longer queries per row** (#686 post-merge
  review). `can_manage_user_status?/2` in the users-list template asked up to
  four `EXISTS` questions per row — ~200 round trips on a fifty-row page, on
  every sort, filter and PubSub re-render — even though `list_users_paginated/1`
  already preloads `:roles`. The rank rule now reads a preloaded `:roles`
  association when there is one, and the list hands it an actor loaded once.

## 1.7.234 - 2026-08-07

### Added
- **One resolver for every redirect core owns** (#685). `Routes.safe_destination/2`
  replaces eleven hardcoded `"/"` / `Routes.path("/")` destinations across
  `auth.ex`, `session.ex`, `oauth.ex`, the confirmation, referral, QR and
  password LiveViews and the maintenance page. Every candidate is proven to
  resolve in the *host's own* router (`Phoenix.Router.route_info/4`, read off
  `conn.private.phoenix_router` or `socket.router`) before anyone is sent there,
  and the chain terminates on a path core declares **and permits**
  unconditionally — `/admin` for an authenticated visitor, `/users/log-in` for
  an anonymous one. `Routes.path("/")` emits a locale-prefixed root (`/en`)
  whose route belongs to the host, so on any host that never declared one every
  such redirect used to 404; measured before the workaround, `/` answered 200
  while `/en`, `/et` and `/ru` all returned 404.
- **`/admin` is now the guaranteed landing for every authenticated visitor**
  (#685). `:phoenix_kit_ensure_admin` exempts that one view
  (`PhoenixKitWeb.Users.Auth.landing_view?/1`) from the admin-area and per-view
  permission checks — authentication, the account gate, maintenance mode and the
  locale hook still run for everyone. A terminal that rejects its own visitor is
  an infinite redirect rather than a fallback, so the page had to admit them and
  is built for it: a visitor holding no permissions is greeted by name and shown
  nothing else — no cards, no statistics, and not one operator query or PubSub
  subscription on their behalf.
- **`main_page_path` site setting** (#685) — the local path of the site's home
  page, used as the anonymous "home" destination. In general site settings,
  beside Project Title and Site Address. Empty (the default) means core falls
  back to its own `/users/log-in`, which exists in every install and every
  locale; it deliberately does **not** default to `"/"`, which no core route
  serves.
- `PhoenixKitWeb.Users.Auth.can_access_admin_view?/2` (#685) — the same decision
  `:phoenix_kit_ensure_admin` enforces on mount, as a pure boolean, so a link,
  card or nav entry and its destination cannot drift. `PhoenixKit.Admin.Events`
  gains `unsubscribe_from_stats/0`, `unsubscribe_from_sessions/0` and
  `unsubscribe_from_presence/0`.

### Changed
- **The admin dashboard is gated block by block** (#685). Its operator half
  moved to `PhoenixKitWeb.Live.Dashboard.Overview` +
  `PhoenixKitWeb.Components.Core.DashboardOverview`. Each card derives its
  visibility from `can_access_admin_view?/2` on the page it links to, so a
  visible card is never a redirect. Platform Statistics, System Information and
  the Refresh button now require `Scope.holds_all_enabled_permissions?/1` — a
  default Admin still passes (the check compares against the operator baseline,
  opt-in keys excluded), but a narrow custom operator role that used to see the
  whole dashboard now sees only the cards it holds permission for. The gate
  decides *before* it queries, and re-decides on every mid-session permission
  change: nobody is evicted from the landing, so the cards, the statistics and
  the subscriptions behind them appear and disappear in place.
- **The admin shell collapses for a visitor with no permissions** (#685). No
  sidebar column, no burger button, no navigation landmark, no "Admin Panel"
  breadcrumb label, and no "View all" footer on the notifications bell — the
  menu never offers a page that would bounce the visitor on arrival. An
  operator's header and sidebar are unchanged.

### Fixed
- **The home-page fallthrough no longer drops the visitor's language** (post-#685
  review). The resolver offered only the bare `"/"` as its home-page candidate.
  On a multilingual host that declared the locale-prefixed landing core's own
  release notes ask for, a logout, a maintenance eject or a failed password
  reset used to land on `/et` and instead flipped the visitor to the
  default-language home — or, where the host declared **only** `/:locale`,
  skipped the home page entirely and terminated on the sign-in page. Both shapes
  are now offered, locale-prefixed first, and both are probed like every other
  candidate, so this cannot reintroduce the 404 the resolver exists to prevent.

## 1.7.233 - 2026-08-06

### Fixed
- **Host apps that register their own module no longer fail to compile** (#684).
  1.7.232 began emitting a compile-time `mod.__info__(:module)` reference for
  every discovered or configured route module, so that Mix rebuilds a host
  router when one of them changes. The reference was emitted unconditionally,
  and `phoenix_kit_routes()` also expands inside phoenix_kit's own router —
  which is built as a dependency, before any parent-app module exists. A host
  that registers its OWN app module in `config :phoenix_kit, :modules` (or
  `:route_modules`) therefore stopped building at all, with
  `function TheHost.__info__/1 is undefined ... could not compile dependency
  :phoenix_kit`. Registering the host module that way is documented practice,
  not misuse: beam discovery cannot see the host app while the host is still
  compiling, so `admin_tabs/0` on the host module is invisible without it. The
  list is now filtered through `Code.ensure_compiled/1`. Where the module is
  genuinely reachable — inside the host's own router — `ensure_compiled/1`
  blocks on the parallel compiler and returns `{:module, _}`, so the reference
  is still emitted and the recompile tracking added in 1.7.232 is unchanged;
  only the case that cannot be referenced yet is skipped.

## 1.7.232 - 2026-08-05

### Added
- **Entry points for "Sign in as user"** (#683). `MultiSession.impersonate/2`,
  its authority rules, the controller action and the POST route all shipped in
  #672 with nothing in any template reaching them. The action now appears in
  the "..." menu on the Users list (table and card views) and on the user
  detail page, behind `impersonable?/2` / `impersonable_uuids/2` — predicates
  that answer with the same private rule the request enforces, so a menu
  cannot offer what the POST would refuse. The list decides a whole page of
  rows against one actor lookup, reading each target's roles from the `:roles`
  preload rather than a query per row. Nothing about who may impersonate whom
  changed.
- **The Edit action on the user detail page** joins Roles, Confirm Email and
  Deactivate in the actions menu (#683), instead of sitting alone in the
  breadcrumb bar where the header-deduplication sweep parked it.

### Fixed
- **Deactivated accounts are no longer offered for impersonation.** The menu
  predicates asked the authority rules, which decide who may borrow whom; the
  `:inactive` refusal is raised later, by `add_authenticated_user/2`. So every
  deactivated row carried a "Sign in as user" item — next to the badge saying
  the account is deactivated — and every click came back "That account is
  deactivated." `user.is_active` is already on the struct the list renders, so
  respecting it costs no query. `impersonate/2` is untouched and still
  re-decides everything server-side.
- **Doubled required-field markers** on the user, role and registration forms
  (#683). `<.input>` renders the marker itself; six labels also hand-appended
  `" *"`. `Organization Name` had the hand-written asterisk but no `required`
  attribute, while the changeset does require it for organization accounts —
  it gains the attribute, so the browser now agrees with the server.
- **The admin nav role badge named the wrong role** (#683). It derived its
  label from `Scope.can_access_admin_area?/1`, which is true for Owner, Admin
  *or any single permission holder* — so a Client, who holds `client_portal`,
  was labelled "Admin", and every custom role was flattened into three
  buckets. The account list directly below it renders
  `MultiSession.role_label/1` and said "Client" while the header said "Admin".
  Both now share that function, reading the names the scope already loaded in
  `cached_roles` instead of re-querying on a component that renders on every
  admin page.
- **Usernames generated from an email keep their letters** (#683). The cleanup
  pass strips anything outside `[a-zA-Z0-9_]`, so `ülo.kask@` became
  `lo_kask` — the first letter of the name silently gone — and a wholly
  non-Latin local part collapsed to nothing. The address is now transliterated
  first (`Ülo.Kask@` → `ulo_kask`, `Иван@` → `ivan`).

### i18n
- **`Person` → `Personal` as the account-type label.** The old source string
  named a human being where the label names a *kind of account*, the
  counterpart of `Organization`. Each locale takes the idiomatic
  private-individual-vs-legal-entity term rather than a calque — Eraisik,
  Privatperson, Particulier, Particular, Privato, Osoba prywatna, Физическое
  лицо. The stored `account_type` value stays `"person"`.
- **18 strings were in the source but in no `.pot` file**, so the SEO /
  robots.txt settings page, the hex.pm package browser and the referral gate
  ("Enter your referral code", "This site is invite-only…") rendered in
  English in every locale. Extracted and translated in all seven.
- **Four reworded strings were rendering their old translation.** `Continue`,
  `Log out`, `Referral code` and `SEO settings` had matched fuzzily against
  older entries, and fuzzy entries do render — German showed **"online"** on a
  Continue button. Retranslated; no fuzzy entries remain.
- Estonian and Russian repairs beyond those: a batch of entries whose
  translation belonged to a neighbouring msgid ("Failed to delete user" under
  the custom-field failure, "Current time" under "Current page", and ~20
  more).

### Internal
- Post-merge review of #683: `dev_docs/pull_requests/2026/683-admin-ui-i18n-and-impersonation-entry-points/CLAUDE_REVIEW.md`.
- Tests for the impersonation menu predicates — `impersonable?/2` agrees with
  `impersonate/2` target by target, `impersonable_uuids/2` agrees with
  `impersonable?/2` over a mixed list, and `impersonation_actor/1` is the ROOT
  account after a switch — plus a unit suite for
  `generate_username_from_email/1`, which had none.

## 1.7.231 - 2026-08-05

⚠️ **Two new migrations (V161, V162) — run `mix phoenix_kit.update`.** V161
converts `phoenix_kit_users.username` to `citext` and **refuses to run** if
your database already holds usernames differing only by case; it names the
offending value so you can rename or merge the accounts, then re-run.

### Added
- **`PhoenixKitWeb.Live.UrlState` — URL-backed search, filter, sort and page
  for list LiveViews** (#680). Typing in a list's search box filtered the
  table but left the address bar untouched on most admin screens: the result
  could not be shared, did not survive a reload, and Back walked out of the
  page instead of back to the previous query. A workspace audit found 26
  LiveViews with that defect and seven independently hand-rolled fixes on the
  screens that did work — six of which rebuilt the path from a literal, so a
  LiveView reachable at more than one route patched itself to the wrong page.

  Declare the state, implement `handle_url_state/2`, push changes with
  `push_url_state/3`. Params are keyed by **assign name** with `url_key:`
  naming the query key separately, so adopting it touches no templates
  (`users.html.heex`, 700 lines, needed no edit). Values equal to their
  default are dropped from the query, so an unfiltered list stays
  `/admin/users`. `cast:`/`in:` whitelist values and no atom is ever created
  from user input; integer params carry a default ceiling of 1,000,000 so a
  crafted `?page=` cannot reach Ecto as an `OFFSET` that overflows
  PostgreSQL's `bigint`. The path comes from the live `uri`, unknown query
  keys are preserved, and the callback runs only on a real change.

  Converted: `users`, `sessions`, `live_sessions`, `jobs/index`,
  `media_selector`.

  ⚠️ **`mode: :patch` (the default) makes a LiveView un-embeddable.**
  `push_patch` requires `handle_params/3` to be exported, and exporting it —
  whatever its body — makes `live_render/3` raise. The two are mutually
  exclusive in LiveView itself. `mode: :history` sidesteps both by driving the
  address bar from a JS hook (`<.url_state_sync mode={:history} />`) instead
  of touching `handle_params` at all. `MediaBrowser.Embed`'s `url_sync: true`
  has always carried the `:patch` constraint through its injected stub; that
  is now stated in its moduledoc rather than implied.
- **`Utils.Slug` gains opt-in transliteration** (#682). A Cyrillic title
  slugified to an empty string — every character fell outside `[a-z0-9]` and
  was stripped. Callers read empty as "no slug yet", so a Ukrainian shop's CSV
  catalogue could not be matched on re-import and inserted the whole feed
  again on every run. `slugify(text, transliterate: true)` maps Russian and
  Ukrainian Cyrillic to Latin and strips Latin diacritics. Opt-in, so existing
  callers keep today's ASCII-only behaviour and a consumer passing the option
  against an older core gets today's result rather than an error.
- **`PhoenixKit.Install.StatusReport`** — the "what should the operator do
  next" decision behind `mix phoenix_kit.status`, extracted so it can be
  tested without pointing the task at a live database in each of five states.

### Fixed
- ⚠️ **V161: `phoenix_kit_users.username` is now `citext`** (#681). Two
  accounts existed in production as `Pavel` and `pavel`. Nothing prevented it:
  `phoenix_kit_users_username_uidx` was a plain btree on a `varchar` column,
  `unsafe_validate_unique` compared exactly, and `get_user_by_username/1` is a
  bare `Repo.get_by`. The mechanism was systematic rather than a fluke —
  `generate_username_from_email/1` force-downcases while
  `ensure_unique_username/3` checked availability case-sensitively, so a
  username set manually with a capital was invisible to the generator, which
  proposed the lowercase form, found it "free", and added no suffix.

  Once such a pair existed, **login by username 500'd for both accounts**:
  that path already lowercased both sides, so its query matched two rows and
  `Repo.one/1` raised `Ecto.MultipleResultsError`. (An earlier draft of this
  entry described the symptom as landing in the wrong account; the failure was
  a hard error, not a silent cross-account login. `email` was unaffected — it
  has been `citext` since V01.)

  Postgres decides comparison semantics from the **column type**, so one
  `ALTER` fixes uniqueness *and* every lookup, including a bare `Repo.get_by`.
  A functional unique index on `lower(username)` would have fixed only the
  constraint and left every read exact-match. `varchar → citext` is
  binary-coercible, so there is no table rewrite; the column's index is
  rebuilt, which is what makes it start rejecting case variants.
- **Username login no longer sequentially scans the users table.**
  `get_user_by_email_or_username_and_password/3` hand-rolled its case folding
  as `fragment("LOWER(?)", u.username)`, which matches no index in the chain —
  there is no functional index on `lower(username)`. Now that the column is
  `citext`, plain equality is both correct and index-backed via
  `phoenix_kit_users_username_uidx`. This was the only username lookup in the
  codebase still scanning, on the one endpoint reachable without
  authenticating.
- **V162: payment-option linkage on billing orders** (#682). Adds a nullable
  `payment_option_uuid` FK (plus its index) to `phoenix_kit_orders`, pointing
  at `phoenix_kit_payment_options`. An order records *how* it is to be paid
  via `payment_method`, a small closed vocabulary; what the customer actually
  chose is a payment-option **row**, with its own name, instructions, provider
  and billing-profile requirement. Several options can share one
  `payment_method` ("Bank transfer (EU)" and "Bank transfer (UK)" are both
  `bank`), and an option can be renamed or deactivated after the order is
  placed. Without a link the choice was discarded at conversion, so an
  operator processing a bank transfer could not tell which instructions the
  customer had been shown. `ON DELETE SET NULL`: deleting a payment option is
  an ordinary operator action and must neither be blocked by historical orders
  nor destroy them.
- **A tab gated on a sub-permission registers correctly** (#682). A module tab
  may be gated on a sub-permission (`"shop.manage_settings"`). Registration
  pushed that through `register_custom_key/2`, which rejects a dotted key —
  and the raise aborted the rest of the callback, so the view → permission
  mapping the admin gate reads was never cached. The module silently fell back
  to the coarser base key for core's gate, and every boot logged a failure for
  a key that was declared correctly. Sub-permissions are already declared
  through `permission_metadata/0`, so registration now skips them.
- **The automatic view gate requires the base of a dotted key** (#682). With
  the dotted key now cached, the admin mount gate resolves one — and it was
  calling `has_module_access?/2`, direct membership only, which by contract
  leaves the base check to its caller. A scope holding an orphaned
  `"shop.manage_settings"` without `"shop"` would have passed a gate the
  sidebar, `can?/2` and every module's own check all refuse.
- **The `PhoenixKitUrlState` JS hook no longer leaks a callback per remount.**
  `handleEvent` registers on the LiveSocket, not the element, so `destroyed()`
  has to call `removeHandleEvent` — it only removed the `popstate` listener.

### Changed
- **`mix phoenix_kit.status` says "code expects", not "update available".**
  Everything it reports is measured against the version compiled into the
  running release; it never asks Hex what exists, so it cannot tell you a
  newer PhoenixKit is out. A version gap is not an optional upgrade being
  offered — it means the schema disagrees with the code already querying it,
  which surfaces as runtime errors on whatever the newer version added. When
  core and a module are both behind, one command fixes both and both reasons
  are now listed, so re-running does not turn up a second finding that was
  already knowable.
- **The test suite can use a database you already have.** `config/test.exs`
  hardcoded `phoenix_kit_test`, which forces a role with `CREATEDB` — exactly
  what a shared or managed instance withholds. `PGDATABASE` and `PGPOOL` now
  join the `PGHOST`/`PGUSER`/`PGPASSWORD` that were already read. Defaults are
  unchanged.
- **`AGENTS.md` no longer claims `mix precommit` runs the test suite.** It
  never did, and CI is `workflow_dispatch`, so in practice nothing ran the
  Elixir suite automatically. Adding `mix test` to `precommit` was tried and
  reverted — the suite is not green from a clean checkout (~5 "unit" tests
  fail with no database, because `Settings` reads hit the DB on a cache miss),
  and a permanently red gate teaches people to ignore the gate. The docs now
  say running the suite is a manual step, and warn that `mix test` with no
  database excludes every integration test **and still exits 0** — the failure
  mode that matters most when the change is a migration.
- Dependency bumps: `etcher` 0.10.0 → 0.10.2, `spitfire` 0.3.13 → 0.4.0.

### Internal
- Post-merge review of #680/#681/#682 with the findings above:
  `dev_docs/pull_requests/2026/680-682-post-merge-review/CLAUDE_REVIEW.md`.
- `test/phoenix_kit/migrations/v162_test.exs` — V162 shipped with no test.
  Pins the column, the FK target, the index, and `ON DELETE SET NULL`
  specifically: that is the migration's whole design decision, and a later
  refactor reaching for a plain `references/2` would silently make it
  `RESTRICT` with nothing failing.

## 1.7.230 - 2026-08-04

### Fixed
- ⚠️ **`mix igniter.install phoenix_kit` failed on every freshly generated
  Phoenix project.** Core declared `{:igniter, "~> 0.7"}` as a required
  dependency in all environments. A stock `mix phx.new` app declares
  `{:igniter, "~> 0.6", only: [:dev, :test]}`, and Mix refuses to converge the
  two:

  ```
  Dependencies have diverged:
  * igniter (Hex package) — the :only option for dependency igniter
    Remove the :only restriction from your dep
  ```

  The install aborted before writing anything. Igniter is now
  `optional: true`, so the host's own declaration wins and the documented
  install path works on a clean project. The version requirement is unchanged
  (`~> 0.6` and `~> 0.7` both admit igniter 0.7/0.8, so no host is forced to
  move).

  Making it optional means core must compile **without** igniter, which it
  previously could not: `mix/tasks/phoenix_kit.gen.admin.page.ex` and
  `phoenix_kit.gen.user.dashboard.ex` called `use Igniter.Mix.Task` unguarded
  and hard-failed a `MIX_ENV=prod` build. Both now carry the same
  `if Code.ensure_loaded?(Igniter.Mix.Task)` guard `phoenix_kit.install` and
  `phoenix_kit.update` already had, and ten igniter-only `PhoenixKit.Install.*`
  helpers are guarded on `Code.ensure_loaded?(Igniter)` so a production build
  no longer prints a wall of "Igniter.X is undefined" warnings. The two helpers
  that *cannot* be guarded away because their non-igniter half is called from
  plain tasks — `Install.Common` (`mix phoenix_kit.status`) and
  `Install.JsIntegration` (`mix phoenix_kit.assets.rebuild`) — instead use the
  existing `Install.IgniterCompat` `:no_warn_undefined` shim, which grew the
  three modules they reference. No task or helper changed behaviour when
  igniter *is* present.

  ⚠️ **Upgrading from ≤ 1.7.229 and your `mix.exs` does not list `:igniter`?**
  You were getting it transitively from PhoenixKit; an optional dep is not
  installed unless the host declares it, so after `mix deps.update phoenix_kit`
  the code-generating tasks stop working. Add:

  ```elixir
  {:igniter, "~> 0.7", only: [:dev, :test]}
  ```

  `mix phoenix_kit.install` / `.update` / `.gen.*` now say exactly this when
  invoked without igniter rather than vanishing from `mix help` (the two
  `gen.*` tasks, newly guarded, had no fallback at all; `install` and `update`
  had one each, and all four now share `Install.MissingIgniter`).
  `PhoenixKit.Install.IgniterCompat` gained a `__mix_recompile__?/0` keyed on
  igniter's availability, so adding the dep later actually rebuilds the tasks
  instead of needing `mix deps.compile phoenix_kit --force`. Tasks that never
  touch igniter — `phoenix_kit.status`, `.gen.migration`, `.assets.rebuild` —
  are unaffected either way.

- **`mix phoenix_kit.update` could crash when two modules needed migrating in
  the same second.** Generated migration filenames took their version from a
  bare `%Y%m%d%H%M%S` timestamp, so two modules upgraded together produced
  duplicate Ecto migration versions. Timestamps are now offset per file and
  bumped past anything already in `priv/repo/migrations`.

- **`mix phoenix_kit.update` silently skipped modules whose migration
  coordinator raised.** The failure was swallowed and the host saw nothing at
  all, leaving it to assume its tables were current. Unreadable modules are now
  reported by name with the error and an explicit note that they were not
  migrated.

- **`mix phoenix_kit.update` wrote module migrations to a hardcoded
  `priv/repo/migrations`.** On a host whose first `:ecto_repos` entry is not
  `MyApp.Repo`, the file landed in a directory the migrator never scans, so
  `ecto.migrate` exited 0 having done nothing — and the run still printed
  `✅ <module> migrated to V##`. The directory is now taken from the resolved
  repo, and each module's version is **re-read from the database** afterwards
  rather than assumed, so a migration that did not run is reported as a failure
  with the path to check.

- **`mix phoenix_kit.update` could hard-fail on a re-run after an interrupted
  update.** The module path had no "migration already exists" guard (the core
  path has had one all along), so a second run wrote a second file with the
  same migration name and `mix ecto.migrate` refused everything with
  `migration name ... is duplicated`. It now reuses the existing file.

- **One bad module aborted the whole `mix phoenix_kit.update` run.** The
  per-module `try/rescue` was lost in the rework, so a module that raised while
  its migration file was written killed the task *after* core had migrated —
  skipping every remaining module and the UUID repair pass. Each module is
  isolated again.

- **`mix phoenix_kit.status` reported `Next: Ready` directly under a
  `1 unreadable ❌` module row.** An unreadable module is deliberately not
  "pending" (migrating a module whose version cannot be read would be worse),
  but it is not "ready" either. `Next` now names the modules to check.

- **`mix phoenix_kit.status --verbose` claimed "No installed module owns
  migrations" whenever the database was unreachable**, which is a different
  fact from having none and sends anyone debugging a missing table the wrong
  way. Not-queried and none-found are now distinct.

- **A module coordinator reporting a non-integer version read as up to date.**
  Under Erlang term ordering `nil >= 2` is `true`, so a coordinator returning
  `nil` for "no version comment found" was classified `:up_to_date` and its
  migration skipped forever, while both tasks reported everything current.
  `Modules.classify/2` now requires integers and reports anything else as
  `:error`.

- **Soft-failure paths guarded with `rescue` alone now also `catch :exit`.**
  Per the project's own convention, an unreachable database raises on an
  unowned checkout but *exits* on a dead pool — so a dead pool crashed
  `mix phoenix_kit.status` outright and killed the closing summary of an
  otherwise-successful `mix phoenix_kit.update`.

- **The sitemap's `x-default` could be claimed by a sibling-dialect entry**
  (#679). Enabled codes are stored BCP-47 (`en-GB`) while sibling-dialect URLs
  render lowercase (`/en-gb/…`), so the case-sensitive `String.contains?` never
  recognised such an entry as language-prefixed and let it pass as the
  unprefixed default. The default picker now matches case-insensitively, in
  line with the per-entry hreflang extraction that already did.

### Added
- **The locale plug accepts enabled full-dialect URL segments** (#679) instead
  of 301-ing every hyphenated segment to its base code. A segment that
  case-insensitively matches an **enabled** language (`/en-gb/…` with `en-GB`
  enabled) is now served as that locale, with the stored-case code on
  `conn.assigns.current_locale` and its base on `current_locale_base`.
  Disabled dialects, unknown dialects, and an empty enabled list (Languages
  module off) all keep the historical redirect-to-base, so nothing changes for
  an install that does not enable sibling dialects.

  This is what makes two enabled dialects of one base addressable as distinct
  public URLs — `phoenix_kit_publishing` gives the non-primary sibling its own
  URL space and previously had it bounced to the base before its controller
  ever ran. The prefixless-primary canonical redirect deliberately does not
  apply on this branch: only non-primary siblings are addressed by full-code
  URLs, and the primary keeps its base-coded (or prefixless) shape.

- **`mix phoenix_kit.status` now reports the schema version of every module
  that owns its migrations**, not just core. Modules implementing
  `c:PhoenixKit.Module.migration_module/0` (`phoenix_kit_inbox`,
  `phoenix_kit_boards`, `phoenix_kit_web_analytics`, `phoenix_kit_legal`,
  `phoenix_kit_stats`) each report installed-vs-expected:

  ```
  PhoenixKit v1.7.230
  ├── Installed: V159 ✅
  ├── Database: Connected ✅
  ├── Modules: 2 modules, 1 update available ⬆
  │   ├── Boards: V01 ✅
  │   └── Inbox: V01 → V02 available ⬆
  └── Next: mix phoenix_kit.update (module schema behind: Inbox)
  ```

  `Next` is module-aware: a host whose core is current but whose module tables
  are a version behind previously reported "Ready". `--verbose` adds each
  module's coordinator and exact version numbers. The row is omitted entirely
  when no installed module owns migrations, so a core-only install keeps its
  compact three-line tree.

- **`mix phoenix_kit.update`'s closing summary lists module versions too**, so
  the last thing printed answers "what version is everything at?" rather than
  covering core alone and leaving module versions in scrollback.

### Changed
- **`mix phoenix_kit.update` now writes every pending module migration first
  and runs `ecto.migrate` once**, instead of a full migrator pass per module.
- **New `PhoenixKit.Migrations.Modules`** — the shared read side of the
  module-migration contract, used by both tasks. Discovery previously lived
  inside `update` only, which is why `status` never knew modules existed. A
  module whose coordinator raises, exits, or reports a non-integer version is
  recorded as `:error`, never propagated, so a broken third-party module cannot
  take down `mix phoenix_kit.status`. `classify/2` is public because it is the
  whole read-side decision, and a private one could only be tested through a
  hand-built entry that supplied the answer.
- **New `PhoenixKit.Install.StatusTree`** — the tree layout, extracted from the
  status task so it can be unit tested without a database. It was previously a
  private function writing straight to `IO.puts/1`, so in practice changes to
  it went unverified.

## 1.7.229 - 2026-08-04

### Changed
- ⚠️ **The `leaf` requirement is now `~> 0.4.1 or ~> 0.5`, up from `~> 0.3`.**
  **This raises the floor — hosts resolving leaf 0.3.x will be moved to 0.4.1+.**

  `~> 0.3` spanned leaf 0.3 → 0.9. For a 0.x package, where each minor is
  effectively a major, that claimed a support window core cannot back. It also
  had a concrete cost: it let a resolver reach for leaf 0.5 while
  `phoenix_kit_publishing` still excluded it, and rather than reporting a
  conflict the resolver quietly settled on an older publishing release. Core
  declares `leaf` for the whole tree — `phoenix_kit_comments` renders the
  composer but inherits the dep from here — so this requirement governs every
  host.

  **If you vendor `leaf.js` or pin it from a CDN, update it to match.** leaf 0.5
  is a server↔client contract change and a bundle left behind fails silently
  (0.5.1 logs a console warning when it detects the mismatch). Hosts using the
  documented `import "../../../deps/leaf/priv/static/assets/leaf.js"` move
  automatically.

## 1.7.228 - 2026-08-04

### Removed
- **The installer no longer rewrites the host's `assets/js/app.js` to add a
  `viewport_width` connect param.** `mix phoenix_kit.install` / `mix
  phoenix_kit.update` edited the host's LiveSocket options into
  `params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth})`,
  justified by responsive PhoenixKit LiveViews reading the width server-side on
  first render. **No such reader was ever written** — nothing in core or in any
  module package reads `viewport_width`, and `phoenix_kit_dashboards`, the named
  beneficiary, has no viewport logic at all. The producer shipped, the consumer
  never did. Editing a host's application source to send a value nothing reads
  is not something a library should do quietly, so the step and its transform
  (`JsIntegration.inject_viewport_param/1` and helpers) are gone.

  **Existing hosts keep the line** — this removes the step, not what earlier runs
  already wrote. It is inert and safe to leave; delete it by hand if you want the
  diff clean. Reported by a host that found the edit in an unexplained `git diff`.

  Note for the report that prompted this: the edit came from
  `phoenix_kit.install`/`update`, **not** from the `:phoenix_kit_js_sources`
  compiler, which only ever writes `priv/static/assets/vendor/`.

## 1.7.227 - 2026-08-03

Host-app feedback triage (#677) — ~43 reports from AI agents working on apps
built with PhoenixKit (Ratelia, Topp, NordSwitch), plus the post-merge review
fixes. **Migration V160**; run `mix phoenix_kit.update`.

### Added
- **Invite-only is enforced as a post-signup access gate** (#677) — with
  `referral_codes_required` on, an account can be created by any route
  (password, magic link, OAuth) but reaches nothing except `/users/referral` and
  log-out until it is admitted. It was previously enforced on the password form
  only, so OAuth and magic-link signups walked straight past it. Keyed on an
  independent flag, never `confirmed_at` — OAuth auto-confirms, so a gate keyed
  on that would open for the path it most needs to close.
- **`mix phoenix_kit.update --status`** (#677) — lists what upgrading gives you,
  read from the migration moduledoc's per-version headings. Seven of the
  reported "missing features" already existed; that is a delivery problem, not
  seven doc gaps.
- **`PhoenixKit.Test.Fixtures`** (#677) — shared test fixtures for host suites.
- **`config :phoenix_kit, hidden_admin_tabs: [...]`** (#677) — drop a module's
  admin section while keeping its data layer. Applied at registry init, so a
  supervisor restart cannot resurrect a hidden tab.
- **`Referrals.PruneWorker`** (#677) — deactivates (never deletes) accounts that
  were created under invite-only and never satisfied it. Off unless
  `referral_unadmitted_retention_days` is set. `mix phoenix_kit.update`
  backfills its cron entry into existing hosts.
- **Sitemap endpoints at the site root** (#677) — `/sitemap.xml` and friends are
  served at the root as well as under the PhoenixKit prefix, because that is
  where crawlers look. Emitted only for prefix-mounted installs.

### Changed
- **Auth pages no longer render in the host's `Layouts.app`** (#677) —
  ⚠️ **breaking default.** Every install's login page was showing the host
  scaffold's Phoenix Framework branding. Opt back in with
  `auth_uses_host_layout: true`.
- **A user's own notification inbox and preferences need no permission grant**
  (#677) — ⚠️ **breaking.** Notifications are delivered to every user, and
  requiring a grant to read your own meant an account could receive mail it was
  structurally unable to open. The `notifications` key is now reserved for the
  administrative all-users view.
- **Custom sitemap exclude patterns ADD to the built-in defaults** (#677) — a
  saved list used to replace them outright, so adding one pattern of your own
  silently un-excluded every admin and auth route and froze that install out of
  later defaults. Save `"!replace"` as the first entry to opt into replacement.
- **`<.button>` honours `variant`, `size` and `navigate`** (#677) — all three
  were undeclared and silently dropped, including in `table_default`'s own
  documented examples. `variant` now replaces the base colour rather than
  appending to it.
- Dependency bumps: `oban`, `tesla`, `leaf`, `mdex_native`.

### Fixed
- **`GET /api/consent-config` 404'd on every page load without
  `phoenix_kit_legal`** (#677) — the vendored bundle asks for it
  unconditionally, so a conditional route meant a `NoRouteError` and a logged
  exception per request. It answers 204; a `{"enabled": false}` body would have
  *granted* consent on bundles vendored before the feature existed. The
  controller is named `PhoenixKitWeb.Controllers.ConsentConfig` — deliberately
  not the name `phoenix_kit_legal <= 0.1.9` publishes its own copy of, so the
  two are safe in either upgrade order.
- **The invite-only janitor starved itself and deactivated nobody** (post-#677
  review) — grandfathered accounts never gain a satisfied stamp and are, by
  definition, the oldest rows, so on any install with more than a batch (500) of
  pre-existing users they filled every batch and the sweep swept nothing, every
  day, silently. The grandfather predicate is now applied in SQL so exempt rows
  cannot occupy a batch slot.
- **`allow_registration` is enforced where accounts are actually created**
  (post-#677 review) — the magic-link *completion* route honoured only
  `magic_link_registration_enabled`, so closing registration outright still let
  every in-flight token create an account; the password form checked the setting
  in `mount/3` but not on submit, and a LiveView socket outlives the page load
  that opened it.
- **Three soft-failure paths in the access gate could still crash the site**
  (post-#677 review) — `invited?/1`, `fallback_boundary/0` and
  `log_deactivation/1` rescued exceptions but not exits, and an unreachable
  database raises on an unowned checkout while *exiting* on a dead pool. Two of
  the three are on the authentication path.
- **Referral-code validation was an unthrottled guessing oracle** (#677) —
  distinct messages per failure mode confirmed which guesses named a real code.
  One message now, rate-limited per IP and (on the post-login screen) per
  account, checked on submit rather than per keystroke.
- **Magic-link settings hid buttons without closing routes** (#677) — both the
  login and registration routes stayed reachable by URL, and in-flight tokens
  kept working, after an admin switched them off.
- **`send_registration_link/1` had no rate limit at all** (#677) — now limited
  on the same buckets as password registration, *before* the user lookup, so the
  generic copy does not become an account-existence oracle via timing.
- **Sitemap exclusions were a one-way door** (#677) — saving one custom pattern
  dropped every built-in exclusion, and saving them back exceeded `varchar(255)`
  while the changeset allowed 1000. **V160** widens
  `phoenix_kit_settings.value` to `TEXT` (catalog-only; no table rewrite).
- **Users received notifications they had no permission to read** (#677).
- **`mix phoenix_kit.update` exited 0 with a migration pending** (#677).
- **Settings written outside the web node stayed invisible until restart**
  (#677) — `get_settings_cached/2` silently read a cache miss as `nil` instead
  of filling it from the database, which would have degraded site-wide on every
  expiry wave once the cache gained a TTL. Cache expiry also gained up to 10%
  jitter so a batch written together does not fall due together.

## 1.7.226 - 2026-08-01

### Added
- **Audio is a first-class type in the media pickers** (#676) — an audio filter in
  the selector modal (grid query, `accept` list, server-side upload gate, copy and
  the "Audio Only" dropdown option), plus `lock_file_type` on the modal and
  `only_file_type` on `MediaBrowser`, which turn a type filter from a starting
  point into a constraint: the control is hidden, the change event is refused on
  the server, and an off-type upload is refused rather than stored out of sight.
- **`Storage.determine_file_type/2`** — the one classifier behind the `file_type`
  column, now public and documented. It takes the filename as well as the mime
  type, so the extensions browsers report as `application/octet-stream` (`.m4a`,
  `.flac`, `.opus`, `.ogg`) are still classified correctly instead of being
  invited by a picker's `accept` list and then refused by its own type gate.

### Fixed
- **An mp3 was stored as a document, so the audio filter never found it** (#676) —
  `determine_file_type/1` was copied into all four upload paths and the copies
  drifted: only the selector modal's knew about audio, while the media browser
  classified audio as `"document"` and the upload controller and full-page selector
  as `"other"`. Since each copy's result is written straight to `file_type`, and
  both new filters query that column literally, the same file was findable or
  invisible depending on which dropzone it was dropped on. All four now call
  `Storage.determine_file_type/2`. Unknown mime types uploaded through the media
  browser are now `"other"` (in the `File` allowlist) rather than `"document"`.
- **Buttons that didn't look clickable** (#676) — Tailwind v4's preflight stopped
  setting `cursor: pointer` on `button`, leaving the SearchPicker's dropdown rows
  (server- and hook-rendered) and the theme dropdown's options with an arrow
  cursor. `cursor-pointer` also joins the SearchPicker's safelist span, since the
  hook writes the class from JavaScript.
- **`EmailStatusBadge` leaked `format_status/1` and `status_class/1` into every
  LiveView** (#676) — it is blanket-imported by `use PhoenixKitWeb, :live_view`, so
  any consumer with its own `format_status/1` failed to compile pointing at code
  that never mentioned email. The import is narrowed to the component itself.
- **The call-to-action block sat flush left and linked nowhere** (#676) — it now
  renders inside a centring wrapper, drops the `inline-block` that was overriding
  daisyUI's `.btn`, and renders without an `href` when it has no action instead of
  defaulting to `"#"`, which scrolled the reader to the top of the page.

### i18n
- The five new audio strings translated in all seven locales. `gettext.extract
  --merge` fuzzy-matches each of them onto its *video* sibling — so
  "Only audio files can be added here." would otherwise have rendered as the
  translation of "only video files" — and fuzzy entries do render.

### Tests
- `test/modules/storage/determine_file_type_test.exs` — DB-free coverage of the
  shared classifier, including the `application/octet-stream` filename fallback.
- The registration-changeset block that shares a describe-level `setup` now
  registers a unique address per test; it was exhausting the 3-per-hour-per-email
  registration limit, and the refusal landed in `setup` reading as "registration is
  broken". The "explicit username wins" case keeps its saved user — the block is
  about editing one.

## 1.7.225 - 2026-07-31

### Fixed
- **A NULL `custom_fields` column silently swallowed atomic writes** (#675) — the
  column is nullable (V18), and in Postgres `NULL || jsonb` is `NULL` and
  `NULL - key` stays `NULL`. `merge_user_custom_fields/3` and
  `delete_user_custom_field/3` built their UPDATE straight off the column, so on a
  NULL row the merge discarded the additions and returned `{:ok, user}` with
  nothing written. Both fragments now `COALESCE(?, '{}'::jsonb)` first — the same
  idiom V30 already uses — which also restores the old whole-map path's side
  effect of normalizing a NULL column to `{}` on any delete.
- **Saving notification preferences rolled back a concurrently-connected channel
  or locale switch** — `Notifications.Prefs` was the last core writer still
  replacing the whole `custom_fields` map, and it rebuilt it from the `%User{}`
  the caller had been holding since `mount/3`. With a settings page open, a
  Telegram connect (`notification_channel:telegram`) or any language switch
  (`preferred_locale`) landing in between was silently reverted by the next save.
  It now writes only its own key through the atomic merge, which is what
  `ChannelConfig`'s per-channel key layout always assumed. Same-key concurrent
  writes are still last-writer-wins, now documented on `Prefs.merge/2`.
- **Internal UI preferences no longer register themselves as admin custom
  fields** — `ensure_definitions_exist/1` registers every key in the map it is
  handed, and the media browser / canvas viewer passed the whole column, so
  `media_view_mode`, `media_expanded_folders`, `media_sidebar_collapsed`,
  `etcher_colors`, `etcher_line_params` and `media_viewer_info_collapsed` appeared
  in the Custom Fields list and the users-table column customizer. Those five call
  sites now pass `ensure_definitions: false`, matching the users and activity list
  views. Definitions already registered on existing installs stay until removed.

### Changed
- **`update_user_locale_preference/2` gained a `@spec`** documenting its two error
  shapes — `{:error, String.t()}` for a validation failure and the primitives'
  `{:error, :not_found}` for a row deleted concurrently.
- **`Prefs.update/2` and `Prefs.merge/2` specs corrected** to `{:error, :not_found}`;
  they no longer return an `Ecto.Changeset`. Both call sites already matched
  `{:error, _}`.

### Tests
- NULL-column coverage for the merge and delete primitives; the documented
  `{:error, :not_found}` contract for `set_user_custom_field/3`; and a regression
  test that a sibling `custom_fields` key written after a caller's snapshot
  survives a `Prefs.merge/2`.

## 1.7.224 - 2026-07-30

### i18n
- **Every shipped locale is now 100% translated with no fuzzy flags** — `de`, `es`,
  `it` and `pl` were stubs (~2106 untranslated each; es ~1967) and are now
  complete: 0 untranslated, 0 fuzzy across `default` (2182), `errors` (24) and
  `phoenix_kit` (7). Together with ru, et and fr, all seven translated locales are
  at 100%. ~8,500 strings.
- **Terminology follows each catalog's own prior entries** rather than being
  invented — e.g. `pl` already used "zasobnik" for *bucket* where de/es/it keep
  "Bucket", and that split was preserved. daisyUI theme names follow the existing
  `fr` precedent: descriptive names translated (`Winter` → Invierno / Inverno /
  Zima), genre and proper nouns kept (`Nord`, `Cyberpunk`, `Lo-Fi`, `CMYK`).
- **`en` fuzzy flags cleared** — `en` is untranslated by design (empty msgstr ⇒
  Gettext falls back to the msgid, already English), but it carried 512 fuzzy
  flags on those empty entries. They were inert, and they made a fuzzy count
  useless as a signal. **"0 fuzzy anywhere in `priv/gettext`" is now a true,
  checkable invariant**, so any future non-zero count means a reword really
  happened and needs a human.
- **Existing good translations were never clobbered** — writes were filtered to
  each locale's untranslated ∪ fuzzy set, which is what preserved the ~139 entries
  `es` already had.

### Fixed
- **`should be %{count} byte(s)` and friends now exist in de/es/it/pl** — the
  entire `errors` domain was untranslated in de, it and pl, so every Ecto
  validation message fell back to English in those locales.

### Verification
- Bidirectional placeholder audit over all 24 catalog files: 0 extra, 0 dropped.
- `mix gettext.extract --merge` reports `0 new, 0 removed, 0 reworded` for all 24
  files and leaves the tree byte-identical.

## 1.7.223 - 2026-07-30

### Fixed
- **fr carried the same live fuzzy-carryover defects as ru/et** — the sign-out
  control read "S'inscrire" (**Sign up**), `Email Unconfirmed` rendered as "E-mail
  **confirmé**", `Integration added` as "Intégration **supprimée**" (removed),
  `Approve` as "avr." (April), `Restore` as "Rétro" (the theme), `unlimited` as
  "sans titre" (untitled), `Full Access` as "Succès", `Port` as "Trier" (Sort),
  `Custom URLs` as "Rôles personnalisés" (Custom **roles**), `Device` as
  "Service", `Create User` as "Créer un dossier" (Create **folder**),
  `No unread notifications` as "Activer les notifications utilisateur", and both
  `%{n}h ago` and `%{n}m ago` as "il y a %{n} **jours**". The xAI key-setup steps
  had inherited Mistral's URLs here too.
- **Placeholders dropped by a fuzzy carryover** — `Requires %{module}` rendered as
  a bare "Required" in de, es, it, pl (and `Active today at %{time}` as "Activo"
  in es), losing the interpolated value. These are worse than being untranslated:
  an empty msgstr falls back to correct English, while these render wrong text
  with the value silently missing. Fixed in all four locales.

### i18n
- **fr is complete** — 0 untranslated, 0 fuzzy across all three domains
  (`default` 2182, `errors` 24, `phoenix_kit` 7). 301 strings translated and 126
  fuzzy entries reviewed individually, 90 rewritten. ru, et and fr are now all at
  100% with no fuzzy flags.
- **The placeholder audit now checks both directions** — the 1.7.222 version only
  caught msgstrs referencing a binding the msgid never supplies; it now also
  catches ones that *drop* a binding the msgid does supply. Plural entries are
  handled correctly (form 0 against `msgid`, the rest against `msgid_plural`),
  since English singulars routinely hardcode "1" and carry no `%{count}`.
  Result across all 24 catalog files: 0 extra, 0 dropped.
- `de`, `es`, `it`, `pl` remain deliberate stubs and still carry ~463–533 fuzzy
  flags that were **not** audited string-by-string — only the provably-broken
  placeholder cases above were fixed. Promoting any of them to a supported locale
  needs the same pass ru/et/fr got. `en` is untranslated by design.

## 1.7.222 - 2026-07-29

### Fixed
- **Fuzzy translations were serving wrong text in ru and et** — Elixir's Gettext
  compiles and serves entries flagged `fuzzy` (the flag is only a translator
  hint), so every translation gettext had auto-carried from a similar-looking
  msgid was live in the UI. `Approve` rendered as "Апр"/"Apr" (April), `Port` as
  "Sort by", `unlimited` as "untitled", `Full Access` as "Success", `Large` as
  "Target", `Preview` as "Back"/"Previous", `Custom URLs` as "Custom roles",
  `%{n}h ago` and `%{n}m ago` both as "…days ago", and the `Nord`/`Winter`/`Black`
  theme names as "No"/"Enter"/"Back". Worst of the set, both stating the opposite
  of the truth on an auth surface: `Email Unconfirmed` rendered as
  "Email **confirmed**" and `Sign up` as "Sign **in**".
- **Provider setup instructions pointed at the wrong vendors** — the xAI and
  OpenAI key-setup steps had inherited Mistral's and DeepSeek's URLs, telling
  ru/et users to fetch an xAI key from `console.mistral.ai` and an OpenAI key
  from `platform.deepseek.com`.
- **`errors.po` had unresolvable interpolation bindings** — six `validate_length`
  messages in both ru and et carried `%{min}`/`%{max}` while Ecto only ever
  supplies `%{count}`, so every min/max length validation error interpolated a
  binding that does not exist. `should have %{count} item(s)` also said "bytes".

### i18n
- **Catalogs resynced with the source** — `mix gettext.extract --merge` across all
  8 locales: 195 msgids that existed in source but in no catalog were added and 12
  dead entries removed. A full merge is now a **no-op** (`0 new, 0 removed, 0
  reworded`) and byte-idempotent, which is what makes the drift actually gone
  rather than deferred.
- **ru and et are back at 100%** — 0 untranslated, 0 fuzzy across all three
  domains (`default` 2182, `errors` 24, `phoenix_kit` 7). 282 ru / 281 et strings
  newly translated; 304 ru / 305 et fuzzy entries reviewed individually, ~136 per
  locale rewritten and the rest confirmed correct and unflagged. Terminology was
  taken from each catalog's existing non-fuzzy usage rather than invented (ru
  "бакет" for bucket, since "Хранилище" is already Storage; et "dimensioon" and
  "teavitus", both already dominant). daisyUI theme names follow the existing fr
  precedent: descriptive names translated, genre/proper nouns kept.
- **Placeholder audit added over all 24 catalog files** — every `%{…}` in every
  msgstr, including each plural form, is bound by its msgid. 0 problems remaining.
- `de`, `es`, `it`, `pl`, `en` are synced but remain stubs by design. `fr` (~86%,
  126 fuzzy) is maintained but incomplete and still carries the same class of
  fuzzy defect — left for its own pass rather than half-done here.

## 1.7.221 - 2026-07-29

### Added
- **A failed email never renders as merely sent** (#674) — the activity badges
  carry their whole meaning in colour (the text is only ever a timestamp), so a
  log whose `status` says the send failed but whose matching timestamp or event
  is missing rendered as the plain blue "sent" badge, contradicting the detail
  page for the same log. A status-only badge now covers that gap.
- **CRM contact card on the user detail page** (#674) — when the optional CRM
  module is installed and enabled, a user linked to a CRM contact gets a card
  linking straight to it.

### Fixed
- **Spam complaints were left showing as sent** (#674 review) — the new failure
  whitelist spelled the status `complained`, which no writer in the tree sets,
  and omitted `complaint`, which is what `SqsProcessor` actually writes and what
  `Emails.Log`'s changeset validates. Five of the six failure statuses were
  covered and the dead entry made the list look complete.
- **Soft bounces stay amber in the activity column** (#674 review) — the
  status-only badge hardcoded `badge-error` for every failure status, repainting
  a retryable soft bounce red in the list while the detail page showed it amber.
  Colour and label now come from `EmailStatusBadge`, so core holds one status →
  colour/label map instead of two that drift.
- **The CRM card checks the viewer's `crm` permission** (#674 review) — every
  admin route shares one `live_session` gated only by `can_access_admin_area?/1`,
  so a role holding `users` but not `crm` rendered a contact's name and was then
  bounced to `/` by `enforce_admin_view_permission/2` on clicking through. The
  permission check also skips the query for viewers who would never see the card.
- **A contact with no name renders a visible link** (#674 review) —
  `phoenix_kit_crm_contacts.name` is nullable, and the card read `.name` directly
  instead of CRM's own `display_name/1` fallback chain, so such a contact
  rendered the card's only link as empty text.

### Tests
- **`email_activity_badges_test.exs`** (new) — the component had none. Enumerates
  the canonical status list from `Emails.Log`'s changeset and asserts the failure
  subset against it both ways, so a whitelist that invents or drops a status
  fails a test whose message says why. Also pins colour parity with
  `EmailStatusBadge`, the labels, and the no-duplicate path.

### i18n
- **The CRM card's new strings are translated** (#674 review) — `This user is
  linked to a CRM contact.` and `Unnamed contact` reached neither `default.pot`
  nor ru/et, the two locales kept at 100%. Appended by hand for the same reason
  as 1.7.220: a full `gettext.extract --merge` now reports 195 new / 53 fuzzy per
  locale, a repo-wide backlog this PR did not cause. `CRM` needed nothing — it
  already exists as a msgid and is translated in both.

## 1.7.220 - 2026-07-29

### i18n
- **The ten strings #673 newly wrapped in `gettext/1` are translated** (#673
  review) — `Add`/`Edit Storage Bucket`, `Add`/`Edit Storage Dimension`,
  `Update Dimension`, `Create`/`Edit User`, `Create a new user account`,
  `Edit user information`, `Media Detail`. The PR wrapped them without touching
  the catalogs, so ru and et — the two locales kept at 100% — rendered them in
  English. Appended by hand to `default.pot` + `ru` + `et`: a full
  `gettext.extract --merge` reports 246 new / 53 fuzzy across 28k lines, a
  repo-wide backlog #673 did not cause, and the fuzzy re-marks would push ru and
  et off 100% rather than toward it.

## 1.7.219 - 2026-07-29

### Added
- **Admin UI standards sweep** (#673) — the admin area moved onto the
  framework's own components. Page-local `<header>` / `<.admin_page_header>`
  blocks fold into the `LayoutWrapper` breadcrumb (`page_section`,
  `page_section_path`, `page_subtitle`, `page_action`), `container mx-auto`
  width caps are gone, hand-rolled form controls are now
  `<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>`, and list views adopt
  `<.table_default>`, `<.empty_state>`, `<.pagination>`, `<.search_toolbar>` and
  `<.nav_tabs>`.
- **`<.row_link>`** (#673) — new core component making a whole table row or card
  clickable with one real `<a>` and a stretched `::after` overlay. A `<tr>` host
  needs `relative transform-gpu`: WebKit ignores `position: relative` on `<tr>`,
  so without a containing block every row's overlay collapses onto the last row
  and every tap on iOS opens that one. Interactive siblings need `relative z-10`.

### Changed
- **`<.select>` and `<.textarea>` render the required marker** (#673 review) —
  `<.input>` grew a red `*` for `required` fields and the sweep deleted the
  hand-rolled markers it replaced, but the other two components never gained
  one. Country on `/admin/settings/organization` was left reading as optional.
- **`<.textarea field={...}>` renders its validation errors** (#673 review) —
  the `FormField` clause mapped `id`/`name`/`value` but not `field.errors`, so a
  field-bound textarea showed no message and no `textarea-error` however the
  changeset failed. The admin-note box on the user detail page was the fourth
  call site to inherit it.
- **`<.pagination_controls>` uses daisyUI 5 `join`** (#673) — `btn-group` was
  removed in daisyUI 5, so the page buttons had lost their grouping.
- **`<.search_toolbar>` takes an `id`** (#673) — defaults to one derived from the
  change event; without a form id LiveView form recovery is silently disabled.

### Fixed
- **The user detail page no longer 500s on a structured custom field** (#673) —
  `custom_fields` is free-form JSONB, and `to_string/1` raises on a map, so any
  user who had ever used the media browser (`media_expanded_folders`, a list) or
  the etcher (`etcher_line_params`, a map) took the whole page down. Structured
  values now render as JSON, lists join.
- **Organization-members rows are clickable on Safari/iOS** (#673 review) — the
  row used `row-link-host`, a class that lives in one host app's `app.css` and
  exists nowhere in this repo, instead of `transform-gpu`. Every member row's
  overlay collapsed onto the last one.
- **Users list rows stay clickable without the Email column** (#673 review) — the
  `row_link` was rendered only inside the `email` cell, but `email` is
  `required: false` in the column picker. Dropping it left every row wearing
  `cursor-pointer` with nothing to click. The overlay now hosts in the first
  visible non-`actions` column.
- **The custom-field "add option" input fills its row again** (#673 review) —
  `class="flex-1"` lands on the `<input>`, but `<.input>`'s
  `<div phx-feedback-for>` wrapper is the flex item; it needed
  `wrapper_class="contents"`.
- **`focus:input-primary` on `<.textarea>`** (#673) — was the input's focus class,
  never the textarea's, so a focused textarea never took the primary border.

## 1.7.218 - 2026-07-29

### Added
- **Sign in as another user** (#672) — `MultiSession.impersonate/2`, a
  `POST /users/session/impersonate/:user_uuid` action, and the authority layer
  over the existing multi-account stack. The rules are role-based on purpose:
  `Scope.can_access_admin_area?/1` is true for **any** permission holder, so a
  permission check would have let a customer with one self-service grant borrow
  another customer's account. Instead the **root** account decides (never the
  active one, or an impersonated session could chain) and must hold Owner or
  Admin; an Owner is never a target; an Admin cannot take another Admin, while
  an Owner can, because there is nothing above it to escalate to. Requires
  `multi_session_enabled`.

### Changed
- **`MultiSession.add_authenticated_user/3`** (#672 review) — takes the
  activity-feed action to write, defaulting to `session.account_added`. Existing
  `/2` callers are unaffected.
- **`already_intercepted: true` now implies `skip_queue: true`** (#670 review) —
  the opt can only mean "a queue worker is re-sending what it dequeued", so
  leaving the two independent let a worker that set one and forgot the other
  offer its own job straight back to the queue that handed it over.
- **`session.impersonated` and `session.account_added` render as notifications**
  (#672 review) — both are claimed by the `security` preference type (so they
  appear in the preferences UI and can be muted) and both have recipient-facing
  copy instead of the humanized raw action string ("Session impersonated").

### Fixed
- **Impersonation refusals are recorded** (#672 review) — the feed was written
  only on success, and only after the session had already changed, despite the
  documented promise of "every attempt, before the session changes". An Admin
  reaching for the Owner's account, reaching sideways for another Admin, or a
  non-staff user hitting the endpoint directly all left no trace at all. They now
  write `session.impersonation_refused` with the deciding rule in
  `metadata["reason"]`, and carry no `target_uuid` so a refused attempt is a feed
  entry rather than a message sent to the account it named.
- **One activity row per impersonation, saying what happened** (#672 review) — a
  success wrote both `session.account_added` and `session.impersonated`, and the
  first is indistinguishable from a user voluntarily adding an account of their
  own.
- **Impersonation authority is settled before the uuid is resolved** (#672
  review) — checking existence first answered "User not found." for an unused
  uuid and a permission message for a live one, turning the deliberately precise
  operator copy into an account-existence oracle for every signed-in user. New
  `MultiSession.may_impersonate?/1` shares its rule with
  `authorize_impersonation/2` so the two cannot drift.
- **Existing users are no longer renamed when the admin form rebuilds its
  changeset** (#671) — `maybe_generate_username_from_email/1` ran on every
  registration changeset and minted a username whenever the params carried none,
  which is exactly what the admin edit form sends; and the uniqueness walk asked
  the database whether the name was taken without excluding the user it was
  generating for, so `maria`'s own row made `maria` look unavailable to maria.
  Opening a user and saving turned `maria` into `maria_1`, then `maria_2`.
- **A generated username carries its uniqueness constraint** (#671 review) —
  generation runs at the end of `registration_changeset/3`, after
  `validate_username/2` has already decided there was no username change to
  guard, so the generated name reached the database unprotected. Two
  registrations racing on the same local part both settled on it and the loser
  got an `Ecto.ConstraintError` raised out of `Repo.insert/1` instead of an
  `{:error, changeset}`.
- **A queued message is intercepted once** (#670) — `skip_queue: true` skipped
  only the queue offer, so a queued-then-drained message went through
  `intercept_before_send/2` twice and a provider that logs per interception
  recorded every send twice.
- **Out-of-contract `maybe_enqueue/2` returns are logged** (#670) — a provider
  bug returning anything other than `:continue` / `{:queued, ref}` still sends
  (a bug must not eat the message) but no longer does so invisibly.
- Removed seven `Logger.info` calls left in the admin user form from debugging
  the username rewrite (#671).

## 1.7.217 - 2026-07-28

### Added
- **SMTP transport settings** (#668) — five optional setup fields on the `smtp`
  integration provider: `security` (`auto` / `ssl` / `starttls` /
  `starttls_optional` / `none`), `auth` (`if_available` / `always` / `never`),
  `verify_cert` (`verify_peer` / `verify_none`), `ca_cert` (a PEM bundle that
  replaces the system store for that connection) and `timeout` (seconds).
  Blank reproduces the previous port-based rule exactly, so existing connections
  send unchanged; unknown values are **refused** rather than coerced back to
  `auto`, so a typo cannot silently downgrade a connection's encryption. The
  Test Connection probe builds from the same `SmtpTransport.config/1` options as
  the send path.
- **Optional `maybe_enqueue/2` callback on `PhoenixKit.Email.Provider`** (#668)
  — offered right after `intercept_before_send/2` on **both** delivery paths, so
  an email package can take delivery over for every outgoing message, including
  the host application's password resets and confirmations. `{:queued, ref}`
  short-circuits the send and reaches the caller as
  `{:ok, %{id: ref, queued: true}}`; `:continue` sends normally. Guarded by
  `function_exported?/3`, so a package built against an older core is unaffected.
  `skip_queue: true` lets a queue worker ask for the real send.
- **Setup fields render by `:type`** (#668) — `setup_field/1` now honors
  `:select`, `:textarea` and `:number` instead of forcing `type="text"`, with a
  text-input fallback for a type it has never heard of. The website-wide
  integration form uses the shared component instead of a hand-rolled copy, so
  the two forms can no longer drift.
- **Sender-address warning on the Email Sending settings page** (#668) — a
  sender that is not a full address (the built-in default `noreply@localhost`
  among them) is silently refused by the email tracking module's `Log`
  changeset, so mail went out and the log stayed empty with nothing in the UI
  saying why. The page now warns, both in a banner and on save.
- **`Chart` core component** (#669) — server-rendered SVG `line_chart/1`,
  `sparkline/1` and `bar_chart/1`. No JS, no external library; theme-aware via
  `currentColor`, and live by construction (assigns change → SVG re-renders).
  Points may be `{x, y}` tuples or `%{x: _, y: _}` maps, `Decimal` is converted
  automatically, and non-numeric points are dropped rather than crashing the
  page — with an `:empty` slot for "nothing usable left".
- **`StatusDot` core component** (#669) — semantic coloured dot with an optional
  label and `pulse`, plus a screen-reader state name so the state is not carried
  by colour alone.
- **`ConnectAccountButton` core component + `PopupLink` JS hook** (#669) —
  OAuth-popup account linking (distinct from `OAuthProvider`, which is app
  sign-in). A real `<a href>` intercepted only once `window.open` returns a
  window, so a blocked popup, JS being off, or a modifier-click all fall back to
  ordinary navigation.
- **`value_color` on `<.stat_card>`** (#669) — for values whose colour *is*
  information (a price coloured by cheapness). Any `;` is stripped so the value
  cannot append further declarations.
- **`mix test.js`** (#669) — `node --test` over the pure logic in the shipped
  hook bundle, wired into `mix precommit`. Skips itself when node is not
  installed, or when the glob matches nothing.

### Changed
- **`<.stat_card>`'s `rounded` attr is now honored** (#669). It was previously
  declared and ignored — the class was hardcoded `rounded-box`. Two consequences
  for consumers: a caller that already passed `rounded="xl"` now actually gets
  `rounded-xl`, and the attr has a closed `values:` list (`box`, `none`, `sm`,
  `md`, `lg`, `xl`, `2xl`, `3xl`, `full`), so a value outside it emits a
  compile-time warning. The whitelist exists because Tailwind scans source for
  literal class names — an interpolated `rounded-#{@rounded}` produces a class
  with no CSS behind it.
- **SMTP `username` and `password` are no longer required fields.** An internal
  relay that authenticates by IP has no login to give, and `SmtpTransport` has
  always had a credential-less branch — but marking the fields required made it,
  and the new `auth: never` / `security: none` settings, impossible to reach:
  the form refused to submit and `connected?/1` refused to call the connection
  configured, so mail silently fell back to the built-in mailer. `host` and
  `port` remain required. The Test Connection probe stops forcing `auth: always`
  when there is no login to prove, which would otherwise have failed every such
  relay.
- **Personal integrations form clears blanks like the website form does.** It
  dropped blank values for *every* field, so a cleared optional field — an SMTP
  CA bundle, a timeout — kept its old value while the form showed empty. Blanks
  are now dropped for `:password` fields only, matching
  `Settings.IntegrationForm`, and values are trimmed on both paths.

### Fixed
- **`mix precommit` failed on dialyzer** — the sender-address check added in
  #668 had an unreachable catch-all clause (`pattern_match_cov`), which halted
  `mix dialyzer` with exit status 2 and, because aliases run in order, meant the
  new `test.js` step never ran at all.
- **`:type` is read softly on the integration save paths too.** `setup_field/1`
  was hardened to tolerate a provider field map without `:type` (external
  modules contribute providers through `integration_providers/0`), but both save
  paths still did `field.type` — so such a provider rendered fine and then raised
  `KeyError` on submit, after the operator had committed to their input.
- **SMTP `timeout` no longer accepts a number with a unit.** `Integer.parse/1`
  returns `30` for both `"30s"` and `"30 minutes"`, so an operator who typed
  minutes got a 30-second timeout with no complaint. The remainder must now be
  empty.
- **`deliver_via_integration/3`'s documented error list** now names the five
  SMTP transport-setting reasons added in #668.

## 1.7.216 - 2026-07-27

### Fixed
- **Every `phx-change` form now carries an `id`** — LiveView cannot perform form
  recovery on an id-less form, so a crash or reconnect silently dropped whatever
  the user had typed, and host test suites saw an unfixable
  `Detected a form with phx-change but missing id` warning coming out of the
  dep's own templates (the only workaround being
  `config :phoenix_live_view, :test_warnings, missing_form_id: :ignore`, which
  also mutes the host's own genuine cases). 26 forms across core, storage,
  sitemap and maintenance were affected. Ids on LiveComponent-rendered forms are
  derived from the component's `@id` (and, for per-row inline folder rename /
  description editors, the folder uuid) so nothing collides when a page renders
  more than one. `<.form for={%{}}>` call sites were affected too — a bare map
  with no `:as` produces a `nil` id — so `MediaBrowser`'s search, the annotation
  composer, the media selector upload form and the storage media-config form are
  fixed as well.

### Changed
- **`<.sort_selector>` accepts an `id`** — defaults to
  `"pk-sort-selector-#{event}"`; pass an explicit one when a page renders two
  sort selectors that share an `event`.

## 1.7.215 - 2026-07-27

### Fixed
- **Sitemap: `/users/qr-login` and `/robots.txt` no longer land in the sitemap**
  — both were missing from Router Discovery's default exclude patterns. The QR
  device-handoff login is a public route with no auth pipeline and no `on_mount`
  hook, and the existing `"/users/log-in"` pattern does not match it; a
  controller-served `robots.txt` reaches the router the same way (Plug.Static
  installs are unaffected). Note that `sitemap_router_discovery_exclude_patterns`
  *replaces* the defaults when saved, so installs that already customized the
  list must re-copy it from `/admin/settings/sitemap` to pick these up.

## 1.7.214 - 2026-07-27

### Added
- **Notification delivery channels** (PR #665) — a parallel routing layer that
  sends notifications to external destinations alongside the in-app inbox.
  Core ships Email (always available, uses the account address) and Telegram
  (auto-discovers the recipient's personal bot connection and its captured
  chats); feature modules contribute more via the optional
  `notification_channels/0` callback. Per-user, per-type opt-in lives in
  `users.custom_fields` under one `notification_channel:<key>` key per channel,
  so no migration is needed and the inbox path is untouched — "Telegram on,
  inbox off" works. Delivery runs off the hot path on a dedicated
  `:notifications` Oban queue with a permanent/transient error taxonomy (a
  blocked bot soft-disables the channel instead of retry-storming).
- **Notification aggregation** (PR #665) — each type can be routed on a digest
  cadence (hourly / 12h / daily / weekly) per delivery mode instead of pinging
  per event; `PhoenixKit.Notifications.DigestWorker` sweeps one fixed window per
  cadence on cron and sends a single summary, with no per-user last-sent state.
  In-app is a delivery mode too, so a digest cadence collapses the inbox to one
  summary row.
- **Personal (per-user) integrations** (PR #665) — connections now carry an
  owner (`:system | :any | {type, id}`) stored in the existing JSONB
  (`owner_type` / `owner_uuid`, write-once, no migration). Two independent
  admin surfaces share the storage: `/admin/settings/integrations` (personal,
  gated by the new `integrations` permission key) and
  `/admin/settings/integrations/website` (website-wide, gated by
  `integrations_system`). Providers declare which scopes they allow
  (`Providers.scopes_of/1`), enforced at row birth so a crafted event cannot
  create a personal OAuth connection.
- **`"*"` superadmin permission key** (PR #665) — a blanket, drift-immune grant
  that makes a role Owner-equivalent for feature access without enumerating
  keys, honored by `Scope.has_module_access?/2`, `can?/2` and
  `accessible_modules/1`. Owner holds it structurally; a host can grant it to a
  custom role. Role-management safety rails (editing Admin, assigning
  Owner/Admin, the last-Owner guard) stay role-name-based and are NOT unlocked
  by it.
- **Permission audit trail** (PR #665) — `permission.granted` /
  `permission.revoked` / `permission.synced` activity entries for
  user-initiated changes (the boot-time auto-grant sweep passes no actor, so
  startup never floods the feed).
- **Telegram bot client** (PR #665) — `PhoenixKit.Integrations.Telegram`:
  `send_message/4` plus a one-shot `get_updates/2` used purely to discover a
  user's `chat_id` during chat linking.
- **Site-wide Default Editor Mode setting** (PR #664) — `editor_default_mode`
  (Hybrid / Visual / Markdown / HTML) under a new "Content Editor" section on
  `/admin/settings`, plus `PhoenixKit.Settings.get_editor_mode/0` returning the
  mode as an atom ready for Leaf's `mode` attr. No migration: the settings LV
  merges `get_defaults/0` over the stored rows.
- **V159** (PR #665) — publishing categories (hierarchical per-group taxonomy,
  `slug` unique per group, `name_i18n` per-language names), post↔category M:N
  assignment, and per-day post view rollups.

### Changed
- `Scope.admin?/1` is renamed **`Scope.can_access_admin_area?/1`** (PR #665).
  The old name misled — it is true for ANY permission holder, not just the
  Admin role. `admin?/1` remains as a `@deprecated` alias. For a "can do
  everything, like Owner" check use `holds_all_enabled_permissions?/1` or
  `superadmin?/1`.
- **Disabled modules are now blocked for everyone, Owner included** (PR #665),
  uniformly across the LiveView mount hook, the fresh-mount gate and the plug —
  previously Owner bypassed enablement in two of the three, so the same user
  saw a disabled module's page through one gate and a redirect through another.
- **Unmapped admin views now require a full-access scope** (PR #665) rather than
  `system_role?`, so a named Admin whose keys an Owner partially revoked no
  longer reaches them. A default Admin still passes (the baseline is enabled
  keys minus the opt-in ones); a deliberately-stripped role gets blanket access
  via the `"*"` key.
- Every permission mutation path (`grant_permission`, `revoke_permission`,
  `set_permissions`, `revoke_all_permissions`) now takes the **same role-row
  lock first** (PR #665). Previously per-key grants and the whole-role sync used
  disjoint lock objects, so a grant committed mid-`set_permissions` survived a
  strip the Owner intended.
- `leaf` 0.3.2 (PR #664) — hex pin and the CDN pin in
  `priv/static/assets/phoenix_kit.js` moved in lockstep.
- `usage_rules` 1.2.7.

### Fixed
- **`mix phoenix_kit.update` now backfills the notification digest cron
  entries** (post-merge review of #665). `ensure_cron_plugin/2` short-circuits
  as soon as `ProcessScheduledJobsWorker` is in the crontab, so an existing host
  got the new `:notifications` queue but never the four `DigestWorker` entries —
  and `DigestWorker` has no other enqueue site. Because the creation path
  already suppresses the per-event inbox row once a type is on a non-immediate
  cadence, a user picking "Daily" on an upgraded host got no per-event row *and*
  no summary: the notifications were silently lost, in-app and external alike.
  The new `ObanConfig.ensure_digest_cron_entries/2` adds each missing cadence
  independently and anchors the crontab block's closing bracket to the
  `crontab:` keyword's own indentation, so a lazy match cannot land entries
  inside a nested list.
- **The notification settings page no longer persists unvalidated keys from form
  params** (post-merge review of #665). `save_channel_types/2` and
  `save_cadences/2` used raw param keys as storage keys, so a crafted submit
  wrote arbitrary `notification_channel:<anything>` blobs — with arbitrary
  nested type/cadence entries — into the user's `custom_fields` JSONB. Both now
  filter against `Channels.keys()` / `["inapp" | Channels.keys()]` and
  `Types.all_pref_keys()`, matching what the sibling in-app save already did.
- **Module-contributed notification channels are no longer dropped in a
  release** (post-merge review of #665). `Channels.external_channels/0` guarded
  with a bare `function_exported?/3`, which answers false for a module that has
  not been loaded yet — the norm under lazy loading. It now calls
  `Code.ensure_loaded?/1` first, matching the sibling `Types.external_types/0`.
- **A wholly-failed Telegram broadcast is no longer silent** (post-merge review
  of #665). When every chat fails permanently the channel still reports `:ok`
  (one blocked subscriber must not disable a working broadcast), but a revoked
  token or a bot kicked everywhere looked exactly like a successful delivery. It
  now logs a warning naming the target count and the failures.
- **The editor-mode allowlist has a single source** (post-merge review of #664).
  The four modes were written out independently in `editor_mode_options/0`, the
  changeset's `validate_inclusion`, and `get_editor_mode/0`'s coercion clauses —
  while `editor_mode_options/0`'s docstring claimed to be the single source for
  all three. A mode added to two of the three either saves and silently coerces
  back to `:hybrid`, or is offered in the picker and rejected by the changeset.
  All three now derive from one `@editor_modes` list.

## 1.7.213 - 2026-07-26

### Changed
- **Lifeline is now validated by value, not just presence.** 1.7.212 raised the
  shipped `rescue_after` to 60 minutes at every emit site, but both the
  installer and `mix phoenix_kit.doctor` still only asked whether an
  `Oban.Plugins.Lifeline` entry existed. Oban's own docs advertise
  `rescue_after: :timer.minutes(5)` as the "more aggressive period" example, so
  a host copying from them sat squarely in the duplicate-execution window while
  PhoenixKit reported everything as fine.
  - `mix phoenix_kit.doctor` warns when `rescue_after` is at or below the
    longest `timeout/1` PhoenixKit ships (30 minutes,
    `Storage.Workers.SyncFilesJob`). An *unset* `rescue_after` is treated as
    safe — that means Oban's own 60-minute default.
  - `PhoenixKit.Install.ObanConfig.ensure_lifeline_plugin/2` raises a too-low
    `:timer.minutes(N)` literal to 60 instead of no-oping on any existing entry.
    Only that literal form is rewritten; any other expression (raw
    milliseconds, a module attribute, a runtime lookup) is left untouched with
    a notice rather than blind-edited.
  - The value now has a single source (`lifeline_entry/0`) feeding the
    generated template, the backfill and the manual-fallback message, so the
    emit sites cannot drift apart again.
- **V157 `down/1` fails loudly instead of opaquely** (issue #663). Rolling back
  re-adds the narrower `phoenix_kit_annotations_kind_check`, and Postgres
  validates a CHECK against every existing row — so one `kind = 'image'`
  annotation created since `up/1` made the rollback die with a bare `23514`
  partway through. `down/1` now checks first and raises a message naming the row
  count and the two real ways forward (remove/convert the rows, or stay on V157
  — its widened CHECK is a superset of V156's). The check runs before anything
  is queued, so no half-applied DDL is left behind. Deleting user annotations
  from a rollback, and `NOT VALID` (a constraint that lies about the rows
  already present), were both rejected as worse; see the new
  `## down/1 is conditional, by necessity` moduledoc section.

### Fixed
- `mix phoenix_kit.doctor` no longer emits a false-positive Lifeline warning on
  a node running `plugins: false`. 1.7.212 stopped the `length(false)` crash but
  then let `false` fall through as `[]` into the Lifeline branch, so a
  deliberately plugin-less node was told to run `mix phoenix_kit.update` — which
  would rewrite `config.exs` for a node that must not run plugins at all. It now
  reports plugins-disabled and skips the check.

### Added
- `test/phoenix_kit/migrations/v157_test.exs` (issue #663) — V157 was the one
  recent migration with no test of its own. Deliberately narrow:
  `annotations/annotation_kind_test.exs` already pins both layers accepting
  `"image"`, so this file pins the CHECK's *whole* vocabulary, which is what a
  later migration could silently narrow while leaving that file green. Not yet
  executed against a live database — see the investigation doc.
- The Lifeline invariant test now discovers workers at runtime (every
  `Oban.Worker` in `:phoenix_kit` exporting `timeout/1`) instead of hardcoding
  three modules, so a new long-running worker fails the test rather than
  quietly eroding the margin.
- `dev_docs/investigations/2026-07-26-issue-663-post-release-audit.md` — full
  write-up of issue #663's four items, including the two that did **not** hold
  up: the Tessera CDN pin (`tessera@v0.3.1` vs `mix.lock` 0.3.4) is a cosmetic
  mismatch only — `alexdont/tessera` has no `v0.3.4` tag, so the recommended
  bump would 404 the loader, and the asset is byte-identical across v0.3.1,
  v0.3.2 and hex 0.3.4 — and the `#652` host-router note is already satisfied by
  the `:browser` pipeline `mix phx.new` scaffolds.

## 1.7.212 - 2026-07-26

### Added
- **`Oban.Plugins.Lifeline` shipped to host apps** (PR #662). The Oban config
  `mix phoenix_kit.install` generates now carries
  `{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}`, and
  `mix phoenix_kit.update` backfills it into an existing host config via the
  new `PhoenixKit.Install.ObanConfig.ensure_lifeline_plugin/2`. Without it a
  job orphaned in `:executing` by a hard crash (`kill -9`, OOM, node loss) is
  never returned to `:available` — and for a unique worker whose `states:`
  includes `:executing`, that orphan permanently blocks every future insert
  for the worker, not just the crashed job.
- `mix phoenix_kit.doctor` warns when the host's running Oban config has no
  Lifeline plugin, pointing at `mix phoenix_kit.update` as the remedy.

### Changed
- `bandit` 1.12.1 → 1.12.3.

### Fixed
- Post-merge review of PR #662 (`dev_docs/pull_requests/2026/662-oban-lifeline-installer/`):
  - **`rescue_after` raised 30 → 60 minutes.** Lifeline rescues purely by
    elapsed time and never checks whether the executing node is still alive, so
    `rescue_after` must exceed the longest job the host can legitimately run.
    PhoenixKit itself ships a 30-minute worker (`Storage.Workers.SyncFilesJob`),
    and every worker without a `timeout/1` callback has no bound at all — at 30
    minutes a long newsletters-delivery, shop-import or sitemap run would be
    flipped back to `:available` and re-executed *concurrently with the still
    running original* (duplicate emails on the delivery queue). 60 minutes is
    Oban's own default and 2× the longest declared timeout. The invariant is
    now documented in the generated `config.exs` comment and locked by a test
    that asserts the emitted value exceeds every shipped worker's `timeout/1`.
  - `add_cron_plugin_to_plugins/2` no longer matches its plugins-block close
    with the un-anchored `\n[ \t]+\]`, which binds to the first *nested* list's
    bracket — the same corruption PR #662 fixed in `ensure_lifeline_plugin/2`
    but left in its sibling. A host whose `plugins:` list contains an entry with
    a list option (`{Oban.Plugins.Reindexer, indexes: [...]}`, Oban Web's stats
    plugin) would have had its `config.exs` mangled by `mix phoenix_kit.update`.
    It now uses the same indentation-anchored pattern and derives the inserted
    entry's indentation from the block instead of hardcoding four spaces.
  - `mix phoenix_kit.doctor`'s Oban check no longer raises on `queues: false` /
    `plugins: false` — Oban's documented way to disable either, standard in test
    config and on hosts that run jobs from a dedicated node. `length(false)`
    raised `ArgumentError`, surfacing as a bogus `FAIL Exception: ...`.

## 1.7.211 - 2026-07-25

### Added
- **Migration V158** — `attachments JSONB NOT NULL DEFAULT '[]'` on
  `phoenix_kit_newsletters_broadcasts`: an ordered list of Storage file uuids
  attached to every email of a broadcast, guarded by a
  `phoenix_kit_newsletters_broadcasts_attachments_is_array` CHECK
  (`jsonb_typeof = 'array'`). Soft references, no FK into
  `phoenix_kit_files` — same precedent as this table's `crm_list_uuid` (V152)
  and `source_params` (V155), so a file later deleted from Media degrades to
  skipped-at-send rather than blocking the delete. Element-level validation
  (uuid-ness, count cap) lives in the `phoenix_kit_newsletters` `Broadcast`
  changeset. `@current_version` bumped 157 → 158 (PR #661).

### Changed
- `bandit` 1.12.0 → 1.12.1, `plug_crypto` 2.1.1 → 2.2.0.

### Fixed
- Post-merge review of PR #661 (`dev_docs/pull_requests/2026/661-broadcast-attachments-v158/`):
  `v158_test.exs`'s `information_schema.columns` lookup now anchors
  `table_schema = 'public'` — `prefix_migration_test.exs` builds the same table
  in a scratch schema on the same database, so an interrupted run could leave
  two matching rows and fail the suite with an unrelated `CaseClauseError`.
  Added a CHECK-rejection test for a JSON scalar (the object case alone covered
  one of the five non-array `jsonb_typeof` results), and a `## down/1`
  moduledoc section recording that V158 must roll back together with the
  newsletters release that writes the column.

## 1.7.210 - 2026-07-23

### Fixed
- **Issue #652** — `** (ArgumentError) flash not fetched, call fetch_flash/2`
  on every router-rendered LiveView that redirects during mount with a flash
  message set (e.g. `:phoenix_kit_ensure_admin`'s "You must log in to access
  this page." redirect for unauthenticated admin-route hits). The dev/test
  router's `:browser` pipeline had no `fetch_flash`/`fetch_live_flash` plug,
  so `Phoenix.LiveView.Controller.live_render/3` crashed instead of
  redirecting whenever it tried to fold the on-mount flash back onto the
  conn. Added `plug :fetch_live_flash` to `lib/phoenix_kit_web/router.ex`'s
  `:browser` pipeline, plus a regression test. Test-harness-only fix — real
  parent apps generated via `mix phx.new` already carry this plug by
  convention.

## 1.7.209 - 2026-07-23

### Added
- **Etcher image annotation tool** — the media viewer's annotation toolbar
  now exposes Etcher's `:image` tool (fresco `~> 0.10`, etcher `~> 0.9`),
  which inserts an image annotation via the OS file picker as a `data:`
  URL (PR #660).
- **Migration V157** — widens `phoenix_kit_annotations_kind_check` to allow
  the new `"image"` annotation kind, paired with `Annotation.@kinds`.
  `@current_version` bumped 156 → 157.

### Fixed
- The `:image` toolbar tool added by PR #660 shipped without widening the
  annotation kind whitelist/CHECK constraint to match — image annotations
  drew fine client-side but silently failed to persist across a reload
  (same regression class as V130's `"marker"` fix). Closed by V157 above.

## 1.7.208 - 2026-07-21

### Changed
- `<.admin_page_header back={...}>`'s back affordance now renders inline
  beside the title (a circular icon chip aligned to the title's first line)
  instead of as a bare ghost button on its own row above it. When
  `back_label` is set, the chip widens to show the label from the `sm`
  breakpoint up; phones always stay icon-only. A blank `back_label=""` now
  normalizes to absent instead of producing an empty `aria-label`/tooltip.
  No attribute API change — all existing `back`/`back_label` call sites
  render the new anatomy unchanged (PR #659).

## 1.7.207 - 2026-07-21

### Added
- **Migration V156** — migrates legacy `phoenix_kit_newsletters_lists` /
  `..._list_members` into the CRM's `phoenix_kit_crm_lists` /
  `..._crm_list_members` (spec §4.5), re-points
  `phoenix_kit_newsletters_broadcasts` off `list_uuid` onto
  `source_type = 'crm_list'` / `crm_list_uuid`, then drops the legacy tables
  and column entirely. Requires a coordinated release with the newsletters
  module — see the migration's moduledoc warning. `@current_version` bumped
  155 → 156.
- `PhoenixKit.Users.Auth.merge_user_custom_fields/3` — atomically merges keys
  into a user's `custom_fields` JSONB column at the database level
  (`custom_fields || additions` inside the `UPDATE` itself), closing a
  lost-update race where two callers merging *different* keys concurrently
  (e.g. a locale-preference switch and a newsletters opt-out) could silently
  drop one writer's key. `delete_user_custom_field/3` gets the same atomic
  treatment (`custom_fields - key`); `set_user_custom_field/3` and
  `update_user_locale_preference/2` now route through these atomic
  primitives instead of a read-modify-write whole-map replace.
- `PhoenixKit.RepoHelper.update_all/3` — delegate to the configured repo's
  `update_all/3`, needed by the atomic custom-fields primitives above.

### Fixed
- `merge_user_custom_fields/3` and `delete_user_custom_field/3` now bump
  `updated_at` on write (missed in the initial PR since `Repo.update_all/2`,
  unlike a changeset-backed `Repo.update/2`, doesn't auto-stamp timestamps).

## 1.7.206 - 2026-07-20

### Added
- **Migration V154** — `phoenix_kit_og_templates` (reusable OpenGraph canvas
  designs; JSONB `canvas`) and `phoenix_kit_og_assignments` (binds a template
  to a `module_key × scope_type × scope_uuid` scope via a partial-index pair),
  powering the upcoming `phoenix_kit_og` plugin. `@current_version` bumped
  153 → 154.
- **Migration V155** — `crm_contact_uuid` on `phoenix_kit_newsletters_deliveries`
  (soft reference, no FK, matching the `crm_list_uuid` convention), a widened
  `..._recipient_check` CHECK (still requires an addressable recipient, and
  now also forbids a row claimed by both `user_uuid` and `crm_contact_uuid`),
  the first DB-level per-broadcast delivery dedup (three partial unique
  indexes), and `source_params` JSONB on `..._broadcasts` for the new
  `user_group` (core-role) recipient source. `@current_version` bumped
  154 → 155.
- `<.bulk_actions_toolbar>` gained a `:trailing` slot for far-right toolbar
  content (e.g. a view-mode switcher) that should sit apart from the
  left-aligned sort/filter controls.
- `<.search_toolbar>` shows a loading spinner while its debounced search is
  in flight; opt out with `loading_indicator={false}` for client-instant
  filters (pairs with the new `TableLocalSearch` hook).
- `TableLocalSearch` JS hook: client-instant row narrowing for
  `<.search_toolbar>` tables once the full row set is already loaded, without
  waiting on the server round-trip.
- `AdminSidebarScroll` JS hook: the admin sidebar keeps its scroll position
  across live redirects and full reloads instead of resetting to the top.
- `<.tab_item>` sets `aria-current="page"` on the active tab.
- `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` gained `page_action`:
  a compact circular action button rendered next to the breadcrumb title.
- `PhoenixKit.Settings.timezone_options/0` and `get_timezone_label/1`: a cheap
  timezone-label accessor that resolves without building the full
  `get_setting_options/0` map, so callers that only need the timezone string
  no longer pay for a `Roles.list_roles/0` query on every call.

### Changed
- Bumped `etcher` to `0.8.2` (fixes invisible circle annotations on a rotated
  canvas).

## 1.7.205 - 2026-07-19

### Changed
- Bumped `beamlab_ex_aws_sqs` to `~> 5.0`, declared as `{:ex_aws_sqs, "~> 5.0", hex:
  :beamlab_ex_aws_sqs}`. v5.0.0 renamed the compiled OTP app back to `:ex_aws_sqs`
  (only the Hex package name is `beamlab_ex_aws_sqs`), so it can be a drop-in for
  anything depending on `:ex_aws_sqs` directly. No code changes — `ExAws.SQS`'s
  public API is unchanged.

## 1.7.204 - 2026-07-19

### Added
- Media browser: per-file kebab menu gained Rotate left/right (counter-
  clockwise + clockwise), saving `metadata["rotation"]` the same way the
  viewer's rotate button does and refreshing the grid thumbnail live.
- Esc now exits the media browser's select mode, mirroring the toolbar's
  Cancel button.

### Changed
- **New folders default to a small hero header** instead of medium
  (`PhoenixKit.Modules.Storage.Folder.header_size` default flips to
  `"small"`). **Migration V153** flips the DB column default to match and
  backfills existing `'medium'` rows to `'small'` (indistinguishable from
  "never customized"); rows already on `'large'` or `'small'` are left
  alone. `@current_version` bumped 152 → 153.
- **A folder's Trash is now scoped to that folder's own subtree** instead
  of always listing every trashed folder/file across the whole install —
  opening Trash inside a folder no longer shows what was trashed under
  unrelated sibling roots. Applies to the trash view, the trash-count
  badge, and Empty Trash.

### Fixed
- **A folder's own cover/logo files were hidden from that folder's file
  listing.** They're real, re-selectable files (not synthetic assets) and
  now show up like any other file in the folder they decorate.
- Estonian (`et`) translations: several `default.po` entries were mapped to
  the wrong string entirely (e.g. "Header size" read as "Pealkiri"/Title,
  "Documents" read as "Kommentaarid"/Comments) rather than being merely
  untranslated.
- **"Test email" on the Email Sending settings page showed a raw
  `{:incomplete_credentials, [...]}` tuple** when the active send
  integration was missing a required field. Now shows a plain-language
  message naming the missing field(s).
- **Migration V152**: a newsletters delivery row could be saved addressable
  by neither a core `User` nor a snapshotted `recipient_email`, making it
  unreachable by any send path. Added a `CHECK (user_uuid IS NOT NULL OR
  recipient_email IS NOT NULL)` constraint as a DB-level backstop (the Ecto
  insert path already guarded this; the constraint just closes the gap for
  anything that bypasses it).

## 1.7.203 - 2026-07-18

### Added
- **Send Profiles moved from `phoenix_kit_newsletters` into core.**
  `PhoenixKit.Email.SendProfile`/`SendProfiles` are now shared infrastructure
  any module can send through, routed via the profile's `Integrations`
  connection (per-provider `ProviderOptions`, including SES/Brevo
  configuration-set and tag options). App-config transport is now
  detect-and-display only.
- **New Settings → Email Sending page**: transport detection, default-profile
  picker, and a seam (`email_settings_sections/0`) where external modules
  (e.g. the `emails` package) mount their own settings sections as
  live_components instead of owning a separate Settings tab. Send Profiles
  CRUD gets its own nested sidebar entry under Email Sending.
- **Quota/credits surfacing per send profile**: SES `GetSendQuota` and Brevo
  `/account` (plan + credits) are now shown per profile; a validator that
  cannot verify actual sending capability (e.g. SES credentials scoped to
  `ses:SendEmail` alone) says so instead of showing a bare green tick.
- **Migration V152**: `email_send_profiles` created in core (uuid-preserving
  copy from the old newsletters table, which is then dropped); CRM contact
  list groundwork (`phoenix_kit_crm_lists`, `phoenix_kit_crm_list_members`,
  citext member email); broadcasts can now source recipients from a CRM list
  (`source_type`/`crm_list_uuid`, soft reference).

### Fixed
- **A stored email connection with a blank required field (SMTP `host`, SES
  `aws_region`) could crash mail delivery with the plaintext secret embedded
  in the crash message.** A connection's `status` can say "connected" while
  an individual field was blanked out after the last successful validation;
  that reached `Swoosh.Mailer.deliver/2` uncaught, which raises with the
  *entire* adapter config — password/access key included — inlined in the
  exception text. `PhoenixKit.Mailer.swoosh_config_for/1` now validates
  required fields itself and fails closed with
  `{:error, {:incomplete_credentials, [field_names]}}` before any
  secret-bearing config is built.
- **`pagination_range/2` could OOM the whole BEAM.** An unclamped
  `current_page` (e.g. `?page=9999999999`) built a descending
  `9999999997..56` Range — ~10 billion iterations in the component's `for`.
  Now clamps into `[1, max(total_pages, 1)]` with an explicit `//1` step as
  a second guard; `pagination_controls/1` additionally gained a
  `total_pages > 1` outer guard.
- `table_default`'s search toolbar rendered no `<form>` when only
  `on_change` was given — `phx-change` on a formless input dies silently
  client-side. The form is now always rendered.
- Admin view permission map: five settings LiveViews (Integrations,
  IntegrationForm, EmailSending, SendProfiles, SendProfileForm) resolved to
  nil → custom "settings"-scoped roles were denied. Mapped explicitly.
- A plugin module assigning `page_section` was a silent no-op —
  `admin.html.heex` now forwards it (and `page_section_path`) to the layout.
- **The universal `smtp` integration provider could not send at all.** gen_smtp
  supplies no TLS options of its own and OTP's `:ssl` now defaults to
  `verify: :verify_peer` with no CA store, so port 465 died with
  `{:options, :incompatible}` and STARTTLS died with `:tls_failed`. The transport
  now builds the options properly (`PhoenixKit.Mailer.SmtpTransport`), including
  the `depth` gen_smtp otherwise defaults to `0` — which rejects every real
  certificate chain.
- **"Test Connection" verified nothing** for `aws_ses`, `smtp` and `brevo_api`:
  the connection was stamped `"connected"` without a byte leaving the box, so a
  wrong key showed green and then failed at send time. All three now perform a
  real check, bounded by a deadline.
- **A failed connection check could take the operator's page down, or leak a
  socket for twenty minutes.** `:gen_smtp_client.open/1` runs in the calling
  process and waits on a hard-coded 20-minute timeout past `connect`; the checks
  now run in an isolated, linked-and-monitored process
  (`PhoenixKit.Integrations.Probe`) that neither kills its caller nor outlives it.

### Security
- **SMTP no longer sends in plaintext when TLS cannot be established.**
  `tls: :if_available` had been masking the broken TLS configuration above by
  silently falling back to an unencrypted session — with the relay password on the
  wire. A relay that expects credentials now fails closed.

### Changed — may require action on upgrade
- **SMTP sending now stops on images with no CA bundle** (`{:error, :no_ca_store}`)
  instead of proceeding with certificate verification disabled. Slim base images
  (distroless, scratch, some Alpine builds) are affected: install `ca-certificates`.
  A relay configured with no username or password still degrades rather than
  failing — it has no credentials to protect.
- **Configured SMTP relays are no longer MX-resolved** (`no_mx_lookups: true`).
  gen_smtp would otherwise look up the relay's MX records and connect to whatever
  they point at, while SNI and the hostname check stay pinned to the configured
  name — a guaranteed certificate mismatch. If you configured `host` as a bare
  domain and relied on MX resolution, point it at the relay itself.
- **AWS SES credentials scoped to `ses:SendEmail` alone now pass Test Connection
  with a note** rather than a bare green tick. They cannot read the send quota, so
  the check can prove the credentials are valid but not that they can send, and it
  now says so on screen instead of only in the log.

## 1.7.202 - 2026-07-18

### Fixed
- Media rotation now persists for any user, not just admins. The embedded
  `MediaBrowser` popup opts every viewer into `persist_rotation` (previously
  gated on `@admin`) — rotation is the file's shared orientation
  (`metadata["rotation"]`), not a per-user preference, so a non-admin who
  could open and rotate a file in an embedded browser saw the turn but it
  never stuck. The admin detail page already did this unconditionally; the
  popup now matches. The `Details` link stays admin-only.

## 1.7.201 - 2026-07-18

### Fixed
- `/admin/media/:file_uuid` was declared before `/admin/media/selector`,
  so the router matched `selector` as a `:file_uuid` param and the
  dedicated selector route was unreachable — reordered.
- Folder header cover/logo images now render the file's saved rotation
  (previously always unrotated, unlike every other thumbnail surface).
- `MediaSelectorModal`/`MediaSelector` selection is now an ordered list
  instead of a `MapSet`, so pick order survives to `MediaGallery`'s
  "featured image" (first entry) instead of being silently reshuffled.
  Multi-select pickers also gained an optional `max_select` cap with a
  "Maximum N files" indicator instead of the consumer silently truncating
  on confirm.
- Media browser bug sweep: "Select all" now covers files inside expanded
  stacks; download (single + bulk) resolves selections that span pages or
  live inside a stack instead of silently no-oping; permanent delete now
  double-checks `status == "trashed"`; leaving trash view reloads the real
  folder list instead of reusing the stale trashed one; switching between
  trash/normal view clears any carried-over selection; paging in
  controlled mode no longer drops the trash/orphaned views through a URL
  round-trip they can't address; deleting the last item on a page clamps
  back to the last populated page instead of showing an empty grid;
  "Delete folder" copy now correctly says contents are deleted recursively
  (not moved to the parent).
- `MediaDetail` no longer crashes on a malformed `file_uuid` route segment
  (falls back to the "not found" state).
- `MediaSelector`'s `return_to` param is now restricted to same-origin
  paths (rejects `//host` / `/\host` bypasses); `page` no longer crashes
  the mount on a non-numeric value; pagination links use `patch` instead
  of `navigate` so a page change doesn't drop the in-memory multi-select;
  the browse query now excludes trashed/system-managed files; a failed
  upload no longer crashes the LiveView.
- `storage_max_upload_size_mb` setting no longer crashes every media
  surface at mount if the stored value isn't numeric.
- Dependency bumps: `beamlab_countries` 1.0.8 → 1.1.0,
  `beamlab_ex_aws_sqs` 4.0.0 → 4.1.0.

## 1.7.200 - 2026-07-17

### Added
- Media thumbnails (browser grid/list/stacks, gallery, both media-selector
  pickers) now render a file's saved rotation as a CSS transform, matching
  what the popup viewer's canvas shows — no re-encode needed, and baked
  annotated thumbnails stay untouched on disk.
- The media browser's "⋯" overflow menu now also lists Add Media, Cancel
  upload, and Search, so every page action is reachable from one place even
  when the toolbar wraps tight.
- 4 strings (`Failed to save rotation`, `Hide details`, `Rotation saved`,
  `Show details`) translated to et/ru.

### Fixed
- A file's rotation or rebaked annotated thumbnail is now reflected in a
  collapsed stack's pile preview — previously only the grid and open
  viewer picked up the live refresh, leaving the pile stuck on the stale
  thumbnail.
- Clicking a file inside an expanded stack now opens the popup viewer
  (previously a silent no-op, since the lookup only searched the current
  page's file list, not the stack's own); the viewer's prev/next now steps
  through the correct sibling list in both stacked and flat views.
- Select-mode toolbar's exit button now reads "Cancel" instead of "Done" —
  it exits without applying anything, so "Done" read like a confirm it
  never was.

## 1.7.199 - 2026-07-17

### Added
- `MultilangForm.mount_multilang/2` now auto-attaches a `:handle_event`
  hook that intercepts the `"switch_language"` event pushed by
  `<.multilang_tabs>` — consumers no longer need their own
  `handle_event("switch_language", …)` clause (forgetting it used to crash
  the LiveView on the first tab click). Opt out with
  `auto_switch_language: false` to handle the event manually.
- `SearchPicker` gains a `search_on_focus` attr (default `false`) that
  opens the dropdown on focus/click of an empty input — promotes the
  previously JS-only `data-search-on-focus` behavior to a documented,
  first-class attribute (the raw rest attr is still honored).
- Event-based `NavTabs` buttons now pulse (`animate-pulse`) while
  `phx-click-loading` is applied, giving instant feedback for a tab
  switch whose content needs a server round-trip.

### Fixed
- Closed a test-coverage gap on the new `mount_multilang/2`
  switch-language hook (and its `auto_switch_language: false` opt-out).

## 1.7.198 - 2026-07-16

### Added
- Live refresh for the `MediaBrowser` popup viewer: `ProcessFileJob` and
  `AnnotationThumbnailJob` now broadcast completion over PubSub
  (`Storage.subscribe_to_file_events/0`), so a just-uploaded file's
  dimensions/variants and a rebaked annotated thumbnail appear in an open
  browser/viewer without a manual reload. Thumbnail updates refresh the
  grid row only — an open annotator session is never remounted mid-edit.
- Collapsible info sidebar in the popup viewer (filename/Download/
  metadata/comments), toggled from a corner button and persisted per-user
  so it survives prev/next, reopen, and reload.
- Rotation-save confirmation: a transient status pill over the canvas
  confirms each persisted rotation (or surfaces a failure) — previously
  the write was invisible, indistinguishable from a view-only rotation.
- Admin-context `MediaBrowser` clicks now open the same in-place modal
  viewer as everyone else (previously they navigated straight to
  `/admin/media/:uuid`); the viewer sidebar gains an "Open details page"
  link to the full admin page instead.
- Folder view now scrolls as a single region — breadcrumbs, hero header,
  toolbar, and file grid scroll together instead of the grid owning its
  own nested scrollport — fixing the list view's sticky column header not
  pinning correctly against the real scroll area.
- Bumped `etcher` to 0.8.0, `fresco` to 0.9.0, `tessera` to 0.3.3.

### Fixed
- `MarkdownEditor`'s unsaved-changes navigation guard is now opt-in
  (`protect_navigation={true}`), off by default. The old `true` default
  never actually armed the guard — a boolean renders as a bare HEEx
  attribute, which failed the JS hook's `=== "true"` string check — so
  this makes the previously-inert behavior deliberate, and hosts that
  pass `protect_navigation={true}` now get a real (working) guard.

## 1.7.197 - 2026-07-16

### Added
- V151: `supplier_source` (`crm_company | crm_contact | local`, CHECK-backed)
  and `is_primary` (partial-unique, one primary per item) columns on
  `phoenix_kit_cat_item_supplier_info` — completes the V149 junction for the
  merged `phoenix_kit_catalogue` sourcing layer, which reads/writes both on
  every insert/update.
- V151: normalizes `phoenix_kit_crm_contacts.email` /
  `phoenix_kit_crm_companies.email` to `citext`, a prerequisite for
  case-insensitive email matching in the CRM v2 backfill and the
  user↔contact bridge.
- `mix phoenix_kit.doctor` gains three checks: **Schema Drift** (a version
  marker claiming a column that's actually missing at the resolved prefix —
  surfaces an installer/migration-runner drift with no other self-service
  signal), **Child Start Order** (reads the host `application.ex` and fails
  when `PhoenixKit.Supervisor`/`Oban` are listed before the Repo, the boot
  crash class where Oban opens a pool against a database connection that
  doesn't exist yet), and prefix resolution now goes through the same
  `PrefixConfig.resolve_prefix/1` as `phoenix_kit.update --status`, fixing
  doctor reporting "not installed" against a prefixed install it was
  actually diagnosing at the wrong schema.

### Fixed
- Closed an `HtmlSanitizer` stored-XSS bypass: the `href`/`src` scheme
  filter only blacklisted literal `javascript:`/`vbscript:`/`data:`, so
  entity-encoded (`jav&#x61;script:`), whitespace-obfuscated
  (`java&Tab;script:`), and raw-control-char variants slipped through into
  any markdown-rendered rich-text sink. Replaced it with an allowlist
  (`http`/`https`/`mailto`/`tel` + relative/fragment URLs) evaluated over a
  decoded, control-char-stripped, normalized value — the transform only
  ever removes an attribute, never rewrites the visible URL.
- Fixed the admin sidebar's width flipping by ~15px around a modal's
  scroll-lock on long admin pages (the drawer grid's auto-sized sidebar
  column resolves differently depending on whether the page root currently
  has a scrollbar).
- `phoenix_kit.doctor`'s Oban Configuration check reported `0 queues, 0
  plugins` because doctor's own pool-capping zeroed the app-env Oban config
  before the check read it; now snapshotted before capping.
- Silenced a dialyzer false positive (`call_without_opaque`) in
  `QrLogin.location_for/1`'s `Task.Supervisor.async_nolink` +
  `Task.yield`/`Task.shutdown` idiom, matching the existing `auth.ex`
  ignore-list precedent for the same opaque-widening class.

## 1.7.196 - 2026-07-15

### Added
- OpenRouter and xAI now declare the `:image_generation` capability (OpenAI
  already did). Both genuinely have real image-gen models (OpenRouter's
  catalog includes Gemini image/GPT-image-1 style entries; xAI has
  `grok-imagine-image[-quality]`) reachable at the standard
  `/images/generations` path — gates `phoenix_kit_ai`'s new "Image
  Generation" Endpoint model type to providers that can actually serve it.

## 1.7.195 - 2026-07-14

### Added
- V150: nullable `browser`/`os` columns on `phoenix_kit_users_tokens`,
  parsed from the User-Agent at login. Session device names ("Safari on
  iOS") are now available for every session, independent of the
  `new_login_alert_enabled` setting — previously the name only came from
  `known_devices`, which that setting gates. The self-service Active
  Sessions list and the admin all-sessions page (new Device column) both
  use it, falling back to a known-device row for pre-V150 sessions.
- `Sessions.get_session_stats/0` gains `by_os`/`by_browser` breakdowns of
  active sessions (most-common first), rendered as two cards on the admin
  sessions page.
- The user-facing "Active today"/"Active yesterday" session labels now
  include the precise sign-in time ("Active today at 14:32").

### Fixed
- Admin Dashboard LiveView subscribed to the sessions PubSub topic but had
  no `handle_info` clause for `{:session_created, ...}`,
  `{:session_revoked, ...}`, or `{:user_sessions_revoked, ...}` — an
  unmatched message crashed and reconnected the LiveView. Now refreshes
  the session-stats tiles on each.
- `mix gettext.extract --merge` fuzzy-matched several of the above's new
  strings against unrelated old strings in the `ru`/`et` locales (e.g.
  "Device" landed as "Service", "By browser" as "browser tab", and the new
  `%{time}` interpolation was dropped from "Active today/yesterday").
  Corrected all affected `ru`/`et` translations to keep both locales fully
  translated, per project convention.

## 1.7.194 - 2026-07-14

### Added
- xAI provider now declares the `:realtime_voice` capability (in addition
  to `:ai_completions`), gating `phoenix_kit_ai`'s new streaming-voice
  Playground panel (built on the `xai` Hex package's `Xai.Realtime`
  WebSocket client) to xAI endpoints only.

## 1.7.193 - 2026-07-14

### Added
- V148: `phoenix_kit_crm_party_roles` table for the `phoenix_kit_crm`
  module — a polymorphic role edge marking an existing CRM company or
  contact as `supplier`, `client`, or another commercial counterparty role
  (a party can hold several roles at once). No FK on the polymorphic
  `(roleable_type, roleable_uuid)` pair; `valid_from`/`valid_to` lifecycle,
  `is_active` filter, role-scoped `metadata`.

### Fixed
- V148's `uuid` column `DEFAULT` now schema-qualifies `uuid_generate_v7()`
  with the install prefix (matching V138/V144) — the unqualified call
  would have resolved via `search_path` and failed on named-schema
  installs.

## 1.7.192 - 2026-07-14

### Added
- **Self-service Active Sessions** — a `:sessions` section in
  `UserSettings` lists a user's live sessions (device, location, last
  active), flags the current one, and lets them revoke a single session or
  all other sessions. Sessions are enriched from `KnownDevice` history;
  degrades gracefully (no browser/OS/location) for sessions predating
  device fingerprinting.
- **QR sign-in remember-me and return-to** — the desktop QR sign-in page
  gained a "Keep me logged in" checkbox and now carries a sanitized
  `return_to` through the mint → approve → finish handoff, both wired into
  the existing `UserAuth.log_in_user/3` `remember_me`/`user_return_to`
  machinery.
- **In-app notification for new-device sign-ins** — `LoginAlerts` now
  raises a standalone `"security"`-type notification (new core
  notification type) alongside the existing email when a login is seen
  from an unrecognized device.
- V147: persists the resolved `"City, Country"` geo-location on
  `phoenix_kit_user_known_devices` (nullable `location`) so Active
  Sessions doesn't need a live geo lookup per render.

### Fixed
- QR confirm screen no longer shows a bare "unknown" IP when
  `IpAddress.extract_from_socket/1` can't read peer data — treated as
  absent, same as a blank IP.
- The desktop QR page's connected mount no longer blocks showing the QR
  code behind a synchronous, up-to-~10s (two sequential providers × 5s
  each) geolocation lookup. `QrLogin.location_for/1` now bounds the lookup
  to 1.5s via an unlinked, supervised `Task` — a slow/unreachable geo API
  degrades to "no location" instead of stalling the page whose only job is
  showing the code quickly.
- Corrected Russian/Estonian translations for the new session-management
  strings introduced above, including an inverted `"Sign out"` →
  `"Войти"`/`"Logi sisse"` ("Log in") that `mix gettext.merge` fuzzy-matched
  against unrelated existing entries and left uncorrected.

## 1.7.191 - 2026-07-13

### Added
- **xAI as a built-in integration provider** — `:api_key` auth, Grok models
  via the OpenAI-compatible `https://api.x.ai/v1` API. Declares
  `:ai_completions`, so it surfaces automatically in `phoenix_kit_ai`'s
  endpoint picker with no changes needed there (provider discovery has been
  fully registry-driven since 0.9.0). *Test Connection* validates against
  `GET /v1/models` — confirmed live (401 without a key) even though the
  endpoint isn't listed on xAI's published API reference.

## 1.7.190 - 2026-07-13

### Security
- **Integration credentials (AWS SES, SMTP, Brevo API keys, etc.) were
  silently stored in plaintext on real host apps.** `encryption_key/0`
  only read the flat `config :phoenix_kit, secret_key_base:` — a key the
  installer never sets — so encryption was effectively always disabled
  outside of manual, undocumented setup. Now falls back to the host app's
  own Phoenix Endpoint `secret_key_base` (which every Phoenix app has),
  keeping the flat key's precedence so any install that *did* set it
  derives an identical key. Pre-existing plaintext values still read back
  correctly and are transparently re-encrypted on next save. `password`
  fields (SMTP) now encrypt too. The KDF is also correctly documented now
  (a single SHA-256, not PBKDF2 as previously claimed).

### Added
- **Integrations-backed email sending foundation** ("Phase 1" of a
  multi-repo newsletters effort — `phoenix_kit_emails` and
  `phoenix_kit_newsletters` both depend on this release). Adds
  `PhoenixKit.Mailer.deliver_via_integration/3`, which sends through any
  configured `PhoenixKit.Integrations` connection instead of only the
  host's static mailer adapter: `aws_ses` (key/secret), a new universal
  `smtp` provider (one named connection per vendor — Brevo, Mailgun,
  SendGrid, a self-hosted relay, etc.), and `brevo_api` (with a real
  *Test Connection* check against Brevo's account endpoint). SMTP
  transport correctly selects implicit TLS (`ssl: true`) on port 465 vs.
  mandatory STARTTLS elsewhere when credentials are present, failing
  closed rather than risking a plaintext credential leak. Recipients
  blocklisted by the optional `phoenix_kit_emails` package (hard bounces,
  complaints, manual blocks) are now refused before delivery on **every**
  outbound path, not just newsletters — auth mail included. New migration
  V145 adds `phoenix_kit_newsletters_send_profiles` (named send
  configurations, at most one default, partial-unique-indexed) and
  `phoenix_kit_newsletters_broadcasts.send_profile_uuid`.
- **New-login security alerts** ("We noticed a new login to your
  account", the same pattern GitHub/xAI/etc. use). Every login path
  (password, magic link, OAuth, QR) now checks the login's device
  (IP + hashed user-agent) against history for that user; an unrecognized
  device is emailed and logged as `user.new_login_detected`, a recognized
  one is silent. Off by default — enable at Admin → Settings →
  Authorization → "Login Notifications". New migration V143 adds
  `phoenix_kit_user_known_devices`.
- **Manufacturing/warehouse module tables consolidated into core.** Moves
  `phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
  `phoenix_kit_machine_operations`, `phoenix_kit_warehouse_transfers`, and
  `phoenix_kit_warehouse_min_stock` out of the `phoenix_kit_manufacturing`/
  `phoenix_kit_warehouse` packages' own migrations and into core's single
  numbered chain (V144), matching the precedent already set for locations
  and other warehouse tables. Upgrade-safe for hosts on published
  `phoenix_kit_manufacturing` 0.2.0.

### Changed
- **Dropped `Jason` in favor of Elixir's built-in `JSON` module (1.18+)**
  everywhere in phoenix_kit's own code — no behavior change; `jason`
  itself stays in the dependency tree (`ecto`, `phoenix`, `ex_aws`, and
  others still require it transitively).
- **`ex_aws_sqs` replaced with the maintained
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs)
  fork.** Unblocks Hex publishing itself: upstream `ex_aws_sqs` (archived,
  last released January 2023) pins `hackney ~> 1.9`, which cannot coexist
  with the `hackney ~> 4.0` upgrade below without an `override: true` —
  and Hex refuses to publish any package depending on one. The fork
  declares no hackney dependency at all. SQS now speaks AWS's JSON
  protocol instead of the legacy XML protocol (response shapes changed
  accordingly in `PhoenixKit.AWS.InfrastructureSetup`); fixed a related
  latent bug surfaced by the switch — the "queue already exists" fallback
  checked for AWS error code `QueueAlreadyExists`, but the real SQS API
  error is `QueueNameExists`.
- Ported the multi-session "Accounts" switcher (add/switch/remove
  account, "log out from all accounts") into
  `UserDashboardNav.user_dropdown/1` — previously only the admin top-bar
  dropdown had it, so host apps rendering their own layout via
  `user_dropdown/1` had no multi-session UI at all.

## 1.7.189 - 2026-07-12

### Added
- **QR device-handoff login ("scan to sign in").** A signed-out browser at
  `/users/qr-login` shows a QR code; an already-signed-in phone scans it
  (native camera, no app needed), reviews the requesting device
  (browser/OS/IP), and taps Approve — the desktop signs in with no
  password. Approval always happens on the trusted phone; the desktop
  receives nothing until the phone approves. Built on the new
  [`keyfob`](https://hex.pm/packages/keyfob) library. Off by default —
  enable at Admin → Settings → Authorization → "Enable QR code sign-in".
  Post-merge hardening: the `qr_login_enabled` setting is now enforced as
  an immediate kill switch on the phone-approval and completion paths (not
  just the desktop entry point), and request creation is rate-limited per
  IP (`PhoenixKit.Users.RateLimiter.check_qr_login_rate_limit/1`) to guard
  the public, pre-auth mint endpoint against ETS-table exhaustion.

### Fixed
- **Prefix hardening for low-privilege multi-schema installs**, driven by
  a field report from a hardened install (DBA-pre-created schema, no
  database-level CREATE, PG15+ non-writable `public`, PgBouncer):
  `CREATE EXTENSION`/`CREATE SCHEMA` now check `pg_extension`/
  `information_schema.schemata` before attempting creation (Postgres
  checks the CREATE privilege *before* the IF-NOT-EXISTS short-circuit,
  failing low-privilege roles even when the object already exists); V27
  now threads `create_schema: false` through to Oban's migration so it
  can't re-default to `true` and execute a failing `CREATE SCHEMA`
  mid-chain; `uuid_generate_v7()` is now created inside the install's
  schema (not wherever `search_path` happens to point) with all ~89 call
  sites schema-qualified, including the pgcrypto `gen_random_bytes` call
  inside the function body; the prefix is validated at every entry point.
  New runtime `PhoenixKit.SchemaPrefix` (all 21 table-backed schemas
  adopt it) means prefixed installs no longer depend on the DB role's
  `search_path` for ordinary queries. Install/update/status/gen.migration
  tooling now persists and resolves `--prefix` correctly, distinguishes an
  unreachable database from a genuinely absent install, and warns when an
  existing host Oban config lacks the install's prefix.
  Post-merge: fixed a matching unqualified-call bug the same PR's own
  sweep missed — V26's pgcrypto `digest()` backfill call was still bare
  (same failure mode as the pre-fix `uuid_generate_v7()`, now qualified
  via the new `Helpers.pgcrypto_call/1`) — and fixed the new Oban
  prefix-detection regex to skip commented-out config blocks (it could
  both false-positive on a commented example block and false-negative
  when a commented block happened to mention `prefix:`, masking a
  genuinely unprefixed active block).
- **daisyUI modal scrollbar-gutter compensations removed.** Fixes a
  reported "clicked cancel and a scroll bar showed up" bug on scrolling
  pages: daisyUI ≥ 5.1's own conditional gutter reservation handles both
  scrolling and non-scrolling pages correctly on its own, so core's
  1.7.179 counter-rules and PkDialog's inline override were fighting it
  and causing the reflow. `PhoenixKit.Install.DaisyUI` now declares a
  designed-for minimum (5.6.0) and warns hosts on an older vendored
  daisyUI via `phoenix_kit.install`/`.update`/`.doctor` — advisory only,
  nothing touches host files.
- **The 1.7.188 hackney 4.x upgrade made this package un-publishable**,
  discovered while cutting this release: `mix hex.publish` refuses to
  build any package carrying an `override: true` dependency, which
  `mix.exs` needed because `ex_aws_sqs` (last released Jan 2023, since
  archived upstream) pins `hackney ~> 1.9` — incompatible with `~> 4.0`
  with no override. Switched the SQS dependency to
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs), a
  maintained fork with the same public API (`ExAws.SQS`) that declares no
  hackney dependency at all, clearing the conflict — `override: true` on
  both hackney and httpoison is gone, and the now-fully-unused
  `httpoison` dependency itself is dropped. The fork also switches SQS
  from the legacy Query/XML protocol to AWS's JSON protocol, which
  changes response shapes (raw `%{"QueueUrl" => ...}` instead of
  `%{body: %{queue_url: ...}}`); `PhoenixKit.AWS.InfrastructureSetup`
  (SQS/DLQ provisioning) is updated accordingly, including a latent bug
  this surfaced — the "queue already exists" fallback path was checking
  for AWS error code `QueueAlreadyExists`, but the real SQS API error is
  `QueueNameExists` (confirmed against `botocore`'s service definition),
  so idempotent re-runs of setup against a differently-configured
  existing queue likely never hit the intended fallback under the old
  protocol either.

## 1.7.188 - 2026-07-12

### Security
- **hackney upgraded 1.25.0 → 4.5.2 and httpoison upgraded 2.3.0 → 3.0.0,
  clearing all 4 hackney CVEs accepted in 1.7.178 (1 HIGH: `ssl:connect/2`
  post-handshake TLS upgrade with no timeout; 2 moderate CR/LF-injection /
  SSRF-bypass; 1 low CRLF injection).** Both are now pinned via `override:
  true` in `mix.exs`, since two stale transitive constraints still declared
  the old majors: `ex_aws_sqs` (last released 2023) pins `hackney ~> 1.9`,
  and `ueberauth_apple` (last released 2023, now removed — see below) pinned
  `httpoison ~> 1.0 or ~> 2.0`. Verified safe to override: `ex_aws_sqs`
  never calls hackney directly (the pin is vestigial, only listed for its
  own `:test` env); `ex_aws` itself already relaxed to `hackney ~> 4.0,
  optional: true` as of 2.7.0 (our lock was just stale at 2.6.1); hackney
  4.0's release notes confirm the public `hackney:request/5` API is
  unchanged from 1.x (the major bump split HTTP/2 and HTTP/3 into separate
  libraries, `h2` and `quic`, and replaced the built-in metrics subsystem
  with a middleware chain); every real hackney consumer in the tree
  (`ex_aws`, `tesla`, `swoosh`) only touches that stable surface. Full
  investigation: `dev_docs/audits/2026-07-12-hackney-upgrade-resolution.md`
  (supersedes `2026-07-07-hackney-cve-2026-advisories-audit.md`).

### Removed
- **BREAKING: Apple Sign-In removed** (`ueberauth_apple` dependency
  dropped, along with its Settings UI, credential storage, and login/admin
  buttons). `ueberauth_apple` has been unmaintained since its 0.6.1 release
  in 2023 and was the sole reason httpoison — and therefore hackney — could
  not move past the versions above. Hosts with Apple Sign-In configured
  will see the "Apple Sign-In" toggle and credential fields disappear from
  Settings → Authorization; any users who previously linked an Apple
  account keep that link (existing `phoenix_kit_user_oauth_providers` rows
  are untouched and still shown/manageable in account settings), but new
  Apple sign-ins are no longer offered. Plan is to reintroduce this via a
  maintained fork of `ueberauth_apple` in a future release.

## 1.7.187 - 2026-07-12

### Fixed
- **`data-confirm` was silently swallowed on `BulkSelectScope` action buttons.**
  The hook's `_onActionClick` calls `e.preventDefault()` synchronously on
  every `data-bulk-action` click; `phoenix_html`'s own window-level click
  listener (which implements `data-confirm`) bails out early via `if
  (e.defaultPrevented) return;`, so its confirm dialog never fired. Any
  button carrying both `data-confirm` and `data-bulk-action` — most notably
  bulk/permanent delete — executed with no prompt. The hook now checks
  `data-confirm` itself and calls `window.confirm()` before proceeding,
  mirroring `phoenix_html`'s native behavior; cancelling stops the click
  and the LiveView event is never pushed. Found while migrating
  `phoenix_kit_comments`, `phoenix_kit_posts`, and `phoenix_kit_entities` to
  BulkSelect — all three already pair `data-confirm` with a destructive
  bulk action and are fixed retroactively once they pick up this release.

## 1.7.186 - 2026-07-12

### Fixed
- **The 1.7.185 `phoenix_kit.js` self-heal never ran on hosts whose
  `mix.exs` was missing the `:phoenix_kit_js_sources` compiler — exactly the
  older installs that need it most.** Root cause (found by a downstream
  agent bisecting a host stuck on stale JS after upgrading): registering
  `:phoenix_kit_css_sources` and `:phoenix_kit_js_sources` was two SEPARATE
  `Igniter.Project.MixProject.update/4` calls against the same `mix.exs`
  `:compilers` key. The first call, hitting an absent key, has to insert
  `[atom] ++ Mix.compilers()` — a `++` call, not a literal list, since
  `Mix.compilers()` is a live call that can't be flattened at install time.
  The second call then lands on that `++` node instead of a list, and
  `Igniter.Code.List.prepend_new_to_list/2` (which only understands literal
  lists) silently fails into a `{:warning, ...}` easy to miss in the wall of
  `mix phoenix_kit.update`/`install` output — so the second compiler never
  actually got registered even though the run reported success. This is
  exactly what happened in production: a host had `:phoenix_kit_css_sources`
  from the first call but never `:phoenix_kit_js_sources` from the second,
  across many `phoenix_kit.update` runs, so the JS-hooks compiler (and
  therefore 1.7.185's vendoring fix) never ran.
  `PhoenixKit.Install.Common.ensure_compilers_registered/2` now registers
  every PhoenixKit compiler in ONE call — used by both `mix
  phoenix_kit.install` and `mix phoenix_kit.update` — and, for hosts already
  stuck in the broken `[atom] ++ Mix.compilers()` shape, descends into the
  literal list on the left of `++` and repairs it there instead of bailing.
  Covered by a regression test that reproduces the exact broken shape and
  asserts both compilers end up present, not just the notice claiming they
  do.

## 1.7.185 - 2026-07-11

### Fixed
- **`phoenix_kit.js` (core JS hooks — `RowMenu`, drawer/modal toggles, etc.)
  could silently 404 in production, breaking every PhoenixKit JS hook with no
  error anywhere.** It was only ever copied into a host's
  `priv/static/assets/vendor/` by the one-shot `File.cp/2` in `mix
  phoenix_kit.install`/`mix phoenix_kit.update` — a deploy that does `rm -rf
  priv/static` + asset rebuild without re-running `phoenix_kit.update` (true
  of most CI/CD pipelines) shipped the stale or missing file, so a bug fix
  landing in this same JS file could ship correctly in every other respect
  (compiled `.ex`/`.heex` changes apply the moment the dependency bumps) while
  the JS fix itself never reached the browser. The `:phoenix_kit_js_sources`
  compiler — which already regenerated `phoenix_kit_modules.js` (the
  external-module hook bundle) on every `mix compile` — now also vendors
  `phoenix_kit.js` itself the same way: self-healing after any `priv/static`
  wipe, with zero dependency on `phoenix_kit.update` ever running again after
  the initial install.
- **`JsIntegration.update_js_file/0` swallowed copy failures** (`rescue` →
  `Logger.warning` → `{:error, reason}` that its one caller, `mix
  phoenix_kit.update`, never checked) — `mix phoenix_kit.update` could report
  success while the vendored file silently stayed stale or absent. Now raises
  (`Mix.raise/1`) on a resolution/copy failure and verifies the destination
  file exists and is non-empty as a post-condition. `mix
  phoenix_kit.assets.rebuild` — billed as *the* asset-rebuild task — now also
  refreshes `phoenix_kit.js` via the same path, not just the CSS pipeline.

## 1.7.184 - 2026-07-11

### Added
- **`Checkbox` core component extended** (`PhoenixKitWeb.Components.Core.Checkbox`):
  `disabled` (previously silently dropped — not in the allowed globals),
  `wrapper_class` (styles the wrapping `<label>` — spacing, or
  `pointer-events-none` to lock a checkbox *without* excluding it from form
  submission the way `disabled` would), `title` (tooltip on the whole label,
  not just the box), and a `:description` slot for secondary helper text. The
  default slot now doubles as rich label content (badges, icons, conditional
  markup) overriding the plain `label` string when given.
- **`LayoutWrapper.app_layout` gains `page_section`/`page_section_path`** —
  an optional breadcrumb segment between "Admin Panel" and `page_title` (e.g.
  "Admin Panel / Users / Jane Doe" on a user detail page instead of jumping
  straight from "Admin Panel" to the user's name).

### Changed
- **Checkboxes across core migrated to `<.checkbox>`** (settings pages,
  registration/OAuth toggles, storage bucket/dimension forms, org tax
  toggle, `user_form`'s boolean custom field) so future daisyUI syntax or
  style changes are a one-file edit instead of a repo-wide sweep. Left
  hand-rolled where the shape doesn't fit a boolean toggle (role-assignment
  checkboxes and the image-format multi-select use `value={item}` collected
  via `Map.values/1`, not the hidden-false/checkbox-true pattern).
- **Users list/detail naming unified.** The admin page title now reads
  `@page_title` ("Users") instead of a hardcoded "User Management" that had
  drifted out of sync with it; the sidebar subtab is "Users" instead of
  "Manage Users".
- **User detail page now offers the same actions as the Users list's `⋮`
  menu** — Roles, Confirm/Unconfirm email, Activate/Deactivate, and (for your
  own profile) Settings, via the same `table_row_menu` component and
  `Auth`/`Roles` context calls. Delete is now hidden (not just rejected on
  click) when `Auth.can_delete_user?/2` says no, matching the list.
- **Users list's Location column explains itself when empty.** If
  `track_registration_geolocation` is off, every row now says "Tracking
  disabled" with a link to Settings → Users, instead of an unexplained
  per-row "No data" that looked like missing data rather than a disabled
  feature.

### Fixed
- **Row-action `⋮` menus could silently eat clicks on menu items (WebKit —
  i.e. every browser on iOS/iPadOS, plus desktop Safari).** The `RowMenu` JS
  hook portals its floating menu to `<body>` while open so it can escape a
  clipped table container; its "click outside closes the menu" listener only
  checked containment against the trigger's wrapper, not the (now
  elsewhere-in-the-DOM) menu itself. Clicking a menu item was treated as an
  outside click: the capture-phase listener closed and relocated the menu
  mid-dispatch, and WebKit drops an in-flight click when its target moves
  during capture — so the tapped action never ran. Fixed by also checking
  containment against the portaled menu.
- **Checkboxes with hidden-false-fallback markup weren't wrapped in a
  `<label>`** across settings pages (registration, notifications,
  multi-session, magic link, OAuth master/provider switches, storage bucket
  enable, org tax enable), so clicking the adjacent text did nothing —
  only the checkbox square itself was clickable. For the OAuth provider
  switches specifically (locked via `pointer-events-none` while the master
  switch is off), the lock moved from the checkbox to the wrapping label so
  wrapping it in `<label>` couldn't let a text click bypass the lock.

## 1.7.183 - 2026-07-11

### Fixed
- **Prefixed (`--prefix`) installs could fail to migrate.** `CREATE INDEX` was
  being called with a schema-qualified index name (`CREATE INDEX prefix.name ON
  ...`), which Postgres rejects outright — an index always lands in its table's
  schema, so only the table reference may be qualified. Affected
  `add_uuid_unique_indexes`/`drop_uuid_unique_indexes` (`uuid_fk_columns.ex`),
  `V56`, `V57`, and `V95`'s media-folder unique index. (#628)
- **Cross-schema false-positive existence checks on prefixed installs.** Several
  idempotency guards (`pg_constraint` lookups in `V35`, `V102`, `V113`, `V115`,
  `V118`, `V119`; an `information_schema.columns` lookup in `V95`) matched on
  constraint/column name alone, so an identically-named constraint or column
  already present in a *different* schema's table made the guard think it existed
  in the current schema too — silently skipping the `ADD CONSTRAINT`/`ADD COLUMN`.
  Fixed by anchoring each check to the target relation (`conrelid = '<prefix>.
  <table>'::regclass` / `table_schema = '<prefix>'`). Added an integration test
  that runs the full versioned migration chain into a named schema and asserts
  every index and column lands correctly. (#628)

## 1.7.182 - 2026-07-10

### Added
- **Fine-grained sub-permissions.** Modules can declare additive permissions under
  their base key via the optional `sub_permissions` field of `permission_metadata/0`
  (e.g. `"calendar.view_others"`), stored in `phoenix_kit_role_permissions.module_key`
  as composed dotted keys. A sub-permission implies its base: granting a sub
  auto-grants the base, revoking the base cascades its subs off, and every write
  path (`grant_permission/3`, `revoke_permission/3`, `set_permissions/3`) normalizes
  the set so no orphan sub-key row can persist. Modules check sub-grants with
  `Scope.can?/2` (key held **and** module enabled). The permission matrix renders
  subs as indented rows under their module. (#627)
- **`V141` — personal calendar events + participants** for the standalone
  `phoenix_kit_calendar` module: `phoenix_kit_calendar_events` (one implicit
  personal calendar per user, timed/all-day exclusive-end pairs with a CHECK,
  cascade on user delete, loose `location_uuid` link) and
  `phoenix_kit_calendar_event_participants` (loose `kind`/`target_uuid` refs with a
  snapshotted `display_name`, visibility resolved live against staff/CRM tables). (#627)
- **Reusable core UI components.** `SearchPicker` (client-instant typeahead with
  browse-on-focus, per-instance event scoping, `direction=up`, cross-source dedup,
  load-more paging), `PopoverPanel` (anchored rich-content popover, client-side
  open/close with click-away), and the `PkDialogDraft` JS hook (preserves an open
  form's draft across a LiveView reconnect). Both function components are imported
  into `PhoenixKitWeb`. (#627)

### Changed
- **Admin is now genuinely permission-gated.** Only `Owner` is hard-coded as
  all-access; `Admin` (and every other role) is governed by the permission matrix.
  Admin defaults to all keys via seeding/auto-grant, and a boot-time Task
  (`auto_grant_new_keys_to_admin/0`) fills newly-installed module keys — but an
  Owner's revocation now sticks everywhere, including fresh mounts (previously the
  system-role bypass ignored revocations on fresh mounts). The full-access fallback
  keys on **table presence** (`permissions_table_ready?/0`), not row count, so
  stripping a role bare can no longer restore access, and a DB blip fails closed. (#627)
- **`V142`** widens `phoenix_kit_role_permissions.module_key` `VARCHAR(50) → VARCHAR(120)`
  so composed sub-permission keys fit. (#627)
- **Role changes are authorized in the context.** `sync_user_roles/3` takes an
  `:actor` and drops changes the actor isn't allowed to make (a non-Owner can't
  grant or strip Owner/Admin); the last Owner can never be removed. The quick
  role-toggle and the permission-matrix revoke route through the same guards. The
  function now returns `{:ok, %{assignments, roles_before, roles_after}}` so audit
  logs record the delta **actually applied**, not the submitted set. (#627)
- **`Checkbox` `checked` default is now `nil`** ("derive from the field's value") —
  a non-nil attr default defeated the field clause's `assign_new`, so a field-bound
  checkbox always rendered unchecked. (#627)
- **`AdminPageHeader` accepts a `class`** to override its default bottom margin
  (e.g. `"mb-0"` when the page owns spacing). (#627)

### Fixed
- **Role/permission mutations are race-free under concurrent admins.**
  Transaction-scoped Postgres advisory locks + in-transaction re-reads: the last
  Owner can never reach zero (shared lock at `count_remaining_owners`), the matrix
  revoke re-reads the role's held keys under a `(role, base)` lock and rejects
  (`:unauthorized`) if a cascaded sub falls outside the actor's grantable set, and
  `set_permissions/3` locks the `Role` row so two concurrent calls can't leave the
  union of disjoint desired sets. (#627)
- **Post-merge review:** refactored `grant_permission/3` to satisfy
  `credo --strict` (removed a redundant `with` clause and one nesting level) — the
  base-then-sub cascade and rollback behavior are unchanged. (#627)

## 1.7.181 - 2026-07-10

### Changed
- **Admin settings pages modernized.** Replaced ad-hoc `<div class="divider">`
  headings across the General, Authorization, Users, Media, and Instance
  Dimensions pages with a reusable `<.section_header>` (icon + uppercase title +
  rule + optional actions slot). Per-field status echoes ("Selected: X | Saved:
  Y", always visible) are replaced by `<.unsaved_hint>`, which renders only when a
  field diverges from its saved value, so clean fields carry no noise. The four
  hand-copied ~95-line OAuth provider guides (Google/Apple/GitHub/Facebook)
  collapse into one `<.oauth_setup_instructions>` component with a `:steps` slot.
  Both new components live in `Components.Core.FormSection`. (#626)
- **Browser Tab identity group + live preview.** The site-icon and default-tab-
  title fields are merged into one "Browser Tab" group on the General page, with a
  live browser-chrome preview (icon + tab title + address bar) that updates as you
  type. The site icon and project logo now default to each other via
  `Settings.get_site_icon_uuid/0` and `get_logo_uuid/0` — setting either brands
  both the browser tab and the app chrome; the favicon and layout wrappers read
  through these resolvers. (#626)
- **Destructive resets now confirm.** The General "Reset ALL settings" and Instance
  Dimensions "Reset to Defaults" actions gained a `data-confirm` guard. (#626)
- **Dependency bump.** `saxy` 1.6.0 → 1.6.1.

### Fixed
- **Registration dirty-indicator missed two toggles.** The Users-page unsaved-
  changes hint for the registration group compared only `allow_registration` and
  `track_registration_geolocation`, so flipping `registration_show_username` or
  `enable_organization_accounts` left the group looking clean. It now checks all
  four keys. (#626)

### i18n
- **Storage-module flashes and page titles localized.** Every `put_flash` in the
  Media settings and Instance Dimensions LiveViews (bucket toggles, redundancy,
  variants, repair, dimension CRUD/reset) is wrapped in `gettext`/`ngettext` with
  proper `%{}` interpolation and correct pluralization for the redundancy-copies
  message. Full `.pot` re-extract with ru/et translations for all new strings.
  Also dropped a dead drag-drop `<script>`/`<style>` block from the Media settings
  template (targeted element ids that no longer exist). (#626)

## 1.7.180 - 2026-07-09

### Added
- **V140 migration: `phoenix_kit_warehouse` tables.** Creates the six tables backing
  the standalone `phoenix_kit_warehouse` package — `phoenix_kit_warehouse_stock`,
  `_inventory_documents`, `_internal_orders`, `_supplier_orders`, `_goods_receipts`,
  `_goods_issues`. Intra-module FKs are kept (`supplier_orders.internal_order_uuid` →
  `internal_orders`, `goods_receipts.supplier_order_uuid` → `supplier_orders`,
  `goods_issues.internal_order_uuid` → `internal_orders`), as is
  `performed_by_uuid` → `phoenix_kit_users`. The host-specific `sub_order_uuid` FK is
  replaced by a generic `source_refs` JSONB column resolved through a host-registered
  callback, so the package depends on no particular "order" concept. Tables ship
  empty — nothing reads or writes them yet. (#624)

### Fixed
- **V140 `quantity >= 0` check was silently skipped on non-`public` schemas.** The
  constraint-existence guard matched `pg_constraint.conname` alone, but constraint
  names are unique per `(schema, table)` — not globally. A second PhoenixKit install
  into another schema in the same database found the first schema's constraint, took
  the `IF NOT EXISTS` false branch, and created `phoenix_kit_warehouse_stock` with no
  non-negative-quantity check while reporting success. Now scoped with
  `AND conrelid = '<prefixed table>'::regclass`, matching V41/V72/V78.
  (post-merge review)
- **V140 `source_refs` reverse lookups were unindexed.** Dropping the indexed
  `sub_order_uuid` FK column in favour of JSONB removed the index behind "which
  documents reference this order?", turning it into a sequential scan. Added
  `USING GIN (source_refs)` on `internal_orders`, `supplier_orders`,
  `goods_receipts`, and `goods_issues`. (post-merge review)
- **V140 `phoenix_kit_warehouse_stock` could not be queried by location.** Its only
  index was `UNIQUE (item_uuid, location_uuid)`, which a composite btree cannot serve
  for a bare `WHERE location_uuid = $1` — the most natural query against a stock
  table, and one every other warehouse table already had an index for. Added
  `phoenix_kit_warehouse_stock_location_uuid_index`. (post-merge review)

### Changed
- **V140 moduledoc corrected.** It justified `item_uuid` / `location_uuid` /
  `storage_folder_uuid` / `supplier_uuid` as FK-less "cross-package references", but
  all four targets (`phoenix_kit_cat_items`, `phoenix_kit_locations`,
  `phoenix_kit_media_folders`, `phoenix_kit_cat_suppliers`) are created by this same
  core migration set — V122 already declares an FK on `location_uuid`. The doc now
  states the truth: an FK is possible, it is omitted pending a delete-semantics
  decision, and referential integrity for those columns is not enforced by the
  database. Also genericised the private downstream app's table names, which were
  rendering on hexdocs. (post-merge review)
- **Dependency bumps.** `ecto` 3.14.0 → 3.14.1, `postgrex` 0.22.2 → 0.22.3,
  `plug` 1.20.2 → 1.20.3, `mdex_native` 0.2.4 → 0.2.5.

## 1.7.179 - 2026-07-08

### Added
- **V139 migration: per-dashboard `config` column.** Adds a JSONB `config` column
  (`NOT NULL DEFAULT '{}'`) to `phoenix_kit_dashboards` for dashboard-level
  presentation state (layout mode, pixel-mode zoom, home tier, per-tier markers),
  read and written whole like `layout`. Idempotent (`ADD COLUMN IF NOT EXISTS`);
  unblocks the dashboards module's next Hex floor. (#623)
- **Installer wires a `viewport_width` LiveSocket connect param.**
  `mix phoenix_kit.install` / `mix phoenix_kit.update` now add
  `viewport_width: window.innerWidth` to the host's LiveSocket `params:` (rewritten
  into a closure so reconnects re-read the width). Responsive PhoenixKit LiveViews
  (e.g. the dashboards builder) use it to resolve the right layout tier server-side
  on the first render instead of a client-hook round-trip; everything degrades
  gracefully without it. The rewrite is deliberately conservative — it anchors on
  the real `new LiveSocket(` call, only patches a `params:` object at the options'
  top brace depth, blanks string literals and comments before depth counting, and
  refuses every ambiguous shape with a manual-instructions notice rather than risk
  corrupting host `app.js`. Pinned by 13 tests in `js_integration_test.exs`. (#623)

### Fixed
- **daisyUI 5.0.x modal scrollbar-gutter strip.** daisyUI 5.0.x reserves a scrollbar
  gutter while a modal/drawer is open and paints it with a base-100 trick that
  mismatches on non-base-100 pages, so classic-scrollbar users saw an uncovered strip
  at the window's right edge on every admin page. An unlayered
  `:root:has(.modal-open, …) { scrollbar-gutter: auto }` counter-rule in the admin
  `LayoutWrapper` and the core root layout beats the layered original regardless of
  stylesheet order. Documented trade-off: scrollable pages get a small reflow on
  modal open instead of the mispainted strip. Upstream fixed this properly in daisyUI
  5.1.0–5.6.x; an `AGENTS.md` TODO tracks removing the rule once hosts upgrade. (#623)

### Changed
- **Migration-history doc block tracks V139.** `Migrations.Postgres`'s version list
  now carries the `### V139` entry and the `⚡ LATEST` marker, which the merge left
  pointing at V138. (post-merge review)

## 1.7.178 - 2026-07-07

### Added
- **Extensible resource deep-links across the activity feed and notifications.**
  External modules can declare how their resource types link to their pages via the
  new optional `resource_links/0` `PhoenixKit.Module` callback — a
  `resource_type => resolver` map where a resolver is a module implementing
  `resolve_comment_resources/1`, a path-template string (`"/admin/widgets/:uuid"`),
  or a `%{"path" => ..., "title" => ...}` map. Merged into `PhoenixKit.ResourceLinks`
  with a documented precedence (resolver module → module template → host
  `comment_resource_paths` setting). (#621)
- **Integration activities deep-link to their Settings edit page.**
  `Integrations.log_activity` now stamps the connection's storage-row `resource_uuid`,
  and the new `PhoenixKit.Integrations.ResourceLinks` resolves `"integration"`
  resources to `/admin/settings/integrations/:uuid`, titled `provider / name`. (#621)
- **Actor and target identities are now clickable in the activity feed and the
  notifications admin list.** A lightweight `resource_email_link/1` component links
  the who-did-it / who-it's-for emails to those users' admin pages, falling back to
  plain text when unresolved. (#621)
- **"All notifications" overview on the Notifications admin page.** A paginated table
  (via `Notifications.admin_list/1`) shows every notification's recipient, rendered
  text, per-user seen/dismissed state, and date. (#621)

### Fixed
- **Jobs admin scheduled-jobs tab no longer crashes.** The template referenced
  `job.id` / `job.resource_id`, which do not exist on the
  `PhoenixKit.ScheduledJobs.ScheduledJob` schema (`@primary_key {:uuid, ...}`,
  `field :resource_uuid`) — every render raised `KeyError`. Now uses `job.uuid` /
  `job.resource_uuid`, consistent with the `repo.get(ScheduledJob, uuid)` lookup. (#622)
- **Notifications admin pagination no longer renders a runaway button list** for an
  out-of-range `?page=` query param. An explicit `//1` range step makes an
  out-of-range page yield an empty range instead of a descending one. (post-merge review)

### Security
- **hackney 1.25.0 advisory batch (EEF-CVE-2026-47069 / 47071 / 47075 / 47076)
  reviewed and accepted — no code change.** There is no fixed hackney 1.x; the fix
  lives only in hackney 4.x, which the dependency tree cannot reach while
  `ueberauth_apple` pins `httpoison < 3.0` (→ `hackney < 2.0`). Real-world exposure is
  low: hackney is only the default HTTP backend for `ex_aws` and the Apple-OAuth path
  (fixed endpoints, no SOCKS5, no user-controlled URLs/cookies/query strings). Full
  analysis and the eventual upgrade trigger:
  `dev_docs/audits/2026-07-07-hackney-cve-2026-advisories-audit.md`.

## 1.7.177 - 2026-07-07

### Changed
- **Auth form fields now render their leading icon *inside* the input.** The
  email/username/password/organization-name fields on the registration, login,
  and magic-link forms previously showed their icon in a separate label above
  the field; they now follow daisyUI 5's `<label class="input">` wrapper pattern
  so the icon sits inside the field border (text labels are retained above). The
  shared `PhoenixKitWeb.Components.Core.Input` `:icon` slot renders inside the
  field accordingly. The organization account-type `<select>`'s label icon was
  dropped for consistency (daisyUI has no icon-inside variant for selects).
- **Updated phoenix to 1.8.9, phoenix_live_view to 1.2.6, websock_adapter to
  0.6.0, and ex_ast to 0.12.9.**

### Fixed
- **The `auth_seo_no_index` regression test no longer raises at mount and breaks
  `mix test`.** Its stand-in `PublicHostAppLive` mounted through
  `:phoenix_kit_mount_current_scope`, whose `handle_params` hook needs a non-nil
  `socket.router` — which `live_isolated/3` never provides. The test now drives a
  routed, test-only LiveView (`PhoenixKitWeb.Test.PublicHostAppLive`, routed only
  under `Mix.env() == :test`) via a real HTTP request, and asserts against the
  actual rendered `noindex`/`nofollow` meta tags a crawler would see rather than
  the raw `:seo_no_index` assign. (#620)

## 1.7.176 - 2026-07-06

### Added
- **Activity feed entries now deep-link to the resource they acted on.** A new
  shared `PhoenixKit.ResourceLinks` resolver turns an entry's
  `(resource_type, resource_uuid)` into a navigable link to the underlying
  record, reusing the comments-moderation two-tier mechanism (auto-registered
  handler modules for `post`/`file`/`user`, then `comment_resource_paths` string
  templates). A core `<.resource_link>` chip renders the resolved title with a
  thumbnail or type icon on both the Activity index Subject cell and the detail
  page, falling back to the resolved user email and then a truncated uuid.
  Resolution is batched per resource type and fails open to the uuid fallback,
  so a missing or throwing handler never crashes the admin feed. (#619)
- **Image rotation in the media viewer is now persisted.** Rotating an image in
  the admin media viewer saves the angle to the file row's `metadata["rotation"]`
  and restores it on the next open, via fresco 0.8's opt-in `persist_rotation`
  server bridge. Every viewer (including public galleries) seeds the saved
  orientation on first paint, but only admin-context hosts — the `MediaBrowser`
  modal (gated on `@admin`) and the admin-only media-detail page — write back to
  the shared file row. (#618)

### Changed
- **Updated fresco to 0.8.0, etcher to 0.7.2, tessera to 0.3.2.** fresco 0.8's
  new `persist_rotation` bridge backs the media-viewer rotation persistence
  above.

## 1.7.175 - 2026-07-06

### Added
- **Sitemap settings page now exposes Router Discovery exclude patterns,
  protected pipelines, custom URLs, and static routes.** These four settings
  (`sitemap_router_discovery_exclude_patterns`, `sitemap_protected_pipelines`,
  `sitemap_custom_urls`, `sitemap_static_routes`) previously had no admin UI —
  changing them required editing the database directly. They're now editable
  from a new "Advanced" section on `/admin/settings/sitemap`, with the
  exclude-patterns field validated against `Regex.compile/1` before saving
  (an invalid pattern is rejected with an inline error instead of being
  silently dropped later) and pipeline names restricted to identifier-safe
  characters.
- **Sitemap sources can now declare their own settings via
  `PhoenixKit.Modules.Sitemap.Sources.Source.sitemap_settings_schema/0`.**
  This new optional callback lets a source module (built-in or contributed by
  another package, e.g. an Entities module) describe boolean/string/integer
  settings with a label, help text, and default; the sitemap settings page
  discovers and renders them automatically, reading/writing through
  `PhoenixKit.Settings` the same way built-in settings work. No core source
  implements it yet — this is purely an extension point for
  settings that don't already have a home in the core UI.

### Fixed
- **Toggling a source-contributed boolean setting no longer crashes the sitemap
  settings page when the field declares a non-boolean default.** The extension
  toggle handler now reads the current value through the same rescue-protected
  path the render uses, so a source that declares `%{type: :boolean, default: nil}`
  (allowed by the `term()` default type) can't raise `FunctionClauseError` from
  `Settings.get_boolean_setting/2`'s `is_boolean/1` guard on click.

## 1.7.174 - 2026-07-05

### Fixed
- **Host layouts are no longer double-wrapped, and both `{@inner_content}` and
  `render_slot(@inner_block)` work.** PhoenixKit LiveViews used to set their
  native Phoenix `:layout` to the host's configured `config :phoenix_kit, layout:`
  — but every page *also* applies that same host layout itself via
  `LayoutWrapper.app_layout` in its render. So a host layout with visible chrome
  rendered twice (doubled header / nav / footer, body singular), and a host layout
  written in the Phoenix 1.8 idiom (`slot :inner_block` + `render_slot(@inner_block)`)
  crashed with `KeyError: key :inner_block not found` because Phoenix invokes a
  `:layout` with `@inner_content` only.

  The native `:layout` is now a pure passthrough (`PhoenixKitWeb.Layouts.app`,
  which renders only `{@inner_content}`), making `app_layout` the **single owner**
  of the host layout — applied exactly once. `app_layout` hands the host layout
  both a real `inner_block` slot and a lazily-derived `@inner_content`, so a host
  layout renders correctly whether it uses `{@inner_content}` (the documented
  contract) or `render_slot(@inner_block)`. A misconfigured layout function falls
  back to PhoenixKit's own layout instead of 500-ing every page.

  Hosts that previously worked around the double-wrap (e.g. detecting slot vs.
  `@inner_content` in their own layout) can drop that workaround.

## 1.7.173 - 2026-07-05

### Changed
- **DaisyUI theme names are now translatable.** `ThemeConfig`'s `@labels` map
  (System, Light, Dark, and 34 other theme names) was hardcoded without gettext
  wrapping, so it rendered in English regardless of locale. Adds
  `translated_label/1` and `translated_label_map/0`; the theme-switcher dropdown
  and the layout wrapper's client-side JS label map now use them.
- **User dashboard nav gains an `:authenticated_links` attribute.**
  `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1` now accepts
  `authenticated_links` (default `[:admin, :dashboard, :settings, :logout]`),
  mirroring the existing `:guest_links` narrowing. Lets a host app hide menu
  entries its own navigation already covers (e.g. `:dashboard`). Narrowing-only:
  `:admin` still requires `Scope.admin?/1`, so it can never grant access.
- **Dependency bumps:** `ex_ast` 0.12.5 → 0.12.7, `mdex` 0.13.2 → 0.13.3,
  `mdex_native` 0.2.3 → 0.2.4, `swoosh` 1.26.2 → 1.26.3 (lockfile).

### Fixed
- **V80 migration could corrupt email-template data on a retried multi-version
  run.** V80 was the only version module that never recorded its own
  `COMMENT ON TABLE phoenix_kit IS '80'` checkpoint. Because update migrations
  run with `@disable_ddl_transaction` (each step auto-commits individually), a
  failure in a later version would cause a subsequent `mix ecto.migrate` to
  resume from V80 and re-run its `ALTER COLUMN ... TYPE jsonb USING
  jsonb_build_object('en', ...)` against already-converted columns,
  double-wrapping the values (`{"en": {"en": "..."}}`). V80 now writes its
  checkpoint like every other version and guards the conversion on the column's
  current type so it's idempotent. (#612)

### i18n
- **French UI strings translated.** French was ~5% translated (1688 of 1776
  msgids blank in `default.po`, all 8 blank in `phoenix_kit.po`) despite most
  strings being reachable from public-facing pages (theme switcher, "Log in",
  etc.). All ~1782 blank entries across `default.po` / `phoenix_kit.po` /
  `errors.po` are now translated to idiomatic French (formal register, plural
  forms per entry).
- Localized three previously-hardcoded labels in the user dashboard nav
  ("Dashboard", "Settings", "Log Out") via `gettext/1`, matching the rest of the
  component; new msgids extracted across all locale catalogs.

### Internal
- Ignore a `Gettext.Backend`-generated `call_without_opaque` Dialyzer false
  positive (Expo's opaque `PluralForms` struct passed into
  `Gettext.Plural.plural/2`) so `mix precommit` passes on Erlang 28 / Elixir
  1.19. Already on the latest `gettext` 1.0.2 / `expo` 1.1.1; no user code is
  involved.

## 1.7.172 - 2026-07-03

### Changed
- Added the `rustler` dependency as optional (lockfile). `mdex_native` builds
  from source (instead of downloading a precompiled NIF) when
  `MDEX_NATIVE_BUILD=1` is set in the environment; that path requires rustler
  itself, not just `rustler_precompiled`.

### Fixed
- **Gettext locale falling back to default on publishing content routes.**
  `process_locale/1` only matched `path_params["locale"]`, but the internal
  routes `phoenix_kit_publishing` generates for localized content
  (`get "/:language/:group"`) bind the segment as `"language"` instead. The
  mismatch meant `Gettext.put_locale/1` was never called on those requests, so
  translations silently rendered in the site default locale regardless of the
  URL prefix (e.g. `/en/articles` rendering Russian nav text).

## 1.7.171 - 2026-07-03

### Changed
- **`RouterDiscovery` sitemap source compiles exclude/include-only patterns
  once per collection instead of once per route per pattern.** Same behavior,
  fewer `Regex.compile/1` calls; invalid patterns (e.g. a bare `"*"`, which is
  not a valid regex) are now logged instead of silently swallowed. Two more
  default excludes: `^/__` (internal/technical routes, e.g. Publishing's
  dispatch catch-all scope) and `^/maintenance$` (PhoenixKit's reserved
  maintenance page) — both mainly load-bearing for installs with a non-default
  `url_prefix`. (#614, #615)
- **New optional `reserved_route_prefixes/0` module callback** +
  `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0`. Lets a module
  declare top-level route path segments it owns (e.g. `["legal"]`), so a
  database-driven dispatcher (e.g. Publishing's `/:language/:group/*path`
  catch-all) can avoid swallowing another module's route just because a
  same-named record happens to exist in its own data. Iterates all installed
  modules (not just enabled ones), since the guarded route is normally
  compiled into the host router independent of the module's runtime
  enabled/disabled toggle. Declaring a prefix is passive on its own — it
  changes nothing until a dispatcher consults it. (#614)
- Bumped `phoenix_live_view` 1.2.4 → 1.2.5, `plug` 1.20.1 → 1.20.2, `makeup`
  1.2.1 → 1.2.2 (lockfile).

### Fixed
- **V70 migration crash on installs missing the legacy `email_log_id` /
  `matched_email_log_id` integer FK columns.** The re-backfill guards checked
  that the UUID companion columns existed but not the legacy integer columns
  the raw SQL actually joins on, so an install where those legacy columns were
  already dropped hit an `undefined column` error. (#613)
- **Sitemap no longer advertises URLs while the SEO module's `noindex`
  directive is active.** `/sitemap.xml` (XML and HTML) now publishes an empty
  but schema-valid `<urlset>` instead of the full URL list whenever
  `seo_no_index` is enabled, and toggling the directive invalidates + triggers
  regeneration of the cached sitemap so it doesn't keep serving a stale file.
  (#614)
- **Sitemap `RouterDiscovery` no longer masks richer entries from other
  sources.** `RouterDiscovery` enumerates every GET route generically; when a
  content source (Publishing, Entities, …) emitted a richer entry (priority,
  `canonical_path`, hreflang alternates) for the same URL, the old
  `loc`-based dedup kept whichever entry was listed first — always the
  generic `RouterDiscovery` one — silently dropping priority and hreflang
  alternates from the sitemap. Dedup now always prefers the richer,
  non-`RouterDiscovery` entry regardless of source order. (#615)
- **`seo_no_index` now reaches a host application's own public LiveViews.**
  Previously only `LayoutWrapper.app_layout_inner/1` (PhoenixKit's own
  admin/plugin views) set the `:seo_no_index` assign that `root.html.heex`
  reads for the `noindex,nofollow` meta tags, so a host app's own public
  LiveView — mounted through PhoenixKit's `on_mount` chain for
  `current_user`/locale support but rendered with its own layout — never got
  the directive even with it enabled. The assign is now set from the
  `handle_params` hook shared by every PhoenixKit `on_mount` variant. (#616)

---

Older releases are archived by quarter in
[`dev_docs/changelogs/`](https://github.com/BeamLabEU/phoenix_kit/tree/main/dev_docs/changelogs):
[2026 Q2](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q2.md) ·
[2026 Q1](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q1.md) ·
[2025](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2025.md)
