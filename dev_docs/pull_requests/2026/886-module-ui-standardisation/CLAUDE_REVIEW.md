# PR #886 — review

**Title:** Add the core side of the module UI standardisation, the Ratelia kit items and a PgBouncer-safe doctor
**Author:** mdon · **Merged:** 2026-10-01 (`aaa28f643`) · **Reviewer:** Claude
**Size:** ~100 files, +8.6k/−2.6k (≈3–4k lines of code and tests once gettext and the built JS are set aside)

Reviewed in three read-only passes — storage/security, UI components, infrastructure/tooling —
and the findings below were **verified by me against the code** (and, for the image ones, against
real ImageMagick) before being recorded. Where a finding was not reproduced it says so.

**Verdict:** the security core is sound: the SSRF-safe fetch (the connection goes to the address
that was checked; every hop re-validated; no proxy env), the address list, `verify_url/2` sharing
one check with the file route, and ImageMagick pinning on every call site in `image_processor.ex`,
`capture_date.ex` and `annotation_thumbnail.ex`. The bugs are in the new format/type logic and in two
time/fail-soft details. Nine were fixed here with tests; the rest are recorded for you.

**Gate:** `mix test` → 7379 tests, 5 failures at the start of this review. Four were load flakes
that pass in isolation (two `DBConnection`/`query_canceled` drops in permission grants, and two
`dashboard_card_reports_test` failures that hit an undefined `MyApp.Repo` — order-dependent,
not investigated further). One was a real, deterministic failure caused by this PR (the `.ico`
test below), now fixed. The touched files then run green: 190 tests, 0 failures.

## Fixed in this review

### BUG - MEDIUM — any file starting `BM` was sniffed as a BMP (`sniff.ex`)
`detect(<<"BM", _::binary>>)` made `BMI,weight,height…` or `BMW 3-series…` an `image/bmp`;
`content_mime_type/3` then relabelled a CSV/note as an image (and `store_from_url` accepted it),
contradicting "documents are left as claimed". **Fixed:** a BMP must also carry a valid file
header — pixel-data offset, then a DIB header of 12/40/52/56/64/108/124 bytes. Test added.

### BUG - MEDIUM — grayscale images were treated as see-through (`image_processor.ex`)
`has_alpha_channel?/1` used `String.contains?(channels, "a")`; ImageMagick prints `gray` for a
black-and-white photo, which contains an "a". Verified: `gray`, `srgb`, `graya` for the three
inputs. Effect: grayscale JPEG/PNG sizes written as PNG (several times larger) instead of JPEG, and
the crop path used a transparent background. **Fixed:** `ends_with?("a")` (srgba, graya, cmyka).
Test added (skipped silently where ImageMagick is absent, like its neighbours).

### BUG - MEDIUM — an animated GIF/WebP resized to a still format never produced its file (`image_processor.ex`)
Verified: `convert gif:a.gif -resize '20x>' png:o.png` on a 2-frame GIF writes `o-0.png` and
`o-1.png` and no `o.png`, so the size fails (and again on every retry) and strays leak into tmp.
The `[0]` pin had been added to `sanitize`/`extract_dimensions`/`has_alpha_channel?` but not to
`resize/5` or `resize_and_crop_center/5`. Not a regression — it failed before — but this PR rewrote
these lines. **Fixed:** `frame_for/2` pins frame 0 for any target but GIF/WebP, which keep their
animation as before. Test added (still PNG/JPG targets, crop, and the GIF/WebP exemption).

### BUG - MEDIUM — trailers after a response body orphaned the download (`remote_fetch.ex`)
Mint emits a second `{:headers, ref, trailers}` for a chunked/HTTP/2 response with trailers. The
`:headers` clause ran again: status 200, so it opened a fresh temp file, replacing `state.io`/
`state.path` — the real download orphaned, its handle open, result an empty file that fails as
`:unsupported_type`. **Fixed:** a `:headers` event once the body has begun is ignored. `handle/4` is
now `@doc false` public (as `Cache.ttl_until/2` is) so the event sequence is tested directly; a local
Bandit server cannot be made to send trailers.

### BUG - MEDIUM — `Cache.remember/4` measured its boundary after the load ran (`cache.ex`)
`value = fun.()` came first, then `ttl_until(until, DateTime.utc_now())`. A load that starts at
23:59:59.9 and ends at 00:00:00.1 holds yesterday's data, but its `end_of_day` TTL was computed from
the new day — served for a whole extra day when the key carries no date (the doc's own example key
`{:day, zone}`). **Fixed:** the clock is read before `fun.()`. *Not covered by a test:* the failure
needs real time to cross a boundary mid-load; the change is one line and correct by inspection.

### IMPROVEMENT - MEDIUM — `end_of_minute`/`end_of_hour` were wrong across the DST fall-back hour (`cache.ex`)
They converted to a naive local time, added to the boundary and re-resolved it with `from_wall/2`,
which takes the *first* of an ambiguous wall time. Tallinn, second pass of the repeated hour
(03:30:10 EET) → the boundary resolved into the past → 1 ms TTL, cache effectively off for that hour;
first pass → 90 minutes instead of 30. **Fixed:** minutes and hours are counted from the zone's own
clock (`end_of_day` still resolves local midnight through the zone). Five tests added, both passes of
the repeated hour, a half-hour-offset zone and a bad zone.

### IMPROVEMENT - MEDIUM — `host_anonymous_scope` ran eagerly and unguarded (`layout_wrapper.ex`)
`Map.put_new(assigns, :current_scope, apply(mod, fun, args))` evaluated the host function on every
render even when a scope was already present, and a raise or typo'd MFA took down every kit page with
the host layout and no user — login and registration included. **Fixed:** skipped when a scope is
present; a failure leaves the key absent and logs. Three tests added.

### IMPROVEMENT - MEDIUM — `ProfileSettingsTabs.hidden_sections/0` "fails open" but only rescued
A dead DB pool *exits* rather than raises (the CLAUDE.md soft-failure landmine), and this read is on
the render path of every profile tab bar. **Fixed:** `catch :exit` with the same log. *Not covered by a
test* — there is no clean way to inject a pool exit into the settings read.

### The deterministic suite failure — `retrieve_file_extension_test.exs`
The test stored plain text under an `.ico` name. `Sniff` now (correctly) treats bytes nothing
recognises as not an image, so the stored type became `application/octet-stream` and the temp copy lost
its extension. **Fixed in the test** — it now writes a real ICO header; a real icon keeps `.ico`.

### Corrected doc — phone font-size rule (`phoenix_kit_globals.ex`)
The doc said `max(16px, 1em)` "only lifts upward". `1em` inside `font-size` is the *parent's* size, and
the selector carries an id, so an `input-lg`/`text-xl` control is brought down to that floor and cannot
opt out. The **behaviour is unchanged** (lowering the specificity would also let daisyUI's small sizes
win again, which is what the rule exists to beat); the doc now says what it does.

### Follow-up from the #885 review — `phoenix_kit_templates` floor
0.2.1 is published and locked (`c476c9b3c`). Pin raised to `~> 0.2.1`; the underscore-name probe and its
`skip:` tags removed; the six host-`_layout` tests now run.

## Not fixed — for you to decide

### BUG - MEDIUM — SVG and ICO uploads keep `file_type: "image"` but can never get variants
`Sniff.magick_coder/1` is `nil` for them, so every size fails at `pinned_input` ("unsupported image
format"); `variant_source?/1` is still true, `FileController` re-queues `ProcessFileJob` for a missing
variant on each request, and no dimensions are recorded. Read from code, **not reproduced**. It is a
product decision (an SVG is its own thumbnail; gating `variant_source?` on the stored mime changes what
the media grid shows), so I left it. Related: `store_from_url`'s default `allowed_types: ["image/"]`
accepts `image/svg+xml` although the `Sniff` moduledoc says SVG is recognised "so it can be refused".

### IMPROVEMENT - HIGH — ffmpeg, ffprobe and pdftoppm are outside the new pinning
No `-f` pin and no `-protocol_whitelist`; `content_mime_type/3` only polices image claims, so a text file
claimed `video/mp4` goes straight to them. A file of `#EXTM3U` with remote or `file:` segments, or a concat
playlist, is picked up by the HLS/concat demuxers — the same class this PR closes for ImageMagick.
**UNVERIFIED** against the deployed ffmpeg. Suggested: `-protocol_whitelist file`, `-f` from `Sniff`, and
refuse video/audio claims whose bytes sniff to unknown/text.

### Other improvements (verified by reading, not changed)
- **Tessera tiles** (`file_controller.ex` → `Tessera.generate_tile`) shell out to `magick convert` with no `-limit`
  and no decoder pin, contradicting the `ImageProcessor` comment "limits on EVERY ImageMagick call". Set
  `MAGICK_MEMORY_LIMIT`/`AREA`/`TIME` in the VM environment, or pass a pinned path, and fix the comment.
- **Never-upscale vs the canvas viewer** — `media_canvas_viewer.html.heex` hard-codes Tessera sources at
  300/800/1920, so a 1448px original (large = 1448) is told 1920 and stays soft at 1450–1920px.
- **README says a pipeline remake is manual**, but `@pipeline` changes every spec hash, so after the upgrade any
  ordinary revision bump of a set makes all of that set's files stale and the reconciler remakes every size.
  The `variant_sets.ex` docstring is the accurate one.
- **Annotation label text** goes into `-draw "text …"` escaping only `\` and `'`; ImageMagick treats a leading
  `@` as read-from-file and `%…` as property expansion. **UNVERIFIED** (the sandbox's ImageMagick cannot draw text).
- **Hidden profile sections are presentation only** — the component's `handle_event`s don't check
  `section in @sections`, so a hand-made `update_email`/`update_password`/`revoke_session` still works for a hidden
  section. The admin copy is honest ("only removes the section from the page"); the CLAUDE.md wording ("hides a
  section site-wide") reads like a control. Either guard the handlers or say so in the `set_section_hidden` doc.
  Also: `hidden_sections/0` is read about six times per profile render.
- **`profile_hidden_sections_test` "readers see it at once"** never starts the settings cache, so it falls back to
  a direct DB read and does not test the re-invalidate-after-commit logic.
- **PostgresPreflight** maps every unmatched `08P01` to `:protocol_violation` ("not PostgreSQL"). PgBouncer uses it
  for `max_client_conn` and "server login has been failing" too, so those print misleading advice (the server's own
  message is still appended; no run outcome changes, and a down database cannot look reachable).
- **Cache** — expired entries are removed only on read, so date-bearing keys on a cache without `max_size` grow
  without bound; a bare `until: :end_of_day` (an easy typo) raises after `fun` has already run.
- **Sitemap opt-out** does not cover content routes (`find_content_route`/`find_index_route`), nor a static entry
  with an explicit `"path"`; `find_route(plug)` skips an opted-out route but can resolve to a sibling route of the same plug.
- **Doctor** — AGENTS.md says it "warns" about a robots.txt without a `Sitemap:` line; the hint is appended to a
  PASS message and, for a routed robots.txt with no static file, prints on every run with no way to silence it.
- **`gen.admin.page`** first-run path still passes the tab list through `Config.configure`'s escape route that the new
  comment says is broken (**UNVERIFIED**, could not run Igniter); the first-run test asserts only the page, not the config.
- **Tests** — the `/big` fetch test only exercises the `content-length` check, not the streaming cap; no test redirects
  to a blocked host or to `http`; image tests wrap their bodies in `if imagemagick?()` and pass vacuously without it.

### Nitpicks
`RemoteFetch`'s public `:unsafe_resolver` option is a production SSRF bypass in `download/2`/`store_from_url/2` opts
(gate it on a test-only env); `@raster_mimes` omits aliases (`image/x-ms-bmp`, `image/vnd.microsoft.icon`) so the
"claimed raster, bytes not" branch is skipped for them; benign alias claims (`image/jpg`, `image/heif`) log a mismatch
warning; `pk_remote_<unique_integer>` resets on VM restart and `File.open` follows symlinks in a shared `/tmp`; DNS
resolution is not bounded by the fetch deadline; `Utils.Date.short/1` prints a `DateTime`'s UTC day (document that callers
shift first) and de/fr/it/es/pl have empty msgstrs, so they fall back to the English order; `Utils.Reorder` with an
integer key accepts a value outside int64 and raises at encode; the crosshair chart wrapper is focusable with no
accessible name when `aria_label` is nil, and ranks `point_note` in O(n²); `UserSettings` resets `show_google_email`
on a partial `send_update`; `form_section` silently drops an `icon` when there is no title.
