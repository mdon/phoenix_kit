## Unreleased

### Changed

- **The Integrations lists say which service an Object Storage connection is.** Every Object
  Storage connection read "Object Storage (S3-compatible)", so a Tigris connection could not be told
  from an Amazon or a Backblaze one. The table (Settings → Integrations and My Integrations) now
  shows the service — Tigris, Cloudflare R2, Backblaze B2, … — as a badge next to the provider, and
  as a "Service" row in the card view. A provider with a `:setup_module` can add its own with an
  optional `label/1` (`Providers.setup_label/2`).
- **The Media Buckets list shows a Type and reads cleanly.** The Provider column is a Type column:
  Local or Cloud, with the service a cloud bucket is on (the one its integration is for — Tigris,
  Cloudflare R2, …) as a badge beside it. Under the bucket's name, the location is in words —
  `fotki-dev-test1 · t3.storage.dev` for a cloud bucket, the path for a local one — instead of
  `tigris:fotki-dev-test1https://t3.storage.dev`.

## 2.45.0 - 2026-10-02

### Added

- **The Object Storage integration opens on a choice of service and asks only what that service
  needs.** "S3-compatible" is a protocol, not a place: the form (site-wide and personal alike)
  now starts with a Service select — Amazon S3, Cloudflare R2, Backblaze B2, Tigris, Wasabi,
  DigitalOcean Spaces, or Other S3-compatible — and shows that service's own fields:
  a grouped region list for Amazon (from `aws_regions`), a region with suggestions for
  Backblaze, Wasabi and Spaces, the account id and optional jurisdiction for R2 (a pasted
  `<id>.r2.cloudflarestorage.com` is read for you), nothing but the keys for Tigris, and an
  endpoint for anything else. Field labels and help follow the service ("Application Key ID" for
  Backblaze, where in the console to find each key). The endpoint is built for you
  (`s3.<region>.backblazeb2.com`, `<account>.r2.cloudflarestorage.com`, `t3.storage.dev`, …);
  what is stored is still `access_key`, `secret_key`, `region` and `endpoint`, plus `service`,
  `account_id` and `jurisdiction` so an edit shows the choice again. A connection saved before this
  opens on the service its endpoint names, so nothing needs migrating. The logic is
  `PhoenixKit.Integrations.ObjectStorageServices`, reached through the new
  `Providers.setup_fields/2`, `setup_attrs/2`, `setup_changed/3` and `setup_saved/3` and a
  provider's optional `:setup_module`, so any provider can shape its form the same way.
  `setup_field/1` gains `:combo` (free text with suggestions), grouped selects, a `prompt` and a
  field-level `on_change`.
- **The storage bucket form starts with a type, and cloud buckets start from an integration.**
  Settings → Media → Add Storage Bucket asks for a Name (the PhoenixKit bucket's own label — it
  used to read "Bucket Name" and was mistaken for the bucket on the storage service) and a Type:
  Local Filesystem, which asks for the storage path, or Cloud storage, which lists the Object Storage
  integrations by name and service with an "Add a connection" link. Picking one sets the bucket's
  provider (R2, B2, Tigris, otherwise S3), fills the endpoint and region and then asks for the
  bucket's name on that service, labelled for it ("Bucket name on Backblaze B2"). Only Amazon has a
  region to choose; only "Other" has an endpoint to type; the rest come from the integration.
  Moving a bucket to another integration replaces what the first one filled in. The old Storage
  Provider select is gone from new buckets; existing buckets show their service and keep working.

### Changed

- **A new Tigris bucket no longer asks for a region.** The list of Tigris cities was only ever the
  request's signing region — Tigris is one global endpoint (`t3.storage.dev`) and places data by a
  setting of the bucket in its own console — so it read as a placement choice and was not one. New
  Tigris buckets sign with `auto`; existing ones keep the region they have.
- **Settings → Integrations is split into tabs.** "Connections" and "Personal integrations" (which
  services users may connect on their own) are tabs of the page; the encryption key warning stays
  above them, so it is seen whichever one is open.
- **The tab of a settings page is in the URL.** General (`/admin/settings`), Users, Authorization,
  Organization, Website access, Emails Transactional, Integrations, Crawlers, Media and Sitemap kept the
  active tab only in the page's state, so a refresh went back to the first tab and a tab could not be
  linked to or reached with the browser's Back button. Each tab now has its own URL
  (`/admin/settings/users?tab=sessions`); the first tab's URL carries no query and an unknown `?tab=`
  opens it. The tabs patch, so the page is not reloaded and unsaved edits in a hidden tab are kept.
  `PhoenixKitWeb.Live.Settings.UrlTabs` (`active/2`, `patch_links/2`) is the shared helper. The
  `switch_settings_tab` event is gone from these pages; the Media page's "Details" link on the
  missing-tools warning is a link to `?tab=external_libraries` now.

### i18n

- The strings the Object Storage service form and the storage bucket form added (37 in all) are
  extracted and translated in de, es, et, fr, it, pl and ru; no entry is fuzzy.


## 2.44.0 - 2026-10-01

### Added

- **Email files can be written in Markdown, with a shared header, footer and layout groups
  (#887).** A `markdown.md` part feeds both bodies: the HTML (links and a lone-link paragraph
  as accent-coloured buttons, tables, lists) and the text (`label: url`). `{{variable}}` /
  `{{{variable}}}` work as in an `html` part and a link target is checked after substitution —
  only `http(s)` and `mailto:` become links. The layout gains `_header` / `_footer` parts, and a
  group (`layout: "billing"` or the email's `layout.txt`) brings `_layout-billing`,
  `_header-billing`, `_footer-billing`, each falling back to the shared one.
  `Content.resolve_with_sources/5` says where every part came from. Raises the
  `phoenix_kit_templates` floor to 0.2.2.
- **Email branding (#887, #890).** Every part of a file email sees `{{logo_url}}` (the site logo
  as an absolute, permanently signed URL; empty for a private library's logo) and
  `{{accent_color}}`. Settings → Emails Transactional has a Branding tab with the accent colour
  (`email_accent_color`, `#rrggbb`, blank = neutral) and the logo emails carry; core's layout
  draws an accent bar only once a colour is set.
- **Admin email preview (#890).** `/admin/settings/email-sending/preview` lists every email the
  site sends — core's eight and those enabled modules declare through the new
  `c:PhoenixKit.Module.email_templates/0` callback (default `[]`; collected by
  `ModuleRegistry.all_email_templates/0`, `PhoenixKit.Email.Catalog`) — renders the chosen one
  in a chosen language with sample values through the same resolution a send uses (HTML in a
  sandboxed iframe, text, subject), and says for each part whether it came from a database
  template, a host file or the built-in default, and which file overrides it. Gated by
  `settings`.

### Changed

- Core's default email copy lives in `PhoenixKit.Email.CoreTemplates` (one function per email),
  shared by the send and the preview; the text is unchanged.

### Fixed

- **A dialect language preference rendered core's default copy in English (#889).** A recipient
  or web visitor on `es-ES` matched no Gettext catalogue and read English; the locale is now
  chosen by `RecipientLocale.gettext_locale/1` (the locale, its `pt_BR` spelling, then its base
  language), shared by the web and by emails and notifications rendered for a recipient.
- **A bare `{{url}}` on a line of a Markdown email** is documented as text, not a link (write
  `[label]({{url}})`).

### i18n

- The strings the three PRs added (the Email preview page, the Branding tab, the core email
  labels — 69 per locale) were never extracted, so every locale showed them in English. They
  are extracted and translated in de, es, et, fr, it, pl and ru, and the fuzzy carry-overs the
  merge produced were rewritten by hand.

## 2.43.1 - 2026-10-01

### Fixed

- **Uploaded and generated media no longer ship in the Hex package.** `priv/media` is
  excluded even when its files are ignored by Git. The release gate inspects the built
  package and refuses media or generated sitemaps before publication.
- **Restricted Media viewers cannot change another person's visible folder.** Folder
  colour, header and cover events use `folder-uuid`; the ownership guard now checks that
  parameter as well as the other folder identifiers.
- **Wall-clock cache deadlines survive slow loads and a busy cache process.**
  `Cache.remember/4` subtracts loading time from a boundary-based lifetime and skips
  caching a value loaded after its deadline. An explicit `Cache.put/4` expiry is measured
  when called, so waiting in the cache's mailbox cannot extend it.
- **Admin-page generator tests no longer overwrite a concurrently running test's repo
  configuration.** The generator tests run synchronously.

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
