# Website access — one page, a list of features, presets instead of modes

Status: BUILT 2026-09-06 (overnight), on max-dev only; no PR until Max has
tried it. The "As built" section at the end records where the build departed
from the plan and why.

## Why

The boss first asked for website *modes* — maintenance (exists), a dev mode, a
third nobody remembers. Talking it through, he wanted to mix and match what
the modes do, which makes modes the wrong unit. So: one settings page,
**Website access**, listing independently switchable features, each with an
explanation and (where it needs one) its own area of options and extras. The
old modes become **presets** that switch a bundle of features on; everything
stays adjustable after. Everything lives on this one page for now; the boss
decides later what belongs elsewhere (some of it fits Authorization).

## Features (each a checkbox)

| Feature | What it does when on | Its area |
|---|---|---|
| **Password gate** | A hard block before anyone sees anything: a blank page with only a password prompt. No login screen, no front page — the password is needed to see the site at all and to reach one's own login. Unlock lives in the session as the current **epoch** (a random value rotated by a password change, switching the gate on, or "ask everyone again" — so a relock never derives from the password itself). | The history of attempts — what was typed, when, from where, success or not — so a bot brute-forcing is distinguishable from a client mistyping or with caps lock on. Optional lockout after N failures per address for M minutes (off by default). An **access link** the admin can copy and send: opening it shows one button, the button unlocks (a bare GET never does, so a link-preview fetcher does not unlock its own session). A lock icon in the admin header while on. |
| **Redirect to production** | A visitor's request to a public URL is redirected (302, same path and query) to the configured production URL. Smart: a logged-in user is not redirected, a path under the admin prefix is not, the gate page and assets are not. Scope: everyone, or search-engine crawlers only. | Production URL; scope. |
| **Visitor notice** | A bar fixed along the bottom of every HTML page (a top bar hid every site's fixed header, core's admin header included): an icon (under-construction / info), text, an optional link ("this is the dev site, the live one is at …"). Everyone sees it, admins included, so they see what visitors see; a later setting may hide it for admins. Injected into the response like the websocket fix, so host layouts get it without work. | Icon, text, link. |
| **Site closed** (was "Maintenance") | Everyone but admins/owners sees a closed page — heading, message, countdown to an end time — instead of the site; by hand or in a scheduled window; Retry-After. Maintenance is no module and has no page of its own any more: it is this feature, and "Maintenance" is a PRESET (Max, 2026-09-07). | Switch, heading, message, the window (from / until, site zone), a status line, a preview, a link to the closed page as an admin. |
| **Hide from search engines** | `noindex, nofollow` on every page — the existing crawlers setting, **shared**: the same value shown and switchable here and on the Crawlers page. | — |
| **Allowed addresses** (idea) | Addresses that pass the gate and the redirect without a password — the office, the boss's home. | The list. |

Presets: **Maintenance** (the closed page on with a maintenance heading and
message — nothing else changes, a live site stays indexed), **Under
construction** (the closed page on with an under-construction heading and
message, notice with the construction icon, noindex), **Dev site**
(password gate on, hide from search engines on, notice on with "the live site
is at …" when a production URL is set), **Live** (everything off). A preset is
a button that sets settings; nothing else.

Environment: the page shows how the app is running (release or mix, MIX_ENV,
host, the site URL setting) and suggests a preset when it looks like a dev
install. It never switches anything on by itself.

Every setting here goes through `PhoenixKit.Settings`, so V184's history
records who switched what and when.

## Where the pieces go

- `PhoenixKit.WebsiteAccess` — the feature registry (`features/0`: key,
  label, explanation, option keys), `enabled?/1`, presets, environment.
  Sub-contexts: `Gate` (password, unlock, attempts, lockout, access link),
  `Redirect`, `Notice`, `AllowedAddresses`.
- `phoenix_kit_access_attempts` (V187 — V185 and V186 went to upstream releases while this was in flight): typed text, success, address, user
  agent, time.
- `PhoenixKitWeb.Plugs.WebsiteAccess` replaces the direct maintenance call in
  `Plugs.Integration`: allowed address → redirect → gate → maintenance, then
  the notice is injected into HTML 200s after `<body>` (and `X-Robots-Tag`
  when hidden from search engines). Every `on_mount` hook in
  `PhoenixKitWeb.Users.Auth` re-checks the gate first and redirects on a
  relock broadcast.
- `PhoenixKitWeb.WebsiteAccessController` at `/phoenix_kit/access`
  (locale-free): GET the prompt, POST verify + unlock, `/link/:token` GET a
  one-button page + POST unlock, `/status` a JSON "ok" exempt from everything.
- `PhoenixKitWeb.Live.Settings.WebsiteAccess` at
  `/admin/settings/website-access`, a Settings sub-tab.

## Not now

Hiding the notice for admins, IP-based rules beyond an allow list, a "notify
me" capture on the under-construction page, read-only mode.

## As built — departures from the plan

- **Logged-in users pass the gate** (setting `website_access_gate_users_pass`,
  default on). They proved more than a password; and without it the admin
  who changes the password is thrown out by their own change. The plug stamps
  such a session as unlocked so the next request costs nothing; switching the
  setting off relocks everyone.
- **Redirect before gate** (panel): bounce the public first; only people who
  may stay ever see a prompt. Redirect only on GET/HEAD, never to the same
  host (loop guard), never for logged-in users or admin paths.
- **Attempts**: what was typed is kept as the "Keep what was typed" setting
  says — everything on a wrong try (default, Max: the boss wants to see
  exactly what the client typed), only a `case`/`close` near miss (a typo is
  one edit per four characters of the password, at most three), or nothing;
  the working password never. A try during a lockout is verdict `locked`,
  unjudged; an access-link entry is `link`. Newest 5000 kept.
- **Client address**: `IpAddress.client_address/1` — `remote_ip`, or behind a
  loopback/private peer (nginx, Docker) the LAST `x-forwarded-for` entry, then
  `x-real-ip`. The old `extract_from_conn/1` answered the proxy's address for
  every visitor, which would have made the allow list, the lockout and the
  history useless on max-dev.
- **Maintenance**: `enabled?/0` is always true, the Modules-page card and
  `enable_module/disable_module` are gone; `set_active/2`, `update_header/2`,
  `update_subtext/2`, `update_schedule/3`, `clear_schedule/1` take the history
  opts. The Website access page edits heading, message and a "back on" time
  (the scheduled end, in the site zone); the full schedule stays on its page.
- **Notice preview** renders from the saved text before the switch is on.
  The bar is fixed to the BOTTOM of the window: injected at the top it sat
  on every fixed header (core's admin header included) and hid it.
- **Header badges** (`WebsiteAccessBadges`): lock while the gate is on, wrench
  while maintenance is active, arrow while redirecting — each links to the page.
- **Blank-able keys** were added to `Setting.@optional_settings`: an empty
  first write of a key not there fails validation (the crawlers keys hit the
  same wall earlier).
- **Environment** reads `MIX_ENV` at runtime, else the compile-time
  `Mix.env()`; `Mix` is not in a release.
- **Not built** (mentioned to the boss as ideas): hiding the notice for
  admins, expiring/named review links, an auto-off timer for the gate, a
  brute-force burst alert, a staging watermark, a scheduled preset change, an
  outbound-email safety switch, robots.txt Disallow while gated.

## Code review by the panel (codex gpt-5.6, Gemini 3.1 Pro, kimi) — fixed

- A page opened while the gate was OFF never subscribed to the relock, so
  switching the gate on left idle tabs with full access (all three) → the
  hook is attached always; the relock handler lets a page stay when the
  gate is off or the user is logged in and logged-in users pass.
- `to=/\evil.example` passed the return-path guard (kimi, codex; Phoenix
  would have raised → a 500 on a crafted link) → strict local-path regex.
- Allowed addresses passed the plug but not the LiveView check (codex) →
  the plug stamps their session as unlocked.
- Lockout check-then-insert race: a burst of parallel guesses all saw the
  count before any was written (codex, kimi) → `Gate.try/2` takes a
  per-address advisory lock around check + record.
- A flood of tries pushed its own failures out of the 5000 cap and lifted
  the lockout (codex); same-microsecond rows went with the cutoff (Gemini)
  → pruning never touches the lockout window and tie-breaks on uuid; it
  runs one attempt in twenty.
- Access-link entries counted as lockout failures (codex, kimi) → only
  case/close/unrelated count.
- Two `X-Forwarded-For` header lines: only the first was read (codex) →
  all instances joined, the last entry wins.
- Prefix exemptions (`/favicon…`, `/robots.txt…`, `/assets/…`) let routed
  pages under those prefixes skip the whole plug (codex) → only the gate's
  own pages are exempt; files served before the router never reach it.
- Invalid UTF-8 in a password or user agent reached Postgres `text`
  (kimi, codex) → judged unrelated / scrubbed; a failed insert logs, never
  500s.
- Case-insensitive compare leaked timing (Gemini) → `secure_compare` there
  too; a stale `content-length`/`etag` after injection (Gemini, kimi) →
  dropped; the same-origin loop guard compared hosts only (codex) → scheme,
  host and port; the edit distance is skipped when lengths differ by more
  than the allowance (kimi).

Accepted, not changed: the password is a restricted (encrypted) setting,
not a hash — the boss wants to read it to hand it to a client; a password
change and its epoch rotation are two writes (a request in between passes
on the old epoch it legitimately held a moment earlier); `<body` inside an
HTML comment before the real one would take the notice; the access-link
token travels in the path.

## Max's first look (2026-09-06 evening) — fixed

- The gate page rendered unstyled: HEEx does not interpolate `{}` inside
  `<style>`, so it shipped a literal `{@style}`. `<%= raw %>` now, tested.
- "Keep only near misses" → a setting, default everything typed.
- The Crawlers-page link errors when that module is off → conditional.
- The bottom bar on the settings page now follows a save without a reload.

## 2026-09-07 — maintenance is a preset, not a page (Max)

"The idea was that maintenance mode would be part of website-access as a
preset — it's just a set of features that should be turned on or off." So:
the separate Settings › Maintenance page is gone (route, LiveView, tab); its
switch, heading, message, scheduled window (from / until), status line and
preview live in the **Site closed** area of the Website access page; the
`/maintenance` public page stays (admin preview banner links back here);
**Maintenance** and **Under construction** are presets that switch the closed
page on with matching stock texts — a heading or message the admin wrote is
kept, a stock one is replaced, so applying one preset after the other does
change the page. `PhoenixKit.Modules.Maintenance` keeps its name and API.
