# CLAUDE_REVIEW.md — PR #753: Dedupe admin route paths across host pages and modules

- **Author:** timujinne
- **Merge commit:** 0f9c01cc (base dc7f57ee, tip c4083fc9 — 3 commits)
- **Scope:** `PhoenixKitWeb.Integration.phoenix_kit_admin_routes/1` — a module's
  `admin_tabs`/`settings_tabs` tab whose path collided with a host-declared
  `:admin_dashboard_tabs` page, or with another module's tab, compiled to TWO
  `live` declarations at the same path. Phoenix silently keeps the first; the
  second is dead code, discoverable only by the compiler's "this clause cannot
  match" warning (invisible without `--warnings-as-errors`). Fixes it with
  `dedupe_admin_routes_by_path/2`: host pages checked first (always win), then
  first-discovered-module-wins for cross-module ties — mirroring the
  precedence `collect_module_tabs/2` already used within one module's own tab
  list.

## Verification performed

- Read the full diff (`lib/phoenix_kit_web/integration.ex`) with the
  surrounding route-generation machinery — `compile_custom_admin_routes/1`,
  `compile_plugin_admin_routes/1` → `compile_module_admin_routes/0` →
  `collect_module_tabs/2`, and how `plugin_admin_routes` is spliced into the
  admin `scope` block alongside `custom_admin_routes`/`external_admin_routes`.
- Confirmed `dedupe_admin_routes_by_path/2`'s AST assumption (`{:live, _meta,
  [path | _rest]}`, literal-string path first arg) actually matches every
  producer that feeds it (`tab_to_route/1`, `tab_struct_to_route/1`).
- Ran the new `PhoenixKitWeb.AdminRouteDedupTest` (throwaway router,
  `phoenix_kit_routes()` compiled under a non-`PhoenixKitWeb.Router` module
  name so the real code paths run) standalone and inside the full suite.
- Traced every OTHER route family that shares the same "flat_map tabs across
  discovered modules" shape, to check whether the same defect exists
  elsewhere and was fixed everywhere it applies:
  - `admin_tabs` + `settings_tabs` → `compile_module_admin_routes/0` →
    now covered by this PR's `dedupe_admin_routes_by_path/2`. ✓
  - `user_dashboard_tabs` → `compile_module_user_routes/1`, used by
    `phoenix_kit_authenticated_routes/1` — **same** `flat_map` across
    discovered modules, **zero** cross-module dedup. Confirmed by reading
    `compile_module_user_routes/1`: it collects `collect_module_tabs(mod,
    :user_dashboard_tabs)` per module with no equivalent of
    `dedupe_admin_routes_by_path/2` applied to the combined list.

## Findings

### IMPROVEMENT - MEDIUM: `user_dashboard_tabs` had the identical cross-module collision bug, left unfixed by this PR (FIXED in this pass)

The PR's own title and moduledoc scope the fix to "the admin surface," but
`compile_module_user_routes/1` (used by `phoenix_kit_authenticated_routes/1`
for `/dashboard/...` routes) has the exact same shape as
`compile_module_admin_routes/0` did before this PR: `flat_map` across every
discovered external module's `user_dashboard_tabs/0`, no dedup between
modules. Two external modules declaring a `user_dashboard_tabs` tab with a
`live_view` at the same path still compile to two `live` declarations at an
identical path today — the same dead-route defect this PR set out to kill,
just in the sibling tab family.

There's no host-side half of this gap to worry about: a host's own
`config :phoenix_kit, :user_dashboard_tabs` entries are navigation-only and
never carry a `live_view` (see the `PhoenixKit.Dashboard` moduledoc's
"Quick Start" example), so there's no host-declared route to check module
tabs against — only the cross-module case applies.

**Fix applied:** `lib/phoenix_kit_web/integration.ex`,
`phoenix_kit_authenticated_routes/1` now pipes `compile_module_user_routes/1`
through the same `dedupe_admin_routes_by_path/2` helper (with an empty
`accepted_routes` list, since there's no host source to prefer). First
module discovered wins ties, consistent with the admin side.

**Test added:** extended `PhoenixKitWeb.AdminRouteDedupTest` (kept in the
same file as the admin-side test rather than a new sibling file — see the
moduledoc addendum: two files each mutating
`Application.put_env(:phoenix_kit, :modules, ...)` as top-level compile-time
code race under `Kernel.ParallelCompiler`, which compiles files concurrently;
confirmed this by extracting the new test into its own file first and
watching it intermittently starve the *existing* test's `FakeExternalModule`
out of `:modules` mid-compile). Two probe modules
(`FakeExternalModule`/`SecondFakeExternalModule`) both declare a
`user_dashboard_tabs` tab at `/dashboard/dedup-collision-probe`; asserts the
collision collapses to one declaration per URL shape (2 routes, not 4) and
that the first-declared module's LiveView wins, plus a non-collision
regression check.

No other findings — the shipped fix itself (host-vs-module precedence,
cross-module tie-break, the `nil`-safe `admin_route_path/1` fallback for
non-`live` quoted forms) is correct and the new test actually exercises the
real code path (a throwaway router module name, not `PhoenixKitWeb.Router`,
which self-exempts from route generation).

## Gate

`mix precommit` and `mix test` (4092 tests + 43 doctests) — clean except the
one pre-existing, environment-only failure tracked in
[[project_sandbox_test_db_no_superuser]] (`DISABLE TRIGGER ALL` needs
superuser, unavailable on this sandbox DB; unrelated to this PR).
