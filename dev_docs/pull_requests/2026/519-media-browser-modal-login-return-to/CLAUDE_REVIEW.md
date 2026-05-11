# PR #519 — MediaBrowser modal upgrades + login `return_to` for LV redirects

**Author:** @alexdont
**Branch:** `dev` ← `dev` (alexdont fork)
**Merged:** 2026-05-08T21:12:10Z (`8494c2b8`)
**Diff:** +189 / -70 (5 files, multiple commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/519

## Verdict

**APPROVE** with one notable behavior change called out below. Three
threads:

1. **MediaBrowser default-mode change.** The 4-mode click handler
   collapses to 3: `select_mode` → `admin` → modal viewer. The
   `viewer` attr is removed; the new default is "click opens the
   modal." Pickers reach `select_mode` via the toolbar's Select
   button.
2. **Modal redesign.** Mobile = full-screen via `position: fixed;
   inset: 0`. Close button moves from sidebar to top-right of the
   modal-box. Chevron-button transform fix. Image-zoom hook
   (`MediaImageZoom`) lazy-loads Panzoom from jsDelivr.
3. **LiveView login redirect carries `return_to`.** Four `on_mount`
   redirect paths in `Auth` now build `?return_to=<encoded>` from
   `Phoenix.LiveView.get_connect_info(socket, :uri)`. The login
   LiveView and `session.ex` already understand the param, so the
   end-to-end flow works without further plumbing.

Findings below are nitpicks plus one IMPROVEMENT-MEDIUM around the
default-mode flip and a stale comment.

## What changed

| Layer | Change |
|---|---|
| `media_browser.ex` | Drop `:viewer` attr; collapse `click_file` to 3-branch cond; default branch now opens viewer instead of entering select_mode |
| `media_browser.html.heex` | Modal-box gains mobile-fullscreen `!fixed !inset-0` chain (lg+: `!w-[95vw] !h-[90vh]` + rounded); close button moves to top-right; chevron buttons wrap in `<div>` to avoid daisyUI's active-state `transform: scale()` clobbering `-translate-y-1/2`; image hooked up to `MediaImageZoom` |
| `phoenix_kit.js` | `MediaImageZoom` hook — lazy CDN-load Panzoom 4.6.0; wheel listener on parent for off-image zoom; mount-time abort if element disconnected; destroyed-cleanup of listeners |
| `users/auth.ex` | Four `redirect(to: Routes.path("/users/log-in"))` calls swap to `redirect(to: login_path_with_return_to(socket))`; new private builder reads `:uri` connect info, encodes `path?query`, guards self-loop |
| `AGENTS.md` | "Click behavior — three modes" section rewritten; removes the `viewer` attr description |

## Findings

### IMPROVEMENT - MEDIUM — Default click behavior flipped from select to modal-viewer; no deprecation cycle for picker callers

`lib/phoenix_kit_web/components/media_browser.ex:998-1003` — old
default branch:

```elixir
true ->
  {:noreply, socket |> do_toggle_file(file_uuid) |> assign(:select_mode, true)}
```

was the picker fallthrough. New default:

```elixir
true ->
  {:noreply, assign(socket, :viewer_file, find_uploaded_file(socket, file_uuid))}
```

Combined with the removal of the `:viewer` attr (`update/2` no longer
seeds `assign_new(:viewer, fn -> false end)`), three breakage shapes
are possible for external callers of `MediaBrowser`:

1. **Caller relied on the old picker default** (no `admin`, no `viewer`,
   expected click-to-select). They now see the modal viewer pop up on
   every click. This is a user-visible behaviour change that can't be
   reverted with a config flag — they have to either pass `admin={true}`
   (wrong — that opens the admin detail page) or update their UX flow
   to instruct users to click the toolbar's Select button first.
2. **Caller passed `viewer={true}`** for explicit modal mode. The attr
   is silently ignored now (the component doesn't use formal `attr`
   declarations — see `lib/phoenix_kit_web/components/media_browser.ex:86`,
   `use PhoenixKitWeb, :live_component` only — so unknown attrs land in
   assigns and are never read). Behaviour is unchanged because the new
   default does what `viewer={true}` used to do, but the assign sits
   dead in `socket.assigns.viewer`. No warning surfaces.
3. **Caller had a UX guide for users that said "click to select."**
   Now-stale documentation outside the repo.

The change *is* the right design — making the default action the
read-only preview means a user accidentally clicking a file gets
information rather than altered selection state. But the migration
cost is real and silent. Two options to mitigate:

- **Keep the `viewer` attr as a soft-deprecated `default: true`.**
  Internally the component would do the right thing whether the caller
  set it or not. A short `@deprecated` comment on the attr telling
  callers "the default is now the modal viewer; pass `select_default:
  true` if you want the old picker behaviour" gives callers a path.
- **Add `attr :select_default, :boolean, default: false`** with formal
  declarations and a one-line moduledoc. A caller can opt back in to
  picker-on-click without having to know about the toolbar's Select
  button.

If neither of those is in the cards, at minimum the AGENTS.md note in
this PR should call out the breaking change to external module authors
who have already wired up MediaBrowser. A `## Breaking changes` line
under the Click behaviour section would do it.

**Where:** `lib/phoenix_kit_web/components/media_browser.ex:97-110, 988-1004`,
`AGENTS.md:473-484`

### IMPROVEMENT - LOW — `media_browser.html.heex:1230-1233` comment still references the removed `viewer` attr

```heex
<%!-- ── Read-only modal viewer ──────────────────────────────────────────── --%>
<%!-- Activated by passing `viewer={true}` to the component. Clicking a file --%>
<%!-- (outside select_mode and admin) sets viewer_file and shows the preview --%>
<%!-- + metadata + Download. Closes via X / Esc / backdrop click.            --%>
```

The first comment line is now wrong — there's no `viewer={true}` to
pass. AGENTS.md was updated, but this template-internal comment was
missed. Two-line fix:

```heex
<%!-- Activated by clicking a file (outside select_mode and admin). The     --%>
<%!-- click_file handler sets viewer_file and renders this block.           --%>
```

**Where:** `lib/phoenix_kit_web/components/media_browser.html.heex:1230-1233`

### IMPROVEMENT - LOW — `login_path_with_return_to/1` could be folded into a guard for the bare login path

`lib/phoenix_kit_web/users/auth.ex:1620-1635`:

```elixir
defp login_path_with_return_to(socket) do
  login_path = Routes.path("/users/log-in")

  case Phoenix.LiveView.get_connect_info(socket, :uri) do
    %URI{path: path} = uri when is_binary(path) and path != login_path ->
      query = if uri.query, do: "?" <> uri.query, else: ""
      login_path <> "?return_to=" <> URI.encode_www_form(path <> query)

    _ ->
      login_path
  end
end
```

Two minor sharpenings:

1. **Path equality check is path-prefix-sensitive.** `path != login_path`
   will treat `/users/log-in` and `/users/log-in/` as different. A user
   landing on `/users/log-in/` (e.g., from a hand-typed URL or a
   trailing-slash-preserving link) would loop back to /users/log-in
   carrying `?return_to=%2Fusers%2Flog-in%2F` — the login form would
   then post-login redirect there, pulling the user back to a
   nearly-identical URL. Probably won't loop infinitely (the second
   visit would be authenticated and skip the redirect entirely), but
   the cycle is wasteful. A defensive `String.trim_trailing(path, "/")`
   on the comparison side would close the gap.
2. **`URI.encode_www_form/1` on `path <> query` works** — it encodes
   `/` as `%2F` and `?` as `%3F`, then login.ex's
   `URI.decode_www_form/1` (or Plug's param parsing) decodes them
   back. Worth a one-line moduledoc on `login.ex:75` explaining that
   `sanitize_return_to/1` sees the *decoded* path (which already
   starts with `/`), so the `String.starts_with?(path, "/")` guard
   on `:78` works.

Neither is load-bearing — the happy path is correct. Surfacing for
the audit.

**Where:** `lib/phoenix_kit_web/users/auth.ex:1620-1635`,
`lib/phoenix_kit_web/users/login.ex:75-83`

### NITPICK — `get_connect_info(socket, :uri)` in `on_mount` returns the URI in both disconnected and connected mounts (no behaviour gap)

The PR's `case` has a catch-all `_` branch that fires when
`get_connect_info/2` returns `nil` or anything that doesn't match
`%URI{}`. Phoenix LV 1.0+'s `:uri` connect info is populated during
both the disconnected (HTTP) mount and the connected (WS) mount, so
the catch-all is mostly future-proofing rather than a runtime path.
That's fine — defensive coding around a contract that *could* change.

What's worth knowing: **on_mount runs twice**, mirroring mount. Both
runs go through `redirect_require_login` and both produce the same
return_to-bearing URL. The browser sees the dead-render redirect first
(because `{:halt, ...}` short-circuits the LV lifecycle), so the WS
connect never even happens. Net effect: one redirect with one
return_to per failed-auth navigation. ✓

### NITPICK — Panzoom CDN dependency is a runtime fetch from jsdelivr

`priv/static/assets/phoenix_kit.js:339-360` lazy-loads
`https://cdn.jsdelivr.net/npm/@panzoom/panzoom@4.6.0/dist/panzoom.min.js`
on first MediaImageZoom mount. The hook gracefully fails (console
error, `panzoomLoading = true` stays set, image stays static — drag/zoom
just doesn't work) if the CDN is unreachable.

Three mitigation observations, none blocking:

1. **The pattern matches SortableJS** (loaded the same way earlier in
   `phoenix_kit.js`), so this is an established convention rather than
   a one-off. Consistency wins here.
2. **The CDN URL is pinned to a major.minor.patch** (`4.6.0`) — a
   future Panzoom 5.x release won't silently break. ✓
3. **Subresource Integrity (SRI) hash** would close the
   "compromised CDN serves malicious JS" attack vector. The script
   tag is created via `document.createElement("script")` without a
   SRI attribute. Adding `script.integrity = "sha384-..."` and
   `script.crossOrigin = "anonymous"` would pin the served bytes.
   Same observation applies to SortableJS and is a workspace-wide
   pattern, not a #519 issue.

**Where:** `priv/static/assets/phoenix_kit.js:339-360`

### NITPICK — `!important` chain on modal-box is well-commented but worth pulling into a daisyUI variant

```heex
<div class="modal-box !fixed !inset-0 !w-auto !h-auto !min-w-0 !max-w-none !max-h-none !m-0 !rounded-none lg:!relative lg:!inset-auto lg:!w-[95vw] lg:!h-[90vh] lg:!rounded-2xl lg:!m-auto p-0 !overflow-hidden">
```

13 `!`-prefixed utilities. The block comment above explains *why*
(daisyUI v5's `.modal-box` defaults win over plain Tailwind), which
is exactly the right defensive documentation — without it, a future
maintainer would assume the `!` was over-engineering.

If this pattern proliferates (other modals needing fullscreen-on-mobile),
extracting a `daisyUI` plugin variant or a `.modal-box.modal-fullscreen`
class would let callers do `<div class="modal-box modal-fullscreen">`
and avoid the !important escalation. Not worth doing for one site.

**Where:** `lib/phoenix_kit_web/components/media_browser.html.heex:1259`

### NITPICK — Chevron-button wrapper: rationale is good, comment placement is split

`lib/phoenix_kit_web/components/media_browser.html.heex:1273-1276`:

```heex
<%!-- Chevron positioning sits on a wrapper div, not the button.    --%>
<%!-- daisyUI's active-state CSS replaces `transform` with          --%>
<%!-- `scale(0.97)` on click, which would clobber a -translate-y-1/2 --%>
<%!-- on the button itself and make it jump down 50% of its height. --%>
```

This explanation belongs *next to* the wrapper-div pattern. Currently
the comment is above the `<%= if has_prev do %>` guard but the same
principle also drives the `has_next` block 14 lines below. A
maintainer editing only the next-button (e.g., to add a hover state)
might miss the active-state-clobbering rationale. Either:

- Move the comment to a moduledoc-level note about the modal layout, or
- Repeat (2 lines) above the next-button block.

Cosmetic.

**Where:** `lib/phoenix_kit_web/components/media_browser.html.heex:1273-1290`

## What's good

- **Default-action flip is the right design.** Read-only modal preview
  on click is the intuitive default; the previous "click adds to
  hidden selection" was an admin-internal pattern that surprised
  picker users. Long-term win even though the migration is real.
- **`get_connect_info(socket, :uri)` for return_to.** This is the
  cleanest LV-side equivalent to `maybe_store_return_to/1` — uses the
  socket-bound URI rather than peeking at conn private state. The
  fallback for missing/unparseable URI is correct (just go to the
  login page; the user types whatever they were trying to reach
  again). Pairs naturally with the existing `?return_to=` flow in
  `login.ex:54`.
- **Modal layout fix is *load-bearing* commented.** The `!important`
  chain explanation, the chevron-wrapper rationale, the close-button
  visibility note ("solid bg-base-100 + ring + shadow-lg keeps it
  visible against any image content (the previous bg-base-100/80
  blended into light photos and disappeared)") — every weird-looking
  decision has a one-paragraph explanation. This is the pattern I
  want to see in CSS-heavy LV templates.
- **`MediaImageZoom` mount/destroyed lifecycle is correct.**
  - `mounted` checks `self.el.isConnected` after the async script
    load — covers the "user closed the modal mid-fetch" race.
  - `destroyed` removes the wheel listener from the parent (not
    just the image element), avoiding a leak when the modal is
    repeatedly opened/closed.
  - `try/catch` around `panzoom.destroy()` handles the case where
    Panzoom failed to attach. Conservative.
- **The `:state_mismatch` ergonomics analogue.** PR #516 tightened
  OAuth state to `:state_mismatch` rather than lenient `:ok`; this
  PR's `login_path_with_return_to` follows the same shape — guard
  the unhappy path by returning a safe fallback rather than
  partial-credit data. Consistent house style.
- **AGENTS.md updated alongside code.** The "Click behavior" section
  in the PR diff matches the new code path. External docs and
  internal behaviour stay in sync — easy to forget on a UX change.
