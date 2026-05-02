---
pr: 513
title: Updated media browser and leaf editor
author: alexdont
merged_at: 2026-05-02T15:14:59Z
reviewer: claude
verdict: APPROVE
---

# Review — PR #513

Seven commits, three product threads:

1. **Media viewer modal.** New `viewer={true}` attr on `MediaBrowser`.
   When set, clicking a file opens an in-place modal with the
   image/video/PDF/icon preview, filename / type / size / MIME /
   uploaded-at metadata, and a Download button. Closes via X / Esc /
   backdrop. Prev/next chevrons (and ←/→ keys) step through the
   current page's `uploaded_files`; arrows hide at boundaries.
   Replaces an earlier `view_path={…}` + standalone `/media/:uuid`
   page that was scrapped after the demo (one click vs. nav round-
   trip — modal won).
2. **Comments thread in the viewer sidebar.** When
   `PhoenixKitComments` is in the dep tree AND its admin toggle is
   on AND the viewer has a logged-in user, the modal embeds
   `PhoenixKitComments.Web.CommentsComponent` under the metadata
   block, scoped to `resource_type="file"`. Optional-dep wiring
   (`@compile {:no_warn_undefined}` + `Code.ensure_loaded?` +
   `@dialyzer :nowarn_function`) follows the established PhoenixKit
   pattern.
3. **`leaf 0.2.10 → 0.2.11`.** Bumps both `mix.exs` and the matching
   CDN URL in `priv/static/assets/phoenix_kit.js` so the browser's
   loaded leaf and the package's compiled-against version stay in
   lockstep.

The core refactor of `handle_event("click_file", …)` from the old
`if select_mode or not admin do …` two-mode if/else into a four-clause
`cond` (select_mode > admin > viewer > picker) is the structural win
of this PR — much easier to reason about and extend. Existing callers
(no `viewer` attr) keep their behavior because every existing branch
either hits `select_mode` or `admin` or falls through to the picker
default, and `viewer` defaults to `false`. AGENTS.md was updated in
the same PR with the four-mode click-priority doc, which is exactly
the right move.

## Findings

### BUG-LOW — `String.starts_with?(f.mime_type, "image/")` crashes when `mime_type` is nil

`lib/phoenix_kit_web/components/media_browser.html.heex:1281` and
:1284:

```heex
<%= cond do %>
  <% String.starts_with?(f.mime_type, "image/") -> %>
    <img ... />
  <% String.starts_with?(f.mime_type, "video/") -> %>
    <video ... />
  <% f.mime_type == "application/pdf" -> %>
    <iframe ... />
  <% true -> %>
    <%!-- icon fallback --%>
<% end %>
```

`String.starts_with?/2` requires a binary first argument; `nil`
raises `FunctionClauseError`. Looking at the `Storage.File` schema
(`lib/modules/storage/schemas/file.ex:125`):

```elixir
field :mime_type, :string
```

— no `:default`, no `validate_required`. The DB column may or may
not be `NOT NULL`; in any case, a row with `mime_type = nil` would
crash the modal render rather than fall through to the icon
fallback.

**Suggested fix:** guard the binary checks.

```heex
<% is_binary(f.mime_type) and String.starts_with?(f.mime_type, "image/") -> %>
  <img ... />
<% is_binary(f.mime_type) and String.starts_with?(f.mime_type, "video/") -> %>
  <video ... />
<% f.mime_type == "application/pdf" -> %>
  <iframe ... />
<% true -> %>
  <%!-- icon fallback --%>
```

A nil mime_type then falls through cleanly to the icon. The third
branch (`==`) is already nil-safe. Trivial and defensive.

### IMPROVEMENT-MEDIUM — PDF iframe lacks `sandbox` attribute

`media_browser.html.heex:1295`:

```heex
<iframe
  src={f.urls["original"]}
  class="w-full h-full rounded border-0"
  title={f.filename}
></iframe>
```

PDFs can carry embedded JavaScript that browsers' built-in PDF
viewers may execute. Without `sandbox`, that JS runs with the
iframe's origin — and if `f.urls["original"]` is **same-origin** to
the parent page (e.g. proxied through a PhoenixKit
`Storage.Plug`-served route), the embedded JS could potentially
reach the parent via `window.parent`. Cross-origin signed S3 URLs
isolate at the browser level so the practical risk is lower; on-
prem deployments serving files from the same origin are exposed.

Suggested fix:

```heex
<iframe
  src={f.urls["original"]}
  sandbox="allow-same-origin"
  class="w-full h-full rounded border-0"
  title={f.filename}
></iframe>
```

`allow-same-origin` lets the PDF viewer load fonts / fetch resources
but blocks scripts. If a deployment relies on PDF JS form-fill or
similar, drop this — but that's a deliberate opt-in.

Scoring this MEDIUM (not LOW) because (a) the modal exposes user-
uploaded files to other authenticated users, which is the expansion
of attack surface this PR introduces, and (b) the fix is one
attribute. LOW would be appropriate if the prior page already had
the same iframe — the page existed for one commit cycle, then was
replaced by the modal, so this is effectively new exposure.

### NITPICK — `viewer_idx` / `has_prev` / `has_next` computed in template on every render

`media_browser.html.heex:1238-1241`:

```heex
<%= if assigns[:viewer_file] do %>
  <% f = @viewer_file %>
  <% viewer_idx = Enum.find_index(@uploaded_files, &(&1.file_uuid == f.file_uuid)) %>
  <% has_prev = is_integer(viewer_idx) and viewer_idx > 0 %>
  <% has_next = is_integer(viewer_idx) and viewer_idx < length(@uploaded_files) - 1 %>
```

`Enum.find_index` walks the list each render, `length/1` walks again
for `has_next`. For a per-page list of files (≤ ~50) this is fine,
but the convention in this codebase is to precompute in the LV /
component and expose as assigns. The viewer only changes file via
`step_viewer/2` and `click_file`, so computing once when
`viewer_file` is assigned would do.

Move into `step_viewer/2` (and the click_file viewer branch):

```elixir
defp assign_viewer(socket, file) do
  list = socket.assigns.uploaded_files

  case file && Enum.find_index(list, fn f -> f.file_uuid == file.file_uuid end) do
    nil ->
      socket
      |> assign(:viewer_file, nil)
      |> assign(:viewer_has_prev, false)
      |> assign(:viewer_has_next, false)

    idx ->
      socket
      |> assign(:viewer_file, file)
      |> assign(:viewer_has_prev, idx > 0)
      |> assign(:viewer_has_next, idx < length(list) - 1)
  end
end
```

— pure tidy-up, not load-bearing.

### NITPICK — `comments_enabled?/0` runs on every modal render

`media_browser.html.heex:1374`:

```heex
<%= if comments_enabled?() and assigns[:phoenix_kit_current_user] do %>
```

The function is:

```elixir
defp comments_enabled? do
  Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
rescue
  _ -> false
end
```

`Code.ensure_loaded?/1` is cheap after the first call, but
`PhoenixKitComments.enabled?/0` typically reads from
`phoenix_kit_settings` (DB roundtrip). The modal re-renders on every
diff while open — including each prev/next step, each comment fan-
out, etc. This is one DB hit per render just for the gating check.

Compute once when `viewer_file` first becomes non-nil and stash in
an assign:

```elixir
# In handle_event("click_file", …, viewer branch):
{:noreply,
 socket
 |> assign(:viewer_file, find_uploaded_file(socket, file_uuid))
 |> assign(:viewer_comments_enabled, comments_enabled?())}
```

The setting could change while the modal is open, but that's an
acceptable staleness window for UI gating — operators don't usually
flip enabled/disabled while users have modals open.

### NITPICK — `step_viewer/2` could simplify

`media_browser.ex:1377-1390`:

```elixir
defp step_viewer(socket, direction) do
  current = socket.assigns.viewer_file
  list = socket.assigns.uploaded_files

  with %{file_uuid: uuid} <- current,
       idx when is_integer(idx) <-
         Enum.find_index(list, fn f -> f.file_uuid == uuid end),
       next_idx <- if(direction == :prev, do: idx - 1, else: idx + 1),
       true <- next_idx >= 0 and next_idx < length(list),
       %{} = next_file <- Enum.at(list, next_idx) do
    assign(socket, :viewer_file, next_file)
  else
    _ -> socket
  end
end
```

Two notes:

- `next_idx <- if(...)` always succeeds (an integer is matched). The
  `<-` is functioning as bare assignment. Could be `next_idx =
  if(...)` to make intent explicit, since the `with` chain doesn't
  actually need the bind to fail-fast.
- The bounds check (`true <- next_idx >= 0 and …`) is necessary
  because `Enum.at/2` accepts negative indices and counts from the
  end. Without it, `step_viewer(:prev)` from index 0 would
  wrap-around to the last file. The current implementation is
  correct; this is just worth a comment so the next reader doesn't
  delete the bounds check thinking `Enum.at` returns nil for
  negatives.

### NITPICK — `.leaf-comments-compact` CSS overrides target Tailwind utility classes

`media_browser.html.heex:14-32`:

```css
.leaf-comments-compact .text-sm { font-size: 0.75rem; ... }
.leaf-comments-compact .p-3 { padding: 0.5rem; }
.leaf-comments-compact .btn-xs { ... }
```

The wrapper shrinks the comments component's typography / padding /
avatars / buttons by overriding the *Tailwind utility classes that
the component currently uses*. If `PhoenixKitComments`'s template
ever changes (`p-3` → `p-2.5`, `btn-xs` → custom class, etc.), these
overrides become silent no-ops with no warning. The inline comment
acknowledges the trade-off honestly.

Long-term: a `compact={true}` attr on `CommentsComponent` that the
component honors internally (its own theme switch, not class
overrides) would be more robust. But that's a cross-package change
out of scope for this PR — the current approach is the right
short-term call.

### NITPICK — `phx-window-keydown` could conflict with parent page key handlers

`media_browser.html.heex:1244`:

```heex
<div class="modal modal-open" phx-window-keydown="viewer_keydown" phx-target={@myself}>
```

`phx-window-keydown` listens on the window, regardless of focus.
Fine for the modal's exclusive use (no other page element should
hear ←/→ while the modal is open) — except if the parent page
itself has a `phx-window-keydown` handler bound to ←/→ for, say,
back/forward navigation in a wizard. Both fire. Not a real concern
for current callers (the admin Media page, the user Media page),
but it's worth keeping in mind for future embeds.

If a clash ever surfaces: switching to `phx-keydown` on a focused
container (`<div tabindex={-1} phx-mounted={JS.focus()}>`) would
scope the listener.

### NITPICK — `bandit 1.10.4 → 1.11.0` arrived in the lockfile silently

`mix.lock` shows bandit bumped from 1.10.4 to 1.11.0 without any
commit body mentioning it. Almost certainly came in via a
`mix deps.update leaf` that incidentally pulled the latest bandit
because of `~>` constraints. Minor version bump on the HTTP server,
not high-risk, but worth a sentence in a future commit body when
ancillary lockfile churn ships in a feature PR — saves the next
reader the "wait, why is bandit in this PR?" pause.

### IMPROVEMENT-LOW — no test coverage on the new branching

`handle_event("click_file", …)` now has four branches and
`step_viewer/2` has boundary logic. There's no
`test/phoenix_kit_web/components/media_browser_test.exs`, and the
component-test gap is already in the AGENTS.md TODOs section from
PR #512.

When that sweep happens, this PR's branches are good candidates:

- `select_mode` + click → toggles only, doesn't open modal/admin
- `admin=true` + click → push_navigate fires, no modal
- `viewer=true` + click → `viewer_file` is set
- default + click → enters select_mode + selects
- `step_viewer(:prev)` from index 0 → no-op
- `step_viewer(:next)` from last index → no-op
- `step_viewer(:next)` from middle → next file's data

Worth tracking against the existing TODOs entry rather than blocking
this PR.

## Things done well

- **`cond`-based click_file dispatch.** Replaces the original
  `if select_mode or not admin do …` two-mode branch with a four-
  clause `cond` — strictly easier to read, easier to extend, and
  preserves existing callers because every prior branch hits the
  same path it always did.
- **Backwards-compatible default.** `viewer` defaults to `false`
  via `assign_new`; every existing caller behaves exactly as before.
- **Optional-dep handling for PhoenixKitComments.** The triad of
  `@compile {:no_warn_undefined, …}` (compile-time) +
  `Code.ensure_loaded?/1` (runtime) +
  `@dialyzer {:nowarn_function, comments_enabled?: 0}` (dialyzer)
  is exactly the established PhoenixKit pattern for optional sibling
  packages. The `try/rescue` fallback in `comments_enabled?/0` is
  the right belt-and-suspenders.
- **Comments component re-keyed by file_uuid.** `id={"media-comments-"
  <> f.file_uuid}` ensures that prev/next remounts the comments
  component cleanly, picking up the new file's thread. Without this,
  the previous file's comments would linger across navigation.
- **Boundary-clamped `step_viewer/2`.** No wrap-around — users
  hitting the start/end see chevrons disappear instead of being
  silently teleported to the other end. Right UX call.
- **`find_uploaded_file/2` returning `nil` is a silent no-op.** If
  the file uuid isn't in the current page's list (pagination drift,
  file deleted between fetch and click), the modal simply doesn't
  render. No crash, no error toast, no orphan UI state.
- **AGENTS.md updated in the same PR.** The new four-mode click
  priority is documented; the two-mode "admin vs picker" doc is
  replaced. No drift between code and AGENTS.md (which has bitten
  recent PRs — see #511's review).
- **Honest dev history.** Three iterations (page → page polish →
  modal replacement) preserved as separate commits. Easy to follow
  the design evolution; the final modal-only design is the right
  product call (smaller diff than maintaining a route + a modal,
  faster UX for "preview many files in a row").
- **Activity-log convention followed.** `resource_type="file"`
  matches the storage system's existing convention so comments link
  cleanly into the activity feed.
- **Leaf bump done thoroughly.** Both `mix.exs` and the CDN URL in
  `phoenix_kit.js` updated. Easy to forget the JS-side; this PR
  caught it.

## Out of scope (worth tracking)

- **Component test coverage.** Already in AGENTS.md TODOs (#512's
  contribution). The branches in `click_file` and the boundary
  logic in `step_viewer` are good candidates when that sweep
  happens.
- **Per-user / public-flag access for the modal.** The PR's first
  commit message is explicit: "the viewer enforces no extra access
  checks beyond authentication, matching the admin detail page's
  approach. Tightening to per-user / public-flag access is a
  separate feature." Track separately.
- **`compact={true}` attr on `PhoenixKitComments.Web.CommentsComponent`.**
  Long-term replacement for the brittle `.leaf-comments-compact`
  Tailwind-utility overrides. Cross-package, not blocking.

## Verdict

**APPROVE.** The viewer modal is a clean, opt-in addition to the
MediaBrowser with sensible defaults that preserve every existing
caller's behavior. The Comments integration follows the established
optional-sibling pattern. The `cond` refactor of click_file is a
real readability win.

The findings are mostly NITPICKs. The two worth landing soon:

1. **Guard `String.starts_with?` with `is_binary(f.mime_type)`** —
   crash safety for files with nil mime_type.
2. **Add `sandbox="allow-same-origin"` to the PDF iframe** — defense
   in depth for embedded-JS PDFs in same-origin deployments.

Both are one-line fixes and worth a follow-up commit.
