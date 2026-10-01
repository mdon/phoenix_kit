# PhoenixKit 2.43.0 — independent release recheck

**Reviewer:** Codex · **Date:** 2026-10-01

Reviewed the published release against Claude's reviews of PRs #881, #884,
#885 and #886, plus the Media-by-viewer changes shipped with them. The release
comparison is against 2.42.1, the immediately preceding published version.

**Verdict:** the published source matches the release commit, but the artifact
contains generated media, the folder ownership guard misses real event payloads,
and the cache deadline fix is incomplete. These defects are fixed locally in
this review; the already-published 2.43.0 artifact still contains them. No version
bump, publication, tag movement or retirement was performed.

## Publication evidence

- Hex reports 2.43.0 published at `2026-10-01T12:50:45.803286Z`, with docs.
- Local and remote `v2.43.0` resolve to
  `f3b3cca2b390f1e0dacb82c998d85bf2dbbd3d25`; remote `main` matches it.
- Downloaded `https://repo.hex.pm/tarballs/phoenix_kit-2.43.0.tar` and checked
  SHA-256 against the Hex release API:
  `081148eade52464d8a9fc4302a772486c1414459793a4bc70677e78e75d3fc3d`.
- Compared every packaged file to the tag: **757 tracked files match byte for
  byte; 2,287 additional files are all under `priv/media/`**. No tracked packaged
  file differs from the tag. The published templates requirement is `~> 0.2.1`.
- `gh release view v2.43.0` reports no GitHub Release. The Git tag, Hex package
  and Hex docs exist independently of a GitHub Release.
- The previous release's changelog entries appear verbatim in the new Q3 archive.

## Fixed in this review

### BUG - HIGH — generated media shipped in the Hex artifact

`mix.exs` packages all of `priv/`, including gitignored files. Its exclusions
covered generated sitemaps but omitted `priv/media/`. The published package
contains **2,287 untracked media files, totaling 1,751,946 bytes uncompressed**,
including `lib-test*`, `lib-*`, `verify*` and timestamped upload/variant paths.
These are runtime artifacts, not library assets. A release built from a checkout
that contains real uploads could expose those bytes to anyone downloading Hex.
This audit did not classify every image as synthetic or assert that production
data was leaked.

The same issue predates this release: the downloaded 2.42.1 package contains
2,052 files under `priv/media/`, totaling 1,645,030 bytes.

**Fix:** exclude the entire `priv/media` tree without deleting local media.
Added a test that creates a media fixture, performs a real `mix hex.build`,
opens both tar layers and asserts no media is present while JS, translations
and library source remain. The release gate also inspects the built artifact
and rejects media or generated sitemaps; a deliberately contaminated tarball
tests that rejection. A rebuilt package contains **757 files and zero media**.

### BUG - HIGH — hyphenated folder parameters bypassed ownership checks

`MediaBrowser.viewer_refused?/3` extracts changed-folder UUIDs using only
`folder_uuid` and `id`. Actual handlers for folder color, header size, header
visibility, cover/logo removal, and starting header/description/rename editing
receive `folder-uuid`.

A restricted viewer may see a folder created by someone else because it holds
one of their files. The visibility check therefore passes, but the ownership
check receives no folder UUID. The handler then writes that other person's
folder. This contradicts the release's promise that restricted viewers change
only folders they created.

**Reproduced before fixing:** through the real Media LiveView, Alice sent
`set_header_size` with `folder-uuid` naming the admin's visible Events folder.
Its stored header size changed from `small` to `large`; the regression test
failed on that database assertion.

**Fix:** include `folder-uuid` in the ownership guard's changed-folder inputs.
The regression exercises valid color and header-size writes and asserts both
remain unchanged for another person's folder.

### BUG - MEDIUM — wall-clock cache deadlines still moved past the boundary

Claude's fix samples `started_at` before loading, but then passes the original
remaining duration to `Cache.put/4` after loading. The cache starts that duration
when it handles the cast. Both loading time and mailbox delay extend the actual
deadline; measuring before the load alone does not implement an absolute boundary.

**Reproduced on released code:** a load started at `13:00:03.155319Z`, with
56,845 ms until the minute boundary, and completed at `13:01:00.179879Z`.
`Cache.get/3` still returned the previous minute's value after the boundary.

**Fix:** subtract monotonic loading time for wall-clock boundaries and omit
expired fills. Integer `until:` durations retain their existing semantics.
Explicit `expires_in:` writes carry the monotonic expiry calculated by the
caller, so a busy cache process does not restart the duration later.

Tests cover a real load crossing a minute boundary and a suspended cache process
receiving an explicit expiry. The latter avoids timing assumptions about mailbox
scheduling; the boundary test can take up to approximately one minute.

### BUG - MEDIUM — a new async generator test corrupted concurrent repo reads

The first full recheck had one failure: `MediaTest` attempted
`MyApp.Repo.all/1`. This is the same failure class Claude recorded as an
uninvestigated order-dependent issue.

The new `phoenix_kit_gen_admin_page_test.exs` ran async and fed Igniter a fixture
containing `config :phoenix_kit, repo: MyApp.Repo`. Igniter's formatting path
temporarily evaluates fixture config using `Application.put_all_env/1`, then
restores it. Concurrent LiveViews can read that temporary value.

**Fix:** run this generator test in the synchronous phase. This follows the
repository's rule for tests that mutate shared application configuration.

## Claude's remaining findings

- **BUG - MEDIUM — SVG/ICO variant eligibility remains inconsistent.** Confirmed
  the SVG helper path: sniffing returns `image/svg+xml`, storage preserves that
  MIME, `variant_source?/1` returns true, but `pinned_input/1` returns
  `unsupported image format`. The file route queues generation for a missing
  variant. Left unchanged: supporting these formats or treating originals as
  their own previews needs an explicit supported-format decision.
- **IMPROVEMENT - HIGH — video processors still auto-detect formats and allow
  protocol access.** Confirmed by reading the `ffprobe` calls in capture-date
  extraction and file processing, and `ffmpeg` variant arguments: no input-format
  pin or protocol whitelist. Non-raster claims remain trusted by
  `content_mime_type/3`. Exploitability was **not reproduced**: this environment
  lacks ffmpeg/ffprobe. Claude's warning remains a follow-up, not a demonstrated
  exploit in this audit.
- The remaining lower-priority items in `CLAUDE_REVIEW.md` remain recorded there;
  this review does not certify that every unverified note is a reproduced bug.

## Validation

- Published source comparison: 757 exact matches; 2,287 extra media files.
- Original full suite with PostgreSQL: **71 doctests, 7,394 tests, one failure,
  six skipped, one excluded**. Integration tests ran; only the test requiring
  CREATEROLE was excluded. The failure is explained above.
- Before-fix reproduction: folder ownership regression failed as expected;
  actual Hex build regression passed after the packaging exclusion.
- Focused fixes: **42 tests, zero failures** (cache, real Media LiveView and
  actual package build), before adding the separate contaminated-artifact gate test.
- Final full PostgreSQL suite: **71 doctests, 7,399 tests, zero failures,
  six skipped, one excluded**, with `PGPOOL=10`, `--max-cases 8`, `--seed 0`.
- Final `mix precommit`: **passed** — compilation with warnings as errors,
  unused-lock check, test compilation, formatting, strict Credo, Dialyzer and
  **254 JavaScript tests**.
- Dependency audits: `mix deps.audit` found no vulnerabilities;
  `mix hex.audit` found no retired or security-advisory packages in the lock.
- The new artifact check rejects the downloaded published tarball and accepts
  the rebuilt package.
- Final rebuild: **757 packaged files, zero media files**, with every file
  byte-identical to the reviewed working tree.

The current artifact cannot be repaired by changing local exclusions. A subsequent
patch release is needed to deliver these fixes to consumers. Earlier packages
continue to contain their published bytes unless separately removed or retired.
