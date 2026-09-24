# PR #872 — Name a downloaded copy for what it is, and let a download download

**Author:** alexdont (Sasha Don) · **Reviewer:** Claude · **Date:** 2026-09-24
**Verdict:** merged into `main` locally, with two fixes. It was merged on top of the
unreleased storage libraries V203 work (private serving), which touches the same
serving path.

## What it does

`Storage.download_name/3` names each variant's download for what it is
(`photo-large.jpg`, `photo-large-annotated.jpg`), with the extension from the
stored instance. `FileController.content_disposition/3` answers with that name,
and `?dl=1` forces `attachment`, also on a bucket that signs the response. The
details page groups its download list into the picture's sizes and the annotated
copies, and links with `?dl=1` plus a matching `download` attribute.

## Findings

### IMPROVEMENT - MEDIUM — the download list dropped every non-standard variant (fixed)

`download_groups/2` listed only `original large medium small thumbnail` and the two
burn slots. The page used to list every variant the file has, so a size an admin
added under Settings → Media → Dimensions (`grid_2x`), and a video's variants,
silently stopped being downloadable. **Fix:** any variant not in the two lists and
not one of the deliberate exclusions (`dzi`, `thumbnail_annotated`, `annotated`)
follows the standard sizes in the picture's group, sorted by name. Test:
`test/phoenix_kit_web/live/users/media_detail_downloads_test.exs`.

### BUG - MEDIUM — a stale download link stopped being a download (fixed)

A versioned URL whose version moved on (the image was edited) redirects to the
current version. That redirect was built without `dl=1`, so clicking a download
link on a page rendered before an edit opened the picture in a tab: exactly the
behaviour the PR set out to remove. **Fix:** the stale-version redirect keeps
`dl=1` when the request had it. Test: `private_file_serving_test.exs`, "a download
link whose version moved on stays a download".

### NITPICK — a pending variant downloads the original under the variant's name (not fixed)

While a variant is still being generated, `/file/...` serves the original as a
stand-in, and the download now names it `photo-large.jpg`. The response is
`no-store` and the window is seconds, so this is left as is.

## Merge notes

Conflicted with V203 in `FileController.serve_variant`: the resolved version takes
both the PR's `download?` and V203's `private?`, so a private file's download is
still never redirected to a public object URL (`keep_private/2`) and keeps its
`private` cache policy.

## Gate

`mix precommit` clean. The controller, disposition, media LiveView and new tests
all pass against the real database (133 tests, 0 failures).
