# PR #800 Review — Let a module own the /admin landing page, and let users pick their start page

**Author:** Max Don (mdon)
**Merged:** 2026-09-11, by fotkin (merge commit `cebea356`)
**Files:** `lib/phoenix_kit/users/auth.ex`, `lib/phoenix_kit_web/live/components/user_settings.ex`,
`lib/phoenix_kit_web/live/dashboard.ex`, `lib/phoenix_kit_web/live/dashboard.html.heex`,
`lib/phoenix_kit_web/users/auth.ex`, `test/phoenix_kit/users/start_page_preference_test.exs`,
`test/phoenix_kit_web/live/dashboard_home_binding_test.exs`

## Summary

Two features:

1. An optional `phoenix_kit_dashboards` module can claim the `/admin` landing
   page (a `live_render`ed child), duck-typed via `admin_home_dashboards/1` so
   core carries no dependency on it. The built-in overview steps aside live,
   via a `{:admin_home, :shown | :empty}` message, as an administrator binds
   or unbinds a dashboard — no reload needed.
2. Each user can pick a personal "start page" (any top-level admin tab they
   can actually see), stored as a relative path in `custom_fields["start_page"]`
   exactly like `preferred_locale`, and consulted at login — after an explicit
   `return_to`, before the site's configured `after_login_path`/`/admin` default.

## Findings

### BUG - MEDIUM: duplicate, weaker copy of the redirect-safety guard

`PhoenixKit.Users.Auth.update_user_start_page/2` validated its input with a
private `local_relative_path?/1` that re-implemented `Routes.local_path?/1`'s
shape check by hand — but without the ASCII control-character check. CLAUDE.md
documents that check as load-bearing: browsers strip tab/CR/LF, so a stored
`"/\t/evil.com"` renders as `//evil.com` — a real open-redirect primitive —
and states `Routes.local_path?/1` is "the only redirect guard" for exactly
this reason.

**Why it wasn't exploitable as merged:** every consumer of the stored value
(`start_page_candidates/1` in `phoenix_kit_web/users/auth.ex`) feeds it back
through `Routes.post_auth_path/2`, whose `usable_candidate?/1` re-checks the
*real* `local_path?/1` before using any candidate. So a smuggled value would
have been stored, then silently skipped at redirect time — not a live
open-redirect. But it is a second, drifting definition of a security-critical
check that the project's own docs single out as the one place this logic
should live, and the exact gap (no control-char check) is the one the
documented function exists to close. A future caller that trusts the stored
value directly (skipping the `post_auth_path` re-guard) would resurrect the
bug for real.

**Fix applied:** `update_user_start_page/2` now calls
`PhoenixKit.Utils.Routes.local_path?/1` directly instead of its own copy;
removed `local_relative_path?/1`. Added a regression test
(`start_page_preference_test.exs`: "refuses a path smuggling an ASCII control
character") that would have failed against the original code.

### Reviewed, no issue found

- `admin_tab_options/1` (user_settings.ex) correctly scopes candidates through
  `TabRegistry.get_admin_tabs(scope: scope)` (permission- and
  visibility-filtered, hidden tabs excluded by the `include_hidden: false`
  default) and resolves paths via `Tab.resolve_path(tab, :admin)`, which uses
  the canonical `:admin` context — consistent with the renameable-admin-segment
  convention (the stored path stays canonical; `Routes.path/1` applies the
  real segment and locale at redirect time).
- The stored preference is a relative path, never a resolved URL — correct
  per its own moduledoc, and verified against every call site.
- `assign_home_view/2` in `dashboard.ex` runs the optional module's
  `admin_home_dashboards/1` unconditionally on both mount passes (disconnected
  + connected) rather than deferring to `connected?/1` — on its face a mount
  double-query. But this is a deliberate, well-reasoned exception: the child
  `live_render` renders its own board in the very same pass, so the parent's
  *first* answer cannot be deferred without painting the overview and the
  dashboard stacked together for one frame. The code comments show this
  tradeoff was made consciously, not missed. Not flagged as a defect.
- The `handle_info({:admin_home, ...})` clause is correctly placed immediately
  after `use Overview` so its clauses stay grouped with the one that macro
  injects (avoids a `--warnings-as-errors` compile failure); the guard's tight
  `state in [:shown, :empty]` is deliberate — no catch-all, so an unrelated
  message still raises rather than being silently swallowed (per the existing
  test contract described in the moduledoc).
- Registering the picker's own scope: `assign_start_page/1` reads
  `socket.assigns[:phoenix_kit_current_scope] || Scope.for_user(user)` because
  the parent LiveView passes only `user=` into this component — one of the
  PR's own mid-review fixes (`f147744e`), reading correctly against the
  component's actual assigns, not the parent's.
- `home_dashboard?/2` and `enabled_module?/1` both guard with
  `Code.ensure_loaded?/1` before `function_exported?/3`, and both `rescue` and
  `catch :exit`, matching the documented duck-typing discipline for optional
  modules (a raising or exiting dependency must never leave `/admin` with
  neither half rendered).
- A user can set their `start_page` to an admin path they currently lack
  permission for (the save handler doesn't re-check the submitted path against
  their own tab list — only that it's a local path). Not a security issue: the
  destination's own permission gate still applies on arrival, so worst case is
  landing somewhere that immediately redirects them again. Not fixed — the
  self-correcting fallback chain in `post_auth_path` already contains it, and
  restricting the accepted value to a specific allowlist here would add
  complexity for a self-inflicted, non-exploitable inconvenience.

## Fix applied

- `lib/phoenix_kit/users/auth.ex`: `update_user_start_page/2` now delegates to
  `PhoenixKit.Utils.Routes.local_path?/1`; removed the duplicate
  `local_relative_path?/1`.
- `test/phoenix_kit/users/start_page_preference_test.exs`: added the
  control-character regression case.

## Verification performed

- Read every changed file with surrounding context (not just the hunks),
  including `Routes.local_path?/1`, `Routes.post_auth_path/2`, `Tab.resolve_path/2`,
  `Registry.get_admin_tabs/1`, and `merge_user_custom_fields/3` /
  `delete_user_custom_field/3` to confirm the new code's assumptions about
  each held.
- Traced every consumer of `Auth.user_start_page/1` to confirm the
  control-character gap could not currently escape to a live redirect
  (`post_auth_path`'s `usable_candidate?/1` re-validates every candidate).
- `mix precommit` — pending (see below).
