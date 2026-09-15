# PR #817 — Keep the original's extension on storage temp copies and report a missing binary as not installed

**Author:** timujinne (`fix/storage-temp-file-extension`) · **Merged:** 2026-09-15 · **Reviewed:** 2026-09-15 (post-merge)

## Verdict

Both fixes address real bugs, and both premises were checked. Carrying the
extension over unconditionally, though, handed the uploader's filename to
ImageMagick's coder selection. That was narrowed to media types post-merge.
Released in 2.23.3.

## Summary of the PR

- `Storage.retrieve_file/1` and `Manager.retrieve_file/2` (default
  destination) append the stored original's extension to the temp copy.
- `PdfProcessor` and `System.Dependencies` read `ErlangError.original`
  instead of `reason` when detecting a missing binary.
- `retrieve_file_extension_test.exs` (integration) and
  `missing_binary_test.exs` (`PATH` pointed at an empty dir).

## Verified premises

- **`original`, not `reason`:** on Elixir 1.19.5 / OTP 28,
  `System.cmd("nope", [])` raises `%ErlangError{original: :enoent, reason: nil}`.
  The old `e.reason == :enoent` checks could never match.
- **ICO needs its extension:** with ImageMagick 6.9.11, `identify` on an ICO
  without an extension fails with `no decode delegate for this image format`.
  The same bytes named `.ico` identify as `ICO`.

## Findings

### BUG - MEDIUM — The uploader's extension selected ImageMagick coders (fixed)

The stored extension comes from the client: `media_browser.ex` takes
`Path.extname(entry.client_name)`, and `upload_controller.ex` uses the
multipart filename. `mime_type` comes from the client's content type too, so
a `drawing.mvg` sent as `image/png` is stored with `file_type: "image"` and
`ext: "mvg"`. `ProcessFileJob.process_image/1` then runs `identify` on the
temp copy.

ImageMagick picks a coder from the file's magic bytes. When there are none
it uses the extension. MVG, MSL and TXT have no magic bytes, so an
extensionless copy never reached those coders, but a `.mvg` copy selects
MVG. MVG is the ImageTragick file-read vector (`image over … 'text:/etc/passwd'`).
On this machine's Debian 6.9.11 build, `t.txt` went to `ReadTXTImage` while
the same bytes without an extension got `no decode delegate`, so the
extension does steer coder choice. The MVG `text:` read was blocked here only
by Debian's hardening (`ExplicitCoderNotAllowed`), which stock and Alpine
builds do not have. `ImageProcessor.detect_format/1` already says the storage
pipeline must not depend on the host's `policy.xml`.

**Fix:** `Manager.temp_extension/1` keeps the extension only when
`MIME.from_path/1` resolves it to `image/*`, `video/*`, `audio/*` or
`application/pdf`. `.mvg`, `.msl`, `.txt`, `.ps`, `.png[0]` and unknown
extensions get no extension. SVG keeps `.svg`, but ImageMagick sniffs SVG by
content anyway, so nothing changes there. Both `Storage.retrieve_file/1` and
the `Manager.retrieve_with_failover/3` default use it. Tests:
`manager_temp_extension_test.exs` (unit), plus an integration case storing a
`.mvg` as `image/png` and asserting its temp copy has no extension.

### IMPROVEMENT - MEDIUM — Video still crashes on a missing binary (not fixed)

The PR covers `PdfProcessor` and `System.Dependencies`. But
`ProcessFileJob.extract_video_metadata/1` calls `System.cmd("ffprobe", …)`
with no rescue, and neither does `VariantGenerator`'s `ffmpeg` call. On a
host without ffmpeg, every video job raises `ErlangError` and is discarded
after three attempts, leaving the row in `"processing"`. That is older than
this PR. A proper fix needs both call sites and a terminal file status, so it
is a separate change.

### NITPICK — Test tagging (fixed / noted)

- `@tag :integration` on the ImageMagick case was redundant, because
  `PhoenixKit.DataCase` already tags the whole module. Removed.
- The ImageMagick case passes without asserting anything when `identify`
  isn't installed. That's acceptable for an environment-dependent check, but
  a green run doesn't prove ICO decoding on such a machine.

### Noted — `Manager.retrieve_file/2` default destination

No caller in `lib/` relies on the new default. `FileController` passes
`destination_path:` explicitly at all three sites, and `replicate_to_buckets/3`
never reaches ImageMagick, so it keeps its full extension.

## Validation

`mix test` on the storage unit + integration files against `beamlab_test`
(ImageMagick present, so the ICO case asserted) and `mix precommit` are both
green.
