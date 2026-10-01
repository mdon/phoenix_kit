# Review handoff — Integration-backed bucket credentials and user-owned storage (V206)

**For:** a second reviewer, working from the repo.
**Author of the change:** Claude (Sonnet 5.5), 2026-09-30, with the maintainer.
**Design record:** `dev_docs/plans/2026-09-22-storage-libraries.md` — section
"Next: V206, user-owned storage" (decisions, risks, work order) and its
"As built" list, which records where the build departed from the plan. Read
that first. Section 7 of the same plan is the original threat model.

## What to review

Two pieces, eleven commits on `main`, all unreleased. Range `04f5ce04a..HEAD`
(`04f5ce04a` is the 2.41.6 release).

```
08192da49  Piece 1 — bucket credentials move into Integrations, one endpoint reader + guard
22ef23c53  the V206 work order (docs only)
7c4391a23  V206 schema + owned bucket + system-only listings
5abe525bd  reads / forced writes / deletes that reach a user's bucket
ad0453f0b  user storage profiles (only / backup)
29f99eb60  purge cleanup; a library's own buckets found through its profile
1a55478dc  creating a library on the user's own storage
a359193f2  the Media tab wizard, admin toggle, connection-in-use warnings
4ee6c3cd4  backup-mode fix, personal provider allowlist, end-to-end test
501428749  owned-bucket check forbids public access
f6b87f8d6  docs, changelog, translations      f0aa067ac  credo fixes
```

55 files, but most of the lines are the generated expected-schema manifest, the
seven PO catalogues and tests. The code worth reading:

| File | What |
|---|---|
| `lib/modules/storage/endpoint.ex` | the one endpoint parser + the SSRF guard (`check/3`, `classify/1`) |
| `lib/phoenix_kit/migrations/postgres/v206.ex` | `owner_uuid` ×2, two partial indexes, `phoenix_kit_buckets_owned_check` |
| `lib/modules/storage/schemas/bucket.ex` | `owned_changeset/4`, `check_owned_rules/1`, Tigris parity |
| `lib/modules/storage/storage.ex` | `list_buckets/0` & `list_enabled_buckets/0` now site-only; `create_owned_bucket/2`, `get_buckets/1`, `owned_buckets_for_dir/1`, `delete_stored_object/2`, `buckets_available?/0` |
| `lib/modules/storage/services/manager.ex` | `read_order/4` (`with_owned_buckets/2`), `forced_buckets/1` |
| `lib/modules/storage/providers/s3.ex` | `credential_owner/1`, `endpoint_policy/1`, the read/write/delete probe |
| `lib/modules/storage/profiles.ex` | `create_user_profile/3` (only/backup), `put_bucket` owner guard, `set_library_profile/2` lock, `delete_user_profile/1`, `user_storage_for/1` |
| `lib/modules/storage/libraries.ex` | `create_user_library/3` with a `"storage"` map, `may_use_own_storage?/1`, purge cleanup |
| `lib/modules/storage/bucket_credentials.ex` | moving a legacy bucket's keys into a connection |
| `lib/phoenix_kit_web/live/components/library_settings.ex` | the wizard |
| `lib/phoenix_kit/integrations/{validators,integrations,providers}.ex` | owner-aware validation; `@personal_offered` |
| `lib/modules/storage/web/bucket_form.{ex,html.heex}`, `settings.{ex,html.heex}` | piece 1's UI |

## What it does

**Piece 1.** A cloud bucket's keys now come from an `object_storage`
Integrations connection; the bucket form has no key fields. Buckets that still
carry their own keys keep working and can be moved (one, or all), never
automatically. One endpoint parser and guard (`Storage.Endpoint`) replaces two
divergent readings. A bucket reads only connections its own owner owns.

**V206.** A user may keep a library in their own S3-compatible bucket, chosen
when the library is created (final once made): *only there*, or *the site's
storage plus a backup of the originals there*. Gated by
`storage_user_buckets_enabled` (off by default), the new `storage.own_storage`
sub-permission and `integrations`.

## Decisions already made (please don't reopen them as findings)

- Backup mode **snapshots the Default profile's buckets at creation**; a site
  bucket added later is not used by existing user libraries.
- Purging a library deletes the objects it wrote in the user's bucket.
- Quotas are out of scope (V207). Users on site storage have none today either.
- `owner_uuid` has **no foreign key**, deliberately (see the V206 moduledoc).
- The bucket keeps its own `region`/`endpoint` (prefilled from the connection);
  the connection supplies only the secrets.
- The SSRF guard is **not a connect-time pin**; that is documented, not hidden.
- A user account's deletion removes their personal connections first, so their
  own bucket's objects are left there. Known and recorded.

## Already verified — please don't re-derive

- `mix test` — **7101 tests, 0 failures**, real database (run against
  `phoenix_kit_test`; note `beamlab_test` is a *different* database).
- `mix precommit` — exit 0 (compile as errors, deps, test.compile, format,
  credo --strict, **dialyzer**, JS tests).
- `mix phoenix_kit.release_check` — passes version-sync and chain_hash;
  fails only "git tree clean" / "tag collision", which is expected pre-release.
- `test/integration/prefix_migration_test.exs` — the whole chain into a named
  schema, V206 included; the repair tests prove the manifest matches what the
  chain builds.
- `test/integration/storage/user_bucket_e2e_test.exs` — a probe, an upload, a
  read, a delete and a purge through a user's bucket against an in-memory S3
  behind `Req.Test` (no socket, so the personal endpoint policy stays on).
- Gettext: 0 fuzzy, untranslated counts equal HEAD per locale, all new strings
  (30 × 7 locales in this piece, 30 × 7 in piece 1) translated.

## NOT verified — please spend your time here

1. **A real bucket.** Nothing has run against real S3, R2, B2 or Tigris: the
   read/write/delete probe, presigned URLs for a user's bucket, virtual-host
   addressing on Tigris, R2 with no `cdn_url`.
2. **Real DNS** in the endpoint guard. Tests inject a resolver.
3. **A browser.** The wizard (radio toggles, the connection picker refreshing,
   the async "Test the bucket"), the bucket form's live connection list, and
   every `data-confirm` text were only exercised through `live/2` and direct
   handler calls.
4. **A host app upgrade.** V206 on a database with real data; the CHECK is added
   `NOT VALID` then validated.

## Where to push hardest

Adversarial questions, roughly by risk:

1. **Isolation.** Is there any path that enumerates buckets for the *site*
   (placement, reads, fallback probing, deletes, backfill, Health, the media
   browser, sibling modules) and could still reach a user's bucket? Grep every
   caller of `list_buckets`, `list_enabled_buckets`, `Repo.all(Bucket)`,
   `get_bucket`, and `Manager.select_buckets_for_retrieval`.
2. **Cross-tenant reach.** Can user A cause a read, write or delete against user
   B's bucket, or use B's connection? (`owns_connection?/2`, `credential_owner/1`,
   `owned_buckets_for_dir/1` found via `key_prefix` — is `key_prefix` really
   unique and unguessable enough? `Library.key_prefix` for a *system* library
   could collide with a user's — check.)
3. **SSRF.** `Endpoint.classify/1` ranges (IPv4-mapped IPv6, NAT64, 6to4,
   `0.0.0.0/8`, decimal/octal/hex IP forms that `:inet.parse_address/1` may or
   may not accept), DNS rebinding between check and request, redirects
   (ExAws.Request.Req defaults `redirect: false` — confirm for every code path,
   including multipart), and whether `Validators.object_storage/2` is reachable
   with no owner (it defaults to the strict policy).
4. **The "final choice" rule.** Every route that writes
   `libraries.storage_profile_uuid`: `set_library_profile/2`,
   `assign_user_profile/2`, the admin Libraries tab, sibling modules, raw
   `Repo.update`.
5. **Migration.** `owned_check` on a database that already has rows; `down`
   ordering; whether `release_check`/`doctor` mention the new objects.
6. **Backup mode arithmetic.** `keep_room_for_backup/1` and the copy counts
   when the Default has `stores: "derived"` rows, `read_only` rows, >4 site
   buckets, or `min_copies_on_write` above the number of originals.
7. **Purge and user deletion.** `do_purge/1` cleanup when the profile delete
   fails; a bucket that still has location rows; the order against the owner's
   deletion (`Auth.delete_user` runs `trash_owned_libraries` then deletes the
   user and their personal integrations).
8. **Permissions.** `may_use_own_storage?/1` is checked in
   `create_user_library/3`; is it the *only* gate? The wizard hides fields, the
   context is the boundary.

## Known soft spots (found, not fixed)

- A site with no site bucket at all offers uploads on the site's libraries
  (`buckets_available?/0` counts a user's bucket); the upload then fails with
  "no available storage buckets".
- The wizard's `probe` assign is a test seam, unset in production.
- `Endpoint.error_message/1` strings are plain English (not gettext), like the
  changeset message they replaced.
- Existing Tigris buckets saved without a bucket name or keys will now fail
  validation on their next save.

## How to run it

```bash
# the suite uses phoenix_kit_test (config/test.exs), not beamlab_test
mix test test/integration/storage test/modules/storage \
         test/phoenix_kit/migrations test/integration/phoenix_kit_web/live

# the new tests, by area
test/modules/storage/endpoint_test.exs                        # parser + guard
test/integration/storage/user_buckets_test.exs                # owned bucket, S3 owner, probe
test/integration/storage/user_bucket_read_path_test.exs       # read order, deletes
test/integration/storage/user_profiles_test.exs               # only / backup, locks, cleanup
test/integration/storage/user_storage_creation_test.exs       # create_user_library/3
test/integration/storage/user_bucket_e2e_test.exs             # through Req.Test
test/integration/phoenix_kit_web/live/users/own_storage_ui_test.exs
test/integration/phoenix_kit_web/live/bucket_form_test.exs
test/phoenix_kit/migrations/v206_test.exs
```

## Output

Write findings to `CLAUDE_REVIEW.md` / `GROK_REVIEW.md` (your agent's name) in
this directory, severities `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT -
HIGH/MEDIUM`, `NITPICK`, each with a file:line and a concrete failing scenario.
Do not edit the code under review; the author writes `CLAUDE_RECHECK.md`.
