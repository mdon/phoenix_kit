# PR #850: Key admin view permission cache by {module, live_action}, not module alone

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (`96f5d9ed`), not yet released; the BUG - HIGH below is fixed post-merge
**Date**: 2026-09-21

## Goal

Custom admin tabs cached their permission by LiveView **module**. Two tabs on
the same module with different `live_action`s (a landing redirector and the
page behind it) collided on one entry, the later registration won, and a
tab's `priority` silently decided which key guarded both routes — including
a redirect loop for users holding the page's own key (#844). The PR keys the
cache by `{module, live_action}` when a tab names an action, keeps a bare
`module` key for tabs that do not, and threads `live_action` through the
mount gate, `can_access_admin_view?/3`, the sidebar's reachability check and
the post-login `return_to` check.

## Verified

- The #844 case is fixed: two actions of one module now resolve
  independently, whichever registers first.
- `{Mod, nil}` is normalised to the bare-module key at registration, so it
  cannot land under a key no lookup uses.
- The remaining action-less callers (`Dashboard.Overview`'s card gates,
  `LayoutWrapper`'s `can_open_inbox`, the moduledoc example) all check core
  views in the static `@admin_view_permissions` map, which this PR does not
  touch — they are unaffected.
- An unmapped view fails **closed** (`admin_view_permission_check(scope,
  nil)` admits only a scope holding every enabled permission), so the
  finding below is a lockout, not an exposure.
- Tests on the combined tree (this PR, #847, #851 and the unreleased V200
  work): 317 tests, 0 failures.

## Findings

### BUG - HIGH: a LiveView's non-tab actions are now unmapped — partial roles are locked out of them

> **Fixed post-merge** as proposed below: `infer_permission_from_custom_tabs/2`
> falls back, last, to `sole_action_permission/2` — the module's tabs'
> permission when they all agree, `nil` when they disagree. Regression tests
> in `per_action_view_permission_test.exs` ("an action with no tab of its own
> (review of #850)"), verified to fail without the fallback. Three existing
> tests asserted the lockout for a single-tab module — "a routed {Mod,
> :action} tab is reachable through the action-aware lookup only"
> (`per_action_view_permission_test.exs`), and "the 1-arity call does not
> see a tab registered under an action" and "omitting the action treats the
> view as unmapped…" (`auth_test.exs`). They now pin the same property on
> the #844 shape (two tabs, two keys), where a module-only lookup must still
> refuse; the first `auth_test.exs` one also asserts the single-tab case
> resolves.

The common admin shape is one LiveView serving several actions while only
one of them is a tab:

```elixir
# config: the tab
%{live_view: {HostAppWeb.ReportsLive, :index}, permission: "reports", …}

# router: the same module, other actions — no tab of their own
live "/admin/reports/:id", ReportsLive, :show
live "/admin/reports/:id/edit", ReportsLive, :edit
```

Before this PR the tab was cached under the bare module, so `:show` and
`:edit` were enforced with `"reports"`. Now it is cached only under
`{ReportsLive, :index}`, and `infer_permission_from_custom_tabs/2` looks up
`{module, action}` then `module` — both miss for `:show`/`:edit`. Measured
on the merged tree (a throwaway probe, since removed):

```
permission_key_for_admin_view(ReportsLive, :index) => "reports"
permission_key_for_admin_view(ReportsLive, :show)  => nil
permission_key_for_admin_view(ReportsLive, :edit)  => nil
permission_key_for_admin_view(ReportsLive)         => nil
```

`nil` is the unmapped branch, which admits only an Owner-equivalent scope.
So a role holding `"reports"` opens the list and is refused on every record
it links to. Owner and a full Admin never notice — they hold every key,
which is why tests that exercise the flow as Admin pass. Namespace inference
(steps 3–4 of the resolution order) rescues core and plugin modules; it does
nothing for **host** LiveViews, which are exactly the custom-tab case this
cache exists for. The post-login `return_to` check inherits the same answer,
so a partial role's `return_to` to `/admin/reports/5` is dropped too.

**Fix** — keep the exact key first, then fall back to the module's action
entries when they all agree:

```elixir
defp infer_permission_from_custom_tabs(view_module, live_action) do
  custom = Permissions.custom_view_permissions()

  Map.get(custom, {view_module, live_action}) ||
    Map.get(custom, view_module) ||
    sole_action_permission(custom, view_module)
end

# Every tab on this module maps to one permission: an action with no tab of
# its own is guarded by it, as it was before per-action keys. When the
# module's tabs disagree (#844) there is no safe answer — stay unmapped.
defp sole_action_permission(custom, view_module) do
  case for({{^view_module, _action}, key} <- custom, uniq: true, do: key) do
    [key] -> key
    _none_or_conflicting -> nil
  end
end
```

That restores the pre-PR behaviour for the single-permission module (the
common case) and keeps #844's split strict: a module whose tabs carry
different keys still answers only for its exact actions. A regression test
should register one `{Mod, :index}` tab and assert `:show` resolves to its
key, and a two-key module still leaves `:show` unmapped.

### NITPICK: the warning on a changed mapping now names a tuple

`do_cache_custom_view_permission/2` logs `View {HostAppWeb.ReportsLive,
:index} permission changed …` — accurate, but a host searching logs for the
module name as it appears in its config (`HostAppWeb.ReportsLive`) finds it
only if it also matches the tuple form. Cosmetic.
