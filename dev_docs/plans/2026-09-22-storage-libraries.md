# Storage libraries: partition files into libraries, each with its own members and storage

**Created:** 2026-09-22
**Revised:** 2026-09-23, after the Grok review
(`dev_docs/reviews/2026-09-23-storage-libraries/`). The phases went from three
to five. V201 is smaller. Private serving moved ahead of user libraries, and
location-truth moved ahead of storage profiles. Four gaps were added
(G11–G14), and G3 and G8 were corrected. Later the same day, **variant sets**
(per-library image and video sizes, §3.4, G15–G19) were added to V204, so they
ship in the same release as storage profiles.
**Status (2026-09-25):** Phase 1 **RELEASED in 2.38.0** (2026-09-23, tag
`v2.38.0`). **Phase 2 RELEASED in 2.39.0** (2026-09-25, tag `v2.39.0`),
after the maintainer tested it in a host app and Grok reviewed it: see
"Phase 2 as built" below. **Phase 3 (V204, location-truth) RELEASED in 2.40.0** (2026-09-25,
published without a host-app test at the maintainer's call; Grok reviewed
it): see "Phase 3 as built" below. **2.40.1** is a cleanup of the §11
leftovers (see the status list at the end of §11). **Next: V205,
storage profiles and variant sets, in progress on `main`**: see "Next: V205"
below for its work order. Phase 1 shipped as **V202**, not V201: PR #860
took V201 for per-user view preferences, so every phase below shifts by one
(V202 partition, V203 private serving + user libraries, V204 location-truth,
V205 profiles + variant sets, V206 user-owned storage). The version numbers in
the body are the plan's original ones. See "Phase 1 as built" below for what
shipped and where it differs from §9. The maintainer answered all open
questions on 2026-09-23 (§10), and the plan body reflects the answers.

### Phase 1 as built (V202)

- `phoenix_kit_storage_libraries` + the Media seed under a **fixed uuid**
  (`00000000-0000-7000-8000-000000000001`, `Storage.Libraries.media_uuid/0`).
  `library_uuid` on files, folders and folder links is NOT NULL with a column
  **DEFAULT of Media's uuid**: existing rows need no rewrite, and every writer
  that names no library (core's and ~10 modules') keeps landing in Media. The
  constant default is what the schema manifest can declare.
- Folder names unique per `(library_uuid, parent)`; folder links reference
  `(file_uuid, library_uuid)`; a library-keyed capture-date index.
- `key_prefix` for new libraries (`lib-<12 hex>`); Media keeps NULL, so its
  keys keep today's per-uploader layout.
- Code keeps libraries apart: a subfolder takes its parent's library, and a
  file cannot be homed in, linked into, or moved to another library's folder
  (`{:error, :other_library}`).
- System libraries are managed in **Settings → Media → Libraries**
  (`LibrariesComponent`: create, rename, delete-when-empty, counts and size),
  the tab the later phases' per-library storage profile and variant set
  pickers belong on. `/admin/media` only switches: its switcher appears once
  a second library exists, and with one nothing about libraries is shown.
- Media stays at the bare `/admin/media`; any other library is `/admin/media/library/<slug>` (`libraries.slug`, from the name,
  `-2`/`-3` on a clash, kept across renames; the fixed `library` segment
  keeps a slug from colliding with `/admin/media/<file uuid>` and
  `/selector`). With only Media the browser gets no library and lists
  exactly what it did before.
- `Storage.Libraries.can?/3` replaces the three per-file checks, **keeping
  today's rules**: `:read` is the uploader or Owner/Admin — NOT the `"media"`
  key (the file-info endpoint deliberately withholds it, issue #687) — and
  `:edit` adds the `"media"` key for system libraries.

Deferred from §9's V201 list, deliberately:

- **The uploader FK → `SET NULL` and the relaxed CHECK.** It changes what
  deleting a user does (their files would stay, uploader-less, instead of
  going with them), which is visible and GDPR-relevant; it ships with user
  libraries, which need it.
- **Dropping V200's user-keyed capture-date index.** The manifest has no way
  to say "removed in version N", so it stays until a phase can retire it
  cleanly. Nothing queries it.
- Indexes are plain builds, not `CONCURRENTLY` — the chain's convention (see
  V193), not the plan's §9 mechanics.

Known phase-1 limit: dedup is still per uploader site-wide, so uploading into
library B bytes the same person already has in Media returns the Media file;
the MediaBrowser refuses that upload in B rather than showing a file B does
not hold (`{:postpone, :in_other_library}`, reported as its own pluralised
warning). The V203 dedup key swap (§6.4) removes this limit.

Fixed before the 2.38.0 tag, from Grok's review
(`dev_docs/reviews/2026-09-23-storage-libraries/CLAUDE_RECHECK.md`):

- The V202 slug backfill assigns slugs one library at a time, checked
  against those already written for the owner. The first version ranked
  and then truncated, so near-identical names could collide and abort the
  migration.
- `list_system_libraries_with_stats/0` returns `holds` (any row at all,
  trashed or system-managed included), and the Libraries tab disables
  Delete on it, matching what `delete_library/1` and the FK refuse.
- The MediaBrowser's upload summary is put by the parent LiveView
  (`parent_flash/3` → `handle_parent_info/2`). A LiveComponent's
  `put_flash` never reached the page. Open follow-up: the browser's other
  `put_flash` calls (folder created, renamed, …) have the same limit and
  were not audited one by one. Most follow a navigation, which carries the
  flash.

Also in 2.38.0, and useful to V203: public-bucket downloads of files that
must not render in place are redirected to a one-hour **presigned** URL
(`Provider.signed_download_url/3`, an optional callback that S3 implements;
`Manager.get_file_access/2` returns `{:signed_redirect, url}`, and proxies
when a provider cannot sign). This is the presigning that §6.7 needs for
private libraries. It is not yet the `"signed"` access type: it only covers
the download case on public buckets, and it skips `cdn_url`.
### Phase 2 as built (V203, released in 2.39.0)

- **Migration:** `phoenix_kit_storage_library_members` (`manager` |
  `contributor` | `viewer`; the owner is `owner_uuid`, never a member row).
  The uploader FK and the folder-creator FK are `ON DELETE SET NULL`, and the
  files CHECK passes a file with a library. The library owner FK is
  `SET NULL`, and its check lets only a **trashed** user library lose its
  owner: deleting a user whose live library still names them fails, so
  `Auth.delete_user/2` must trash them first (`trash_owned_libraries/1`). It
  repeats V202's slug statements (#871). Constraints are replaced add
  `NOT VALID` → validate → swap, each in its own statement.
- **Dedup differs from §6.4:** no unique index was swapped. The manifest
  cannot declare a removal, so a dropped index it still listed would be
  reported missing and rebuilt by repair. Instead a file outside Media folds
  its library into `user_file_checksum`
  (`Storage.calculate_user_file_checksum/3`); the existing unique index then
  holds one copy per uploader per library, and Media's keys are unchanged.
- **Permissions:** the `"storage"` key (which gated nothing before) is "take
  part in user libraries"; its sub-permission `"storage.create_library"`
  creates them. `storage_user_libraries_enabled` (default off) and
  `storage_user_library_limit` (default 10) are settings on Settings → Media
  → Libraries.
- **Private serving (§6.7):** `URLSigner.private_token/3` (`w<expiry
  base36>-<HMAC>`); the window is `storage_private_url_window_hours`, and a
  URL is minted at least a quarter window before it expires. Responses are
  `private, max-age=3600`. `Storage.authorized_url/4` is the module-facing
  minter. Presigned redirects stay allowed; plain public redirects are
  proxied.
- **Pages, per the §10 decisions (items 7–11), with one change:** browsing is
  **`/admin/libraries`**, not `/dashboard/media` (`/dashboard` is being phased
  out). Per the maintainer, end users never need Media directly;
  `phoenix_kit_photos` is their surface, and `/admin/libraries` is for
  moderation and testing. The profile's Media tab (`LibrarySettings`)
  manages libraries and members. The admin metadata list of §8 is a card on
  Settings → Media → Libraries, not a separate `/admin/storage/libraries`.
  Opening a user's library as Owner/Admin is audit-logged
  (`storage.library_opened`, now in `AuditLog.Entry`'s allowed actions: the
  plan's "no migration" was right, but the changeset had an allowlist).
- **Security fix found on the way:** a `MediaBrowser` showing one library
  now refuses any event naming another library's file or folder. The scope
  check alone admits everything without a scope folder.
- **A listing that names no library means the site's libraries** (every
  library that is not private, `Libraries.exclude_private/1`), not "every
  library". A user library is read only by passing its uuid. This is the
  contract for every module: before Grok's review, `nil` meant everything,
  so orphan cleanup (which names none) would have deleted user-library files
  as unreferenced, and `/admin/media`, host embeds and the pickers listed
  them. A private library's files are also never orphans when the library
  *is* named. `/admin/media` now always passes its system library.
- **Also from the review** (`dev_docs/reviews/2026-09-25-storage-libraries-v203/`):
  the `/admin/media/:uuid` detail page needs `Libraries.can?/3` for a private
  file (the `media` key alone no longer opens one); `get_public_url*` never
  hands a private file a bucket object URL; a private file's tiles are
  cached `private`; a viewer cannot open a library's member list.
- **Orphan cleanup only trashes** (maintainer's request): "Move all orphaned
  to trash" and `mix phoenix_kit.cleanup_orphaned_files --delete` go through
  `DeleteOrphanedFileJob`, which now calls `Storage.trash_file/1`.
- **`/admin/libraries` for an Owner/Admin** also lists every other user's
  library below their own (found in the host-app test: the admin saw none).
- **Known limits, left for later** (see "Next" below): a contributor can
  organise and trash any file of the library through the browser, which has
  no per-file ownership check (the API's `allows?/2` says only "upload").
  Restoring a trashed user library is not offered. An Owner/Admin opening a
  private file's detail page at `/admin/media/:uuid` is not audit-logged
  (only opening the library is). V200's user-keyed capture-date index is
  still there.

### Phase 3 as built (V204, released in 2.40.0)

- **Migration:** duplicate location rows removed (the oldest of each
  instance/bucket pair kept, by `inserted_at` then uuid), a UNIQUE
  `(file_instance_uuid, bucket_uuid)` index, an index on `path` (reads look
  a key up by it), and the location's bucket FK `CASCADE` → `RESTRICT`.
  `Storage.delete_bucket/1` returns a changeset error for a bucket that
  still holds files; the settings page says to disable it instead.
- **Reads (§6.2):** `Storage.Locations` resolves a key to the buckets its
  active rows name. `Manager`'s reads, `file_exists?`, `public_url`,
  `get_local_file_path` and `get_file_access` try those first (in the usual
  order), then the other enabled buckets, and record a bucket found that
  way. Deletes are unchanged: an unreferenced key goes from every enabled
  bucket, which is right while every library writes the same buckets.
- **Writers:** `store_system_file/3` (tiles), `store_file/2` (comment
  attachments) and the original-recreation path record their locations
  (`Locations.record_all/2`, after the instance row exists).
  `force_bucket_ids` is written exactly: no redundancy cap, no reorder.
- **Checks (after Grok's review):** `phoenix_kit_file_location_checks`
  records that an instance was checked against every bucket and how many
  held it. It, not "has a location row", is what the backfill walks: a
  read's fallback records the one bucket it found, and must not retire the
  instance while its other copies are unrecorded. Writers mark their
  instances checked, V204 marks instances that already had rows, and a
  confirmed miss (`found_in: 0`) is not probed on every request
  (`Locations.known_missing?/1`).
- **Backfill:** `LocationBackfillJob`, 50 unchecked instances per run, next run 5 s
  later on `file_processing`, unique pending. Queued 30 s after boot and by
  the daily trash prune while any instance has no row; the Health page
  shows how many are left. The fallback probe stays (decided: until the
  backfill finishes; in practice it only costs anything for keys that have
  no row, i.e. genuinely missing objects once the backfill is done).
- **Bucket cache:** `Manager.invalidate_bucket_cache/0` on every bucket
  create/update/delete.
- **One checksum (G12):** `UploadController` hashes SHA-256.
  `ChecksumBackfillJob` recomputes the 32-hex MD5 rows from each original
  (guarded on the old value; a row colliding with the uploader's own copy
  is left). Queued like the location backfill.
- **Moved to V205: G11, per-`(bucket, key)` reference counting.** While
  every library writes the same buckets, a key's buckets are the same set
  everywhere, so a global count is exact. It matters once profiles give
  libraries different buckets and a bucket can be drained, which is what
  V205's reconciler does, so it is built with it.
- **Phase-2 follow-ups, done here:** a contributor changes only the files
  they uploaded (`MediaBrowser` `own_files_only`, with the browser's write
  events in one list held to its readonly clauses by a test); an owner
  restores a trashed user library until it is purged
  (`Libraries.restore_library/2`, the Media tab's Trash); an Owner/Admin
  opening a user-library file's detail page is audit-logged.

### V204, location-truth: the work order it was built from

The original §9 "V203" list, renumbered. It is the load-bearing change for
everything after it: per-library storage (V205) and user-owned buckets
(V206) cannot work while reads try every enabled bucket by key. Order of
work inside the release:

1. **Location uniqueness (G7):** dedupe `phoenix_kit_file_locations`, then a
   UNIQUE `(file_instance_uuid, bucket_uuid)` index. New manifest object.
2. **Every writer records locations (§6.1, G13):** `store_file/2` (comment
   attachments), `store_system_file/3` (Tessera tiles), and
   `ApplyImageEditJob`'s outputs pinned to the original's buckets. Fix
   `force_bucket_ids` being capped and reordered (§11).
3. **Location backfill job (§6.2):** an Oban job, started by the release,
   that probes system buckets by key once per instance with no location and
   records what it finds. Never a migration step.
4. **Reads, serving and deletes by location (§6.2):** `retrieve_file`,
   `get_file_access`, `public_url`, `delete_file` resolve through the
   instance's active locations (local first, then ascending priority, as
   today), with a probe-and-record fallback for rows the backfill has not
   reached, removed one release later.
5. **Reference counting per `(bucket, key)` (G11):** an object on a bucket
   is deleted only when no active location on that bucket names its key;
   the delete touches only that bucket. Goes through
   `Storage.delete_stored_objects/2`, which already re-checks under the
   directory lock.
6. **Bucket FK on locations → RESTRICT (G4):** a bucket that still holds
   locations cannot be deleted (a `{204, ...}` constraint revision in the
   manifest, the V203 replace pattern).
7. **Bucket cache invalidation:** bucket edits apply at once instead of
   after up to 5 minutes (`manager.ex`'s `:persistent_term` cache).
8. **One checksum algorithm (G12):** `UploadController` hashes SHA-256 like
   everything else; a job recomputes existing MD5 `file_checksum`s (32 hex)
   by reading the original. Until recomputed, a row simply does not dedup.

Decided (2026-09-25): **the backfill runs by itself, throttled**: queued
after the update, small batches on `file_processing`, progress on the
Health page. **The probe fallback stays until the backfill reports every
instance done**, not for a fixed number of releases, so a host that updates
rarely is never left with files nothing can find.

Small follow-ups from phase 2 that can ride along or go first: the
contributor per-file check in the browser, restoring a trashed user
library, and audit-logging an admin's `/admin/media/:uuid` open of a private
file. Outside core: `phoenix_kit_photos` builds its library switcher on
`Libraries.list_user_libraries/1` and serves through
`Storage.authorized_url/4`.

### Next: V205, storage profiles and variant sets (work order)

Written 2026-09-25, before any code. The body's "V204" sections (§3.2, §3.4,
§4, G1–G6, G9, G10, G15–G19, §6.1, §6.3) are this release. It is built on
`main` in the steps below. Each step keeps the suite green and changes
nothing a user can see until the editors land (step 6), and the release
goes out once, after the maintainer tests it, like V203.

**Where this differs from the body, decided while writing this:**

- **Fixed uuids for the two defaults,** like Media: the Default profile is
  `00000000-0000-7000-8000-000000000002` and the Default variant set is
  `…0003`. `phoenix_kit_storage_dimensions.variant_set_uuid` gets the Default
  set's uuid as its column DEFAULT, so a writer that names no set (a sibling
  module seeding a size) keeps working, the same trick as `library_uuid`.
- **Every bucket goes into the Default profile, not only enabled ones.**
  `enabled` stays the emergency stop, and placement and serving skip a
  disabled bucket whatever its profile says. Re-enabling a bucket then works
  as it does today. A bucket created later joins the Default profile, since
  today every new bucket joins the pool.
- **`generate_variants`, not `generate_video`.** `storage_auto_generate_variants`
  switches off every automatic variant today, not only video transcodes, so
  the set's flag means the same thing. Which video sizes exist is already
  decided by the set's `applies_to: "video"` rows.
- **The file records its variant set too.** G6 gives a file
  `placed_profile_uuid` + `placed_revision`. Variants need the same, or a set
  change would mean scanning every instance. So there are also
  `placed_variant_set_uuid` + `placed_variant_revision`. `spec_hash` (G16)
  then says, within a stale file, *which* instances to regenerate.
- **`spec_hash` only on instances generated from a size.** An annotated
  thumbnail, a burned render or an edit's backup has none, so the reconciler
  never deletes it as "a size the set no longer has". The migration stamps
  the instances whose name matches a current size (or one of its alternative
  formats) with that size's hash. The hash is `md5` over a canonical text of
  the spec, so SQL and Elixir compute the same value.
- **Left for V206:** `owner_uuid` on profiles and buckets and
  `buckets.shareable` (they only matter for user-owned storage), quotas, and
  the cached usage table (G9). V205 does the other half of G9: placement
  skips a bucket over its `max_size_mb`. Its usage comes from the existing
  `SUM` query, cached for a few minutes.

**Steps, in order:**

1. **V205 migration + schemas + contexts. No behaviour change.**
   - Tables `phoenix_kit_storage_profiles` (name unique, `is_default` unique
     when true, `copies_originals`/`copies_variants` 1..5,
     `min_copies_on_write` 1..`copies_originals`, `revision`) and
     `phoenix_kit_storage_profile_buckets` (PK `(profile_uuid, bucket_uuid)`,
     profile FK CASCADE, bucket FK RESTRICT, `role`/`stores`/`status`
     checks, `write_priority`, `serve_order`, and the G10 columns
     `storage_class` + `encryption`, which nothing reads yet).
   - Table `phoenix_kit_variant_sets` (`is_default`, `selectable`,
     `generate_variants`, `generate_tiles`, `revision`).
   - `libraries.storage_profile_uuid` / `variant_set_uuid` (NULL = the
     default, FK RESTRICT). `files.placed_profile_uuid`, `placed_revision`,
     `placed_variant_set_uuid`, `placed_variant_revision`.
     `file_instances.spec_hash`. `storage_dimensions.variant_set_uuid`
     (NOT NULL, DEFAULT the Default set, FK CASCADE), and the name index
     reshaped to UNIQUE `(variant_set_uuid, name)` by a `{205, …}` revision
     (G18).
   - Seeds (§4): the Default profile from `storage_redundancy_copies` and a
     row per bucket (`write_priority` = `NULLIF(priority, 0)`, `serve_order`
     = local first, then priority); the Default set from
     `storage_auto_generate_variants` / `storage_tile_generation_enabled`;
     every dimension into it; `spec_hash` stamped; `placed_*` stamped on
     every file whose completed instances each have at least the Default
     copy count of active locations (today's health rule), and the variant
     set stamp on every file.
   - Manifest declarations (catalog-exact, from `Repair.Probe.snapshot/2`),
     `chain_hash` restamp, a `v205_test.exs` like V204's.
   - `Storage.Profiles` and `Storage.VariantSets`: CRUD, every change bumps
     `revision`, `resolve/1` from a library (cached, dropped on any change).
     `Storage.spec_hash/1`, proven equal to the SQL stamp by a test.
2. **Placement follows the profile (§6.1, G1, G2, G5, G9 half, G13).**
   `Manager.store_file/2` takes the profile and whether the object is an
   original or derived. It picks active rows whose `stores` fits and whose
   bucket is enabled and not full, primary before replica before backup,
   fixed `write_priority` first and then the shuffled pool, up to the copy
   count. Fewer than `min_copies_on_write` successes fail the write and
   remove what was written; fewer than the copy count queue the reconciler
   for the file. Variants are placed by the profile as derived objects, no
   longer forced onto the original's buckets (image-edit outputs keep
   following the key they replace). A cross-user clone needs the donor's
   library to resolve to the same profile and set (§6.4). Creating a bucket
   adds it to the Default profile; deleting an empty one removes its rows.
   `storage_redundancy_copies` reads and writes the Default profile.
3. **Serving by role and `serve_order` (G1, G3).** `Locations` returns a
   key's buckets with their role and order in the file's profile. Serving
   (`get_file_access`, `public_url`, `get_local_file_path`) never uses a
   `backup`; primaries come before replicas, in `serve_order`; a location on
   a bucket the profile no longer lists comes last. `retrieve_file` (reading
   bytes to process them) may use a backup last.
4. **Variants follow the set (G15–G19).** The generator reads the file's
   set, records `spec_hash`, and honours the set's `generate_*` flags (the
   two settings become read-through aliases for the Default set). The
   standard slots (`thumbnail`, `small`, `medium`, `large`,
   `video_thumbnail`) cannot be deleted or renamed, and `small`/`medium`/
   `large` keep the aspect ratio. A missing variant is served as the
   nearest smaller one, then a placeholder, never the original for a
   thumbnail-class request (G17). `Storage.variant_for/2` (G19).
   `mix phoenix_kit.doctor` reports a set missing a standard slot.
5. **The reconciler (§6.3, G4, G6, G11, G15).** `Storage.Workers.ReconcileJob`
   walks stale files in batches, by uuid. For each instance it keeps the
   good locations, copies to more eligible buckets until the copy count is
   met (verified), then unlinks locations on buckets that are draining or
   no longer in the profile. An unlink deletes the object from that bucket
   only, and only when no other active location on that bucket names the
   key (G11, under the directory lock). Then it generates missing sizes,
   regenerates those whose `spec_hash` differs, and deletes those the set no
   longer has. A fully compliant file is stamped, and a failure leaves it
   stale for the next pass. Instances not yet location-checked are skipped.
   Queued by profile/set/library changes, by under-replicated uploads and
   daily by the prune job. The Health page shows it, and `SyncFilesJob` and
   the `sync_under_replicated*` functions go.
6. **Editors (§8).** Settings → Media: a profiles section (copies, and per
   bucket its role, stores, priority, serve order and status) that replaces
   the redundancy input, and variant sets replacing the dimensions list
   (one tab per set, standard slots pinned, "regenerate" bumps the
   revision). Settings → Media → Libraries: profile and set pickers per
   system library. The user's Media tab: a set picker among `selectable`
   sets (the profile stays Default until V206).
7. **Docs, CHANGELOG, review.** Storage README, the plan's "Phase 4 as
   built", a Grok review, then the maintainer's test on dev before
   publishing.

**Progress** (`main`, not pushed until the V205 migration is final: a
database that ran an earlier build of it through a git dependency would
never get a later change, the #871 lesson):

- Step 1 done (`b3724a5b6`). The migration, manifest, schemas, `Profiles`
  and `VariantSets`. Bucket create/delete/priority already keep the
  Default profile in step, because the profile's bucket FK is RESTRICT.
- Step 2 done (`fd6eab9f7`). `Manager.store_file/2` places by profile (`:profile`,
  `:kind`); `Storage.store_by_profile/4` is the one entry for uploads,
  tiles, variants, re-stores and the legacy `store_file/2`; a file records
  its placement (`record_placement/2`), and an incomplete store marks it
  stale (`placed_revision = 0`). The copy target is capped at the buckets
  the profile can use right now, as in the migration's stamp: a profile
  change bumps the revision, which makes the file stale again when more
  buckets become usable. `Storage.redundancy_copies/0` and
  `set_redundancy_copies/1` are the setting's alias. Until step 5, the
  Health page's sync still copies to any enabled bucket.
- Step 3 done (`c72ece343`). `Locations.ranked/1` gives a key's buckets with the role
  and serve order its file's profile gives them (a bucket the profile no
  longer lists ranks after its buckets, backups last). Serving
  (`get_file_access`, `public_url`) follows that order strictly, so a
  remote copy can come before a local one, and never uses a backup; reads
  for processing (`retrieve_file`, `file_exists?`) may use a backup last.
  A key with no rows yet keeps today's rule (local first).
- Step 4 done (`cda8e47e8`). The generator takes the sizes of the file's library's set
  and records each variant's `spec_hash`; a full run stamps
  `placed_variant_set_uuid` / `placed_variant_revision`, or 0 when a size
  failed. A size change bumps its set's revision (a reorder does not).
  Standard sizes cannot be deleted (`{:error, :standard_slot}`) or renamed,
  and small/medium/large keep the aspect ratio (the `Dimension` changeset).
  The two generation settings are the Default set's flags
  (`Storage.get_auto_generate_variants/0`, `tile_generation_enabled?/0` and
  their setters, which keep the rows in step); tiles follow the file's own
  set (`VariantSets.tiles_for?/1`, `tiles_among/1` for a grid page,
  `put_dzi_url`'s `tiles:`). A missing image size stands in as the nearest
  smaller size, then the edit placeholder (`VariantSets.stand_in/3`), never
  a full original larger than the size. `Storage.variant_for/2` picks by
  purpose; moving core call sites that want a size rather than a slot
  (`ImageSet`'s `"medium"`, grids) onto it is left as a follow-up. `mix
  phoenix_kit.doctor` warns about a set missing a standard size.
- Step 5 done (`21019482b`). `Storage.Reconciler` (the service) and
  `Storage.Workers.ReconcileJob` (10 files a run, 2 s apart, one pending
  run; queued by every revision bump, a library's profile or set change, an
  incomplete upload or variant run, the daily prune and boot). Per file,
  under a session advisory lock: each checked, completed instance gets
  copies up to the profile's count (capped at the buckets it can use; a
  copy counts once `Manager.holds?/2` sees it), then copies on buckets the
  profile no longer uses for it are unlinked (`Storage.unlink_location/2`,
  G11: the object goes only when no other active location on that bucket
  names the key and no instance under the key is unchecked). **Never
  unlinks without a good copy elsewhere** (a test caught the capped target
  of zero deleting a draining profile's only copy). Sizes: missing ones
  made, ones with another `spec_hash` remade, ones the set no longer lists
  removed (`Storage.remove_instances/2`), disabled ones kept. Trashed
  files keep their placement but get no new sizes. Stamps only what now
  matches, at the revisions read at the start. The Health page lists the
  stale files and queues a pass; `SyncFilesJob` is a shim that queues the
  reconciler (remove next release) and the `sync_under_replicated*`
  functions and `get_health_report/1` are gone.
- Step 6 done (`4b764e459`). Settings → Media gets a **Storage profiles** tab
  (`ProfilesComponent`: copy counts, and per bucket role/stores/write
  priority/serve order/status saved on change, add/remove, create/delete).
  The dimensions page is now **Variant sets** (a tab per set via `?set=`,
  its flags, "Check every file", create/delete; sizes are created in the
  set; standard sizes are pinned first with no Delete). The Libraries tab
  picks each system library's profile and set; the user's Media tab picks a
  selectable set for a library they own. The Configuration tab keeps the
  copies / automatic sizes / tiles controls, relabelled as the Default
  profile's and set's (they are the same aliases), rather than removing
  them. The setting rows are kept in step inside `Profiles.update_profile/2`
  and `VariantSets.update_variant_set/2`, whichever screen edits the
  Default. All new strings translated in the seven locales (77 each: 59 new
  and 18 fuzzy carry-overs rewritten); the untranslated backlog is
  unchanged (de/fr 50, et/ru 71, es/it/pl 74).
- Step 7: CHANGELOG under `## Unreleased` (`dd4757b62`), Storage README.
  Two independent reviews found 25 issues, two of them data loss (the
  reconciler trusting a location row as a good copy; making over burned
  thumbnails); all but two fixed, with tests. See
  `dev_docs/reviews/2026-09-26-storage-libraries-v205/CLAUDE_REVIEW.md`.
  V205 gained `files.reconcile_attempted_at` in that round (it was not
  pushed yet). Left: Grok's review, the maintainer's test on dev, then push
  and publish.

**Scope:** phoenix_kit (core), Storage module, in five releases (V201–V205).
First consumer: `phoenix_kit_photos`.
**Related:** `PhoenixKit.Modules.Storage.CaptureDate` and V200 (the capture-date
index this plan re-keys); `phoenix_kit_photos` plans
`2026-09-21-phoenix-kit-photos.md` and `2026-09-22-roadmap-after-stage-0.md`.

Line numbers below are as of commit `fb393135` (2.37.4). V202 and #860 have
since moved most of them (for example `list_files`' `bucket_uuid` filter is
now `storage.ex:5033`), so search by function name. V200 is released, so
every phase here is a new version, starting at **V201**.

---

## 1. The idea

Every stored file belongs to exactly one **library**. A library is a partition
of the file store with its own members, its own settings and its own storage.

- **System libraries** are site-wide and managed by admins. Examples: the site's
  media (avatars, branding, everything that exists today), or a shared
  "Company" library.
- **User libraries** are created by users. Examples: "Personal", "Business", or
  one per project. A user may give a library storage they bring themselves.

Why this matters beyond Storage: Google Photos has one library per account.
Apple Photos opens one library at a time and syncs only one. A person with a
personal library, a business library and project libraries, switching between
them instantly and sharing some of them, is a real differentiator for
`phoenix_kit_photos`. It has to be in the data model from the start, because
everything downstream keys on it: the timeline scope, the capture-date index,
permissions, share links and realtime events.

**A library is a partition, not a tag.** A file is in one library. Collections
that cross it (albums, folder links) live *inside* a library. Moving a file to
another library is an explicit operation, and it may move bytes (§6.3).

## 2. What core does today

### Files are owned by their uploader, and very little scopes by it

- `user_uuid` is the uploader (`UploadController.resolve_upload_user/2`,
  `upload_controller.ex:173`; MediaBrowser `media_browser.ex:4218`). Avatars,
  branding and comment attachments are all owned by whoever uploaded them.
  There is no site-owned user-facing file. The only files without an owner are
  `system_managed` children (Tessera tiles, edit backups), which is enforced by
  CHECK `phoenix_kit_files_user_or_parent_check` (`v135.ex:9602`).
- Listing is scoped by **folder**, not user: `list_files/1`,
  `list_files_in_scope/2`, trash, orphans and folder queries have no user
  clause. MediaBrowser's `scope_folder_id` is a virtual root; the host decides
  who may reach a browser.
- `user_uuid` matters in four places:
  1. owner predicates: `FileController.authorize_file_read/2`
     (`file_controller.ex:495`, uploader or Owner/Admin), `ImageEditing.allowed?/2`
     (`image_editing.ex:381`) and `AnnotationBurnController.allowed?/3` (`:116`)
     (uploader, Owner/Admin, or the `"media"` key), and `MediaSelectorModal`'s
     optional `user_uuid` filter (`:763`);
  2. per-user dedup (below);
  3. the object key: `{user_uuid[0..1]}/{md5[0..1]}/{md5}/{md5}_{variant}.{ext}`
     (`storage.ex:4089-4126`). `storage_default_path` is a separate setting and
     not part of the key;
  4. the V200 capture-date index `(user_uuid, taken_on DESC, taken_at DESC)`.
- **Folders are global.** `phoenix_kit_media_folders.user_uuid` is only the
  creator. Names are unique **site-wide** per parent
  (`phoenix_kit_media_folders_name_parent_idx`, `v135.ex:3962`), so two users
  cannot both have a root folder called "Personal".
- **Permissions are role-level only.** There is no per-object ACL anywhere in
  core. The `"media"` key gates `/admin/media`, which shows every file.
- **Organizations** are user rows with `account_type = "organization"`. A person
  belongs to at most one (`users.organization_uuid`). They have no roles and no
  Storage integration.

### Buckets are one global pool, and the read path ignores FileLocation

- **Write:** `Manager.select_buckets_for_storage/2` (`manager.ex:151`, private)
  takes all enabled buckets, fixed priorities first (1 = highest) and then
  priority-0 buckets shuffled, and takes `storage_redundancy_copies` of them.
  It writes the same key to each and records a `FileLocation` per bucket
  (`storage.ex:4145`). Variants are passed the original's buckets as
  `force_bucket_ids` (`variant_generator.ex:218`), but that list is capped by
  the redundancy setting and reordered to enabled-bucket order
  (`manager.ex:42-47, 168-172`), so a variant is not guaranteed to sit in
  every bucket the original is in.
- **Read and serve:** `get_file_access/1` returns the **first local bucket** that
  has the object. Only after that does it consider remote buckets, in
  `priority` order **ascending**, so priority 0 comes before 1
  (`manager.ex:176-179, 332-371`). Writes and reads therefore use opposite
  orders: with local at 0 and cloud at 1, a two-copy setup already writes to
  the cloud first and serves from local.
- **Read, serve and delete never consult FileLocation.**
  `Manager.retrieve_file`, `file_exists?`, `public_url`, `get_file_access` and
  `delete_file` (`manager.ex:64-122, 364-402`) try every enabled bucket by key.
  They read a `:persistent_term` bucket cache with a 5-minute TTL that nothing
  invalidates (`manager.ex:291`). `FileServer.get_file_location/2`, the
  location-aware lookup, exists but has no callers.
- **Some writers record no locations:** `store_file/2` (comment attachments,
  `storage.ex:3283`; its key is a timestamp and random suffix, not the
  hierarchy above) and `store_system_file/3` (Tessera, `storage.ex:2282`).
  Tiles are stored as child files whose only instance has
  `variant_name: "original"` (`storage.ex:2310-2343`). `ApplyImageEditJob`
  stores its rendered output and backup through automatic selection, not
  pinned to the original's buckets (`apply_image_edit_job.ex:232, 299`).
- **Serving** (`FileController.show`, `file_controller.ex:50`): a local bucket is
  served with `send_file`. `access_type: "private"` is proxied through Phoenix.
  Anything else, including the unimplemented `"signed"`, redirects to
  `public_url`, which is `cdn_url` or an AWS-style URL and ignores a custom
  `endpoint` (`s3.ex:81-87`). *Since 2.38.0:* a file that must download
  rather than render (not an image, video, audio, PDF or plain text) is
  redirected from a public bucket to a one-hour presigned URL instead
  (`{:signed_redirect, url}`), or proxied if the provider cannot sign.
- **Signed file URLs are capability URLs.** The token is the first 4 hex
  characters of an MD5 and never expires (`url_signer.ex:137-156`). It carries
  no user, and `show/2` checks nothing else.
- **No bucket migration exists.** Deleting a bucket cascades its location rows
  and leaves the objects behind. `SyncFilesJob` only tops up under-replicated
  files. Nothing moves files off a bucket.
- **Deletion counts references per key, not per bucket.** `unreferenced_keys/2`
  treats a key as live while any instance names it (`storage.ex:3418-3434`),
  and `Manager.delete_file/1` then deletes the key from every enabled bucket
  (`manager.ex:74-83`).

### Dedup is per user and shares objects across users

- `user_file_checksum = sha256(user_uuid <> file_checksum)`, UNIQUE, not partial
  (`storage.ex:2215`; index `#{prefix}_phoenix_kit_files_user_file_checksum_index`,
  `v135.ex:2558`). A same-user duplicate returns the existing file. System
  rows set `user_file_checksum = checksum` (`storage.ex:2321`).
- A **cross-user** duplicate is cloned by `clone_file_for_user`
  (`storage.ex:4186`). The clone is a new row with the **same**
  `file_checksum`, sharing the donor's objects, keys and FileLocations, in the
  donor's buckets.
- **`file_checksum` is not one algorithm.** `UploadController` hashes with MD5
  (`upload_controller.ex:222`). MediaBrowser and `Storage.calculate_file_hash/1`
  use SHA-256 (`storage.ex:4833`). The same bytes uploaded through the two
  paths are not recognised as duplicates.

### Credentials

- `secret_access_key` is encrypted on save (`bucket.ex:230`); `access_key_id` is
  plaintext. A bucket may instead use `integration_uuid`, and the Integrations
  system already has an `object_storage` provider with `scopes: [:system, :personal]`
  (`integrations/providers.ex:915`).
- `S3.resolve_credentials/1` fetches the integration with `owner: :any`
  (`s3.ex:188`). There is no ownership check, and only the keys are used;
  region and endpoint come from the bucket row.
- `endpoint` is free-form, with no host validation (`s3.ex:163`). The
  integration validator strips `https://` (`validators.ex:718-726`) but
  `S3.aws_config/1` does not. For a local bucket, `endpoint` is a server
  filesystem path. Only admins can create buckets today
  (`/admin/settings/media/buckets`, `"media"` key).

### User deletion

`Auth.delete_user/2` ends with `Repo.delete(user)`. Where nothing blocks it,
the FK `fk_files_user_uuid ... ON DELETE CASCADE` (`v135.ex:6412`) **deletes
every file row the user uploaded**, and the bucket objects are left behind.
Several things can block it: the folder creator FK has no ON DELETE
(`v135.ex:8576`), and `phoenix_kit_comment_media` and `phoenix_kit_cat_pdfs`
reference files `ON DELETE RESTRICT` (`v135.ex:9638, 9566`).
`anonymize_user_files` (`auth.ex:3837`) is effectively a no-op. With shared
libraries, the cascade is data loss: a member leaving a business library would
take everything they ever uploaded to it.

## 3. Data model

### 3.1 Libraries

```
phoenix_kit_storage_libraries                                       -- V201
  uuid                  uuidv7 PK
  name                  varchar            -- unique per owner, not site-wide
  kind                  varchar            -- "system" | "user"
  owner_uuid            uuid NULL → users ON DELETE RESTRICT   -- NULL for system; may be an organization user row
  visibility            varchar            -- "site" (system libraries) | "private"; drives serving (§6.7)
  key_prefix            varchar            -- object-key prefix for new files (G8)
  settings              jsonb default '{}' -- non-placement settings, §3.3
  is_default            boolean            -- one default system library; one default per user
  trashed_at            timestamptz NULL
  timestamps
  + storage_profile_uuid NULL → storage_profiles                   -- V204; NULL = the Default profile
  + variant_set_uuid     NULL → variant_sets                       -- V204; NULL = the Default variant set

phoenix_kit_storage_library_members                                 -- V202
  library_uuid     → libraries ON DELETE CASCADE
  user_uuid        → users     ON DELETE CASCADE
  role             varchar            -- "owner" | "manager" | "contributor" | "viewer"
  PK (library_uuid, user_uuid)

phoenix_kit_file_instances + spec_hash                                                (V204, G16)
phoenix_kit_files          + library_uuid NOT NULL → libraries ON DELETE RESTRICT   (V201; children inherit the parent's)
                           + UNIQUE (uuid, library_uuid)                             (V201; target of the folder-link FK)
                           + placed_profile_uuid, placed_revision                    (V204, G6)
phoenix_kit_media_folders  + library_uuid NOT NULL → libraries ON DELETE RESTRICT   (V201)
phoenix_kit_media_folder_links + library_uuid, FK (file_uuid, library_uuid) → files (uuid, library_uuid)
                                                                                     (V201; a link cannot cross libraries)
```

Rules:

- **Uploader and library are separate.** `files.user_uuid` stays "who uploaded
  it". The uploader FK moves from CASCADE to SET NULL, and the CHECK becomes
  `user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL OR library_uuid IS NOT NULL`,
  so deleting a user no longer deletes library content.
- **Libraries are never deleted by a cascade.** Deleting a user first transfers
  or trashes the libraries they own. That step is `RESTRICT` on `owner_uuid`, so
  it cannot be skipped. Purging a trashed library is a job: it deletes the
  library's files through the normal delete path (which respects shared keys,
  G11), then the library row.
- **Access** (§6.5) is the union of the uploader, library membership, the
  `"media"` key for system libraries, and `Scope.system_role?`.
- An **organization** can own a library (`owner_uuid` = the org's user row).
  Its members are added as library members, with no magic inheritance, because
  core organizations have no roles to map.
- Folder names are unique per `(library_uuid, parent)`, not site-wide.
- The name "library" does not collide with anything in core code; it is only
  used in prose for the media store. Avoid "workspace" (an admin-label preset)
  and "space" (`location_spaces`, `machines.space_uuid`).

### 3.2 Storage profiles: where a library's bytes live (V204)

A library does **not** list buckets itself. It points at a **storage profile**,
and the profile holds everything core's global storage settings express today.
Here is why:

- Most libraries share one setup. With per-library bucket lists, changing the
  site's storage would mean rewriting a row for every user's "Personal"
  library, and every copy could drift.
- Today's global setup becomes the **Default** profile (§4). Any library with
  no profile uses it, so existing installs behave exactly as before.
- A user who brings their own storage creates their **own** profile (§7).

```
phoenix_kit_storage_profiles
  uuid, name
  owner_uuid           NULL = system profile; else the user (or organization) who owns it
  is_default           exactly one system profile
  copies_originals     1..5   -- replaces storage_redundancy_copies
  copies_variants      1..5   -- variants can be regenerated; 1 is usually enough
  min_copies_on_write  1..copies_originals (G5)
  revision             integer, bumped on any change to the profile or its buckets (G6)
  timestamps

phoenix_kit_storage_profile_buckets
  profile_uuid         → storage_profiles ON DELETE CASCADE
  bucket_uuid          → buckets ON DELETE RESTRICT   -- a bucket in use cannot vanish
  role                 "primary" | "replica" | "backup"         (G1)
  stores               "all" | "originals" | "derived"          (G2, G13)
  write_priority       NULL = shuffled pool (today's priority 0), else fixed order
  serve_order          integer                                   (G3)
  status               "active" | "read_only" | "draining"       (G4)
  storage_class        varchar NULL   -- later (G10)
  encryption           jsonb NULL     -- later (G10)
  PK (profile_uuid, bucket_uuid)

phoenix_kit_buckets        + owner_uuid NULL → users   -- NULL = system bucket (V205)
                           + shareable boolean         -- a system bucket that user profiles may include (V205)
phoenix_kit_file_locations + UNIQUE (file_instance_uuid, bucket_uuid)   (V203, G7)
                           bucket FK: CASCADE → RESTRICT               (V203, G4)
```

How today's setups map onto profiles:

| Setup | Profile |
|---|---|
| All local | local (primary), 1 copy |
| Local + cloud | local (primary, served) + B2 (backup, never served), 2 copies |
| Cloud + cloud | R2 (primary) + B2 (replica), 2 copies |
| A photo library, cost-aware | originals: local (primary) + B2 (backup); derived: local only |
| Business on its own storage | a user-owned profile over the company's S3 buckets |

A user profile may contain only buckets its owner owns, plus system buckets
marked `shareable`. A shareable bucket must not be `access_type: "public"`.

### 3.3 Other library settings

These are validated by a core schema and stored in `libraries.settings`:

| Key | Meaning | Falls back to |
|---|---|---|
| `max_upload_size_mb` | per-file cap | `storage_max_upload_size_mb` |
| `quota_mb` | total size cap (G9) | none |
| `auto_generate_variants`, `tile_generation` | per-library overrides | the global settings |

There is deliberately no "dedup off" switch: the unique key (§6.4) makes a
second row of the same bytes by the same uploader in the same library
impossible, and that is the intended behaviour.

Module-specific settings (for example `phoenix_kit_photos`' face grouping opt-in
and location visibility) live in the module's own tables, keyed by
`library_uuid`. They do not go in core's jsonb. Core validates only its own keys.

### 3.4 Variant sets: which derived files a library gets (V204)

A storage profile says *where* bytes live. A **variant set** says *which*
derived files exist: sizes, formats, quality, crop, alternative formats,
video transcodes and tiles. A library points at one of each, and they change
independently. A business library on company S3 can use the site's normal
thumbnails, and a photo library on the default storage can need sizes a blog
never does. Folding sizes into the profile would multiply profiles by every
combination.

```
phoenix_kit_variant_sets
  uuid, name
  is_default           exactly one; built from today's phoenix_kit_storage_dimensions rows (§4)
  selectable           user libraries may choose it
  generate_video       boolean   -- replaces storage_auto_generate_variants for video transcodes
  generate_tiles       boolean   -- replaces storage_tile_generation_enabled
  revision             integer, bumped on any change to the set or its dimensions (G16)
  timestamps

phoenix_kit_storage_dimensions     + variant_set_uuid NOT NULL → variant_sets ON DELETE CASCADE
                           name unique per set, not site-wide   (G18)
```

Rules:

- **Sets are defined by admins only.** User libraries choose from sets marked
  `selectable`. Variants cost the server's CPU even when the bytes land on a
  user's own bucket, so a user-defined set (eight AVIF sizes plus 1080p
  transcodes of every upload) would be a denial-of-service lever. This is
  deliberately unlike storage profiles, where users bring their own buckets.
- **Standard slots are a contract.** A variant's name is part of every file
  URL (`/file/:uuid/:variant/:token`). About 30 files in core use literal
  names, and `ImageSet` prefers `"medium"` (`image_set.ex:179`). Every set must
  define `thumbnail`, `small`, `medium`, `large` and `video_thumbnail`. A set
  may change their size, format and quality, but not drop or rename them.
  Custom names (for example `grid_2x`) come on top. *Decided (§10.5):*
  `small`, `medium` and `large` must keep the aspect ratio
  (`maintain_aspect_ratio = true`, enforced by the dimension changeset for
  those slots), because grids and justified layouts depend on it. Only
  `thumbnail` may be cropped, for example square for list rows and avatars.
- **Ask by purpose, not by name** (G19). A consumer that cares about pixels
  calls `Storage.variant_for(file, min_width: 300, aspect: :preserve)`, which
  resolves against the file's library's set. An admin can make `small` a
  square crop in one set and not in another, so a name alone promises nothing.

## 4. The Default profile, the Default variant set, and upgrading existing installs (V204)

V204 creates one system profile, `Default`, with `is_default = true`:

- one `profile_buckets` row per currently **enabled** bucket. `write_priority`
  is copied from `buckets.priority`, with 0 mapped to NULL (the pool).
  `serve_order` reproduces today's read behaviour: local buckets first, then
  ascending `priority`;
- role `primary` and `stores = "all"` on every row, because today every copy is
  equal;
- `copies_originals = copies_variants = storage_redundancy_copies`, and
  `min_copies_on_write = 1` (today's rule).

Nothing is copied or moved. The migration also **stamps**
`placed_profile_uuid = Default` and the current `placed_revision` on every file
whose active locations already satisfy the Default profile. By V204 every file
has location rows (V203 backfilled them), so this is a set-based update, not a
walk over objects. Only files that are genuinely under-replicated start out
stale, exactly the ones today's health page would flag.

Every library with a NULL profile resolves to `Default`. Changing the global
settings UI then means editing the Default profile, and
`storage_redundancy_copies` stays only as a read-through alias for one release.

The same migration creates the **Default variant set**:

- every existing `phoenix_kit_storage_dimensions` row moves into it
  (`variant_set_uuid` is set, and the global name uniqueness becomes
  per-set uniqueness);
- `generate_video` and `generate_tiles` are copied from
  `storage_auto_generate_variants` and `storage_tile_generation_enabled`, which
  then become read-through aliases for one release;
- if an install has deleted or renamed a standard slot, the migration does
  **not** invent one. It reports the missing slot through `mix phoenix_kit.doctor`
  and the settings page. Serving falls back per G17 until an admin fixes it;
- every existing instance is stamped with the `spec_hash` of the dimension
  that currently has its name (G16). An instance whose recorded pixels do not
  match that spec is left stale for the reconciler, which is exactly the
  "admin edited a size" backlog that exists silently today.

Nothing is regenerated by the migration itself.

## 5. Gaps in core storage that this plan closes

Every item below must be addressed. Most exist **today**, independent of
libraries, but per-library storage makes each of them either necessary or
visible. The tag after each title is the release it lands in.

**G1. Roles for copies** (V204). Every copy is equal today. A cloud copy kept
only as a backup (for egress cost or a cold tier) cannot be kept out of
serving. `role`:

- `primary`: written and served;
- `replica`: written, served if no primary has it;
- `backup`: written, read only by repair, restore and the reconciler, never served.

**G2. Originals and derived files placed separately** (V204). Variants are
handed the original's buckets, but capped and reordered (§2), so the placement
is neither separate nor exact. Keeping thumbnails on fast local disk and
originals in the cloud is the largest cost lever for a photo library. Hence
`stores` per profile bucket and separate `copies_originals` / `copies_variants`.

**G3. Serving order as a first-class setting** (V204). *Corrected after review.*
Writes and reads already use opposite orders (§2), so "write to the cloud
first, serve from local" works today. What cannot be expressed:

- "serve from the CDN or remote copy even though a local copy exists", because
  local always wins in `get_file_access/1`;
- "never serve this copy" (G1).

`serve_order` replaces the implicit local-first-then-ascending rule, and is
filtered by role.

**G4. Safe removal of a bucket** (V203 for the FK, V204 for statuses). Today,
disabling a bucket makes its objects unreachable once the 5-minute cache
expires, while their FileLocations stay `active` and health still counts them.
Deleting a bucket cascades its location rows and orphans the objects
(`v135.ex:4684`). The fix:

- per-profile-bucket `status`: `read_only` stops writes and keeps serving;
  `draining` makes the reconciler copy everything to the remaining buckets,
  verify, and then unlink;
- the bucket FK on `file_locations` becomes RESTRICT, so a bucket that still
  holds locations cannot be deleted;
- the global `enabled` flag becomes an emergency stop, not the way to retire a
  bucket.

**G5. The write rule** (V204). An upload succeeds if **one** bucket accepted it
(`manager.ex:188-222`). Missing copies are filled only when an admin starts a
sync from the Health page. The fix:

- `min_copies_on_write`: the upload fails unless at least this many copies
  succeed;
- the rest are queued automatically to the reconciler, which never waits for a
  person.

**G6. Reconciler bookkeeping** (V204). When a profile changes, or a library
moves to another profile, something has to find the files that are not where
they should be, without rewriting millions of rows. Each file records
`placed_profile_uuid` and `placed_revision`. It is stale when the profile
differs from its library's, or when the revision is older. The migration
stamps files that are already compliant (§4). One reconciler (§6.3) replaces
`SyncFilesJob` and works through stale files in batches.

**G7. Location uniqueness** (V203). `phoenix_kit_file_locations` has no unique
index on `(file_instance_uuid, bucket_uuid)`, only single-column btrees
(`v135.ex:2466-2474`). Duplicate rows are possible today and would confuse
location-based reads. The migration dedupes any existing duplicates, then
builds the UNIQUE index concurrently.

**G8. A key prefix per library** (V201, for new files). *Corrected after
review.* Keys today are `{user_uuid[0..1]}/{md5[0..1]}/{md5}/…`, with no
configurable prefix (`storage.ex:4089-4126`). New files in a library are keyed
`{library.key_prefix}/{md5[0..1]}/{md5}/…`. That is what makes it possible to:

- wipe or export one library from a shared bucket;
- apply S3 lifecycle rules per library;
- scope IAM or bucket policies to a business prefix.

Existing objects keep their keys, since a key is an address recorded on the
instance, not something derived at read time. A file that moves to another
library on the same buckets also keeps its key.

**G9. Usage accounting and capacity** (V204, with quotas in V205). Sizes live
on `file_instances`, and nothing sums them per library or per profile. Quotas
and user-owned storage need a cached usage figure per library and per profile
bucket, updated by the reconciler and on ingest and delete.
`buckets.max_size_mb` exists but selection ignores it. Profiles will skip a
bucket that is over its cap, and the UI will show it as full.

**G10. Room for storage class and encryption** (schema in V204, behaviour
later).

- A storage class per profile bucket (S3 IA or an archive tier). Allowed only
  on `backup` rows, because archive tiers need a restore step before a read.
- Encryption per profile bucket: an SSE-KMS key for business buckets, or
  client-side encryption for user-owned ones.

The columns exist from V204 so that adding them later needs no redesign.

**G11. Reference counting per `(bucket, key)`** (V203). *Added after review.*
Clones share keys by design. Deletion today treats a key as live while any
instance anywhere names it, then deletes it from every enabled bucket (§2).
Once libraries use different buckets, that is wrong in both directions:

- a drained bucket's objects are kept forever because another library still
  names the key;
- deleting "this file's old locations" without a per-bucket count removes
  bytes another library still needs.

An object on a bucket is deletable only when no **active location on that
bucket** references its key. The delete touches only that bucket.

**G12. One checksum algorithm** (V203). *Added after review.*
`UploadController` records MD5 and everything else records SHA-256 (§2), so
dedup silently misses across upload paths. New uploads all use SHA-256. A job
recomputes `file_checksum` for existing MD5 rows (they are recognisable by
length: 32 versus 64 hex characters) by reading the original. Until a row is
recomputed it simply does not dedup, which is today's behaviour.

**G13. Placement classifies rows by what they are, not by `variant_name`**
(V203 for locations, V204 for placement). *Added after review.* Tessera tiles
and edit backups are child files whose instance is named `"original"`. A rule
keyed on `variant_name == "original"` would put tile pyramids on the
originals' buckets. The rule is:

- the original instance of a non-`system_managed` file is an **original**;
- everything else (variants, tiles, manifests, edit renders) is **derived**
  and follows the parent file's library.

The V203 location backfill covers tiles and `store_file/2` originals, which
have no location rows today.

**G14. Private serving** (V202). *Added after review. It blocks user
libraries.* Files in a non-`site` library must not be reachable by a
permanent 4-character token, and must never be answered with a redirect to a
public object URL. See §6.7.

The variant gaps below also exist today, independent of libraries. They land
with variant sets in V204.

**G15. Editing a size changes nothing already stored.** `update_dimension/2`
and `delete_dimension/1` only write the row (`storage.ex:1065, 1083`). Files
keep the old pixels under the same name. A deleted size leaves its variant
files in storage forever. A new size exists only for new uploads. The only
regeneration is a per-file button on the media detail page
(`media_detail.ex:192`). With sets, a change bumps the set's `revision`, and
the reconciler (§6.3) generates what is missing, regenerates what is stale,
and deletes what was removed, per G11.

**G16. An instance does not record which spec produced it.** It has only
`variant_name` and its own pixels, so stale variants cannot be found without
re-deriving every one. Each generated instance stores a `spec_hash` over
width, height, crop, format, quality and alternative formats. An instance is
stale when its hash differs from the current dimension with that name in its
library's set.

**G17. A missing variant is served as the original.** `FileController` serves
the original and queues generation (`file_controller.ex:970-1016`). In a grid
of 10k photos, a new or renamed thumbnail size means thousands of full
originals sent as thumbnails. The fallback becomes the nearest existing
**smaller** variant, then a placeholder, and never the original for a
thumbnail-class request. Generation is still queued.

**G18. Dimension names are unique site-wide** (`phoenix_kit_storage_dimensions_name_index`, `v135.ex:2498`). Inside sets they are unique
per set, so two sets can each define `thumbnail` at a different size.

**G19. Consumers pick variants by name.** See §3.4: `variant_for/2` resolves
by purpose against the library's set. Core call sites that need a size rather
than a slot (grids, previews, the photos timeline) move to it. Call sites that
genuinely mean a slot (`thumbnail` in a list row) keep the name.

## 6. Behaviour changes

### 6.1 Placement follows the library's profile (V204)

- `select_buckets_for_storage/2` takes a library and resolves its profile. It
  picks buckets with `status = "active"` whose `stores` matches originals or
  derived (G13), fixed `write_priority` first and then the shuffled pool, up to
  the profile's copy count, skipping full buckets (G9).
- A bucket that is not in the profile is never written. In particular, a user
  bucket never receives another library's file.
- Every writer records FileLocations (V203): fix `store_file/2` and
  `store_system_file/3`, and pin `ApplyImageEditJob`'s outputs to the
  original's library.

### 6.2 Reads, serving and deletes follow FileLocation (V203)

This is the load-bearing change. Once buckets differ per library, "try every
enabled bucket by key" is wrong:

- it misses a file that is only in a user bucket;
- it would probe, and on delete *write to*, a bucket that belongs to another
  library's profile.

So `retrieve_file`, `get_file_access`, `public_url` and `delete_file` resolve
through the instance's active FileLocations:

- **serving** goes by role (G1), then `serve_order` (G3). Until V204 there are
  no roles, and the order is today's: local first, then ascending priority;
- **repair** may read any location;
- **deleting** follows G11.

Before the cutover, a **backfill job** creates location rows for every instance
that has none (tiles and `store_file/2` originals included, G13). It probes
system buckets by key once, off the serve path. The read path keeps a
probe-and-record fallback only for rows the backfill has not reached yet, and
it is removed one release later. The bucket cache is invalidated on bucket
and profile changes.

### 6.3 Moving bytes: one reconciler (V204)

A single job makes each file match its library's **profile and variant set**:

- **locations:** copy, verify, then unlink, and delete objects per G11 (G4, G5,
  G6);
- **variants:** generate missing ones, regenerate stale ones (G16), and delete
  ones the set no longer has, per G11 (G15).

Generation goes through the existing `file_processing` queue, so CPU use stays
bounded by that queue's concurrency. The job runs:

- when a file moves to another library, or a library to another profile or
  variant set;
- when a profile, a variant set, or their rows change (the revision bumps);
- after an upload that stored fewer copies than the profile wants;
- on a schedule, as today's health sync does.

A move between libraries that resolve to the **same** profile is a row update
only.

### 6.4 Dedup (V201 unchanged, V202 per library)

*Revised after review.*

- **V201 does not touch dedup.** `user_file_checksum` and its unique index stay
  exactly as they are. Every existing file is in one library, so nothing
  changes.
- **V202 swaps the unique key to `(library_uuid, user_file_checksum)`.** It
  builds the new index concurrently, then drops
  `#{prefix}_phoenix_kit_files_user_file_checksum_index`. Existing rows already
  have unique `user_file_checksum` values, so the pair is unique on every
  install by construction: no rows merge, and no FKs have to be repointed.
  Meaning: one copy per uploader per library. The same person may keep the
  same photo in Personal and Business. System rows (`user_file_checksum =
  checksum`) stay unique too.
- The same-uploader lookup (`get_file_by_user_checksum/1`) is scoped to the
  target library.
- **Cross-user cloning stays within one library and one profile.** The donor
  must be in the target library, or in a library that resolves to the same
  **system** profile **and the same variant set** (a clone copies the donor's
  variant instances). Otherwise the file is stored fresh. A clone must never
  make one library depend on another library's buckets.

### 6.5 Access checks become library checks (V201 rule, V202 members)

*Revised after review.* One predicate, `Storage.Libraries.can?(scope, file, action)`,
with actions `:read | :upload | :edit | :trash | :manage`, replaces the
owner-equality checks in `authorize_file_read/2`, `ImageEditing.allowed?/2`
and `AnnotationBurnController.allowed?/3`. It allows:

1. the **uploader** of the file (today's rule, kept: a user keeps access to
   their own avatar and attachments);
2. a **member** of the file's library, by role (from V202);
3. the `"media"` key, for files in **system** libraries only;
4. `Scope.system_role?` (Owner/Admin), subject to §8 for user libraries.

Also:

- `MediaBrowser` and `MediaSelectorModal` take a `library_uuid`. For the
  selector, it replaces the `user_uuid` filter.
- File PubSub events gain `library_uuid`, and ideally a per-library topic. Today
  every subscriber gets every file event on the site.

### 6.6 Capture-date index (V201)

Replace V200's `(user_uuid, taken_on DESC, taken_at DESC)` with
`(library_uuid, taken_on DESC, taken_at DESC)` under the same partial predicate,
built concurrently. A cross-library "everything I can see" view is then
`library_uuid = ANY($1)` over a handful of libraries. V201 then drops
`phoenix_kit_files_capture_date_index`. Nothing in core queries the old index.
Its one consumer, `phoenix_kit_photos`, moves to the library scope in the same
step.

### 6.7 Private serving (V202)

*Added after review.* Today every file is reachable by a permanent 4-hex-char
token, and non-private buckets redirect to a public object URL (§2). That is
acceptable for a site's own media, but not for a person's photos. For files in
a library with `visibility = "private"`:

- *Decided (§10.4):* file URLs carry a **time-window token**. It is an HMAC
  (keyed from `secret_key_base`) over the file uuid, the variant and a window
  end, where the expiry is rounded **up** to a fixed window (default 12 hours,
  a setting). Within one window the same image has the same URL, so browser
  and CDN caches keep working. Near a window boundary the minter uses the next
  window, so a URL is never handed out with only minutes left. The page that
  renders the file mints the URL after an access check (§6.5), and a LiveView
  re-mints on render and reconnect. `show/2` rejects the legacy 4-character
  token for these files, and answers an expired token with 403, never with the
  file;
- serving **never** redirects to `public_url`. It streams from local, proxies,
  or (once implemented) redirects to a short-lived **presigned** object URL
  (the documented `"signed"` access type);
- share links (a later feature) are their own capability with their own
  expiry, not the file URL.

System libraries (`visibility = "site"`) keep today's URLs, so nothing changes
for existing installs.

## 7. User-owned storage (V205)

User-owned storage is the riskiest part of this plan, and it comes last.

- **S3-compatible buckets only.** A user-supplied `local` bucket would be
  arbitrary filesystem write access on the server.
- **User buckets live only in their owner's profiles.** They are never in the
  Default profile, never probed for another library, and never listed as
  system buckets.
- **Credentials come from a personal integration** (`object_storage`, scope
  `:personal`, which already exists). The ownership check lives in **both**
  places: the bucket changeset refuses an `integration_uuid` the bucket's owner
  does not own, and `S3.resolve_credentials/1` passes `owner:` instead of the
  default `:any` (`s3.ex:188`, `integrations.ex:295-302`). Region and endpoint
  come from the integration.
- **One endpoint normalizer.** The integration validator and `S3.aws_config/1`
  must parse endpoints the same way, so the server does not connect to a
  different string than the one that was validated.
- **Endpoint validation (SSRF).** The server connects to whatever endpoint a user
  types. Require `https`, resolve the host, and refuse loopback, private,
  link-local and metadata ranges both at save time and at connect time (DNS can
  change). This is currently missing even for admin buckets. `cdn_url` gets the
  same host validation, since it is concatenated into redirects (`s3.ex:81-83`).
- **Serving.** User buckets are private (§6.7). Proxying through Phoenix costs
  server bandwidth on every view, so the `"signed"` access type (presigned GET,
  short expiry) is implemented here if it was not in V202.
- **Failure is normal.** Users revoke keys, delete buckets and hit their own
  quotas. The library shows a storage-health state, uploads fail loudly, and
  nothing in a system bucket silently absorbs the writes.
- **Quotas** (G9) apply to user libraries on system buckets. On their own
  buckets, users pay for their own storage.

## 8. Admin UI

### `/admin/media`: a switcher over **system** libraries (V201)

The Media section's library switcher lists **system libraries only**. The
default system library holds everything that exists today, so the page looks
exactly as it does now until a second system library is created. User
libraries are not in the switcher. They are the users' own content, not the
site's media, and a site with many users would bury the system ones.

### `/admin/storage/libraries`: user libraries as metadata (V202)

Admins still need to know that user libraries exist. That is because of
**system buckets**: a user library on a system profile is stored, and served
from the site's domain, at the operator's expense and under the operator's
responsibility. Takedown requests, abuse, quota disputes, support and GDPR
requests all land with the admin. So this list shows:

- owner, members, profile, file count, size, health and trash state;
- actions: suspend uploads, trash, change quota, move to another profile.

It does **not** browse contents. *Decided (§10.3):* opening a user library's
files needs the Owner or Admin role (`Scope.system_role?`), and every opening
writes an entry through `PhoenixKit.AuditLog.create_log_entry/1` (its `action`
is a plain string, so `"storage.library_opened"` needs no migration). The
entry records who, which library, when, the IP address and the user agent.
The `"media"` key alone never grants it.

### `/admin/settings/media`: system buckets, profiles and variant sets (V204–V205)

The variant sets editor replaces today's single dimensions list: one tab per
set, the standard slots pinned at the top, and a "regenerate" action that
bumps the revision instead of doing nothing (G15). Only admins see it.

The bucket list and the profiles editor show **system** buckets and profiles
only. User-owned buckets and profiles are managed by their owners under the
user's settings. Admins see them only as a read-only row per bucket: owner,
provider, endpoint **host**, health and the libraries using it. Credentials
are never shown. An admin can disable a user bucket, for example when an
endpoint misbehaves, but cannot edit it.

## 9. Phases and migration mechanics

### Phases

Each phase is a separate release with its own migration version.

**V201: the partition, system libraries only.**

- The `libraries` table; one default system library, "Media", with
  `visibility = "site"`.
- `library_uuid` on files, folders and folder links, backfilled into "Media".
- Folder names unique per library; folder links held to one library.
- The capture-date index re-keyed (§6.6), and `key_prefix` for new files (G8).
- The uploader FK moves to SET NULL, with the CHECK relaxed (§3.1).
- The access rule of §6.5 (uploader, `"media"`, Owner/Admin). With a single
  library, behaviour is identical to today.
- The system-library switcher in `/admin/media`.
- **Not in V201:** user libraries, members, and any change to dedup.

`phoenix_kit_photos` can build and measure its timeline against a system
library at this point, since the scope is `{:library, uuid}` either way.

**V202: private serving and user libraries.**

- Private serving (§6.7, G14). This ships **together with** user libraries,
  never after them.
- `library_members`, user library CRUD, a default library per user, and upload
  routing to it.
- *Decided (§10.2):* user libraries are **off by default**. The setting
  `storage_user_libraries_enabled` (default `false`) turns them on per
  install. The permission key `storage.create_library` (a sub-permission of
  `"storage"`) decides which roles may create them. The setting
  `storage_user_library_limit` caps how many a user may own. Membership in
  someone else's library needs no permission key; the library's role decides.
- The dedup key swap (§6.4).
- `/admin/storage/libraries` (§8).
- Placement is still the global pool. User libraries live on the system
  buckets.
- *Carried over from phase 1 (shipping as V203):* the uploader FK →
  `SET NULL` with the relaxed CHECK (§3.1), which user libraries need. Also
  retire V200's user-keyed capture-date index once the manifest can express a
  removal, or in the same step. V202 already added
  `phoenix_kit_files_library_capture_date_index`.
- *Promised when PR #871 was closed (2026-09-24):* V203 **repeats V202's
  idempotent slug statements**: `ADD COLUMN IF NOT EXISTS slug`, the
  `WHERE slug IS NULL` backfill, and `CREATE UNIQUE INDEX IF NOT EXISTS`
  on the owner/slug index. V202 was on `main` without `slug` from
  2026-09-23 13:01 to 22:12 UTC. That build never reached Hex, but a
  database that ran it (a git dependency) never gets the column otherwise.

**V203: location-truth.**

- The location backfill job (§6.2, G13), then reads, serving and deletes by
  location.
- Per-`(bucket, key)` reference counting (G11).
- Location uniqueness (G7) and the bucket FK moving to RESTRICT (G4).
- The writers that skip locations fixed, and the bucket cache invalidated.
- One checksum algorithm (G12).

**V204: storage profiles, variant sets and placement.** One release, one
migration, so the reconciler is built once for both.

- Profiles and the Default profile (§4); G1–G6, G9, and the G10 columns.
- Variant sets and the Default variant set (§3.4, §4); G15–G19.
- The reconciler, for locations and variants (§6.3).
- The profiles editor and the variant sets editor.

**V205: user-owned storage.** Everything in §7, plus quotas (G9).

### Migration mechanics

PhoenixKit's update wrappers run with `@disable_ddl_transaction true`
(`phoenix_kit.gen.migration.ex:148`, `postgres.ex:1485`), so there is no
enclosing transaction and each version can use non-blocking DDL. On
installs with large `phoenix_kit_files` tables:

- **Adding `library_uuid`:** add it nullable, with no default rewrite; backfill
  in batches by primary key; add `CHECK (library_uuid IS NOT NULL) NOT VALID`,
  then `VALIDATE CONSTRAINT` (the pattern V164 already uses, `v164.ex:137`);
  then `SET NOT NULL`, which PostgreSQL 12+ skips scanning when a validated
  check proves it; then drop the check.
- **Indexes:** always `CREATE [UNIQUE] INDEX CONCURRENTLY IF NOT EXISTS`, and
  drop the old index only after the new one is valid. Drop by the real,
  prefixed name (`#{prefix}_phoenix_kit_files_user_file_checksum_index`).
- **Schema manifest:** every new table, column, index and constraint is added
  to `expected_schema.ex`, or `Migrations.Repair` and `mix phoenix_kit.doctor`
  report drift. Names that embed the prefix must fit the 42-byte budget in
  `helpers.ex` (`@longest_embedded_object_name`), and its test fails loudly if
  one does not.
- **FK changes** (uploader to SET NULL, the location bucket FK to RESTRICT, the
  new library FKs): add as `NOT VALID`, then `VALIDATE` in a separate
  statement.
- **Anything that reads bytes** (the location backfill, checksum recomputation)
  is an Oban job started by the release, never a migration step.
- Each version must be re-runnable, like V200.

## 10. Maintainer decisions (2026-09-23)

All questions were answered by the maintainer, one at a time.

1. **Existing files go into one system library, "Media".** Access and
   `/admin/media` stay exactly as they are today. Users move files into
   personal libraries themselves once V202 exists. (§9, V201.)
2. **User libraries are off by default:** a setting turns them on, a role key
   (`storage.create_library`) decides who may create them, and a setting caps
   how many each user may own. Existing PhoenixKit sites do not suddenly offer
   a feature they never planned for. (§9, V202.)
3. **Admins may open a user library's contents only with the Owner or Admin
   role, and every opening is audit-logged.** Everyone else sees metadata only.
   (§8.)
4. **Private files use time-window tokens:** an HMAC over the file, the variant
   and an expiry rounded up to a window (12 hours by default), so URLs stay
   stable and cacheable within a window. (§6.7.)
5. **Five standard slots** (`thumbnail`, `small`, `medium`, `large`,
   `video_thumbnail`) in every variant set. `small`, `medium` and `large`
   always keep the aspect ratio; only `thumbnail` may crop. (§3.4.)
6. **"Library" everywhere:** core, `phoenix_kit_photos` and Fotki all use
   one word, in the code and in the UI.

### Decisions for V203 (2026-09-24)

7. **User-facing settings move to a tabbed profile page, one URL per tab:**
   `/profile/settings/{account,security,sessions,notifications,integrations,media}`.
   A tab shows only when it applies. `/profile/settings` opens the first
   tab, and `/profile/settings/integrations` keeps its URL. Personal
   integrations used to be the last section of one long page, shown only to
   holders of the opt-in `integrations` key, which is why they were hard to
   find.
8. **The profile's Media tab holds settings only:** the user's libraries,
   members and default library. It appears only when user libraries are
   enabled for the install and the user may have them. **Browsing and
   uploading is in the admin area, not `/dashboard`** (`/dashboard` is being
   phased out; signed-in users and admins share `/admin`, whose segment is
   renameable, so code writes canonical `/admin/...`): `/admin/libraries`
   lists the user's own libraries and the ones they are a member of, and
   `/admin/libraries/<slug>` is the MediaBrowser over one of them. The
   permission that lets a role have user libraries opens the admin area to
   it, like any other key. `/admin/media` stays the system libraries.
9. **User-owned storage (V206) is set on the same Media tab**, and only if
   the host allows it. It is a personal `object_storage` integration used
   either as the library's **only** storage (a profile with that one
   bucket as `primary`) or as a **backup** copy (`backup` role next to the
   system buckets). This needs V205's profiles, so it stays last.
10. **Deleting a user trashes the libraries they own.** A job then purges
    them, bytes included, through the normal delete path. Their uploads in
    system libraries or in other people's libraries stay, with no uploader
    (FK `SET NULL`).
11. **V203 is built completely and released once.** It holds private
    serving, members, user libraries, the profile tabs, `/admin/libraries`,
    the dedup key swap, the uploader FK, the slug repeat (#871) and the
    admin metadata page. The maintainer tests it on dev before it is
    published.

## 11. Existing bugs found while researching this (independent of the plan)

- `list_files(bucket_uuid: …)` filters on `f.bucket_uuid`, which does not exist
  (`storage.ex:4672`). It raises if used.
- `phoenix_kit_media_folders_user_uuid_fkey` has no ON DELETE (`v135.ex:8576`).
  Deleting a user who ever created a folder should fail with an FK violation.
  Not verified at runtime.
- `phoenix_kit_comment_media` and `phoenix_kit_cat_pdfs` reference files
  `ON DELETE RESTRICT` (`v135.ex:9638, 9566`). A user who attached a comment
  image or catalogue PDF also cannot be deleted while those rows exist.
- `anonymize_user_files` updates a column that does not exist, and the error is
  swallowed (`auth.ex:3837`).
- `delete_user` leaves the deleted user's bucket objects behind.
- `file_checksum` is MD5 in `UploadController` (`upload_controller.ex:222`) and
  SHA-256 elsewhere, so dedup misses across upload paths (G12).
- `store_file/2` and `store_system_file/3` record no FileLocations
  (`storage.ex:3283, 2282`). `ApplyImageEditJob` writes outputs unpinned from
  the original's buckets (`apply_image_edit_job.ex:232, 299`).
- `force_bucket_ids` is capped by redundancy and reordered, so variants are not
  reliably co-located with the original (`manager.ex:42-47, 168-172`).
- The bucket cache (`manager.ex:291`) is never invalidated; bucket edits take up
  to 5 minutes to apply.
- `storage_default_bucket_uuid` is configurable but unused.
- `public_url` ignores a custom S3 `endpoint`. `access_type: "signed"` is
  documented but falls through to a public redirect. (2.38.0 added
  presigned *download* redirects on public buckets, see "Phase 1 as built",
  but the access type itself is still unimplemented.)

Rechecked 2026-09-24: none of the items above were fixed by 2.38.0.

**Status, 2026-09-25** (after 2.40.0 and the 2.40.1 cleanup):

- `list_files(bucket_uuid: …)`: **fixed in 2.40.1** (filters through active
  locations).
- The media folder creator FK, comment/catalogue `RESTRICT`s blocking user
  deletion, `anonymize_user_files`, `delete_user` leaving objects behind:
  **fixed in 2.39.0** (V203: uploads are kept uploader-less, owned
  libraries are trashed and purged through the normal delete path).
- MD5 in `UploadController`: **fixed in 2.40.0** (SHA-256, MD5 rows
  recomputed by `ChecksumBackfillJob`).
- `store_file/2` and `store_system_file/3` recording no locations,
  `ApplyImageEditJob` unpinned, `force_bucket_ids` capped: **fixed in
  2.40.0**.
- The bucket cache never invalidated: **fixed in 2.40.0**.
- `storage_default_bucket_uuid` unused: **removed from the settings page in
  2.40.1** (its dead handler too). The setting row stays, unread; storage
  profiles (V205) replace the idea.
- `public_url` ignoring a custom endpoint, `access_type: "signed"` falling
  through to a public redirect: **fixed in 2.40.1** (`S3.endpoint/1` reads
  an endpoint once for requests and URLs, and refuses an unusable one
  instead of falling through to AWS; Tigris is addressed virtual-host
  style; an IPv6 endpoint is bracketed, and proxied rather than presigned;
  an R2 bucket with no public domain is proxied; a signed bucket serves a
  5-minute presigned URL, selectable in the bucket form; private and signed
  buckets never hand out a plain object URL).
- **Still open:** `S3.resolve_credentials/1` does not check who owns the
  integration. That belongs to V206 (user-owned storage), with the SSRF
  endpoint validation.
