# Media translations — a language switcher for a file's title, alt text and description

**Created:** 2026-09-19
**Status:** Steps 1–4 BUILT on `main` 2026-09-19, released as 2.32.0. Step 5 (siblings) open.
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

## Two constraints that shape the design

1. **`metadata` cannot hold translations.** Anything structured per language
   written there would sit beside `rotation`, `tags` and EXIF keys that are
   read at the top level. The text gets a column of its own.
2. **The stored text must not depend on which language is primary**
   (maintainer, 2026-09-19). The shared `Utils.Multilang` structure embeds a
   `_primary_language`, keeps that entry complete and stores every other
   language as a *diff against it*; a site that changes its primary language
   then needs `rekey_primary/2` on every record. That diffing pays off for an
   entity with dozens of fields. For three it buys nothing — and the first
   cut of step 1, which used it with `metadata["title"]` as the primary
   text, had a real bug: after a primary change, text typed on the new
   primary tab was copied over the old primary's entry.

## Decisions (maintainer, 2026-09-19)

| Question | Answer |
|---|---|
| Translatable metadata, or a file per language? | Translatable metadata |
| Add an `alt` field? | Yes |
| Translate folder name/description? | No — admin-only organisation tools |
| A switcher on the editors? | **No tabs.** The admin language switcher already offers exactly the enabled content languages and the language lives in the URL — the editors edit the language the page is shown in |
| Per-relation captions (`post_media.caption`, `comment_media.caption`) | Left alone for now; once file-level text works, posts and comments may start using it |

## Design

- **Storage.** V199 adds `data jsonb NOT NULL DEFAULT '{}'` to
  `phoenix_kit_files`: `%{"en-US" => %{"title", "alt", "description"},
  "et" => %{…}}`. Every language holds its own text; nothing marks a
  primary. Real columns were rejected: nothing sorts or searches on them.
- **Fallback is decided at read time**, per field: the language asked for
  (exact → base code → first stored dialect of the base) → the site's
  *current* primary language → any language → `nil`, and for alt `""`.
  **Never the file name as alt.** Changing the primary language converts
  nothing.
- **Files from before V199** keep their title/description in `metadata`, in
  no recorded language. Invariant: **`data` empty ⇒ `metadata` is the
  primary-language text; `data` non-empty ⇒ `data` is the truth.** The first
  save (in any language) moves the `metadata` text into `data` under the
  primary language. No backfill migration. After that `metadata` only
  receives a copy of the primary-language text on a primary-language save —
  for the PDF processor's fill-if-missing title and the viewer's stored
  title. A cleared field is copied as `""`, not removed, or the PDF
  processor would fill it back in.
- **One read/write path:** `Storage.FileDetails`, an embedded schema holding
  the three fields *in one language*. `Storage.change_file_details/3`,
  `update_file_details/3` (`lang:` option; re-reads the row `FOR UPDATE` and
  replaces that language's entry only — fixes the editors' whole-map replace
  and makes two admins translating at once safe), `translated_title/3`,
  `translated_alt/3`, `translated_description/3` (`primary:` option for bulk
  reads, default `Multilang.primary_language/0`).
- **Not used:** `MultilangForm.merge_translatable_params/4` and
  `Multilang.put_language_data/3` — they produce the diffed shape. The
  *components* still apply: `<.multilang_tabs>`, `<.multilang_fields_wrapper>`
  and `<.translatable_field>` in its `secondary_name` + `lang_data_key` mode
  (`lang_data_key="title"`, plain keys).
- **The language comes from the caller** (the URL's locale) — never from the
  session.

## Steps

1. **DONE — V199 + `FileDetails` + `Storage` API + tests.** No UI.
2. **DONE — detail page** (`media_detail.ex`): a `FileDetails` form for the
   page's language (`FileDetails.content_language(@current_locale)`), saved
   with `lang:`. No tabs (see Decisions). What tabs would have given is
   covered by: a badge naming the language + "Switch the page language to
   translate." (multi-language sites only), and the primary-language text as
   each empty field's **placeholder** — never its value, or an untouched save
   would store English under `et`. Alt text is offered for images only. Tags
   stay in `metadata`. Accepted cost: switching language is a navigation, so
   unsaved edits in the three fields are lost.
3. **DONE — viewer sidebar** (`media_canvas_viewer.ex`, a LiveComponent): the
   same, through the same `update_file_details/3`. It reads the language from
   the process's Gettext locale — a LiveComponent shares its LiveView's
   process, where the navigation hook put it — so no host (core or sibling)
   passes anything new.
4. **DONE — consumers.** `FileController.info` returns `title` / `alt` /
   `description`, resolved from an optional `?locale=` (validated as a
   language-code shape; never the session). `<.image_set>` and the
   page-builder `Image` fall back to the file's alt text in the page's
   Gettext locale when no `alt` is written — `alt=""` stays decorative, and
   `<.image_set>` with pre-loaded `variants` looks nothing up (it must not
   bring back the N+1 the caller avoided): list pages use
   `Storage.translated_alts/3`, one query. System-managed files are never
   read. MediaBrowser grid + both pickers put the alt text on thumbnails
   (`MediaThumbnail.alt_text/2`), file name where there is none. The grids
   still *list* files by file name — showing titles instead is a UI change
   nobody asked for.
5. **Siblings:** posts and catalogue swap `alt={file.original_file_name}` for
   `Storage.translated_alts/3` (list pages) or `translated_alt_by_uuid/3`,
   feature-detected with `function_exported?/3` so the `~> 2.0` core pin
   stays.

Single-language installs see no tabs (`Multilang.enabled?/0`); they just gain
an alt field.

## Review (Grok, 2026-09-19)

`dev_docs/reviews/2026-09-19-media-translations/GROK_REVIEW.md`; what was
done about it is in `CLAUDE_RESPONSE.md` beside it. It changed three things
in this design:

- **The page's language is read from the process, as a full dialect.**
  Gettext's locale is downgraded to a base code, so with `en-US` + `en-GB`
  co-enabled the viewer saved an `/en-GB/` edit over the `en-US` text.
  `Auth.put_gettext_locale/1` now records the undowngraded dialect beside it
  (`Languages.put_request_locale/1`); `Multilang.current_locale/0` reads it,
  and the viewer, the grids and the image components use that. Passing an
  assign was not enough: the viewer sits inside LiveComponents that have no
  `@current_locale` either.
- **An editor never opens pre-filled with a sibling dialect's text**
  (`FileDetails.from_file/3` matches the language at any precision, not its
  siblings); readers still fall back across dialects.
- **Every read-modify-write of `metadata` goes through
  `Storage.update_file_metadata/2`** (row held `FOR UPDATE`): the two
  rotation writes, and the detail page's tags, which now ride in the details
  save itself (`update_file_details/3`'s `:metadata` option).

## Known gaps

- Writing under a bare base code (`"en"`) replaces every dialect of that
  language (`"en-GB"`, `"en-US"`). Deliberate — a site that enabled `"en"`
  has no page a leftover dialect entry could be shown on — and the same rule
  as `Multilang.put_language_data/3`. The editors only ever write an ENABLED
  code, so two co-enabled dialects never hit it.
- The "any language" last resort picks the first language by code order —
  deterministic, not meaningful.
