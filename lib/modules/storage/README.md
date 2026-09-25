# PhoenixKit Storage System Specification

**Version:** 1.0
**Created:** 2025-10-28
**Status:** Planning Phase

## Overview

Comprehensive distributed file storage system for PhoenixKit with multi-location redundancy, automatic variant generation, smart volume selection, and secure URL serving.

---

## Architecture

### Database Schema (5 Tables with UUIDv7)

#### 1. phoenix_kit_buckets
Storage provider configurations (local disk, AWS S3, Backblaze B2, Cloudflare R2)

```elixir
- id (uuid_v7, PK)
- name (string, required) - Display name
- provider (string, required) - "local", "s3", "b2", "r2"
- region (string, nullable) - AWS region or equivalent
- endpoint (string, nullable) - Custom S3-compatible endpoint
- bucket_name (string, nullable) - S3 bucket name
- access_key_id (string, nullable) - Credentials identifier, not a secret — not encrypted
- secret_access_key (string, nullable) - Encrypted at rest
- integration_uuid (uuid, nullable, no FK) - Alternative credential source (a PhoenixKit.Integrations connection); mutually exclusive with access_key_id/secret_access_key
- cdn_url (string, nullable) - CDN endpoint for file serving
- path_prefix (string, nullable) - Base path for files
- enabled (boolean, default: true)
- priority (integer, default: 0) - 0 = random/emptiest, >0 = specific priority
- max_size_mb (integer, nullable) - Maximum storage capacity
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_buckets_enabled` on `enabled`
- `idx_buckets_provider` on `provider`

---

#### 2. phoenix_kit_files
Original file uploads with metadata

```elixir
- id (uuid_v7, PK)
- original_file_name (string, required) - User's original filename
- file_name (string, required) - System filename (uuid_v7-original.ext)
- mime_type (string, required) - image/jpeg, video/mp4, etc.
- file_type (string, required) - "image", "video", "document", "archive"
- ext (string, required) - jpg, mp4, pdf, etc.
- checksum (string, required) - MD5 or SHA256 hash
- size (integer, required) - File size in bytes
- width (integer, nullable) - Image/video width in pixels
- height (integer, nullable) - Image/video height in pixels
- duration (integer, nullable) - Video duration in seconds
- status (string, required) - "processing", "active", "failed"
- metadata (jsonb, nullable) - EXIF, codec info, etc.
- data (jsonb, default {}) - title / alt / description per language (V199)
- taken_at (timestamptz, nullable) - when the photo/video was taken, UTC (V200)
- taken_on (date, nullable) - the LOCAL date it was taken; what a library groups by (V200)
- taken_at_offset (integer, nullable) - seconds east of UTC, when known (V200)
- taken_at_source (string, nullable) - manual / exif / container / filename / inserted_at (V200)
- user_uuid (uuid_v7, FK -> phoenix_kit_users.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_files_user_uuid` on `user_uuid`
- `idx_files_file_type` on `file_type`
- `idx_files_status` on `status`
- `idx_files_inserted_at` on `inserted_at`
- `phoenix_kit_files_capture_date_index` on `(user_uuid, taken_on DESC, taken_at DESC)`,
  partial over a user's visible, processed images and videos (V200)

**Foreign Keys:**
- `user_uuid` references `phoenix_kit_users(uuid)` ON DELETE CASCADE

---

#### 3. phoenix_kit_file_instances
File variants (thumbnails, resizes, video qualities)

```elixir
- id (uuid_v7, PK)
- variant_name (string, required) - "original", "thumbnail", "medium", "large", "720p", "1080p"
- file_name (string, required) - System filename (uuid_v7-variant.ext)
- mime_type (string, required)
- ext (string, required)
- checksum (string, required)
- size (integer, required) - Variant file size in bytes
- width (integer, nullable)
- height (integer, nullable)
- processing_status (string, required) - "pending", "processing", "completed", "failed"
- file_uuid (uuid_v7, FK -> phoenix_kit_files.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_file_instances_file_uuid` on `file_uuid`
- `idx_file_instances_variant_name` on `variant_name`
- `idx_file_instances_processing_status` on `processing_status`

**Foreign Keys:**
- `file_uuid` references `phoenix_kit_files(uuid)` ON DELETE CASCADE

**Unique Constraint:**
- `unique_file_variant` on `(file_uuid, variant_name)`

---

#### 4. phoenix_kit_file_locations
Physical storage locations (redundancy tracking)

```elixir
- id (uuid_v7, PK)
- path (string, required) - Full path within bucket
- status (string, required) - "active", "syncing", "failed", "deleted"
- priority (integer, default: 0) - Location priority for retrieval
- last_verified_at (timestamp, nullable) - Last health check
- file_instance_uuid (uuid_v7, FK -> phoenix_kit_file_instances.uuid)
- bucket_uuid (uuid_v7, FK -> phoenix_kit_buckets.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_file_locations_file_instance_uuid` on `file_instance_uuid`
- `idx_file_locations_bucket_uuid` on `bucket_uuid`
- `idx_file_locations_status` on `status`

**Foreign Keys:**
- `file_instance_uuid` references `phoenix_kit_file_instances(uuid)` ON DELETE CASCADE
- `bucket_uuid` references `phoenix_kit_buckets(uuid)` ON DELETE CASCADE

---

#### 5. phoenix_kit_storage_dimensions
Admin-configurable dimension presets for variant generation

```elixir
- id (uuid_v7, PK)
- name (string, required) - "thumbnail", "medium", "large", "720p", "1080p"
- width (integer, nullable) - Target width in pixels
- height (integer, nullable) - Target height in pixels
- quality (integer, default: 85) - Compression quality 1-100
- format (string, nullable) - "jpg", "webp", "png", null = keep original
- applies_to (string, required) - "image", "video", "both"
- enabled (boolean, default: true)
- order (integer, default: 0) - Display order in admin
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_dimensions_enabled` on `enabled`
- `idx_dimensions_order` on `order`

**Unique Constraint:**
- `unique_dimension_name` on `name`

**Default Seeded Dimensions (8 total):**

The V18 migration will seed the following default dimensions:

```elixir
# Image Dimensions (4)
%{
  name: "thumbnail",
  width: 150,
  height: 150,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 1
}

%{
  name: "small",
  width: 300,
  height: 300,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 2
}

%{
  name: "medium",
  width: 800,
  height: 600,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 3
}

%{
  name: "large",
  width: 1920,
  height: 1080,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 4
}

# Video Quality Dimensions (3)
%{
  name: "360p",
  width: 640,
  height: 360,
  quality: 28,  # CRF value for FFmpeg video encoding
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 5
}

%{
  name: "720p",
  width: 1280,
  height: 720,
  quality: 28,
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 6
}

%{
  name: "1080p",
  width: 1920,
  height: 1080,
  quality: 28,
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 7
}

# Video Thumbnail (1)
%{
  name: "video_thumbnail",
  width: 640,
  height: 360,
  quality: 85,
  format: "jpg",
  applies_to: "video",
  enabled: true,
  order: 8
}
```

**Default Seeded Bucket:**

The V18 migration will seed one default local storage bucket:

```elixir
%{
  name: "Local Storage",
  provider: "local",
  region: nil,
  endpoint: nil,
  bucket_name: nil,
  access_key_id: nil,
  secret_access_key: nil,
  cdn_url: nil,
  path_prefix: nil,  # Uses storage_default_path setting from existing system
  enabled: true,
  priority: 0,       # Random selection, prefer emptiest drive
  max_size_mb: nil   # Unlimited (will use all available disk space)
}
```

**Default Seeded Settings:**

The V18 migration will add 3 new settings:

```elixir
%{key: "storage_redundancy_copies", value: "1"}           # Store files on 2 buckets
%{key: "storage_auto_generate_variants", value: "true"}  # Auto-generate thumbnails/resizes
%{key: "storage_default_bucket_id", value: nil}          # No default bucket (use selection algorithm)
```

---

## File Type Support

| Type | Extensions | Scalable? | Variants Generated | Processing |
|------|-----------|-----------|-------------------|------------|
| **Image** | jpg, jpeg, png, webp, gif, heic | ✅ Yes | All enabled image dimensions | Mogrify/Vips |
| **Video** | mp4, webm, mov, avi, mkv | ✅ Yes | Quality variants + thumbnail | FFmpeg |
| **Document** | pdf, doc, docx, txt, md | ❌ No | Original only | Metadata extraction |
| **Archive** | zip, rar, 7z, tar, gz | ❌ No | Original only | None |

---

## Storage Logic

### Directory Structure
All instances stored **next to original** in same directory:

```
/bucket/path/
  018e3c4a-9f6b-7890-original.jpg
  018e3c4a-9f6b-7890-thumbnail.jpg
  018e3c4a-9f6b-7890-medium.jpg
  018e3c4a-9f6b-7890-large.jpg
```

### Redundancy
- Setting: `storage_redundancy_copies` (integer, 1-5, default: 1)
- Each file + all variants replicated across N buckets
- Example: redundancy = 2, file stored on 2 different buckets

### Smart Volume Selection (Priority System)

**Algorithm:**
1. Get `storage_redundancy_copies` setting (e.g., 2)
2. Query all enabled buckets
3. Separate buckets:
   - **Priority buckets** (priority > 0) → sorted by priority ASC
   - **Random buckets** (priority = 0) → sorted by free space DESC
4. Select buckets:
   - Take priority buckets first (in priority order)
   - Fill remaining slots with emptiest random buckets
5. Upload file + all variants to selected buckets

**Priority Values:**
- `priority = 0` (default): Random selection, prefer most empty drive
- `priority > 0`: Specific priority (1 = highest priority, 2 = second, etc.)

**Free Space Calculation:**
```elixir
free_space = bucket.max_size_mb - sum(all file sizes in bucket)
```

**Example with 5 buckets, redundancy = 2:**
- Bucket A: Local SSD (priority 0, 500GB free)
- Bucket B: AWS S3 (priority 0, 200GB free)
- Bucket C: Backblaze B2 (priority 1)
- Bucket D: Cloudflare R2 (priority 0, 800GB free)
- Bucket E: Local HDD (priority 2)

**Selection Result:** C (priority 1), E (priority 2)
**If no priority buckets:** D (800GB free), A (500GB free)

---

## URL Structure & Security

### URL Format
```
https://site.com/file/{uuid_v7}/{instance_name}/{token}
```

### Example
```
https://site.com/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/a3f2
```

### Token Generation
```elixir
# Token = first 4 chars of MD5(file_id:instance_name + secret_key_base)
data = "#{file_id}:#{instance_name}"
secret = Application.get_env(:phoenix_kit, :secret_key_base)
token = :crypto.hash(:md5, data <> secret)
        |> Base.encode16(case: :lower)
        |> String.slice(0..3)
```

### Security Benefits
- ✅ Prevents file enumeration (can't guess URLs)
- ✅ Each instance has unique token
- ✅ Token changes if secret changes
- ✅ Secure comparison prevents timing attacks
- ✅ No user-guessable patterns

### Versions and caching

A file URL may carry `?v=` — the first 16 hex characters of the served
instance's checksum (`URLSigner.signed_url(uuid, variant, version: instance)`,
`URLSigner.version/1`). Build URLs with it wherever the instance is at hand.

| Request | Response |
|---|---|
| `v` names the bytes the variant holds now (any hex prefix of 8+ characters) | `public, max-age=31536000, immutable` |
| `v` names other bytes | `302` to the current `v`, `no-store` |
| no `v`, file never edited | `public, max-age=86400` + ETag |
| no `v`, file edited before | `public, no-cache` + ETag (revalidated on every use) |
| variant not generated yet (the original stands in) | `no-store`, `x-variant-status: pending` |
| an image edit is rendering, or failed | a grey SVG placeholder, `no-store` (also `cdn-cache-control`), `x-variant-status: editing` / `edit-failed` |
| a system-managed file (tile chunk, an edited image's unedited original) | `404` |

Deep-zoom tiles carry the version in the path, because the viewer derives
tile URLs from the manifest's path and drops its query:
`/tiles/<token>/<uuid>-<v>.dzi` and `/tiles/<token>/<uuid>-<v>_files/<level>/<col>_<row>.<ext>`,
stored under `_tiles/<uuid>/<v>/`. A version that is not the current one is
a 404. The legacy `/tiles/<token>/<uuid>.dzi` resolves to the current version
and is never cached.

---

## Title, alt text and description (translatable)

A file's title, alt text and description are read and written through
`PhoenixKit.Modules.Storage.FileDetails` — never by reaching into `data` or
`metadata` directly:

```elixir
Storage.translated_alt(file, locale)          # "" when none — never the file name
Storage.translated_title(file, locale)        # nil when none
Storage.translated_description(file, locale)

Storage.translated_alts(uuids, locale)        # %{uuid => alt}, one query — for list pages
Storage.translated_alt_by_uuid(uuid, locale)

Storage.change_file_details(file, %{}, lang: "et")              # an editor tab's changeset
Storage.update_file_details(file, params, lang: "et")           # replaces that language only
```

The text lives in the `data` column, one entry per language:
`%{"en-US" => %{"title" => …, "alt" => …}, "et" => %{…}}`. Every language
holds its own text and **none is marked as primary**, so changing the site's
primary language converts nothing. Each field resolves when it is read: the
language asked for (or a dialect of it) → the site's current primary language
→ any other language. Resolving many files? Pass `primary:` once instead of
letting every call read the setting.

The editors (the media detail page, the viewer sidebar) have no language
tabs: they edit the language the page is shown in
(`FileDetails.content_language(locale)`), so the admin language switcher is
the content switcher.

This is deliberately not the `PhoenixKit.Utils.Multilang` structure (diffs
against an embedded primary): for three fields it buys nothing and ties the
stored text to a setting that can change.

A file saved before V199 has its title and description in `metadata`; while
its `data` is empty that text is read as the primary language's, and the
first save moves it into `data`. After that `metadata` only receives a copy
of the primary-language text, for the readers that still look there.

## Libraries

Every file, media folder and folder link belongs to one **library**
(`library_uuid`, V202), a partition of the file store. Everything that existed
before V202 is in **Media**, the default system library, which has a fixed uuid
(`Storage.Libraries.media_uuid/0`). Media is also the column default, so any
writer that names no library, core's or a module's, lands there. System
libraries are created, renamed and deleted (when empty) in Settings → Media →
Libraries; `/admin/media` shows a switcher once a second one exists. Media is the bare `/admin/media`; any other library is
`/admin/media/library/<slug>`, where the slug comes from its name and is kept
when it is renamed (`Libraries.get_system_library_by_slug/1`).

- **Store into a library:** `Storage.store_file_in_buckets(..., library_uuid: uuid)`.
  A library with a `key_prefix` keys new objects under it
  (`{key_prefix}/{hash[0..1]}/{hash}/…`); Media has none and keeps the
  per-uploader layout (`{user_uuid[0..1]}/{hash[0..1]}/{hash}/…`).
- **Folders:** a root folder takes the library its attrs name (default Media),
  and a subfolder always takes its parent's. Folder names are unique per library
  and parent.
- **Nothing crosses libraries:** attaching, linking or moving a file into
  another library's folder, or moving a folder under another library's parent,
  returns `{:error, :other_library}`. A folder link carries its file's library,
  and the database refuses one that does not.
- **Listing one library:** the root-level listing, search, orphan and trash
  functions take `library_uuid:`. Without it they list every library, exactly
  as before.
- **Access:** `Storage.Libraries.can?(scope, file, :read | :edit)` is the
  single per-file check: the uploader, an Owner/Admin, the `"media"` key
  (edit, system libraries only), and a user library's owner and members.
- **Dedup is per library:** one copy per uploader per library. Media keeps
  the key it always had; any other library folds itself into
  `user_file_checksum` (`Storage.calculate_user_file_checksum/3`).

### User libraries (V203)

Off until the install turns them on (`storage_user_libraries_enabled`,
Settings → Media → Libraries). A user with the `"storage"` permission uses
the libraries they own or are a member of; `"storage.create_library"`
creates them, up to `storage_user_library_limit`. Each is `private`, and its
members are `manager`, `contributor` or `viewer` (`Libraries.allows?/2`).

- **API:** `Libraries.create_user_library/2`, `list_user_libraries/1`,
  `get_user_library/2` (by uuid, or the owner's own slug), `add_member/4`,
  `update_member_role/4`, `remove_member/3`, `trash_library/2`,
  `set_default_library/2`, `default_user_library/1`. Each checks the
  caller's role itself.
- **Pages:** users manage their libraries on the profile's Media tab
  (`/profile/settings/media`); `/admin/libraries` browses them (moderation
  and testing). `phoenix_kit_photos` is the end-user surface.
- **Trash and deletion:** a trashed library frees its name at once and is
  purged, bytes included, after `trash_retention_days` (`PurgeLibraryJob`,
  queued by the daily prune). Deleting a user trashes the libraries they own
  first (the database refuses otherwise, V203), and keeps their uploads
  elsewhere with no uploader.
- **Admins:** an Owner or Admin can open a user's library at
  `/admin/libraries/<uuid>`; every opening is audit-logged
  (`storage.library_opened`).

### Private files

A file in a private library (every user library) is served only with a
**time-window token**: an HMAC over the file, the variant and an expiry
rounded up to a window (`storage_private_url_window_hours`, default 12). The
file and tile routes refuse its permanent token, answer an expired one with
403, never redirect to a public object URL, and send `private` cache headers
(`private, max-age=3600`, tiles included). `get_public_url*` does not return
a bucket's object URL for one.

- ⚠️ **Mint a private file's URL after an access check:**
  `Storage.authorized_url(scope, file, variant)` checks
  `can?(scope, file, :read)` and mints the right token. The other URL helpers
  (`get_public_url*`, `list_image_set_variants*`) mint the permanent token,
  which a private file refuses: they fail closed.
- Building URLs by hand: `URLSigner.signed_url(uuid, variant, private: true)`,
  with `Libraries.private_file?/1`, or `Libraries.private_among/1` for a batch.
- ⚠️ **A `MediaBrowser` given a `library_uuid` refuses any event that names a
  file or folder of another library.** A host embedding it for a user
  library relies on that: the scope-folder check alone admits everything.

## When a photo or video was taken

`PhoenixKit.Modules.Storage.CaptureDate` reads it; four columns hold it
(V200). `taken_on` is the **local date** and is what to group by: a photo
taken at 23:00 on 31 July in California is a July photo, although it is
already 1 August in UTC, so grouping on `taken_at` files it under the wrong
month. `taken_at` is the UTC instant — exact when the offset is known, the
local time stored as UTC when it is not (most EXIF has no offset), which
still orders a library correctly.

Where a date comes from, strongest first (`taken_at_source`):

1. `manual` — set by a person; never replaced automatically
2. `exif` (images: `DateTimeOriginal`, else `DateTimeDigitized`, with their
   offset tags) and `container` (video: QuickTime's creation date, which
   keeps the local time and offset, else `creation_time`, UTC)
3. `filename` — `IMG_20180701_120000.jpg`, `PXL_20240315_081100123.jpg`,
   `2018-07-01 12.34.56.jpg`, …
4. `inserted_at` — the upload time; every file has one, so every image and
   video resolves to *some* date

A file's modification time is not a source: stored originals live on disk or
in object storage, where it is the upload time.

**Who writes it.** `ProcessFileJob` dates each new upload from the bytes it
already downloads for the dimensions, in the same guarded transaction.
`Storage.Workers.CaptureDateBackfillJob` dates files stored before V200:

```elixir
CaptureDateBackfillJob.enqueue()        # a pass in the background (file_processing queue)
CaptureDateBackfillJob.pending_count()  # images and videos still without a date
```

```bash
mix phoenix_kit.storage.backfill_capture_dates   # a pass in the foreground, with progress
```

**Never downgraded.** An image edit keeps only the ICC profile, so an edited
original has no EXIF, and re-reading it finds the file name or the upload
time at best. Every automatic writer goes through `CaptureDate.replace?/2`: a
date is replaced only by one from an equally strong or stronger source, and a
manual date never. An edited image is dated from its unedited backup
(`original_file_uuid`) instead of its own bytes.

**Needs** ImageMagick's `identify` for images (already required) and `ffprobe`
for video. Without `ffprobe` a video falls back to its file name or upload
time — the same degradation its dimensions and duration already have.

## Editing images

`PhoenixKit.Modules.Storage.ImageEditing` edits a stored image after upload:
crop, quarter turns, mirroring, straightening, redaction (blur, pixelate,
black box), brightness and contrast. The edit is data
(`PhoenixKit.Modules.Storage.ImageEdit`, stored in `files.edits`), always
applied to the unedited original by `ApplyImageEditJob` with ImageMagick. The
UI is `PhoenixKitWeb.Components.ImageEditor`.

**The file keeps its uuid.** Its `"original"` instance becomes the edited
bytes, so every module that stored the uuid shows the edit, and every reader
of the original (variants, tiles, downloads, public URLs) gets it without
knowing. Object keys are content-addressed, so the edited bytes get new keys.

**The unedited original is not destroyed** (setting
`storage_image_edit_mode`, default `keep_original`). Its instance rows move
to a hidden child file — `system_managed`, `file_name: "unedited-original"`,
`parent_file_uuid` = the file, `files.original_file_uuid` points at it — that
is never listed, never a dedup target and never served by the public routes.
Whoever may edit the image can download it
(`GET /api/files/:uuid/unedited`), restore it, or delete it, which bakes the
edit in. With `replace_original`, every save bakes immediately.

**The unedited original leaves the keys it was served under.** On a public
bucket a file's objects are reachable as plain bucket URLs (the file routes
redirect to them), so bytes left at those keys would survive a redaction
behind any saved link. The first edit therefore copies every unedited object
to a private key (`unedited_<128 random bits>_<name>`, same directory), points
the backup's rows and locations at the copies, and deletes the served keys
once nothing references them. A key another file still references (a
cross-user copy of the same bytes) is that file's and stays. A backup made
before this (2.28.0) moves on its next edit; a revert brings the copies back
as the file's keys, and the next edit copies them again.

**What an edit cannot take back:** copies already made of a response. A
versioned file URL is served `immutable`, so a browser or CDN that fetched
the unredacted image keeps it until its own cache expires. If you front
files with a CDN and redact, purge it: `[:phoenix_kit, :storage,
:file_edited]` telemetry fires after each swap with the `file_uuid` and the
`removed_keys`.

**While an edit renders** (`edit_state: "pending"`) **or after it failed**
(`"failed"`), every variant of the file is served as a placeholder: a
half-applied redaction must never show what it hides. Retry from the editor
or with `ImageEditing.retry/2`.

**Concurrency.** Saving bumps `edit_revision`. Every step of the job checks
it: a render for an older revision is thrown away, a revision already
published is not published twice, and a failure marks only its own revision.
Variant and dimension results are recorded only while the original they were
made from is still the file's (`Storage.original_key?/2`).

**Deleting stored objects.** An object is deleted exactly when no instance
row references its key any more (an edited file and its backup share a
directory; cross-user copies share keys). `Storage.delete_stored_objects/2`
re-checks the references under the directory's advisory lock and deletes
inside it; publishing a new object takes the same lock and checks the object
still exists. Never delete a stored object any other way.

**Annotations** are drawn in pixel space, so an image with annotations
refuses edits that change its geometry (crop, turn, mirror, straighten);
redaction and tone changes are fine, and "save as copy" always is. An edit
that changes the geometry also clears avatar crops made on the image.

**Not editable:** GIFs and other animated images, system-managed files,
trashed files, and formats ImageMagick cannot write back.

---

## Settings

New settings added in V18 migration:

```elixir
storage_redundancy_copies: "1"           # How many bucket copies (1-5)
storage_auto_generate_variants: "true"   # Auto-generate thumbnails/resizes
storage_default_bucket_id: nil           # Default bucket for uploads (optional)
```

**Access in code:**
```elixir
PhoenixKit.Settings.get_setting("storage_redundancy_copies", "1")
```

---

## Data Flow Example

**User uploads profile.jpg (2000x2000 JPEG):**

### 1. Upload
```
POST /api/upload
Content-Type: multipart/form-data
```

### 2. Create File Record
```elixir
%PhoenixKit.Storage.File{
  id: "018e3c4a-9f6b-7890-abcd-ef1234567890",  # UUIDv7
  original_file_name: "profile.jpg",
  file_name: "018e3c4a-9f6b-7890-original.jpg",
  mime_type: "image/jpeg",
  file_type: "image",
  ext: "jpg",
  checksum: "abc123def456...",
  size: 524_288,  # 512 KB
  width: 2000,
  height: 2000,
  status: "processing",
  user_id: "018e1234-5678-..."
}
```

### 3. Queue Background Job
```elixir
Oban.insert(ProcessFileJob.new(%{file_id: "018e3c4a-..."}))
```

### 4. Generate Variants (4 enabled dimensions)
```elixir
# Original (no resize)
%FileInstance{
  variant_name: "original",
  file_name: "018e3c4a-9f6b-7890-original.jpg",
  size: 524_288,
  width: 2000,
  height: 2000,
  processing_status: "completed"
}

# Thumbnail (150x150)
%FileInstance{
  variant_name: "thumbnail",
  file_name: "018e3c4a-9f6b-7890-thumbnail.jpg",
  size: 8_192,
  width: 150,
  height: 150,
  processing_status: "completed"
}

# Medium (800x800)
%FileInstance{
  variant_name: "medium",
  file_name: "018e3c4a-9f6b-7890-medium.jpg",
  size: 102_400,
  width: 800,
  height: 800,
  processing_status: "completed"
}

# Large (1920x1920)
%FileInstance{
  variant_name: "large",
  file_name: "018e3c4a-9f6b-7890-large.jpg",
  size: 262_144,
  width: 1920,
  height: 1920,
  processing_status: "completed"
}
```

### 5. Select Buckets (redundancy = 2)
```elixir
# Priority buckets available: B2 (priority 1), R2 (priority 2)
selected_buckets = [
  %Bucket{name: "Backblaze B2", priority: 1},
  %Bucket{name: "Cloudflare R2", priority: 2}
]
```

### 6. Upload to Storage
Each bucket receives all 4 instances:

```
Backblaze B2:
  /path/018e3c4a-9f6b-7890-original.jpg
  /path/018e3c4a-9f6b-7890-thumbnail.jpg
  /path/018e3c4a-9f6b-7890-medium.jpg
  /path/018e3c4a-9f6b-7890-large.jpg

Cloudflare R2:
  /path/018e3c4a-9f6b-7890-original.jpg
  /path/018e3c4a-9f6b-7890-thumbnail.jpg
  /path/018e3c4a-9f6b-7890-medium.jpg
  /path/018e3c4a-9f6b-7890-large.jpg
```

### 7. Create Location Records (8 total)
4 instances × 2 buckets = 8 location records

```elixir
%FileLocation{path: "/path/018e3c4a-...-original.jpg", bucket_id: b2_id, instance_id: orig_id}
%FileLocation{path: "/path/018e3c4a-...-thumbnail.jpg", bucket_id: b2_id, instance_id: thumb_id}
%FileLocation{path: "/path/018e3c4a-...-medium.jpg", bucket_id: b2_id, instance_id: med_id}
%FileLocation{path: "/path/018e3c4a-...-large.jpg", bucket_id: b2_id, instance_id: large_id}
# ... 4 more for R2
```

### 8. Update Status
```elixir
File.update(file, %{status: "active"})
```

### 9. Generate Signed URLs
```elixir
PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "thumbnail")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "medium")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/b7e5"

PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "large")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/large/c2d9"
```

---

## Implementation Phases

### Phase 1: Database Foundation (Current Session)

**Deliverables:**
- ✅ Add `{:uuidv7, "~> 1.0"}` dependency to `mix.exs`
- ✅ Create migration V19 with all 5 tables
- ✅ Seed default dimensions (thumbnail, small, medium, large, 720p, 1080p)
- ✅ Seed default local bucket (priority 0)
- ✅ Add storage settings (redundancy_copies, auto_generate_variants)
- ✅ Create 5 Ecto schemas with UUIDv7 support
- ✅ Create `PhoenixKit.Storage` context module:
  - CRUD operations for all entities
  - Smart bucket selection with priority system
  - Free space calculation for random buckets
  - URL generation helpers
  - Token signing functions
- ✅ Create `PhoenixKit.Storage.URLSigner` module
- ✅ Test compilation

**Files to Create:**
1. `lib/phoenix_kit/migrations/postgres/v19.ex`
2. `lib/phoenix_kit/storage.ex`
3. `lib/phoenix_kit/storage/bucket.ex`
4. `lib/phoenix_kit/storage/file.ex`
5. `lib/phoenix_kit/storage/file_instance.ex`
6. `lib/phoenix_kit/storage/file_location.ex`
7. `lib/phoenix_kit/storage/dimension.ex`
8. `lib/phoenix_kit/storage/url_signer.ex`

**Files to Modify:**
1. `mix.exs` - Add ecto_uuidv7 dependency

---

### Phase 2: Admin UI (Next Session)

**Deliverables:**

#### Buckets/Volumes Management
- Location: `/admin/settings/storage/buckets`
- Features:
  - List all storage buckets/volumes
  - Add new bucket with provider dropdown (local, s3, b2, r2)
  - Edit bucket configuration (name, credentials, endpoint, priority, max size)
  - Delete bucket with safety checks
  - Enable/disable buckets
  - Show usage statistics (used space, free space)
  - Test connection button
  - Provider badges: [Local] [S3] [B2] [R2]

**Files to Create:**
1. `lib/phoenix_kit_web/live/settings/storage/buckets.ex`
2. `lib/phoenix_kit_web/live/settings/storage/buckets.html.heex`
3. `lib/phoenix_kit_web/live/settings/storage/bucket_form.ex`
4. `lib/phoenix_kit_web/live/settings/storage/bucket_form.html.heex`

#### Dimensions Management
- Location: `/admin/settings/storage/dimensions`
- Features:
  - List all dimension presets
  - Add new dimension (name, width, height, quality, format)
  - Edit dimension presets
  - Delete custom dimensions (protect seeded defaults)
  - Enable/disable dimensions
  - Set applies_to (image, video, both)
  - Drag-to-reorder dimensions

**Files to Create:**
1. `lib/phoenix_kit_web/live/settings/storage/dimensions.ex`
2. `lib/phoenix_kit_web/live/settings/storage/dimensions.html.heex`
3. `lib/phoenix_kit_web/live/settings/storage/dimension_form.ex`
4. `lib/phoenix_kit_web/live/settings/storage/dimension_form.html.heex`

#### Updated Storage Settings
- Location: `/admin/settings/storage` (existing page)
- Add redundancy copies selector (1-5)
- Add auto-generate variants toggle
- Add default bucket selector dropdown
- Keep existing path configuration

**Files to Modify:**
1. `lib/phoenix_kit_web/live/settings/storage.ex`
2. `lib/phoenix_kit_web/live/settings/storage.html.heex`

---

### Phase 3: File Upload & Processing (Future)

**Deliverables:**

#### Upload Controller
- Route: `POST /api/upload`
- Features:
  - Handle multipart file uploads
  - Validate file type and size
  - Generate unique filename with UUIDv7
  - Calculate checksum (MD5 or SHA256)
  - Detect MIME type and extract metadata
  - Create `phoenix_kit_files` record
  - Queue background processing job

**Files to Create:**
1. `lib/phoenix_kit_web/controllers/upload_controller.ex`
2. `lib/phoenix_kit/storage/upload.ex` - Upload handling logic

#### Background Processing (Oban)
- **Image Processing** (Mogrify/Vips):
  - Generate variants for enabled dimensions
  - Optimize images (compression, format conversion)
  - Extract EXIF data (width, height, orientation)
- **Video Processing** (FFmpeg):
  - Generate quality variants (720p, 1080p)
  - Extract video thumbnail (frame at 1 second)
  - Extract metadata (duration, resolution, codec)
- **Document Processing**:
  - Extract metadata (page count, author, etc.)
  - No variant generation
- **Storage Distribution**:
  - Select buckets using priority system
  - Upload original + variants to all selected buckets
  - Create `phoenix_kit_file_instances` records
  - Create `phoenix_kit_file_locations` records

**Files to Create:**
1. `lib/phoenix_kit/storage/workers/process_file_job.ex`
2. `lib/phoenix_kit/storage/processors/image_processor.ex`
3. `lib/phoenix_kit/storage/processors/video_processor.ex`
4. `lib/phoenix_kit/storage/processors/document_processor.ex`
5. `lib/phoenix_kit/storage/uploaders/local_uploader.ex`
6. `lib/phoenix_kit/storage/uploaders/s3_uploader.ex`

**Dependencies to Add:**
- `{:mogrify, "~> 0.9"}` or `{:vix, "~> 0.5"}` - Image processing
- `{:ffmpex, "~> 0.10"}` - Video processing
- `{:ex_aws, "~> 2.5"}` - AWS S3 integration
- `{:ex_aws_s3, "~> 2.5"}` - S3 operations
- `{:oban, "~> 2.17"}` - Background jobs (if not already present)

---

### Phase 4: File Serving (Future)

**Deliverables:**

#### File Serving Controller
- Route: `GET /file/:file_id/:instance_name/:token`
- Features:
  - Token verification (prevent unauthorized access)
  - Query `phoenix_kit_file_locations` for file paths
  - Try each location in priority order (automatic failover)
  - Stream file with correct headers:
    - `Content-Type` (from mime_type)
    - `Content-Length` (from size)
    - `Cache-Control` (e.g., max-age=31536000 for immutable files)
    - `ETag` (from checksum)
  - Log access for analytics
  - Support range requests (HTTP 206 for video streaming)

#### CDN Integration
- If bucket has `cdn_url`, redirect to CDN
- Otherwise serve directly from storage (local/S3)

**Files to Create:**
1. `lib/phoenix_kit_web/controllers/file_controller.ex`
2. `lib/phoenix_kit/storage/file_server.ex` - Serving logic

**Router Update:**
```elixir
get "/file/:file_id/:instance_name/:token", FileController, :show
```

---

### Phase 5: Admin Dashboard (Future)

**Deliverables:**

#### Storage Analytics Dashboard
- Location: `/admin/storage` or dedicated storage section
- **User Statistics**:
  - Files uploaded per user
  - Storage used per user (bytes, formatted)
  - Top 10 storage users
- **File Statistics**:
  - Total files count
  - Total storage used (formatted)
  - Files by type (images, videos, documents, archives)
  - Files by status (active, processing, failed)
- **Storage Distribution**:
  - Storage used per bucket/volume
  - Free space per bucket
  - Redundancy health (files with missing copies)
- **Charts & Visualizations**:
  - Storage growth over time (line chart)
  - File type distribution (pie chart)
  - Bucket usage (bar chart)

**Files to Create:**
1. `lib/phoenix_kit_web/live/dashboard/storage.ex`
2. `lib/phoenix_kit_web/live/dashboard/storage.html.heex`

**Context Methods to Add:**
```elixir
# In PhoenixKit.Storage
def get_storage_stats()
def get_user_storage_stats(limit \\ 10)
def get_bucket_usage_stats()
def get_file_type_distribution()
def get_storage_growth_over_time(days \\ 30)
def get_redundancy_health()
```

#### File Browser (Optional)
- Location: `/admin/storage/files`
- Features:
  - Browse all files in system
  - Filter by user, file type, date range
  - Search by filename
  - View file details and all instances
  - See which buckets store each file
  - Delete files (cascade delete instances and locations)
  - Bulk operations (delete, move, verify)

**Files to Create:**
1. `lib/phoenix_kit_web/live/storage/file_browser.ex`
2. `lib/phoenix_kit_web/live/storage/file_browser.html.heex`
3. `lib/phoenix_kit_web/live/storage/file_details.ex`
4. `lib/phoenix_kit_web/live/storage/file_details.html.heex`

---

## Future Features (Planned but Not Scheduled)

### Cloud Backup Mode
**Setting:** `storage_cloud_backup_only` (boolean, default: false)

**Concept:**
- Local storage prioritized for both upload and retrieval
- Cloud storage used only as backup/disaster recovery
- Reduces cloud bandwidth costs
- Faster file serving from local drives

**Upload Behavior (when enabled):**
1. Always upload to local buckets first
2. Then replicate to cloud buckets for redundancy
3. If redundancy = 2:
   - Use 2 local drives if available
   - If only 1 local, use 1 local + 1 cloud
   - If no local, fall back to 2 cloud buckets

**Retrieval Behavior (when enabled):**
1. Always try local locations first
2. If local fails, automatic failover to cloud
3. Site stays up even if all local drives fail

**Implementation:**
```elixir
# Settings
%{key: "storage_cloud_backup_only", value: "false"}

# Bucket selection logic
def select_buckets_cloud_backup_mode(buckets, redundancy_count) do
  local = Enum.filter(buckets, & &1.provider == "local")
  cloud = Enum.filter(buckets, & &1.provider in ["s3", "b2", "r2"])

  local_selected = select_by_priority_and_space(local, redundancy_count)

  if length(local_selected) < redundancy_count do
    cloud_needed = redundancy_count - length(local_selected)
    cloud_selected = select_by_priority_and_space(cloud, cloud_needed)
    local_selected ++ cloud_selected
  else
    local_selected
  end
end

# File serving order
def get_file_locations_cloud_backup_mode(file_id, instance_name) do
  locations = query_file_locations(file_id, instance_name)

  # Sort: local first, then cloud
  Enum.sort_by(locations, fn loc ->
    if loc.bucket.provider == "local", do: 0, else: 1
  end)
end
```

### File Verification & Health Checks
- Periodic background job to verify file integrity
- Check file existence and checksum matches
- Mark missing/corrupted locations as `failed`
- Alert admin if redundancy falls below threshold
- Auto-repair by copying from healthy locations

### Storage Migration Tools
- Move files between buckets
- Batch migration with progress tracking
- Verify after migration
- Update location records

### Advanced Analytics
- File access logs (who accessed what, when)
- Most popular files
- Bandwidth usage per bucket
- Cost estimation for cloud storage

### API Endpoints
- RESTful API for file upload/download
- Authentication with API tokens
- Rate limiting
- Webhook callbacks for processing completion

---

## Code Structure

```
lib/
├── phoenix_kit/
│   ├── storage.ex                      # Main context module
│   ├── storage/
│   │   ├── bucket.ex                   # Bucket schema
│   │   ├── file.ex                     # File schema
│   │   ├── file_instance.ex            # FileInstance schema
│   │   ├── file_location.ex            # FileLocation schema
│   │   ├── dimension.ex                # Dimension schema
│   │   ├── url_signer.ex               # Token generation/verification
│   │   ├── upload.ex                   # Upload handling (Phase 3)
│   │   ├── file_server.ex              # File serving logic (Phase 4)
│   │   ├── workers/
│   │   │   └── process_file_job.ex     # Background processing (Phase 3)
│   │   ├── processors/
│   │   │   ├── image_processor.ex      # Image variant generation (Phase 3)
│   │   │   ├── video_processor.ex      # Video variant generation (Phase 3)
│   │   │   └── document_processor.ex   # Document metadata (Phase 3)
│   │   └── uploaders/
│   │       ├── local_uploader.ex       # Local filesystem upload (Phase 3)
│   │       └── s3_uploader.ex          # S3-compatible upload (Phase 3)
│   └── migrations/
│       └── postgres/
│           └── v18.ex                  # Storage system migration (Phase 1)
├── phoenix_kit_web/
│   ├── controllers/
│   │   ├── upload_controller.ex        # File upload endpoint (Phase 3)
│   │   └── file_controller.ex          # File serving endpoint (Phase 4)
│   └── live/
│       ├── settings/
│       │   ├── storage.ex              # Storage settings (modified Phase 2)
│       │   ├── storage.html.heex       # Storage settings view (modified Phase 2)
│       │   └── storage/
│       │       ├── buckets.ex          # Buckets management (Phase 2)
│       │       ├── buckets.html.heex   # Buckets view (Phase 2)
│       │       ├── bucket_form.ex      # Bucket form component (Phase 2)
│       │       ├── bucket_form.html.heex
│       │       ├── dimensions.ex       # Dimensions management (Phase 2)
│       │       ├── dimensions.html.heex
│       │       ├── dimension_form.ex   # Dimension form component (Phase 2)
│       │       └── dimension_form.html.heex
│       ├── dashboard/
│       │   └── storage.ex              # Storage analytics (Phase 5)
│       │   └── storage.html.heex       # Storage analytics view (Phase 5)
│       └── storage/
│           ├── file_browser.ex         # File browser (Phase 5)
│           ├── file_browser.html.heex
│           ├── file_details.ex         # File details modal (Phase 5)
│           └── file_details.html.heex
└── modules/
    └── storage/
        └── spec.md                     # This file
```

---

## Testing Strategy

### Unit Tests
- Schema validations
- Context CRUD operations
- Token generation/verification
- Bucket selection algorithm
- Free space calculation

### Integration Tests
- File upload flow
- Background processing
- Multi-location redundancy
- Failover behavior
- File serving with token verification

### Performance Tests
- Large file uploads (>100MB)
- Concurrent uploads
- Token generation speed
- Database query performance

---

## Security Considerations

### Token-based URLs
- ✅ Prevents enumeration attacks
- ✅ Each instance has unique token
- ✅ Secure comparison prevents timing attacks
- ✅ Tokens rotate if secret_key_base changes

### File Upload Validation
- ✅ MIME type verification (not just extension)
- ✅ File size limits (per bucket max_size_mb)
- ✅ Malware scanning (future integration)
- ✅ User upload quotas (future feature)

### Access Control
- ✅ User-specific file ownership (user_id foreign key)
- ✅ Admin-only bucket/dimension management
- ✅ Role-based permissions (leverage existing role system)

### Credentials Storage
- ✅ Encrypt `secret_access_key` at rest (`PhoenixKit.Integrations.Encryption`, AES-256-GCM)
- ✅ `access_key_id` is a credentials identifier, not a secret — stored as-is, not encrypted
- ✅ Cloud buckets may reference a `PhoenixKit.Integrations` connection (`integration_uuid`)
  instead of storing keys directly — mutually exclusive with direct credentials
- ⚠️ No bulk backfill for a `secret_access_key` already in the column when encryption was
  added — it stays plaintext until the next save of the bucket for ANY reason (the
  changeset re-derives and re-encrypts it opportunistically, not on a schedule)
- ✅ Use environment variables for secrets
- ✅ Never log credentials

---

## Migration Path

### From V18 to V19
1. Run `mix phoenix_kit.update`
2. System detects current version (V18)
3. Applies V19 migration:
   - Creates 5 new tables
   - Adds 3 new settings
   - Seeds default dimensions
   - Seeds default local bucket
4. No downtime required (additive changes only)
5. Existing PhoenixKit features unaffected

### Rollback Strategy
- V19 migration includes `down/1` function
- Drops all 5 tables
- Removes settings
- No data loss for existing features

---

## Performance Optimization

### Database Indexes
All critical queries indexed:
- File lookups by user_id
- Instance lookups by file_id
- Location lookups by instance_id and bucket_id
- Dashboard analytics (file_type, status, inserted_at)

### Caching Strategy (Future)
- Cache bucket configuration (rarely changes)
- Cache dimension presets (rarely changes)
- Cache file metadata for hot files (Redis)
- CDN caching for static files

### Query Optimization
- Use `preload` for associations (avoid N+1)
- Paginate file browser queries
- Use database aggregations for analytics
- Index all foreign keys

---

## Dependencies

### Phase 1 (Immediate)
```elixir
{:uuidv7, "~> 1.0"}  # UUIDv7 generation with Ecto.Type support
```

### Phase 3 (Future)
```elixir
{:mogrify, "~> 0.9"}       # Image processing (ImageMagick wrapper)
# OR
{:vix, "~> 0.5"}           # Image processing (libvips wrapper, faster)

{:ffmpex, "~> 0.10"}       # Video processing (FFmpeg wrapper)
{:ex_aws, "~> 2.5"}        # AWS SDK
{:ex_aws_s3, "~> 2.5"}     # S3 operations
{:oban, "~> 2.17"}         # Background jobs (if not present)
```

---

## Configuration

### Application Config
```elixir
# config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  secret_key_base: "..." # Required for token generation

# Optional overrides
config :phoenix_kit, PhoenixKit.Storage,
  max_upload_size_mb: 100,
  allowed_mime_types: ["image/*", "video/*", "application/pdf"]
```

### Environment Variables (Phase 3)
```bash
# AWS S3
AWS_S3_BUCKET=...

# Backblaze B2
B2_KEY_ID=...
B2_APPLICATION_KEY=...
B2_BUCKET=...

# Cloudflare R2
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=...
```

---

## Changelog

### V19 Migration - Storage System Foundation
**Added:**
- 5 new database tables (buckets, files, file_instances, file_locations, dimensions)
- UUIDv7 support via uuidv7 package
- Smart bucket selection with priority system
- Token-based URL security
- Multi-location redundancy support
- 3 new settings (redundancy_copies, auto_generate_variants, default_bucket_id)
- Seeded default dimensions (thumbnail, small, medium, large, 720p, 1080p)
- Seeded default local bucket

**Files Created:**
- `lib/phoenix_kit/migrations/postgres/v19.ex`
- `lib/phoenix_kit/storage.ex`
- `lib/phoenix_kit/storage/bucket.ex`
- `lib/phoenix_kit/storage/file.ex`
- `lib/phoenix_kit/storage/file_instance.ex`
- `lib/phoenix_kit/storage/file_location.ex`
- `lib/phoenix_kit/storage/dimension.ex`
- `lib/phoenix_kit/storage/url_signer.ex`

---

## Notes

- All UUIDs are v7 version (time-sortable)
- PostgreSQL-only (uses JSONB for metadata)
- Migration follows Oban-style versioning pattern
- Compatible with existing PhoenixKit authentication and role systems
- No breaking changes to existing functionality
- Ready for production use after Phase 4 completion

---

**End of Specification**
