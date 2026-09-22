# Storage libraries: partition files into libraries, each with its own members and buckets

**Created:** 2026-09-22
**Status:** PROPOSAL, not started. Open questions for the maintainer are at the end.
**Scope:** phoenix_kit (core), Storage module, in three releases (V201–V203). First consumer: `phoenix_kit_photos`.
**Related:** `PhoenixKit.Modules.Storage.CaptureDate` and V200 (the capture-date
index this plan re-keys); `phoenix_kit_photos` plans
`2026-09-21-phoenix-kit-photos.md` and `2026-09-22-roadmap-after-stage-0.md`.

Line numbers below are as of commit `fb393135` (2.37.4). V200 is released;
Phase 1 ships as **V201**.

---

## 1. The idea

Every stored file belongs to exactly one **library**. A library is a partition
of the file store with its own members, its own settings, and its own
storage buckets.

- **System libraries** are site-wide and managed by admins. Examples: the site's
  media (avatars, branding, everything that exists today), or a shared
  "Company" library.
- **User libraries** are created by users. Examples: "Personal", "Business", or
  one per project. A user may point a library at buckets they bring themselves.

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
     (`file_controller.ex:495`), `ImageEditing.allowed?/2`
     (`image_editing.ex:381`), `AnnotationBurnController.allowed?/3` (`:116`),
     and `MediaSelectorModal`'s optional `user_uuid` filter (`:763`);
  2. per-user dedup (§2.3);
  3. the object key: `"#{user_prefix}/#{hash_prefix}/#{md5}"` (`storage.ex:4090`);
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

- **Write:** `Manager.select_buckets_for_storage/2` (`manager.ex:151`) takes all
  enabled buckets, fixed priorities first and priority-0 buckets shuffled,
  then takes `storage_redundancy_copies` of them. It writes the same key to each
  and records a `FileLocation` per bucket (`storage.ex:4145`). Variants are
  pinned to the original's buckets through `force_bucket_ids`
  (`variant_generator.ex:218`).
- **Read, serve and delete never consult FileLocation.**
  `Manager.retrieve_file`, `file_exists?`, `public_url`, `get_file_access` and
  `delete_file` (`manager.ex:64-122, 364-402`) try every enabled bucket by key.
  They read a `:persistent_term` bucket cache with a 5-minute TTL that nothing
  invalidates (`manager.ex:291`). `FileServer.get_file_location/2`, the
  location-aware lookup, exists but has no callers.
- **Some writers record no locations:** `store_file/2` (comment attachments,
  `storage.ex:3283`) and `store_system_file/3` (Tessera, `storage.ex:2282`).
  `ApplyImageEditJob` stores its rendered output and backup through automatic
  selection, not pinned to the original's buckets (`apply_image_edit_job.ex:232, 299`).
- **Serving** (`FileController.show`, `file_controller.ex:50`): a local bucket is
  served with `send_file`. `access_type: "private"` is proxied through Phoenix.
  Anything else, including the unimplemented `"signed"`, redirects to
  `public_url`, which ignores a custom `endpoint`.
- **No bucket migration exists.** Deleting a bucket cascades its location rows
  and leaves the objects behind. `SyncFilesJob` only tops up under-replicated
  files. Nothing moves files off a bucket.
- **Unused settings:** `storage_default_bucket_uuid` can be set in the UI but
  is never used for selection.

### Dedup is per user and shares objects across users

- `user_file_checksum = sha256(user_uuid <> file_checksum)`, UNIQUE
  (`storage.ex:2215`, `v135.ex:2558`). A same-user duplicate returns the existing
  file.
- A **cross-user** duplicate is cloned by `clone_file_for_user`
  (`storage.ex:4186`). The clone is a new row that shares the donor's objects,
  keys and FileLocations, in the donor's buckets. Deletion is safe because of
  `unreferenced_keys`.

### Credentials

- `secret_access_key` is encrypted on save (`bucket.ex:230`); `access_key_id` is
  plaintext. A bucket may instead use `integration_uuid`, and the Integrations
  system already has an `object_storage` provider with `scopes: [:system, :personal]`
  (`integrations/providers.ex:915`).
- `S3.resolve_credentials/1` fetches the integration with `owner: :any`
  (`s3.ex:188`). There is no ownership check, and only the keys are used;
  region and endpoint come from the bucket row.
- `endpoint` is free-form, with no host validation (`s3.ex:163`). For a local
  bucket it is a server filesystem path. Only admins can create buckets today
  (`/admin/settings/media/buckets`, `"media"` key).

### User deletion

`Auth.delete_user/2` ends with `Repo.delete(user)`. The FK
`fk_files_user_uuid ... ON DELETE CASCADE` (`v135.ex:6412`) then **deletes every
file row the user uploaded**. The bucket objects are left behind.
`anonymize_user_files` (`auth.ex:3837`) is effectively a no-op. With shared
libraries this is data loss: a member leaving a business library would take
everything they ever uploaded to it.


## 3. Data model

### 3.1 Libraries

```
phoenix_kit_storage_libraries
  uuid                  uuidv7 PK
  name                  varchar            -- unique per owner, not site-wide
  kind                  varchar            -- "system" | "user"
  owner_uuid            uuid NULL → users  -- NULL for system; may be an organization user row
  storage_profile_uuid  uuid NULL → storage_profiles  -- NULL = the system default profile (§4)
  key_prefix            varchar            -- object-key prefix for this library (§5, G8)
  settings              jsonb default '{}' -- non-placement settings, see §3.3
  is_default            boolean            -- one default system library; one default per user
  trashed_at            timestamptz NULL
  timestamps

phoenix_kit_storage_library_members
  library_uuid     → libraries ON DELETE CASCADE
  user_uuid        → users     ON DELETE CASCADE
  role             varchar            -- "owner" | "manager" | "contributor" | "viewer"
  PK (library_uuid, user_uuid)

phoenix_kit_files          + library_uuid NOT NULL → libraries   (system_managed children inherit the parent's)
                           + placed_profile_uuid, placed_revision   (§5, G6)
phoenix_kit_media_folders  + library_uuid NOT NULL → libraries
```

Rules:

- **Uploader and library are separate.** `files.user_uuid` stays "who uploaded
  it". Access comes from library membership. The uploader FK moves from
  CASCADE to SET NULL, and the CHECK becomes
  `user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL OR library_uuid IS NOT NULL`,
  so deleting a user no longer deletes library content. Deleting a *user
  library* is its own explicit operation, with a trash period.
- **System library access** comes from role permissions (the existing `"media"`
  key, or a per-library permission key), not from rows in `library_members`.
  **User library access** comes from membership. The owner's own row has
  `role = "owner"`.
- An **organization** can own a library (`owner_uuid` = the org's user row).
  Its members are added as library members, with no magic inheritance, because
  core organizations have no roles to map.
- Folder names are unique per `(library_uuid, parent)`, not site-wide.
  A FolderLink must not cross libraries.
- The name "library" does not collide with anything in core code; it is only
  used in prose for the media store. Avoid "workspace" (an admin-label preset)
  and "space" (`location_spaces`, `machines.space_uuid`).

### 3.2 Storage profiles: where a library's bytes live

A library does **not** list buckets itself. It points at a **storage profile**,
and the profile holds everything core's global storage settings express today.
Here is why:

- Most libraries share one setup. With per-library bucket lists, changing the
  site's storage would mean rewriting a row for every user's "Personal"
  library, and every copy could drift.
- Today's global setup becomes the **Default** profile. V202 builds it from the
  enabled buckets and `storage_redundancy_copies`. Any library with no
  profile uses it, so existing installs behave exactly as before.
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
  stores               "all" | "originals" | "variants"         (G2)
  write_priority       NULL = shuffled pool (today's priority 0), else fixed order
  read_order           integer, independent of write_priority    (G3)
  status               "active" | "read_only" | "draining"       (G4)
  storage_class        varchar NULL   -- later (G10)
  encryption           jsonb NULL     -- later (G10)
  PK (profile_uuid, bucket_uuid)

phoenix_kit_buckets        + owner_uuid NULL → users   -- NULL = system bucket
                           + shareable boolean         -- a system bucket that user profiles may include
phoenix_kit_file_locations + UNIQUE (file_instance_uuid, bucket_uuid)   (G7)
                           bucket FK: CASCADE → RESTRICT               (G4)
```

How today's setups map onto profiles:

| Setup | Profile |
|---|---|
| All local | local (primary), 1 copy |
| Local + cloud | local (primary, served) + B2 (backup, never served), 2 copies |
| Cloud + cloud | R2 (primary) + B2 (replica), 2 copies |
| A photo library, cost-aware | originals: local (primary) + B2 (backup); variants: local only |
| Business on its own storage | a user-owned profile over the company's S3 buckets |

A user profile may contain only buckets its owner owns, plus system buckets
marked `shareable`.

### 3.3 Other library settings

These are validated by a core schema and stored in `libraries.settings`:

| Key | Meaning | Falls back to |
|---|---|---|
| `max_upload_size_mb` | per-file cap | `storage_max_upload_size_mb` |
| `quota_mb` | total size cap (G9) | none |
| `dedup` | `"library"` or `"off"` | `"library"` |
| `auto_generate_variants`, `tile_generation` | per-library overrides | the global settings |

Module-specific settings (for example `phoenix_kit_photos`' face grouping opt-in
and location visibility) live in the module's own tables, keyed by
`library_uuid`. They do not go in core's jsonb. Core validates only its own keys.

## 4. The default profile and upgrading existing installs

V202 creates one system profile, `Default`, with `is_default = true`:

- one `profile_buckets` row per currently **enabled** bucket. `write_priority`
  is copied from `buckets.priority`, with 0 mapped to NULL (the pool), and
  `read_order` follows the same order, since that is today's read behaviour;
- role `primary` and `stores = "all"` on every row, because today every copy is
  equal;
- `copies_originals = copies_variants = storage_redundancy_copies`, and
  `min_copies_on_write = 1` (today's rule).

Nothing is copied or moved. Every library with a NULL profile resolves to
`Default`. Changing the global settings UI then means editing the Default
profile, and `storage_redundancy_copies` stays only as a read-through alias for
one release.

## 5. Gaps in core storage that this plan closes

Every item below must be addressed. Most exist **today**, independent of
libraries, but per-library placement makes each of them either necessary or
visible. The tag after each title is the phase it lands in.

**G1. Roles for copies** (Phase 2). Every copy is equal today, and a file is
served from whichever enabled bucket answers first in priority order. A cloud
copy kept only as a backup (for egress cost or a cold tier) cannot be
expressed. `role`:

- `primary`: written and served;
- `replica`: written, served if no primary has it;
- `backup`: written, read only by repair, restore and the reconciler, never served.

**G2. Originals and variants placed separately** (Phase 2). Variants are pinned
to the original's buckets (`variant_generator.ex:218`) and replicated as often
as the original. Keeping thumbnails on fast local disk and originals in the
cloud is the largest cost lever for a photo library. Hence `stores` per
profile bucket and separate `copies_originals` / `copies_variants`. Tessera
tiles and edit backups count as variants of their parent.

**G3. Read order separate from write order** (Phase 2). One `priority` drives
both today, so "write to the cloud first, serve from local" is impossible.
`read_order` decides serving among a file's active locations, filtered by role.

**G4. Safe removal of a bucket** (Phase 2). Today, disabling a bucket makes its
objects unreachable once the 5-minute cache expires, while their FileLocations
stay `active` and health still counts them. Deleting a bucket cascades its
location rows and orphans the objects (`v135.ex:4684`). The fix:

- per-profile-bucket `status`: `read_only` stops writes and keeps serving;
  `draining` makes the reconciler copy everything to the remaining buckets,
  verify, and then unlink;
- the bucket FK on `file_locations` becomes RESTRICT, so a bucket that still
  holds locations cannot be deleted;
- the global `enabled` flag becomes an emergency stop, not the way to retire a
  bucket.

**G5. The write rule** (Phase 2). An upload succeeds if **one** bucket accepted
it (`manager.ex:188-222`). Missing copies are filled only when an admin starts
a sync from the Health page. The fix:

- `min_copies_on_write`: the upload fails unless at least this many copies
  succeed;
- the rest are queued automatically to the reconciler, which never waits for a
  person.

**G6. Reconciler bookkeeping** (Phase 2). When a profile changes, or a library
moves to another profile, something has to find the files that are not where
they should be, without rewriting millions of rows. Each file records
`placed_profile_uuid` and `placed_revision`. It is stale when the profile
differs from its library's, or when the revision is older. One reconciler
(§6.3) replaces `SyncFilesJob` and works through stale files in batches.

**G7. Location uniqueness** (Phase 2). `phoenix_kit_file_locations` has no
unique index on `(file_instance_uuid, bucket_uuid)`, only single-column btrees
(`v135.ex:2466-2474`). Duplicate rows are possible today and would confuse
location-based reads. The migration dedupes any existing duplicates, then adds
a UNIQUE index.

**G8. A key prefix per library** (Phase 1 for new files). Keys are
`<storage_default_path>/<first 2 chars of user_uuid>/<hash>/<md5>`
(`storage.ex:4090`). A per-library `key_prefix` is what makes it possible to:

- wipe or export one library from a shared bucket;
- apply S3 lifecycle rules per library;
- scope IAM or bucket policies to a business prefix.

Existing objects keep their keys, since a key is an address recorded on the
instance, not something derived at read time. A file that moves to another
library on the same buckets also keeps its key.

**G9. Usage accounting and capacity** (Phase 2, with quotas in Phase 3). Sizes
live on `file_instances`, and nothing sums them per library or per profile.
Quotas and user-owned storage need a cached usage figure per library and per
profile bucket, updated by the reconciler and on ingest and delete.
`buckets.max_size_mb` exists but selection ignores it. Profiles will skip a
bucket that is over its cap, and the UI will show it as full.

**G10. Room for storage class and encryption** (schema in Phase 2, behaviour
later).

- A storage class per profile bucket (S3 IA or an archive tier). Allowed only
  on `backup` rows, because archive tiers need a restore step before a read.
- Encryption per profile bucket: an SSE-KMS key for business buckets, or
  client-side encryption for user-owned ones.

The columns exist from Phase 2 so that adding them later needs no redesign.

Related pre-existing defects that the same work must fix are in §11: writers
that record no locations, the bucket cache never being invalidated, an unused
default-bucket setting, and `public_url` ignoring custom endpoints.

## 6. Behaviour changes

### 6.1 Placement follows the library's profile

- `select_buckets_for_storage/2` takes a library and resolves its profile. It
  picks buckets with `status = "active"` whose `stores` matches originals or
  variants, fixed `write_priority` first and then the shuffled pool, up to the
  profile's copy count, skipping full buckets (G9).
- A bucket that is not in the profile is never written. In particular, a user
  bucket never receives another library's file.
- Every writer records FileLocations: fix `store_file/2` and
  `store_system_file/3` (children inherit the parent's library), and pin
  `ApplyImageEditJob`'s outputs to the original's library.

### 6.2 Reads, serving and deletes follow FileLocation

This is the load-bearing change. Once buckets differ per library, "try every
enabled bucket by key" is wrong:

- it misses a file that is only in a user bucket;
- it would probe, and on delete *write to*, a bucket that belongs to another
  library's profile.

So `retrieve_file`, `get_file_access`, `public_url` and `delete_file` resolve
through the instance's active FileLocations:

- **serving** goes by role (G1), then `read_order` (G3);
- **repair** may read any role;
- **deleting** touches only buckets that actually hold a location, and only
  keys that no other instance references.

`FileServer.get_file_location/2` already sketches this. For rows with no
locations, the fallback probes **system** buckets only and backfills the
locations it finds. The bucket cache is invalidated on bucket and profile
changes.

### 6.3 Moving bytes: one reconciler

A single job makes each file's locations match its library's profile: copy,
verify, then unlink and delete unreferenced objects (G4, G5, G6). It runs:

- when a file moves to another library, or a library to another profile;
- when a profile or its buckets change (the revision bump);
- after an upload that stored fewer copies than the profile wants;
- on a schedule, as today's health sync does.

A move between libraries that resolve to the **same** profile is a row update
only.

### 6.4 Dedup becomes per library

- `user_file_checksum` is replaced by a library-scoped
  `library_file_checksum = sha256(library_uuid <> file_checksum)`, with a UNIQUE
  index. The same bytes may then exist in a person's Personal and Business
  libraries.
- **Cross-library cloning** (today's cross-user clone) is allowed only when both
  libraries resolve to the same **system** profile. Otherwise the file is
  stored fresh. A clone must never make one library depend on another
  library's buckets.

### 6.5 Access checks become library checks

One predicate, `Storage.Libraries.can?(scope, library, action)`, with actions
`:read | :upload | :edit | :trash | :manage`, replaces the owner-equality checks
in `authorize_file_read/2`, `ImageEditing.allowed?/2` and
`AnnotationBurnController.allowed?/3`. Admin bypass stays on `Scope.system_role?`.

- `MediaBrowser` and `MediaSelectorModal` take a `library_uuid`. For the
  selector, it replaces the `user_uuid` filter.
- **Signed file URLs remain capability URLs** (URLSigner, no user check). That is
  existing design. It is acceptable for system libraries but weak for a
  private user library. §10 lists it as a question rather than changing it here.
- File PubSub events gain `library_uuid`, and ideally a per-library topic. Today
  every subscriber gets every file event on the site.

### 6.6 Capture-date index

Replace V200's `(user_uuid, taken_on DESC, taken_at DESC)` with
`(library_uuid, taken_on DESC, taken_at DESC)` under the same partial predicate.
A cross-library "everything I can see" view is then `library_uuid = ANY($1)`
over a handful of libraries. V200 is already released, so V201 creates the
library index and drops `phoenix_kit_files_capture_date_index`. Nothing in
core queries the old index. Its one consumer, `phoenix_kit_photos`, moves to
the library scope in the same step.

## 7. User-owned storage

User-owned storage is the riskiest part of this plan, and it comes last.

- **S3-compatible buckets only.** A user-supplied `local` bucket would be
  arbitrary filesystem write access on the server.
- **User buckets live only in their owner's profiles.** They are never in the
  Default profile, never probed for another library, and never listed as
  system buckets.
- **Credentials come from a personal integration** (`object_storage`, scope
  `:personal`, which already exists). Fix `S3.resolve_credentials/1` to require
  the integration's owner to be the bucket's owner instead of `owner: :any`.
  Also take region and endpoint from the integration.
- **Endpoint validation (SSRF).** The server connects to whatever endpoint a user
  types. Require `https`, resolve the host, and refuse loopback, private,
  link-local and metadata ranges both at save time and at connect time (DNS can
  change). This is currently missing even for admin buckets.
- **Serving.** Default user buckets to private. Proxying through Phoenix costs
  server bandwidth on every view. Implement the documented but missing
  `"signed"` access type (presigned GET, short expiry) so a user bucket can be
  served by redirect instead.
- **Failure is normal.** Users revoke keys, delete buckets and hit their own
  quotas. The library shows a storage-health state, uploads fail loudly, and
  nothing in a system bucket silently absorbs the writes.
- **Quotas** (G9) apply to user libraries on system buckets. On their own
  buckets, users pay for their own storage.

## 8. Admin UI

### `/admin/media`: a switcher over **system** libraries

The Media section's library switcher lists **system libraries only**. The
default system library holds everything that exists today, so the page looks
exactly as it does now until a second system library is created. User
libraries are not in the switcher. They are the users' own content, not the
site's media, and a site with many users would bury the system ones.

### `/admin/storage/libraries`: user libraries as metadata

Admins still need to know that user libraries exist. That is because of
**system buckets**: a user library on a system profile is stored, and served
from the site's domain, at the operator's expense and under the operator's
responsibility. Takedown requests, abuse, quota disputes, support and GDPR
requests all land with the admin. So this list shows:

- owner, members, profile, file count, size, health and trash state;
- actions: suspend uploads, trash, change quota, move to another profile.

It does **not** browse contents. Opening a user library's files is a separate,
narrower permission (Owner and Admin roles only, per `Scope.system_role?`), and
it is **logged**. Whether admins may open user libraries at all is an open
question (§10).

### `/admin/settings/media`: system buckets and profiles only

The bucket list and the new profiles editor show **system** buckets and
profiles only. User-owned buckets and profiles are managed by their owners
under the user's settings. Admins see them only as a read-only row per
bucket: owner, provider, endpoint **host**, health and the libraries using
it. Credentials are never shown. An admin can disable a user bucket, for
example when an endpoint misbehaves, but cannot edit it.

## 9. Phases

Each phase is a separate release, with its own migration version.

**Phase 1 (V201): libraries as a partition.** This is what `phoenix_kit_photos`
Stage 1 needs, and nothing else.

- Tables `libraries` and `library_members`; `library_uuid` on files and folders.
- Backfill every existing file and folder into one default system library,
  named "Media", which keeps today's behaviour exactly. The column becomes
  NOT NULL after the backfill.
- Library-scoped folder name uniqueness, dedup (§6.4 first bullet), access
  checks (§6.5), the capture-date index (§6.6), and `key_prefix` for new
  uploads (G8).
- The uploader FK moves to SET NULL, with the CHECK relaxed (§3.1).
- V201 is additive except for dropping V200's user-keyed index and the
  `user_file_checksum` unique index, which the library-scoped ones replace.
- `store_file_in_buckets/7` and the upload paths take a library. Default: the
  user's default library if they have one, else the default system library.
- Library CRUD API, and the system-library switcher in `/admin/media` (§8).
- Placement is unchanged in this phase: every library still writes to the
  global pool.

**Phase 2 (V202): profiles and placement.**

- `storage_profiles` and `storage_profile_buckets`, the Default profile (§4),
  and the file placement columns.
- G1–G7, G9 (usage and capacity), and the G10 columns.
- Location-based reads and deletes (§6.2) and the reconciler (§6.3).
- The profiles editor and `/admin/storage/libraries` (§8).
- The pre-existing defects in §11 that sit on this path.

**Phase 3 (V203): user-owned storage.** Everything in §7, plus quotas (G9).

## 10. Open questions for the maintainer

1. **Default library for existing files.** One system "Media" library (this
   plan), or split existing files into each uploader's personal library? One
   library preserves today's behaviour. A split is what a photos user would
   expect, but it changes what `/admin/media` shows.
2. **Who may create user libraries?** Everyone, a role key, or a setting? Is
   there a per-user limit?
3. **May admins open user libraries?** This plan proposes metadata for
   admins, and logged content access for Owner and Admin only. The
   alternative is no content access at all, with takedown by file uuid only.
4. **Capability URLs for private user libraries.** Keep the permanent 4-char
   tokens, or add expiring signed URLs for libraries marked private?
5. **One word in the UI.** Is it "library" everywhere, or "vault" in Fotki's
   copy? Core should use "library" either way.

## 11. Existing bugs found while researching this (independent of the plan)

- `list_files(bucket_uuid: …)` filters on `f.bucket_uuid`, which does not exist
  (`storage.ex:4672`). It raises if used.
- `phoenix_kit_media_folders_user_uuid_fkey` has no ON DELETE (`v135.ex:8576`).
  Deleting a user who ever created a folder should fail with an FK violation.
  Not verified at runtime.
- `anonymize_user_files` updates a column that does not exist, and the error is
  swallowed (`auth.ex:3837`).
- `delete_user` leaves the deleted user's bucket objects behind.
- `store_file/2` and `store_system_file/3` record no FileLocations
  (`storage.ex:3283, 2282`). `ApplyImageEditJob` writes outputs unpinned from
  the original's buckets (`apply_image_edit_job.ex:232, 299`).
- The bucket cache (`manager.ex:291`) is never invalidated; bucket edits take up
  to 5 minutes to apply.
- `storage_default_bucket_uuid` is configurable but unused.
- `public_url` ignores a custom S3 `endpoint`. `access_type: "signed"` is
  documented but falls through to a public redirect.
- `S3.resolve_credentials/1` does not check integration ownership.
