# PR #621 — Extend activity deep-links: actor/target, integrations, module callback

**Author:** alexdont (`feat/activity-deep-link-extensibility`)
**Merge:** `5316ab41` · **Reviewer:** Claude · **Date:** 2026-07-07

## Summary

Extends the resource deep-link system (`PhoenixKit.ResourceLinks`, added in #619) three ways:

1. **Actor/target links** — the activity feed (`index`/`show`) and the notifications
   admin list now render the actor email and target email as links to those users'
   admin pages, via a new light-weight `resource_email_link/1` component.
2. **Integration handler** — `"integration"` resources resolve to their Settings
   edit page (`PhoenixKit.Integrations.ResourceLinks`), and `Integrations.log_activity`
   now stamps `resource_uuid` so integration activities deep-link.
3. **Module-declared links** — a new optional `resource_links/0` `PhoenixKit.Module`
   callback lets external modules register `resource_type => resolver` entries
   (resolver = a module implementing `resolve_comment_resources/1`, a path-template
   string, or a `%{"path" => …, "title" => …}` map). Wired into `ResourceLinks`
   via `module_resolvers/0` / `module_templates/0` with a documented precedence.

Also adds `Notifications.admin_list/1` + a paginated "All notifications" table on the
Notifications admin overview page.

## Verdict

Solid, well-documented PR. The resolution refactor is correct and the extensibility
contract mirrors the existing handler contract cleanly. One low-severity robustness
fix applied; the rest are improvement notes. No blocking issues.

Verification performed (traced, not assumed):
- `ModuleRegistry.all_modules/0` returns `[module()]` atoms → the `module_resolvers/0`
  iteration (`Code.ensure_loaded?/1` + `function_exported?/3`) is sound.
- `Integrations.find_uuid_by_provider_name/1` accepts `{provider, name}` and returns
  `{:ok, uuid}` / `{:error, _}` → the `log_activity` stamp is correct.
- `Notifications.Render.render/2` exists (`render(notification, locale \\ nil)`) →
  `render_notification/2` is valid.
- `resource_email_link/1` is reachable (`PhoenixKitWeb.Components.Core.ResourceLink`
  imported at `phoenix_kit_web.ex:129`); `PhoenixKit.ResourceLinks` aliased in the
  component; all handler/template results carry `:path` and `:prefixed`, so the
  `<.link navigate|href>` / `url/1` calls never `KeyError`.
- Precedence `cond` in `resolve_for_type/2` preserves the pre-PR fall-through
  (empty handler → template) — no regression.

## Findings

### BUG - LOW — notifications pagination range descends for out-of-range `?page=` (FIXED)

`lib/phoenix_kit_web/live/modules/notifications/index.html.heex`

```heex
<%= for page <- max(1, @page - 2)..min(@total_pages, @page + 2) do %>
```

`parse_page/1` clamps the `?page=` param to a minimum of 1 but not to `total_pages`
(which isn't known until after the query). For a hand-crafted URL like
`?page=99999` with `total_pages=2`, the range becomes `99997..2`, a **descending**
range, and the comprehension renders ~99 995 page buttons — a mild self-inflicted
DoS on the admin's own LiveView render. Normal in-app navigation never triggers it
(links only emit `1..total_pages`), hence LOW.

**Fix applied:** added an explicit `//1` step so an out-of-range start yields an
empty range instead of a descending one:

```heex
<%= for page <- max(1, @page - 2)..min(@total_pages, @page + 2)//1 do %>
```

**Note:** the core `PhoenixKitWeb.Components.Core.Pagination.pagination_range/2`
helper (`pagination.ex:299`) has the *identical* `max(1, p-2)..min(total, p+2)`
pattern with no step guard — same latent issue, pre-existing, not touched here.
Worth the same `//1` treatment in a future pass (see improvement below).

### IMPROVEMENT - MEDIUM — the headline `resource_links/0` mechanism has no test coverage

`test/phoenix_kit/resource_links_test.exs` gains a test for the built-in
`"integration"` handler only. The actual new feature — module-declared
`resource_links/0` resolution through `module_resolvers/0` / `module_templates/0`,
and the three-way precedence (resolver module → module template → host setting
template) — is untested. A regression in `module_templates/0` (e.g. the `is_atom`
partition, or `prefixed: true` on module templates) would ship silently.

Not fixed here: exercising it needs a fake module registered in
`ModuleRegistry`'s persistent-term, which is awkward in the DB-free unit suite.
Recommend a follow-up that stubs `all_modules/0` (or seeds the pterm) and asserts
(a) a template-string entry resolves `prefixed: true` and (b) a resolver-module
entry appears in `handlers/0`.

### IMPROVEMENT - LOW — `module_resolvers/0` recomputed up to 2× per resource type

Per `resolve/1`, each resource type calls `resolve_for_type/2`, which calls
`handlers/0` → `module_resolvers/0`, and (on a handler miss)
`resolve_via_module_template/2` → `module_templates/0` → `module_resolvers/0`
again. So `module_resolvers/0` — which iterates every discovered module and calls
`resource_links/0` on each — runs between T and 2T times for a page with T resource
types. Cheap per call, but avoidable: compute it once per `resolve/1` and thread it
(or memoize). Minor; left as-is.

### NITPICK — reuse `<.pagination>` instead of hand-rolling; stats queries in `mount`

- The notifications page hand-rolls the `join` pagination markup. Core already ships
  `<.pagination>` / `pagination_controls/1` for exactly this (standalone admin page
  with deep-linkable `?page=` state). Reusing it would be more consistent (and, once
  the range guard above lands there, inherit the fix). Left as-is to keep the PR's
  footprint.
- `mount/3` calls `Notifications.admin_stats()` and `retention_days()` (both DB/
  settings reads) — runs twice (HTTP + WS mount) per the LiveView Iron Law.
  **Pre-existing** (not introduced by this PR); the PR correctly moved the *list*
  load into `handle_params/3`. Flagging only so it's on record.
