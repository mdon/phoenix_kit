# Grok Review — PR #744 "Make nav_tabs adoptable (patch, variant, badge tone) and fix the daisyUI tabs class"

**Merge commit:** 1f0b86cc
**Author:** mdon (fix/daisyui-tabs-box)
**Files:** `lib/phoenix_kit_web/components/core/nav_tabs.ex`, `lib/phoenix_kit_web/live/users/live_sessions.ex`, `lib/phoenix_kit_web/live/users/live_sessions.html.heex`, `test/phoenix_kit_web/components/core/nav_tabs_test.exs`

## Summary of the change

`nav_tabs` was the ecosystem's tab component in name only — most module
libraries reimplemented the markup, which is why renaming one daisyUI class
(`tabs-boxed` → `tabs-box` in v5) took 21 edits across 8 repositories. Two
gaps in the component itself were why: it could only emit `navigate` (a
query-param strip remounts and drops socket state), and the frame was baked
in (`class` can only add). This PR closes both, plus the badge gaps the
connections migration turned up, and migrates `live_sessions`' filter row
which had been kept hand-rolled because its handler read `phx-value-type`
instead of the component's `phx-value-tab`.

- Link keys now mirror `Phoenix.Component.link/1`: `:navigate`, `:patch`,
  with `:path` a permanent alias for `:navigate`. Two keys raise;
  `nil` counts as absent.
- `variant={:plain}` drops `tabs-box` (which *is* the daisyUI frame), not
  just the redundant `bg-base-200 p-1` overrides.
- Optional keys treat `nil` as absent (`badge: if(n > 0, do: n)` no longer
  renders an empty pill). `:badge_class` wins over the active-tab primary
  tone.
- `tablist_class/2` and `tab_class/2` are public so tab-*styled* markup
  that is not a tab strip can share one definition.
- 19 component tests cover both link modes, the payload key, both variants,
  badges, and each failure path.

Verified against producing code, not the PR text:

- Existing in-repo callers (`jobs/index`, `user_details`,
  `modules/billing/.../billing_tabs.ex`) already match on `%{"tab" => _}`
  and use `:path` or event tabs — both still work.
- `live_sessions`' URL state still uses `url_key: "type"`; only the
  *event* payload changed, and the only emitter is the template this PR
  rewrites. No other `filter_by` / `phx-value-type` pair exists on that
  LiveView.
- Grep of every `phoenix_kit*` checkout found no local `tab_class/1` or
  `tablist_class/2` that would collide with the new public helpers once
  they land in every LiveView via `use PhoenixKitWeb, :live_view`.

Companion PRs (module libraries) depend on this landing first.
`phoenix_kit_user_connections` #7 uses `:patch` / `:badge_class` and would
render inert tabs against an older core.

## Findings

### 1. IMPROVEMENT - MEDIUM — blanket `import NavTabs` now injects `tab_class` / `tablist_class` into every LiveView

`phoenix_kit_web.ex` already blanket-imports `PhoenixKitWeb.Components.Core.NavTabs`.
Before this PR that only exported `nav_tabs/1`. After it, `tab_class/{1,2}`
and `tablist_class/{0,1,2}` are in every LiveView in the ecosystem.

The same file documents this exact failure mode on `EmailStatusBadge`
(`format_status/1` / `status_class/1` — `phoenix_kit_posts` hit it) and
the umbrella AGENTS.md records core 2.0's `bar_chart/1` breaking
`phoenix_kit_web_analytics` the same way.

No current collision in any checked-out module. The helpers are *meant* to
be used from templates, so restricting the import to `nav_tabs: 1` would
defeat the point. **Fixed** by making the imported surface explicit
(`only:`) and adding the same class of comment `EmailStatusBadge` carries,
so a later helper does not silently join the global namespace.

### 2. NITPICK — test moduledoc says passing `:patch` now raises; it does not

> A module passing `:patch` to an older core would land in the button
> branch with `on_change` nil and render a strip wired to `phx-click={nil}`
> — right down to the styling. Those cases raise now.

The raise is for *two* link keys on one tab. A lone `:patch` is the new
happy path. The older-core silent-degrade story is real and is why
user_connections #7 must merge after this release, but it is not what
raises. **Fixed** the moduledoc.

### 3. NITPICK — no LiveView test for the live_sessions payload-key rename

`handle_event("filter_by", %{"type" => _}, _)` became `%{"tab" => _}`. The
template is the only emitter, so the pair is consistent. There is no
existing `live_sessions` test file to extend, and adding a full
integration mount just to assert the event key is out of proportion.
Left as-is; the component tests already pin `phx-value-tab`.

## Not fixed / out of scope

- `:boxed` still ships the redundant `bg-base-200 p-1` on top of
  `tabs-box`. The PR calls this out; keeping them avoids a visual shift
  for every existing strip. A later cleanup can drop them once callers
  have been eyeballed.
- Open Graph's 9 segmented controls stay out of the component (radio
  inputs inside a `phx-change` form). Agreed — that is a radiogroup, not
  a tablist.
- `Logger.warning` on a dead tab fires on every render. Deliberate: this
  is a library and a raise would take the LiveView down. Not worth a
  once-token.
