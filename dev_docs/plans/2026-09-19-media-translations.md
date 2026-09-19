# Media translations — a language switcher for a file's title, alt text and description

**Created:** 2026-09-19
**Status:** Step 1 BUILT on `main` 2026-09-19 (unreleased). Steps 2–5 open.
**Scope:** phoenix_kit (core); follow-ups in phoenix_kit_posts and
phoenix_kit_catalogue.
**Related:** `PhoenixKit.Utils.Multilang`, `PhoenixKitWeb.Components.MultilangForm`,
`dev_docs/guides/2026-09-11-core-components.md` ("Multilang Form Components"),
`lib/modules/storage/README.md`.

A user asked for a language switcher on media. Confirmed reading: the file's
**metadata** is translated — one file, its title / alt text / description per
language — not a different file per language.

---

## What existed before

- `phoenix_kit_files` has no text columns. Title, description and tags live
  in the untyped `metadata` JSONB next to `rotation` and the EXIF/PDF keys,
  all read at the top level. There was **no alt text at all**.
- Two editors write it, neither with a changeset, and they are meant to read
  each other's writes: the detail page (`media_detail.ex`, `save_metadata`)
  and the viewer sidebar (`media_canvas_viewer.ex`, `save_media_details`).
  Both replace the whole `metadata` map from a row read earlier.
- Nothing public reads it. Every `<img>` uses the file name or `alt=""`;
  `/api/files/:uuid/info` returns no text; the pickers hand hosts uuids only.
- Core ships the whole multilang toolkit and has no consumer of it; the
  reference implementation is phoenix_kit_catalogue's `Category`.

## The constraint that shapes the design

`MultilangForm.merge_translatable_params/4` **owns the map it writes to**: it
restructures it into `%{"_primary_language" => …, "en-US" => %{…}}`. Pointed
at `metadata` it would move `rotation`, `tags` and EXIF into the
primary-language sub-map and break every `metadata["rotation"]` read. So the
translations get a column of their own.

## Decisions (maintainer, 2026-09-19)

| Question | Answer |
|---|---|
| Translatable metadata, or a file per language? | Translatable metadata |
| Add an `alt` field? | Yes |
| Translate folder name/description? | No — admin-only organisation tools |
| Per-relation captions (`post_media.caption`, `comment_media.caption`) | Left alone for now; once file-level text works, posts and comments may start using it |

## Design

- **Storage.** V199 adds `data jsonb NOT NULL DEFAULT '{}'` to
  `phoenix_kit_files` — the Multilang structure, keys `_title`, `_alt`,
  `_description`. The primary-language text **stays in `metadata`**
  (`"title"`, `"alt"`, `"description"`): every existing reader keeps working,
  the PDF processor's fill-if-missing title keeps working, no backfill. The
  structure's primary entry is a copy, refreshed on every save. Real columns
  were rejected: nothing sorts or searches on them, and they would be a
  second source of truth beside `metadata["title"]`.
- **One read/write path:** `Storage.FileDetails`, an embedded schema with the
  shape MultilangForm expects (primary text as fields + `:data`).
  `Storage.change_file_details/2`, `update_file_details/2` (re-reads the row
  `FOR UPDATE` and merges — fixes the editors' whole-map replace),
  `translated_title/2`, `translated_alt/2`, `translated_description/2`.
  Resolution: the language's own translation → dialect/base fallback (via
  `Multilang.get_raw_language_data/2`) → primary text → `nil`, and for alt
  `""`. **Never the file name as alt.**
- **The language comes from the caller** (the URL's locale) — never from the
  session.

## Steps

1. **DONE — V199 + `FileDetails` + `Storage` API + tests.** No UI.
2. **Detail page** (`media_detail.ex`, a LiveView): replace the raw form with
   a `FileDetails` changeset + `to_form`; `mount_multilang/1`;
   `<.multilang_tabs>` + `<.multilang_fields_wrapper>` around title / alt /
   description **only** — tags and file info stay outside (wrapper scope
   rule). Form needs a unique `id`. Tags keep their own merge.
3. **Viewer sidebar** (`media_canvas_viewer.ex`, a LiveComponent):
   `attach_hook` raises there — wire `"switch_language"` by hand (guide rule
   3). Add alt. Save through `update_file_details/2`.
4. **Consumers:** `FileController.info` gains `title` / `alt` /
   `description`, resolved from an optional `?locale=`; the shared `Image` /
   `ImageSet` components fall back to `translated_alt/2` when the caller
   passes no alt; MediaBrowser grid + pickers show the title/alt in the
   admin's current locale.
5. **Siblings:** posts and catalogue swap `alt={file.original_file_name}` for
   the helper, feature-detected with `function_exported?/3` so the `~> 2.0`
   core pin stays.

Single-language installs see no tabs (`Multilang.enabled?/0`); they just gain
an alt field.

## Known gaps

- A host that changes its primary language leaves `data["_primary_language"]`
  on the old code. `Multilang.maybe_rekey_data/1` exists for this; wire it in
  step 2 where the form loads the data.
- `update_file_details/2` takes `"data"` whole from the form, so two admins
  translating the same file into different languages at once: last save wins
  for the translations (the primary text and the rest of `metadata` are
  merged safely). Same behaviour as catalogue.
