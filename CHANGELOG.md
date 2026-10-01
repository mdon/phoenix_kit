## 2.43.0 - 2026-10-01

### Added

- **Media shows each viewer only what is theirs.** A holder of `media` without the new
  `media.view_all` sees, in a site library, the files they uploaded, the folders they
  created or that hold their files, and those folders' ancestors: in the grid, folders,
  tree, search, counts, trash and orphans, and on the file's own page. An Owner/Admin or a
  holder of `media.view_all` sees everything, as before. Every event that names someone
  else's file or a folder the viewer cannot see is refused, so is changing a folder they did
  not create, and a hand-edited `?file=` link opens only a file of the library shown that the
  viewer may see (it opened any file, of any library, before). A trashed file's URL answers its
  uploader, an Owner/Admin or a `media.view_all` holder; changing another person's file needs
  `media.view_all`. Emptying the trash and clearing orphans work for a restricted viewer on
  their own files only.
- **User libraries join Media's switcher**, grouped "Site" and "Mine" (`/admin/media/my/<id>`).
  A holder of `media` who is not an Owner/Admin is sent there from `/admin/libraries`; that page
  remains for people who hold `storage` without `media` and for the admin's audited list of other
  users' libraries. The profile's Media tab has an "Open" link on every library.
- **Two sub-permissions of `media`:** `media.view_all` (see everyone's files in the site's
  libraries) and `media.manage` (Settings → Media: buckets, sizes, health). They appear under
  Media in the permissions matrix.
- **Which services users may connect on their own is a site setting.** Settings →
  Integrations has a "Personal integrations" card: a checkbox per provider that supports
  personal use, and the personal "add integration" page offers exactly the ticked ones. The
  list used to be fixed in code (Telegram and OpenRouter); until an admin saves a choice those
  two are still what users are offered, so nothing changes on upgrade. A provider opts in with
  `personal_default: true` (offered until the admin chooses), and Object Storage is also
  offered while users may keep a library on their own bucket (`personal_also_while`). The
  page refuses a provider it did not offer, even to a hand-made event.
- **A shared HTML layout for emails built from files and defaults** (`PhoenixKit.Email.Layout`).
  Core's auth emails and the defaults a module passes to `Mailer.send_from_template/4` ship no
  `html` part, so they went out as plain text; they now arrive as HTML — the site's name above
  the body, the name and a link to the site below it, inline styles, no brand colours, no external
  resources, and no words of its own to translate. A text-only message is escaped, split into
  paragraphs and its `http(s)://` addresses linked (a link ends at invisible and bidirectional
  format characters, so it cannot display one address and open another). A host overrides the
  layout with `_layout/html.html` under its `phoenix_kit_templates` root (needs
  `phoenix_kit_templates` 0.2.1; older releases skip the name and core's layout is used). A layout
  without `{{{content}}}` is refused with one warning. `layout: false` opts out; an `html` part
  that is already a whole document, and any database template, are never wrapped. A blank `html`
  or `text` part (an empty override file) is now treated as missing. See `guides/email-templates.md`.

- **Module UI standardisation, core side.**
  - `<.date_nav>` — previous / today / next over a date held in the URL (stateless patch links, optional
    native picker, `DateNav.parse_param/2` clamps to min/max). Not in the global import list; import it.
  - `line_chart hover={:crosshair}` — a snapping crosshair with a server-computed readout (x, value, optional
    `point_note`, the rows active at that x), keyboard (arrows, Home/End, Escape), touch (tap to pin) and a
    polite live region; the native tooltips stay as the no-JS readout.
  - `SearchPicker` draws its list in the top layer (a modal body or overflow ancestor no longer cuts it off),
    closes on blur, picks on touch-up, and takes `close_on_pick`, `row_layout="stacked"` and the input's
    `form`/`maxlength`/`required`/`inputmode`.
  - `table_default` gets a `toolbar_primary` slot, `bulk_actions_toolbar` a `primary` slot, `form_actions`
    `submit_disabled`, `form_section` an `:actions` slot, an optional title, and `page_action` `show_label`.
    `Utils.Reorder` and `sortable_row` take non-UUID keys; modals take heights in `dvh` as well as `vh`.
  - `Utils.Date.short/1` and `short_with_year/1` — localized day-month dates.
- **Settings → Users → Profile Page:** an admin chooses which sections the user settings page shows (custom
  fields, email, start page, annotation reset, password, connected accounts, sessions, notifications, and the
  Google address inside the identity form). What is stored is the list of *hidden* sections, so a section added
  later shows up; a tab whose sections are all hidden is not offered; name and avatar cannot be hidden. The
  toggle is attributed to the admin. It hides the section on the page — it is not an access control.
- **`Storage.store_from_url/2`** — a fetch that cannot reach the server's own network: public addresses only
  (`Utils.PublicAddress`, IPv4 and IPv6, with `config :phoenix_kit, :blocked_ip_ranges` for ranges only your
  network knows), every redirect re-checked, https never downgraded to http, ports 80/443, size and time capped,
  bytes sniffed for the type. `URLSigner.verify_url/2` is the file route's own check for a file URL.
- **`Cache.remember/4`** — get-or-compute with a wall-clock expiry (`until: {:end_of_day, "Europe/Tallinn"}`,
  `:end_of_hour`, `:end_of_minute`); errors are returned, never stored. `Cache.put/4` takes `expires_in:`.
- **`PhoenixKitWeb.Plugs.ProbeBlock`** — answers scanner probes (`/.env`, `wp-login.php`, `*.php`) with a bare
  404; `/.well-known/` always passes; `extra:` / `except:` adjust it.
- **Sitemap:** `config :phoenix_kit, sitemap: [extra_sources: [...]]` adds sources without restating the
  defaults; a route with `metadata: %{sitemap: false}` stays out of the sitemap. The doctor warns when robots.txt
  (a static file or a routed one) has no `Sitemap:` line, and counts image sizes made by an older pipeline.
- **Host hooks:** `config :phoenix_kit, host_live_view_locale: :leave` keeps a host LiveView's own locale;
  `host_anonymous_scope: {Mod, :fun, args}` gives the host layout its own scope when nobody is signed in
  (display only). `hidden_admin_tabs` now also covers host, legacy and runtime-registered admin tabs.

### Fixed

- **`PhoenixKit.System.Dependencies` compiles on OTP 28.** The external-tools list held compiled
  `~r` sigils in a module attribute, which OTP 28 cannot escape into a function body; it is built
  in a function now.
- **A file that merely starts with the letters `BM` is no longer an image.** A CSV or note beginning
  "BMI,weight…" was sniffed as a BMP and stored as `image/bmp`; a BMP must also carry a valid file header.
- **A grayscale image is no longer treated as see-through.** `gray` contains the letter the alpha check
  looked for, so black-and-white photos were written as PNG instead of JPEG.
- **An animated GIF or WebP resized to a still format makes its file.** ImageMagick wrote one file per
  frame and never the one asked for, so the size failed on every retry; frame 0 is used unless the target is
  itself a GIF or WebP.
- **A download whose response ends with trailers is kept.** The trailers re-opened the temporary file and
  orphaned the downloaded one (`Storage.store_from_url/2`).
- **`Cache.remember/4` measures its boundary from before the load.** A load straddling midnight kept
  yesterday's value for a day more; `end_of_minute`/`end_of_hour` are also right across the hour the clocks go back.
- **`host_anonymous_scope` no longer takes the login pages down.** The host's function runs only when the
  layout has no scope yet, and one that raises leaves the scope absent and logs.
- **The hidden-profile-sections read fails open on a dead pool too** (it caught raises, not exits).
- **The profile's tabs stay on the personal integration "add" and edit pages.** They
  disappeared after "Add integration", so the page no longer said where you were.
- **The Multiple Sessions setting reads "Enable multiple sessions"** (it said "multi-account
  switcher in the header"; the switcher is in the user menu).

- **Image sizes keep transparency and are never enlarged.** A see-through image gets a PNG (or
  `variant_alpha_format`) size instead of a black-backed JPEG, and a size larger than its original is the
  original's size. Sizes made earlier keep working; `VariantSets.remake_all/0` remakes them (manual — it
  queues every size of every file — and every spec hash changed, so an ordinary revision bump of a size set
  also makes that set's files stale).
- **ImageMagick is pinned to the sniffed format and limited on every call.** A file is decoded only by the
  coder its bytes name, never one chosen from its file name; bytes nothing recognises under an `image/*` claim
  are stored as `application/octet-stream`.
- **The doctor no longer leaves a pooled connection with an empty `search_path`.** Behind PgBouncer in
  transaction mode its session-level `SET`/`RESET` landed on different backends, and a host's pages then failed
  with "relation does not exist" until the pool was reset; the setting is now transaction-local.
  `PostgresPreflight` no longer calls a PgBouncer login rejection "unreachable".
- **`table_default` keeps its toolbar on an empty plain table**, `gen.admin.page` stops rewriting the host's tab
  list and pointing gettext at the kit, `PublicAddress` no longer treats reserved IPv6 space as public, the
  `SearchPicker` list no longer sticks on "Searching…" when focus is elsewhere, and phone form fields no longer
  zoom iOS (including kit pages inside a host layout).
- **Core compiles on Elixir 1.18 with OTP 28.**

### Changed

- **`phoenix_kit_templates` floor is `~> 0.2.1`.** Core's email layout looks up the host's `_layout`
  override, which 0.2.0 skips.
- **The storage administration screens (Settings → Media: buckets, sizes, profiles, health) need
  `media.manage`, no longer just `media`.** So giving an end user Media does not hand them the
  bucket form.

### Upgrading

- Every role that holds `media` when this boots is granted `media.view_all` and `media.manage`
  once (and Admin gets them with the other new keys), so **nothing changes for existing roles**.
  A role created afterwards gets neither by default: a holder of `media` alone sees only their own
  files. Revoke `media.view_all` from a role to make it so; it is not given back.
- The media pickers (`MediaSelectorModal` and the featured-image picker) are not filtered by viewer.

---

Older releases are archived by quarter in
[`dev_docs/changelogs/`](https://github.com/BeamLabEU/phoenix_kit/tree/main/dev_docs/changelogs):
[2026 Q3](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q3.md) ·
[2026 Q2](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q2.md) ·
[2026 Q1](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2026-Q1.md) ·
[2025](https://github.com/BeamLabEU/phoenix_kit/blob/main/dev_docs/changelogs/2025.md)
