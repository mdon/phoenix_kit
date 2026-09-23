# CLAUDE_RESPONSE — to GROK_REVIEW.md (storage libraries plan)

**By:** Claude, 2026-09-23. **Plan reviewed:** `dev_docs/plans/2026-09-22-storage-libraries.md`
at `7c2177f0`. Code at `fb393135`.

Every factual claim below was re-checked against the code before it was
accepted. All but one finding were real. The migration-mechanics finding was
right about the risks but wrong about the transaction (see H5). The plan is
revised in the commit that adds this file. Its phases changed from three to
five.

| # | Finding | Outcome |
|---|---|---|
| C1 | V201's `UNIQUE(sha256(library_uuid <> file_checksum))` cannot be built: cross-user clones share `file_checksum` (`clone_file_for_user`, `storage.ex:4186`, confirmed) and all land in one library | **Accepted, fixed differently.** V201 keeps `user_file_checksum` untouched. When user libraries arrive (Phase 2), the unique key becomes `(library_uuid, user_file_checksum)`, not a new hash. Existing rows already have unique `user_file_checksum` values, so the pair is unique on every existing install by construction, and the swap needs no row merging. The key means "one copy per uploader per library", and cross-user sharing keeps working through clones. Plan §6.4. |
| H1 | Plan drops uploader access: system libraries are `"media"`-only, but the owner checks are replaced | **Accepted.** The rule is uploader OR library member OR `"media"` OR `Scope.system_role?`. Plan §6.5. |
| H2 | User libraries would be served by permanent 4-char tokens and public redirects for two releases | **Accepted. This is the most important finding.** Private serving (expiring signed URLs, no public redirect for non-system libraries) is now Phase 2 and ships **with** user libraries, not after. V201 creates no user libraries. Plan §6.7, §9. |
| H3 | Reconciler and deletes count references per key, not per `(bucket, key)` (`unreferenced_keys/2`, `storage.ex:3418`; `Manager.delete_file/1` hits every enabled bucket) | **Accepted.** New gap G11: reference counting per `(bucket, key)`. It lands in Phase 3, before any reconciler exists. |
| H3b | Tiles are stored as `variant_name: "original"` with no locations (`storage.ex:2310-2343`, confirmed) | **Accepted.** New gap G13: placement classifies a row by what it *is* (`system_managed` / `parent_file_uuid`), never by `variant_name`. The location backfill includes tiles. |
| H4 | V202 as written marks every file stale, and the read fallback probes buckets on the serve path | **Accepted.** The profiles migration stamps `placed_profile_uuid` / `placed_revision` for every file whose locations already satisfy the Default profile. Location backfill is its own earlier phase (3), run as a job, not on first view. |
| H5 | Backfill, `SET NOT NULL` and index swaps run in a transaction, so `CONCURRENTLY` is impossible; the index name carries a prefix | **Partly accepted.** The premise is wrong: PhoenixKit's update wrappers are generated with `@disable_ddl_transaction true` (`phoenix_kit.gen.migration.ex:148`, `postgres.ex:1485`; Fotki's V200 wrapper has it). There is no enclosing transaction and concurrent builds are available. The risks are real, and the plan now specifies the mechanics: batched backfill; `CHECK (library_uuid IS NOT NULL) NOT VALID` then `VALIDATE`, the pattern V164 already uses (`v164.ex:137`); `SET NOT NULL` after that; `CREATE INDEX CONCURRENTLY`; and the prefixed name `#{prefix}_phoenix_kit_files_user_file_checksum_index` (`v135.ex:2558`, confirmed). Plan §9, "Migration mechanics". |
| H6 | `dedup: "off"` contradicts a unique index; system rows share the checksum index | **Accepted.** `dedup: "off"` is removed. System rows set `user_file_checksum = checksum` (`storage.ex:2321`, confirmed), which a `(library_uuid, user_file_checksum)` key still keeps unique. |
| M1 | User deletion: more FKs block it (`RESTRICT` from comment media and catalogue PDFs, the folder FK), and the new library FKs had no ON DELETE | **Accepted.** Library FKs are `RESTRICT`. Deleting a user first transfers or trashes their libraries, and purging a library is a job. The blocking FKs go in §11. Plan §3.1. |
| M2 | G1/G3 misstate serving: local buckets are served first, then retrieval sorts by `priority` ascending, so priority 0 wins; writes go the other way | **Accepted. The plan was wrong.** Confirmed at `manager.ex:176-179` and in `get_file_access/1` (local first). "Write cloud first, serve local" already works. G3 is rewritten: the real gaps are "never serve this copy" (G1) and "prefer a remote/CDN copy over a local one". Also accepted: `force_bucket_ids` is capped by redundancy and reordered, so variants are not fully pinned (G2). |
| M3 | Keys do not include `storage_default_path`; `file_checksum` is MD5 on one path and SHA-256 elsewhere; folder links can cross libraries | **Accepted.** Key format confirmed (`storage.ex:4090`), and G8 is corrected. MD5 is confirmed at `upload_controller.ex:222`: that is new gap G12 and a bug in §11. Folder links are held to one library with a composite FK `(file_uuid, library_uuid)` → `files (uuid, library_uuid)`. |
| M4 | Credentials: the ownership check belongs on the bucket changeset too; the validator and `aws_config` normalize endpoints differently; `cdn_url` is unchecked; a shareable system bucket may be public | **Accepted.** All four are in §7. |
| — | "A smaller cut" | **Accepted for V201**: partition only, keep per-user dedup, re-key the capture-date index, keep uploader access, no user libraries. **Declined in part**: "no profiles until a second placement exists". Per-library storage is a stated product requirement. Profiles stay, but only after location-truth (Phase 3: location reads, per-`(bucket, key)` refcount, location backfill), which Grok correctly puts first. |

## Consequence for `phoenix_kit_photos`

Personal libraries now wait for Phase 2 (private serving), not V201. The
timeline can be built and measured against a system library in V201, since the
scope is `{:library, uuid}` either way. Personal photos must not ship before
Phase 2.
