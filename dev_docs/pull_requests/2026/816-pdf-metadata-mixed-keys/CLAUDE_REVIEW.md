# PR #816 — Fix ProcessFileJob discarding every PDF on hosts with poppler

**Author:** timujinne (`fix/pdf-metadata-mixed-keys`) · **Merged:** 2026-09-15 · **Reviewed:** 2026-09-15 (post-merge)

## Verdict

The diagnosis is right and the fix is correct: pdfinfo's string-keyed fields
merged into the atom-keyed `%{status: "active"}` update made `cast/3` raise
`Ecto.CastError`, and nesting them under `:metadata` removes the mixed-key map.
With the crash gone, a key collision in `metadata` became reachable; the merge
order was fixed post-merge. Released in 2.23.3.

## Summary of the PR

- `PdfProcessor.file_attrs/2` builds `%{metadata: existing ∪ pdfinfo}`.
- `ProcessFileJob.process_pdf/1` passes that instead of the raw pdfinfo map.
- Unit tests cover nesting, merging, the empty result, and a clean cast next
  to `:status`.

## Findings

### BUG - MEDIUM — pdfinfo's Title replaced the user's title (fixed)

`metadata["title"]` is not only a pdfinfo field. The media detail page
(`media_detail.ex` `save_metadata`) saves the user-editable title, description
and tags into the same map, and reads them back from it. `file_attrs/2`
merged pdfinfo *over* the existing map, so each run of the job replaced the
user's title with the document's own Title ("Microsoft Word - draft.docx").
The job does run again on a row that already has a title: a duplicate upload
goes through `queue_variant_generation/3`, which enqueues `ProcessFileJob`
for the existing file.

Before this PR the collision was unreachable: the job raised before the
update, and without poppler pdfinfo returned `%{}`.

**Fix:** the merge order is reversed, so pdfinfo only fills keys the map does
not already hold. A PDF's Title still becomes the default title on first
processing. Test: `a title already on the file wins over pdfinfo's Title`.

### IMPROVEMENT - MEDIUM — Failed attempts leak the temp copy (not fixed)

`process_image/1` and `process_pdf/1` remove `temp_path` only on success.
Their `else` branches, and the error returns of `process_video/1` and
`process_document/1`, leave the full retrieved original in `System.tmp_dir!()`.
With `max_attempts: 3`, the crash this PR fixes left three copies of every PDF
uploaded to a poppler host. This is older than the PR and the crash it fixes
no longer happens, so it is left out of this release. The clean fix is a
single `with_temp_copy(file, fun)` helper that deletes the copy in an `after`.

### NITPICK — Stale-read merge (not fixed)

`file_attrs/2` merges into `file.metadata` as loaded when the job started, and
the retrieval can take a while on S3. A metadata save that lands in between
is overwritten. The window is short, and `save_metadata` itself replaces the
whole map from the struct held in assigns. A jsonb `||` update would close
both, but that belongs with the broader metadata-write pattern, not this fix.

### NITPICK — Dead code nearby (not fixed)

`extract_document_metadata(_, "application/pdf")` can't be reached, because
PDFs route to `process_pdf/1`. `extract_image_metadata/1` also returns
`format: "jpeg"` for every image, which isn't a column and is dropped by
`cast/3`. Both are older than this PR.

## Validation

`mix test` on the storage unit + integration files against `beamlab_test`
and `mix precommit` are both green.
