# PR #534 Review — Updated the media browser with tessera

**Branch:** `dev` → `dev` (in-tree)
**Author:** Sasha Don (`alexdont`)
**Merge commit:** `af982865`
**Reviewer:** Claude (Opus 4.7 1M)
**Date:** 2026-05-11
**Scope:** 14 files, +818 / −28

Skills consulted: `elixir:using-elixir-skills`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`.

---

## Summary

Adds Tessera (OpenSeadragon wrapper) as a Deep-Zoom Image viewer in the MediaBrowser, with **lazy** tile + manifest generation served from new public routes. Also introduces V113 — a `system_managed` flag + `parent_file_uuid` FK on `phoenix_kit_files` (so tile chunks live as cascading children of their source image), and a `phoenix_kit_comment_media` junction table that isn't yet consumed anywhere.

The viewer-side work and the system-managed exclusion plumbing in `Storage` are sensible. The **public tile-serving endpoints in `FileController` ship without authentication, without dedup, and with synchronous in-band image generation** — that combination is the headline concern of this review. Several findings below are MUST-fix before this feature is ready for production traffic.

The PR body is also empty — no design notes, no test plan, no migration acknowledgement. For a +818 change touching public routes and storage invariants, that's a process gap.

---

## BUG — CRITICAL: Tile + manifest endpoints have no authentication

`lib/phoenix_kit_web/integration.ex:256-257` registers two new public routes:

```elixir
get "/tiles/:dzi_filename", FileController, :serve_manifest
get "/tiles/:files_segment/:level/:tile_filename", FileController, :serve_tile
```

Compare to the existing pattern one line above (`integration.ex:254`):

```elixir
get "/file/:file_uuid/:variant/:token", FileController, :show
```

The existing pattern uses **signed URLs** — `FileController.show/2` calls `verify_token(file_uuid, variant, token)` before serving (`file_controller.ex:84`). The new tile endpoints take `file_uuid` straight from the URL and serve the binary with **no token, no signature, no scope check, no auth at all**.

Consequences:

1. Anyone who knows or guesses any `file_uuid` can pull a high-resolution DZI tile of any image in the system — even files that should only be visible to their owner, to authenticated admins, or behind a scoped context.
2. UUIDv7 has time-ordered prefixes — partial enumeration is feasible if the attacker has any anchor (e.g. a known upload timestamp).
3. The endpoint **also triggers ImageMagick tile generation** on first request (see next finding), so the auth gap is also a write-side gap.

**Fix:** mirror the signed-URL pattern. Generate a per-`file_uuid` (not per-tile) signed URL that's checked by both `serve_manifest` and `serve_tile`. The viewer URL builder (`generate_urls_from_instances/3` in `media_browser.ex`) is already the only place that emits the DZI manifest URL — sign it there and propagate the token down to tile requests via the manifest XML.

This is non-optional. Until this is fixed, every file in the system with `width`/`height` set is enumerable by anyone who can reach the route.

---

## BUG — CRITICAL: Synchronous in-band tile generation is a DoS surface

`serve_tile/2` and `serve_manifest/2` run the full generation pipeline **synchronously in the request process**:

1. `Storage.get_file_instance_by_name(file_uuid, "original")` (DB roundtrip)
2. `Manager.retrieve_file(instance.file_name, destination_path: temp_path)` (bucket download of the *original*, which may be a 50 MB image)
3. `Tessera.generate_tile/4` (ImageMagick subprocess — typically 100-500 ms per tile)
4. `Storage.store_system_file/3` (multi-bucket write + 2 DB inserts inside `with`)
5. `read_tile_storage/1` — *re-downloads the freshly-written tile from the bucket* to a second tempfile, reads it into memory, returns body

A single client triggering a zoom session asks for ~64 tiles on the first deep zoom. That's:

- 64× full-original bucket downloads
- 64× ImageMagick processes (likely concurrent if the viewer fetches in parallel)
- 64× sequential `Storage.store_system_file` calls (each with bucket writes + DB inserts)
- 64× redundant bucket-download-and-buffer of the tile we *just wrote*

Real-world impact:

- **DoS by zoom.** Hitting an endpoint with no auth (per BUG #1) → an attacker can flood `/tiles/<any-uuid>_files/<level>/<col>_<row>.jpg` with arbitrary coordinates, generating thousands of useless tiles per file_uuid until the bucket fills or ImageMagick subprocesses choke the BEAM.
- **Bucket bill.** Each tile request is two bucket roundtrips (download original, re-download tile) — even on cache hits.
- **Tail latency.** Even a legitimate user's first zoom session blocks an HTTP worker for half a minute generating tiles.

**Fix surface** (any one of these works; ideally combine):

1. **Async generation via Oban.** First request enqueues a `Tessera.GenerateTileJob`, responds with `503 Service Unavailable` + `Retry-After` header. Viewer retries; subsequent requests hit the cached tile.
2. **Pre-generate manifest + lowest 2-3 levels at upload time** so the cold path only fires for genuinely-deep zoom.
3. **Per-`file_uuid` mutex** (via `:global.set_lock/1` or an Oban unique job key) so concurrent requests for the same image dedupe.
4. **`redirect/2` to a signed bucket URL on cache hit** (mirroring `FileController.show`'s `{:redirect, url}` branch at `file_controller.ex:90`) instead of `Manager.retrieve_file` → `File.read!` → `send_resp` — saves the second bucket roundtrip on every tile.

This is also non-optional. Lazy generation is fine; **lazy generation in the request path on an unauthenticated route is not**.

---

## BUG — HIGH: No dedup on concurrent tile-generation requests → duplicate File rows

Two browser tabs (or two OpenSeadragon pre-fetches for adjacent tiles) hit the same uncached tile concurrently:

1. Both call `Manager.file_exists?(destination)` → `false` for both.
2. Both call `generate_tile_from_original/7` → two ImageMagick processes.
3. Both call `Storage.store_system_file/3` → **two `File` rows + two `FileInstance` rows**, both pointing at the same destination `key`.

There's no unique constraint on `(parent_file_uuid, file_name)` in V113, so PG accepts both. The bucket-side write is last-wins, but the DB now has dupes that will surface as duplicate-key conflicts later or as orphaned rows once cleanup is added.

**Fix options:**

1. Add `CREATE UNIQUE INDEX ... ON phoenix_kit_files (parent_file_uuid, file_name) WHERE system_managed = true` in V113 → `Storage.store_system_file/3` uses `Repo.insert(..., on_conflict: :nothing, conflict_target: [:parent_file_uuid, :file_name])`.
2. Or hold a per-key mutex during the generate-and-store step.

The unique-constraint approach also fixes the failure mode where a generate-and-store succeeds, the bucket write fails, and a retry sees the orphaned DB row.

---

## BUG — MEDIUM: Tempfile leak on Tessera generation exception

`generate_tile_from_original/7` (`file_controller.ex:328-359`) and `read_tile_storage/1` (`file_controller.ex:363-376`) both follow the pattern:

```elixir
case ... do
  {:ok, _} ->
    body = File.read!(temp_path)
    File.rm(temp_path)
    {:ok, body}

  {:error, _} = err ->
    File.rm(temp_path)
    err
end
```

If `File.read!` raises (e.g. tempfile pre-deleted by aggressive `/tmp` cleanup, disk full mid-read), the `File.rm` is skipped. Same for `Tessera.generate_tile/4` — if it raises (not just returns `{:error, _}`), the tempfile leaks. Over time these stack up in `/tmp` until inode exhaustion.

**Fix:** wrap each in `try/after`:

```elixir
try do
  body = File.read!(temp_path)
  {:ok, body}
after
  File.rm(temp_path)
end
```

Or use `:tmp_dir!/1` + the BEAM-managed cleanup helpers if Tessera supports them.

---

## BUG — MEDIUM: V113 migration moduledoc claim is misleading

The V113 moduledoc / `postgres.ex` block ends with:

> All column / FK / NOT-NULL changes use raw SQL with explicit `IF NOT EXISTS` / `DO $$ … END $$` guards so re-running on a partially-applied schema is a no-op (the migration was previously numbered V112 in dev branches; this lets those environments roll forward without crashing on the existing FK constraint).

This is a footgun comment. The V112 we shipped to hex 1.7.108 a few hours ago has **completely different content** (projects archived_at / translations / position / etc.). There is no public consumer whose V112 contains the system_managed FK that V113 now adds. The "previously V112 in dev branches" framing implies users might have a V112 with this content; they don't.

Either:
- Drop that sentence — the idempotence guards stand on their own merit (legitimate, recommended PhoenixKit pattern).
- Or replace it with an internal-only note explaining what Alex's local dev DB looked like before this PR landed, but make explicit that public consumers will never hit that path.

As written, it sows confusion for future maintainers ("why does V113 carry migration-collision guards against V112?").

---

## IMPROVEMENT — HIGH: No DB-level CHECK constraint enforcing the system-managed invariant

`file.ex:248-256` enforces "user_uuid OR parent_file_uuid is set" in the changeset (`validate_system_managed_invariants/1`). The DB itself has no check. Any code path that bypasses the changeset (raw inserts, future migrations, `Repo.insert_all`, external tools) can violate the invariant silently — producing a `File` row with neither a user owner nor a parent, which then breaks both ownership checks (BUG #1's would-be fix) and cascade cleanup (V113's `ON DELETE CASCADE` only fires from `parent_file_uuid`).

**Fix:** add to V113:

```sql
ALTER TABLE phoenix_kit_files
  ADD CONSTRAINT phoenix_kit_files_user_or_parent_check
  CHECK (user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL);
```

The constraint is cheap and turns a soft invariant into a hard one. Also document in the schema's `@moduledoc` that the DB enforces it.

---

## IMPROVEMENT — HIGH: No test coverage for V113 or the tile endpoints

The PR adds:

- A new migration with non-trivial idempotence guards.
- A new schema field with a custom validation (`validate_system_managed_invariants`).
- Two new public-facing controller actions with regex parsing and lazy generation.
- A new context function (`Storage.store_system_file/3`).

Zero tests added. Compare to PR #533 (V112) which shipped with a test file structure that V107 / V106 already established.

Minimum suggested coverage:

- `test/phoenix_kit/migrations/v113_test.exs` — pin the schema state (column existence, FK constraint, partial indexes, `phoenix_kit_comment_media` schema).
- Schema test for `validate_system_managed_invariants` — both branches (user_uuid path, parent_file_uuid path, both-null rejection).
- Controller tests for `serve_manifest` / `serve_tile` — happy path (cache hit), cache miss (generation), invalid UUID (404), invalid level/coord (404), non-image file_uuid (415).
- Tile-generation dedup test — concurrent requests for the same uncached tile must not produce duplicate `File` rows (this is BUG #3's regression test).

---

## IMPROVEMENT — MEDIUM: `phoenix_kit_comment_media` table is created but has no consumer in this PR

V113 creates a `phoenix_kit_comment_media` junction table (`comment_uuid` ↔ `file_uuid` + `position` + `caption`). The PR doesn't add:

- A schema module for it.
- Any context function that inserts/reads it.
- Any caller in the comments module.

So the table will sit empty until a future PR wires it. That's a real risk: schema decisions made in isolation often need to change when the consuming code finally lands. The `(comment_uuid, position)` unique constraint is a guess about the access pattern (is `position` actually 0-indexed? Are there gaps? Is reordering common enough to want a different key?), and the `ON DELETE :restrict` on `file_uuid` is a strong policy choice that hasn't been validated by the unlink-lifecycle code.

**Suggestion:** either land the consumer code (schema + context + caller) in the same PR, or split V113 into two migrations and defer the junction table to the PR that uses it.

---

## IMPROVEMENT — MEDIUM: `tessera` version pin `~> 0.1` is too loose for a 0.x library

`mix.exs:122`:

```elixir
{:tessera, "~> 0.1"},
```

For Hex packages under 1.0, the Elixir convention is `~> 0.X.0` (allows patch bumps only). `~> 0.1` permits any `0.1.x` AND `0.2.x` AND beyond — which by SemVer 0.x semantics can include breaking changes. Tessera is at `0.1.0` per the lockfile.

**Fix:** `{:tessera, "~> 0.1.0"}`.

---

## IMPROVEMENT — MEDIUM: Every tile request roundtrips through the application origin

`read_tile_storage/1` (`file_controller.ex:363-376`) always pulls the tile binary into the BEAM, then `send_resp` returns it. For S3/B2/R2-backed deployments, this means:

- Tile bytes traverse the bucket → application origin → client path for every tile request (even cache hits).
- The application origin is the bottleneck for the entire viewer experience.
- The 1-year immutable `Cache-Control` only helps when there's a CDN in front of the origin; the origin itself does full work on every request.

The existing `FileController.show/2` solves this with its `{:redirect, url}` branch (`file_controller.ex:90`) — it issues a 302 to a signed bucket URL. The tile endpoints should mirror that.

**Fix:** on cache hit, build a short-lived signed bucket URL via `URLSigner` (or whatever Manager exposes) and `redirect(conn, external: url)` instead of streaming the body through Phoenix.

---

## IMPROVEMENT — LOW: `parse_tile_path/3` regex only accepts `jpg` / `png`

`file_controller.ex:265`:

```elixir
[_, col_str, row_str, ext] <-
  Regex.run(~r/^(\d+)_(\d+)\.(jpg|png)$/, tile_filename),
```

`webp` and `avif` are widely supported by modern OpenSeadragon builds and offer meaningful bandwidth wins. If Tessera supports them, the regex (and `content_type_for/1`, `format_atom/1`) needs to accept them. If Tessera doesn't, file a note here so future maintainers know why the format set is restricted.

---

## NITPICK — `content_type_for/1` and `format_atom/1` have no fallback clause

```elixir
defp content_type_for("jpg"), do: "image/jpeg"
defp content_type_for("png"), do: "image/png"
```

Will raise `FunctionClauseError` on any other input. The upstream regex in `parse_tile_path/3` filters to `jpg|png`, so currently safe — but the coupling is implicit. Either add an explicit catch-all clause that returns `:error`, or doc the invariant inline.

---

## NITPICK — Dead `destination = key` rebind in `Storage.store_system_file/3`

`storage.ex` line ~1430:

```elixir
destination = key

with {:ok, _info} <-
       PhoenixKit.Modules.Storage.Manager.store_file(content_path,
         path_prefix: destination
       ),
```

`destination` is just `key`. The rename adds nothing — use `key` directly throughout the function. Minor, but it confused me on first read.

---

## NITPICK — Empty PR description

The PR body on GitHub is empty. For a +818-line change that:

- Adds a public route family without auth
- Lazily generates files on a hot path
- Changes a long-standing NOT NULL constraint on `user_uuid`
- Adds an unrelated migration for a table that isn't yet used
- Introduces a new third-party dependency at 0.1.0

…a description with "what is Tessera / why this approach / what's tested / what's deferred" would have made the issues above visible at review time instead of post-merge. For non-trivial PRs, even three sentences in the body are valuable.

---

## Things done well

- **System-managed exclusion is plumbed thoroughly.** Every `list_*` / `count_*` / orphan / trash query in `storage.ex` got `exclude_system_managed/1`; `VariantGenerator.should_generate_variants?/1` is gated; the changeset validates the invariant; partial index supports the filter. The plumbing here is comprehensive and reads as one coherent change.
- **Cascade is correct.** `parent_file_uuid` FK is `ON DELETE :delete_all` so deleting a source image cleans up its tile rows automatically. Matches the "tiles are an implementation detail of their source" intent.
- **Settings-level kill switch.** `storage_tile_generation_enabled` defaults to `"false"`, and the URL emission in `generate_urls_from_instances/3` is gated on it, so existing deployments don't lazily generate anything until the operator opts in. Good safety default.
- **Idempotent V113.** The DO-block guards and `IF NOT EXISTS` clauses follow the V112 pattern correctly — re-running is a no-op.
- **MediaBrowser layer-selection logic.** `tessera_sources/1` and `maybe_append_layer/4` are tidy — clear ordering, clear gates, easy to extend. The comments explain the *why*.

---

## Suggested follow-up patch

Priority order, top items are MUST-fix before this is safe to expose:

1. **(CRITICAL)** Add signed-token auth to `/tiles/...` routes. Mirror `FileController.show`'s `verify_token/3`. Sign the manifest URL in `generate_urls_from_instances/3` and propagate per-tile tokens via the manifest XML.
2. **(CRITICAL)** Move tile generation off the request path. Either pre-generate at upload time, or use an Oban job with the controller responding `503 Retry-After` on cache miss. At minimum, add per-`file_uuid` mutex so concurrent requests dedupe.
3. **(HIGH)** Add unique index on `(parent_file_uuid, file_name) WHERE system_managed = true` and `on_conflict: :nothing` in `Storage.store_system_file/3`.
4. **(HIGH)** Add `CHECK (user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL)` constraint in V113.
5. **(HIGH)** Wrap tempfile lifecycle in `try/after` so exceptions don't leak `/tmp`.
6. **(HIGH)** Add `test/phoenix_kit/migrations/v113_test.exs` + controller tests for the tile endpoints.
7. **(MEDIUM)** On tile cache hit, `redirect/2` to a signed bucket URL instead of streaming the body through Phoenix.
8. **(MEDIUM)** Decide: ship `phoenix_kit_comment_media` consumer code in this PR, or split the junction table into a separate migration for the PR that uses it.
9. **(MEDIUM)** Tighten Tessera pin to `~> 0.1.0`.
10. **(MEDIUM)** Rewrite the "previously V112 in dev branches" sentence in V113's moduledoc — public consumers will never hit that path; the comment is misleading.

Items 1, 2, and 3 are the only ones that block production exposure. Items 4-10 are quality / safety / test gaps that should land before the next release.
