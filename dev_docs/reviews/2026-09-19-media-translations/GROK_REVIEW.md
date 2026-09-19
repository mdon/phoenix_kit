# GROK_REVIEW — media translations (V199 / FileDetails)

**For:** Claude (author of the four commits), working from the repo.
**Reviewer:** Grok, 2026-09-19.
**Range:** `e947f7b2..ae7c44ea` on `main` (unpushed; this is a local review, not GitHub).
**Design:** `dev_docs/plans/2026-09-19-media-translations.md`

```
ae7c44ea  Add the media alt text to image components, the file info API and the grids
7b516908  Add per-language title, alt text and description to the media editors
c0f4e255  Fix media file translations to not depend on the primary language
d5ef6ce2  Add translatable title, alt text and description to media files (V199)
```

39 files, +2798 / −709. I read the plan, `FileDetails`, V199, both editors, `image_set` / `Image`, `FileController.info`, the grids, Multilang’s `put_language_data/3`, and the tests. I ran:

```
mix test test/modules/storage/file_details_test.exs \
         test/integration/storage/file_details_test.exs \
         test/integration/phoenix_kit_web/components/image_alt_test.exs \
         test/phoenix_kit/migrations/v199_test.exs \
         test/integration/phoenix_kit_web/live/users/media_detail_details_test.exs \
         test/phoenix_kit_web/components/media_canvas_viewer_media_meta_test.exs
```

52 tests, 0 failures (real DB).

The core is sound. Independent per-language `data`, read-time fallback, legacy `metadata` adopted on first save (including a non-primary first save), `FOR UPDATE` replacing one language, placeholders not values, `?locale=` shape-checked and never the session, system-managed files excluded from info and `translated_alts/3`. V199 is additive, prefix-qualified, re-runnable. No new gettext fuzzy flags; the eight new strings are translated in all seven catalogues.

Nothing here needs a revert. The five things you asked about are all real. One of them is worse than the plan’s known gap, on writes, in the viewer only.

---

## Answers to the five hard questions

### 1. `file_attrs/4` drops same-language keys at different precision, and a bare `en` drops `en-GB`

**Confirmed.** Same predicate as `Multilang.same_base?/2` / `drop_base_siblings/3`. Not a defect for the cases the plan cares about. The unit test covers writing a dialect, not writing the bare base.

`drop_entry/2` (`file_details.ex:290-306`):

```elixir
defp drop_entry(data, lang) do
  Map.reject(data, fn {key, _entry} -> same_language?(key, lang) end)
end

defp same_language?(a, b) when is_binary(a) and is_binary(b) do
  a == b or a == DialectMapper.extract_base(b) or b == DialectMapper.extract_base(a)
end
```

That is the same function as `PhoenixKit.Utils.Multilang.same_base?/2` (`multilang.ex:249-260`). Consequences:

| Write | Drops | Keeps |
|---|---|---|
| `"en-US"` | `"en"`, `"en-US"` | `"en-GB"` |
| `"en"` | every English dialect (`"en"`, `"en-US"`, `"en-GB"`, …) | `"et"` |

The comment on `drop_entry` is accurate for the first row and silent on the second. `file_details_test.exs:176-188` asserts the first row only.

The editors store under `FileDetails.content_language/2`, which is an **enabled** code, so a site that enabled `"en-US"` / `"en-GB"` writes those keys and does not hit the bare-base drop. A site that enabled bare `"en"` *wants* leftover `"en-US"` precision-drift collapsed. I would not change the predicate. I would add the missing test so the contract is explicit: writing `"en"` against `"en-GB"` drops it.

### 2. Older files: empty `data` ⇒ `metadata` is primary text; first save (any language) moves it; after that `metadata` is only a primary-language copy

**Confirmed.** Implemented, including first save in a non-primary language. Tests assert both sides.

Read (`own_text/3`, `file_details.ex:236-247`): if `data` has any language map, only `data`; if `data` is empty and the asked language is the primary, `file.metadata`; otherwise `%{}`. Unit tests `file_details_test.exs:57-70` (legacy metadata as primary, including `data: nil`; once `data` holds anything, a stale metadata title is ignored).

Write (`adopt_legacy_text/2`, `:278-284`): on empty `data`, the metadata text is inserted under the **primary** language *before* the new language is applied. Unit test `:168-174` is the plan’s “first save in any language”:

```
legacy metadata title "Harbour", save et "Sadam"
→ data == %{"en-US" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}}
→ metadata unchanged (not a primary save)
```

Primary saves then `mirror/2` into metadata, a cleared field as `""` (`:145-175`, test `:145-160`). That matches the PDF processor (`pdf_processor.ex:119-127`): `Map.merge(pdf, existing)` so a present `""` is not filled back. Integration `file_details_test.exs:61-72` goes through `Storage.update_file_details/3`.

I would not change this.

### 3. Viewer sidebar language: process Gettext locale, not an assign

**Confirmed.** LiveComponent shares the LiveView process; the navigation hook does set Gettext. For one enabled code per base this is right. For two co-enabled dialects of one language, the viewer **writes the wrong language** — worse than the plan’s known read-prefill gap. The detail page does not have this bug.

Call site (`media_canvas_viewer.ex:597-598`, also `:504`):

```elixir
defp content_language,
  do: FileDetails.content_language(Gettext.get_locale(PhoenixKitWeb.Gettext))
```

`seed_file_row_state/2` stores that as `:media_meta_lang`; save uses `socket.assigns[:media_meta_lang] || content_language()`. Language switch is `push_navigate` (`users/auth.ex:1106`), so the LiveView remounts; the component is not left holding a stale assign across a locale change. That part is fine.

The hook **does** put the process locale, on every `handle_params` (`put_gettext_locale/1`, `:1189-1199`). It also **downgrades to the base code** when the URL dialect is not a Gettext catalog (core ships `en`, `de`, `es`, `et`, `fr`, `it`, `pl`, `ru`). The comment at `:1149-1157` is explicit: `current_locale` keeps the full dialect; only Gettext gets the base.

`FileDetails.content_language/2` then maps that base onto the first enabled code with `same_language?/2` (`file_details.ex:92-99`).

| Setup | `/en-US/` viewer | `/en-GB/` viewer | Detail page |
|---|---|---|---|
| enabled `["en"]` or only `["en-US"]` | `"en"` / `"en-US"` | n/a or same | correct |
| enabled `["en-US", "en-GB"]` (supported — see `Multilang.same_base?/2`’s comment) | both URLs yield Gettext `"en"` → first matching enabled code, almost certainly `"en-US"` | **saves as `en-US`**, overwriting US English | `current_locale` is `"en-GB"` → saves `"en-GB"` |

The plan’s known gap is *read-time* pre-fill of an empty `en-GB` tab from `en-US`. This is a *write* to the other dialect’s key. Grids / `<.image_set>` / page-builder `Image` also read Gettext, so they share the collapse on the **read** path (`find_entry` still finds a dialect of `en` — acceptable). Only the viewer *writes* through this path.

Core embeds (`media_detail.html.heex`, `media_browser.html.heex`, `media_viewer.html.heex`) pass nothing for locale, which was the point.

I would not require every host to pass a new assign. I would make the dialect optional and have core pass the one it already has:

```elixir
# media_canvas_viewer.ex
defp content_language(socket) do
  FileDetails.content_language(
    socket.assigns[:current_locale] || Gettext.get_locale(PhoenixKitWeb.Gettext)
  )
end
```

and pass `current_locale={@current_locale}` from the three core embeds. Hosts that pass nothing keep today’s behaviour. See [Issue 1](#issue-1--suggestion--viewer-writes-the-wrong-dialect-when-two-are-co-enabled).

Tests that do not set `:media_meta_lang` save as primary; the translation test sets `media_meta_lang: "et"` explicitly (`media_canvas_viewer_media_meta_test.exs:213-242`). No production host in core embeds the viewer outside PhoenixKit’s on_mount chain.

### 4. `<.image_set>` default `alt` `""` → `nil`

**Confirmed.** The one caller-visible behaviour change. In Elixir only `nil` and `false` are falsy, so `assigns.alt || file_alt(assigns)` does **not** treat `alt=""` as missing. Decorative stays decorative. Tested. In-repo callers that needed decorative already pass `alt=""`.

`image_set.ex:50-52, 74`: `attr :alt, :string, default: nil` then `assign(:alt, assigns.alt || file_alt(assigns))`. `file_alt/1` looks up only when `variants: nil` (`:113-123`); any pre-loaded `variants` (including `[]`) returns `""` and does not query.

Tests (`image_alt_test.exs:40-62`): no alt → file alt; `alt="Mine"` wins; `alt=""` stays empty; `variants={[]}` does not look up. CHANGELOG documents the migration.

The only in-repo `<.image_set>` is `media_gallery.html.heex:27-30` (not in this diff). It already passes `alt=""` **and** pre-loaded variants, so it stays decorative and does not N+1. Sibling packages that omitted `alt` and did **not** pre-load variants will now show the file’s alt (the intended change); those that pre-load variants still get `""` until step 5 passes `Storage.translated_alts/3`.

Page-builder `Image` (`image.ex:42, 64, 86-93`) is the same `||` shape: missing `"alt"` → lookup, `alt=""` kept. Lookup only when `src` is nil/`""` **and** `file_uuid` is present. That lookup is untested — see [Issue 3](#issue-3--suggestion--image-file-alt-lookup-is-untested).

I would not change the `||`.

### 5. Detail page tags: second `update_file` after the details save

**Confirmed.** Real two-call sequence. `FOR UPDATE` on the first call does not cover the second. The race is lost **rotation / other `metadata`**, not lost title in `data`. Same class of clobber the changelog says is gone, much smaller window.

```167:170:lib/phoenix_kit_web/live/users/media_detail.ex
    with {:ok, file} <-
           Storage.update_file_details(socket.assigns.file, params["details"] || %{}, lang: lang),
         {:ok, file} <-
           Storage.update_file(file, %{metadata: Map.put(file.metadata || %{}, "tags", tags)}) do
```

`update_file_details/3` (`storage.ex:2367-2393`) locks `FOR UPDATE`, merges one language, commits, **releases the lock**. `update_file/2` (`:2316-2319`) is a plain `changeset |> repo().update()` on that returned struct — and `File.changeset/2` does not cast `:data`, so the second write cannot touch translations. Concurrent `persist_rotation/3` (`media_canvas_viewer.ex:661-673`) does `get_file` + `Map.put(..., "rotation", ...)` with no lock. If it lands between the two calls, the tags write puts `"tags"` onto the **pre-rotation** metadata map and the rotation is gone.

Same LiveView is sequential, so a user rotating and saving on one page cannot hit this. Two tabs, or the detail form plus another browser on the viewer, can. The LiveView test checks rotation **after** a single-threaded save (`media_detail_details_test.exs:72-79`).

If the second call fails, details are already committed and the flash is `"Failed to save details"`. Recoverable, misleading.

See [Issue 2](#issue-2--suggestion--tags-write-reopens-the-metadata-lost-update).

---

## Issues

### Issue 1 — SUGGESTION — viewer writes the wrong dialect when two are co-enabled

- File: `lib/phoenix_kit_web/components/media_canvas_viewer.ex:597`
- Status: open

The plan’s known gap is read-time pre-fill. The viewer’s Gettext-base locale turns that into a silent write to the other dialect’s key on a host that enabled both `en-US` and `en-GB` (a configuration `Multilang.same_base?/2` calls supported). The detail page is fine because it uses `socket.assigns.current_locale`.

Fix: prefer `assigns[:current_locale]` (full dialect) and fall back to Gettext; pass `current_locale={@current_locale}` from the three core embeds. Hosts that pass nothing keep today’s behaviour. I would not make every sibling pass it as a required assign.

I did not file this as a bug because it only fires on the configuration the plan already called a known gap. It is still the one thing I would actually change before this ships, if that configuration is in play at all.

### Issue 2 — SUGGESTION — tags write reopens the metadata lost-update

- File: `lib/phoenix_kit_web/live/users/media_detail.ex:167`
- Status: open

Fold tags into the same locked transaction as the language entry (pass them through `update_file_details/3`, or a sibling that holds the row, merges `"tags"`, and writes once). At minimum, re-read `FOR UPDATE` before the tags write and `Map.put` onto that fresh map. Title/alt/description in `data` stay safe either way.

### Issue 3 — SUGGESTION — Image file-alt lookup is untested

- File: `test/integration/phoenix_kit_web/components/image_alt_test.exs:65`
- Status: open

`ImageSet` is tested for “no alt → file’s own”, “caller alt wins”, “`alt=""` stays empty”, and “pre-loaded variants skip lookup”. `Image` only tests a direct `src` (no file) and an author alt **with `src` set**, which takes the `file_alt(_src, _)` clause and never calls `translated_alt_by_uuid/2`. A regression in `Image.file_alt/2` (the `src in [nil, ""]` guard, or the lookup itself) would not fail this file.

Add the ImageSet equivalents for a `file_uuid` with no `src` and no `alt` (the `<img>` has to actually render, so the file needs a public URL / instance), plus `alt=""` with `file_uuid` and no `src`.

### Issue 4 — NITPICK — Tags view-mode copy is still English

- File: `lib/phoenix_kit_web/live/users/media_detail.html.heex:263`
- Status: open

The rewritten view-mode block gettexts Title / Alt text / Description and `{gettext("None")}`, but the Tags row still uses the English literals `"Tags:"` and `"None"`. The edit-mode label is already `{gettext("Tags (comma-separated)")}`.

---

## What I checked and am leaving alone

- **V199.** `ALTER TABLE #{prefix}phoenix_kit_files ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'` plus the version-marker COMMENT. No indexes, no extensions, no `regclass` in the migration itself (the test’s `'phoenix_kit'::regclass` is public-schema only). `expected_schema` `pos: 28` follows V195’s `edited_from_uuid` at 27. `FileDetails` is embedded (no `SchemaPrefix`); `File` already uses it.
- **`File.changeset/2` does not cast `:data`.** Only `details_changeset/2` does. The tags `update_file` therefore cannot wipe translations. Keep it that way.
- **`FOR UPDATE` on `update_file_details/3`.** Integration test `file_details_test.exs:61-72` saves et from a stale struct after a rotation was written; both survive. That is the bug the changelog claims to fix, and it holds for `data` and for metadata keys the details save itself re-reads.
- **Placeholders never values.** LiveView test `media_detail_details_test.exs:82-117` (Estonian page: `placeholder="Harbour"`, refute `value="Harbour"`, untouched save stores nothing under `et`).
- **System-managed files.** `translated_alts/3` and `get_servable_file/1` skip them; `translated_alt_by_uuid/3` returns `""`. Tested.
- **`FileController.info`.** Auth required, owner or system role, `?locale=` is `~r/\A[a-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/`, invalid → primary, never the session. Tested at `info_details/2`, not over HTTP — good enough for the mapping; the authz suite already owns the gate.
- **NUL bytes** stripped in `clean/1`. Postgres would reject them in jsonb.
- **Gettext.** No new fuzzy flags. Eight new strings translated in de/es/et/fr/it/pl/ru (en msgstr empty as source).
- **Forms.** `id={"media-details-form-#{uuid}"}` and `id={"media-meta-form-" <> uuid}`. No `phx-change`, so no missing-form-id warning. Tags sit outside any multilang wrapper (there isn’t one).
- **Alt is never the file name** on the Storage API (`translated_alt` → `""`). Grids still fall back to filename by plan (`MediaThumbnail.alt_text/2` returns `nil` on `""`).
- **`from_file/3` docs** say “no fallback”; `own_text` uses `find_entry`, which *does* dialect-fallback. That is the plan’s known gap (editor tab for `en-GB` pre-filled from `en-US`). The unit test named “no fallback” only checks an unrelated language (`lv`). I would not treat this as a new defect; the docs overclaim by a dialect.

---

## Suggested order if you touch anything

1. Viewer: prefer `current_locale` assign, pass it from the three core embeds. Optional. Unblocks co-enabled dialects without breaking the “hosts pass nothing” default.
2. Tags in the same locked write as the language entry. Small, closes the changelog hole.
3. Image lookup tests. Cheap.
4. Gettext the Tags / None literals.

I would not change `same_language?/2`, the legacy `data`-empty invariant, or the `image_set` `||`.
