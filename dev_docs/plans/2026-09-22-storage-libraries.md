# Storage libraries: partition files into libraries, each with its own members and storage

**Created:** 2026-09-22
**Revised:** 2026-09-23, after the Grok review
(`dev_docs/reviews/2026-09-23-storage-libraries/`). The phases went from three
to five. V201 is smaller. Private serving moved ahead of user libraries, and
location-truth moved ahead of storage profiles. Four gaps were added
(G11–G14), and G3 and G8 were corrected. Later the same day, **variant sets**
(per-library image and video sizes, §3.4, G15–G19) were added to V204, so they
ship in the same release as storage profiles.
**Status:** PROPOSAL, not started. Open questions for the maintainer are at the end.
**Scope:** phoenix_kit (core), Storage module, in five releases (V201–V205).
First consumer: `phoenix_kit_photos`.
**Related:** `PhoenixKit.Modules.Storage.CaptureDate` and V200 (the capture-date
index this plan re-keys); `phoenix_kit_photos` plans
`2026-09-21-phoenix-kit-photos.md` and `2026-09-22-roadmap-after-stage-0.md`.

Line numbers below are as of commit `fb393135` (2.37.4). V200 is released, so
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
  `endpoint` (`s3.ex:81-87`).
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
  may change their size, format, quality and crop, but not drop or rename
  them. Custom names (for example `grid_2x`) come on top.
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

- file URLs carry an **expiring** signed token, bound to the file, the variant
  and an expiry, with a real HMAC rather than a 4-character MD5 prefix. The
  page that renders the file mints it after an access check (§6.5).
  `show/2` rejects the legacy token for these files;
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

It does **not** browse contents. Opening a user library's files is a separate,
narrower permission (Owner and Admin roles only, per `Scope.system_role?`), and
it is **logged**. Whether admins may open user libraries at all is an open
question (§10).

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
- The dedup key swap (§6.4).
- `/admin/storage/libraries` (§8).
- Placement is still the global pool. User libraries live on the system
  buckets.

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

## 10. Open questions for the maintainer

1. **Default library for existing files.** One system "Media" library (this
   plan), or split existing files into each uploader's personal library? One
   library preserves today's behaviour. A split is what a photos user would
   expect, but it changes what `/admin/media` shows. With V201 as it now
   stands, a split could only happen in V202 or later, when user libraries and
   private serving exist.
2. **Who may create user libraries?** Everyone, a role key, or a setting? Is
   there a per-user limit?
3. **May admins open user libraries?** This plan proposes metadata for
   admins, and logged content access for Owner and Admin only. The
   alternative is no content access at all, with takedown by file uuid only.
4. **Token format for private files.** A signed `Phoenix.Token` with an expiry
   (simple, and the page re-mints it on render), or presigned-only serving?
   Also, how long should the expiry be for a photo grid that stays open for
   hours?
5. **Standard slots.** Are `thumbnail`, `small`, `medium`, `large` and
   `video_thumbnail` the right required set? Should `small` be guaranteed
   aspect-preserving, since grids depend on it?
6. **One word in the UI.** Is it "library" everywhere, or "vault" in Fotki's
   copy? Core should use "library" either way.

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
  documented but falls through to a public redirect.
- `S3.resolve_credentials/1` does not check integration ownership, and
  `aws_config/1` does not normalize the endpoint the way the integration
  validator does.
