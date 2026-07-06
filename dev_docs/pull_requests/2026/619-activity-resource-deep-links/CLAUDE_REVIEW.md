# PR #619 — Add resource deep-links to the activity feed

- **Branch:** `alexdont/feat/activity-resource-deep-links`
- **Author:** Alexander Don (alexdont)
- **Merge:** `e74cf0e2` (feature commit `376e0e24`)
- **Version:** no bump in the PR; shipped in the 1.7.176 release cut alongside #618.
- **Reviewer:** Claude (Opus 4.8)

## Summary

Activity entries now link to the record the action happened on. A new
`PhoenixKit.ResourceLinks` resolver turns an entry's `(resource_type,
resource_uuid)` into the underlying resource's page, reusing the comments
moderation two-tier mechanism (auto-registered handler modules →
`comment_resource_paths` string templates). A core `<.resource_link>` chip
renders the resolved title + thumbnail/icon; the Activity index Subject cell and
the detail page render it, falling back to the resolved user email, then a
truncated uuid.

**Overall: correct, no changes required.** No CRITICAL/HIGH bugs. Resolution is
batched (no N+1), fails open to a uuid fallback rather than crashing the admin
feed, and URL-encodes path placeholders. The one substantive finding is a
cross-package **drift risk** that can't be fixed from this repo; the rest are
nitpicks. Documented, not fixed — see rationale per item.

## Verification performed

- **Key matching holds.** Handlers return `%{uuid => info}` keyed by the DB
  `f.uuid` (loaded as the UUIDv7 string), and `resolve/1` re-keys the context by
  `{resource_type, id}`. The index/show templates look up
  `{entry.resource_type, entry.resource_uuid}` — same string form on both sides,
  so links resolve.
- **Correct lifecycle on the index.** `ResourceLinks.resolve/1` is called in
  `load_activities/1`, reached via `handle_params` → `apply_params` — not
  `mount/3`. Batched one query per `resource_type`.
- **Handler return shape is safe for the chip.** Both core handlers
  (`PhoenixKit.Annotations`, `PhoenixKit.Users.CommentResources`) always return a
  `:title` key (+ optional `:thumb_url`), so `<.resource_link>`'s `@info.title`
  can't `KeyError`. `full_title` is absent from handler results but the component
  falls back with `@info[:full_title] || @info.title`.
- **Injection-safe paths.** `apply_path_template/3` runs uuid and
  `:metadata.<key>` values through `URI.encode/2`; titles render as
  auto-escaped HEEx text.
- **Admin-only surface.** The Activity feed is admin-gated, and the resolved
  targets (`/admin/media/:uuid`, `/admin/users/view/:uuid`) are admin routes, so
  a signed thumbnail URL in a chip is not a public exposure.

## Findings

### IMPROVEMENT - MEDIUM — handler registry duplicated across packages (drift risk); NOT fixable here

`lib/phoenix_kit/resource_links.ex` — `default_resource_handlers/0`

`ResourceLinks` re-declares the `"post"`/`"file"`/`"user"` → handler-module map.
Per the moduledocs of `PhoenixKit.Annotations` and
`PhoenixKit.Users.CommentResources` ("Registered as the `…` handler by
`phoenix_kit_comments`' `resolve_comment_resources/1` dispatch"), the external
comments package **also** owns a copy of this registry. Two registries in two
packages that must stay in sync is the classic "two lists drift apart" smell:
add a fourth handler to one and not the other, and deep-links silently differ
between the Comments moderation admin and the Activity feed.

- **Why it matters:** the whole value of the shared resolver is a single source
  of truth; a duplicated registry undermines that.
- **Why not fixed here:** the duplicate lives in the external
  `phoenix_kit_comments` package, not this repo. The `ResourceLinks` moduledoc
  claims comments "delegates here," but that delegation must be implemented (and
  the local copy deleted) on the comments side. Nothing in this repo can enforce
  it.
- **Recommendation:** when updating `phoenix_kit_comments`, point its dispatch at
  `PhoenixKit.ResourceLinks.handlers/0` and delete its local map, so
  `handlers/0` is the sole registry.

### IMPROVEMENT - LOW — `Activity.Show.mount/3` resolves links in `mount/3` (pre-existing pattern)

`lib/phoenix_kit_web/live/activity/show.ex` — `mount/3`

The added `ResourceLinks.resolve([entry])` is a DB-backed call placed in
`mount/3`, which LiveView runs twice (HTTP + WS). This **matches the module's
existing shape** — `Activity.get_entry/1` and `resolve_resource_user/1` already
run in `mount/3` here — so the PR doesn't introduce the anti-pattern, but the
extra resolution does double on reconnect. Left as-is to avoid diverging one
query from the rest of the mount; the index page already does the right thing
(resolves in `handle_params`). Recorded so the cost is on the books.

### NITPICK — double `Map.get(@resource_users, ...)` in the index template

`lib/phoenix_kit_web/live/activity/index.html.heex`

The `cond` evaluates `Map.get(@resource_users, entry.resource_uuid)` once in the
`match?/2` guard and again to read `.email` in the body. Binding it once would
read cleaner. Rendered per row, but it's a cheap map lookup on an already-loaded
map — not worth the churn on merged code. No fix.

### NITPICK — uuid-truncation length differs between fallback paths

`lib/phoenix_kit/resource_links.ex`

The handler-less `resolve_title/4` fallback truncates a uuid to 8 chars
(`String.slice(0..7)`), while the template path's `truncate_value/1` uses 15
(`@metadata_max_display_length`). Cosmetic only — both are display strings.

### DOC NIT — return-shape moduledoc lists `full_title` as always present

`lib/phoenix_kit/resource_links.ex` moduledoc shows `full_title:` in the value
map, but handler-backed results omit it (only the template path sets it). The
component tolerates the absence. Harmless.

## Positives

- Batched resolution per `resource_type`; no N+1 across an activity page.
- `resolve_for_type/2` plus both handlers rescue to `%{}` — an unavailable or
  throwing handler degrades to the uuid fallback instead of crashing the feed.
- The index `cond` has a `true ->` catch-all, preventing `CondClauseError` when
  `resource_uuid` is nil but `resource_type` is set.
- Raw-path + render-time `Routes.path/1` (`prefixed: true`) vs verbatim
  host-template paths (`prefixed: false`) is consistent with the handlers'
  contract and avoids double-prefixing under a non-root `url_prefix`.
- Tests (`test/phoenix_kit/resource_links_test.exs`) cover the DB-free paths
  (item filtering, unknown-type fallthrough, `url/1` dispatch, `handlers/0`
  registration); handler/template resolution is left to call-site integration
  suites, which is reasonable.
