# PR #521 — Fix admin permissions for external plugin LiveViews

**Author:** @timujinne
**Branch:** `fix/external-plugin-admin-permissions` ← `dev`
**Merged:** 2026-05-08T21:12:23Z (`9fdbf438`)
**Diff:** +126 / -4 (4 files, 2 commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/521

## Verdict

**APPROVE.** A small, well-targeted fix for a real "fail-closed by
accident" bug. Custom-role users with explicit plugin permissions
(`entities`, `billing`, `ai`, …) were silently locked out of plugin
admin pages because `infer_permission_key_from_module/1` only knew how
to resolve the core `PhoenixKit.Modules.*` namespace — every external
plugin (`PhoenixKitEntities.*`, `PhoenixKitBilling.*`, …) returned
`nil` from all three resolution paths, which collapsed onto the
"no permission" branch in `enforce_admin_view_permission/2`.

The fix wires up a fourth resolution path: when the LiveView's
top-level namespace doesn't match `PhoenixKit.Modules`,
`ModuleRegistry.get_module_key_for_namespace/1` looks up registered
plugins by exact top-level segment and returns the plugin's declared
`module_key/0`.

Two things make this PR a particularly clean example of the genre:

1. The **second commit** — the tightening from `[^top_namespace | _]`
   to `[^top_namespace]` after a live-repro footgun — is captured in
   the PR body with the exact failure case
   (`get_module_key_for_namespace("PhoenixKit") => "db"`). That kind
   of "we shipped a v1, found a problem, here's the v2" paper trail
   is exactly what audit-friendly review wants.
2. The new tests use **`Module.create/3` with explicit top-level
   names** to dodge the test-module auto-nesting pitfall. Cheap
   detail; matters because every other "fake plugin in a test" pattern
   I've seen in this repo gets bitten by `defmodule X` resolving to
   `PhoenixKit.SomeTest.X`.

Findings below are nitpicks only.

## What changed

| Layer | Change |
|---|---|
| `module_registry.ex` | New `get_module_key_for_namespace/1` — iterates `all_modules/0`, matches `Module.split(mod) == [top_namespace]`, returns `module_key/0` (when binary). Reads from `:persistent_term` (no GenServer call), so cost is O(N) over registered modules with no IPC. |
| `auth.ex` | New `[top \| _rest] -> ModuleRegistry.get_module_key_for_namespace(top)` clause on `infer_permission_key_from_module/1`. Old `_ -> nil` removed (unreachable post-Module.split — Dialyzer flagged it). |
| `auth.ex` | `permission_key_for_admin_view/1` exposed as `@doc false def` (was `defp`) so unit tests can exercise it without LiveView mounting. |
| Tests | New `auth_test.exs` (4 cases), new `module_registry_test.exs` describe block (3 cases). Use `Module.create/3` for fixture modules. |

## Findings

### NITPICK — `Module.create/3` fixture modules persist across the test process lifetime

`test/phoenix_kit_web/users/auth_test.exs:14-22` and
`test/phoenix_kit/module_registry_test.exs:120-127` both create
top-level module names (`PhoenixKitFakePluginFixture`,
`PhoenixKitNamespaceFixture`) via `Module.create/3`. These modules
live in the BEAM atom table and module registry until the test
process exits — in CI that's the lifetime of `mix test`, which is
fine, but on a `iex -S mix test` the atoms persist into the IEx
session post-suite.

The leak is harmless (atom-table growth is bounded by the number of
unique fixture names — two atoms here), but two clean-up shapes are
worth considering for future tests:

1. **Use `setup` not `setup_all`** when only one test in the describe
   block uses the fixture. `setup_all` runs once per file; `setup`
   per-test, and `Module.create/3` is idempotent (same body in same
   compilation context is allowed).
2. **Name fixtures with the file's hash**
   (e.g. `PhoenixKitFakePluginFixture_AuthTest`) so two test files
   creating the same conceptual fixture don't compete for the same
   atom name.

The PR's setup is correct as-written; this is forward-looking advice
for the next plugin-permission test.

**Where:** `test/phoenix_kit_web/users/auth_test.exs:14-22`,
`test/phoenix_kit/module_registry_test.exs:120-127`

### NITPICK — `@doc false def` exposure could move to a dedicated `Internal` module

`lib/phoenix_kit_web/users/auth.ex:1150-1151`:

```elixir
@doc false
def permission_key_for_admin_view(view_module) do
```

This works (the function is reachable from tests, hidden from generated
docs, but anyone calling it gets a Dialyzer warning if they aliased
`Auth` and Dialyzer is set strict). It's the minimum viable change.

If the workspace gets a third or fourth "private function we want
unit-tested" in `Auth`, consider:

```elixir
defmodule PhoenixKitWeb.Users.Auth.Internal do
  @moduledoc false
  # Test-only API — not part of the public Auth contract.

  defdelegate permission_key_for_admin_view(view), to: PhoenixKitWeb.Users.Auth
end
```

Then tests `alias PhoenixKitWeb.Users.Auth.Internal` and `Internal`
becomes the documented seam. Out of scope for #521.

**Where:** `lib/phoenix_kit_web/users/auth.ex:1149-1162`

### NITPICK — `safe_call(mod, :module_key, nil)` returns `nil` for both "module crashed" and "module returned nil"

`lib/phoenix_kit/module_registry.ex:194-196`:

```elixir
with [^top_namespace] <- Module.split(mod),
     key when is_binary(key) <- safe_call(mod, :module_key, nil) do
  key
else
  _ -> nil
end
```

The `is_binary(key)` guard correctly funnels both "module crashed in
`module_key/0`" and "module returned `nil`" into the `else` branch.
But the failure modes are different in operational terms:

- A module crashing in `module_key/0` is a *plugin bug* — should be
  logged at `:warning` (matching `safe_enabled?/1`'s pattern at
  `module_registry.ex:82-88`).
- A module legitimately returning a non-binary value (e.g.
  `module_key`, an atom, by accident) is a *spec violation* — the
  same `:warning` log would help a developer notice during dev.

Currently both pathways are silent. Not a behavior bug, just an
observability gap. Worth a follow-up to push the warning logging into
`safe_call/3` so every `safe_call` consumer gets it for free.

**Where:** `lib/phoenix_kit/module_registry.ex:191-201`

### NITPICK — `permission_key_for_admin_view/1` resolution order bears a docstring note

The function resolves through four sources in this order:

1. `@admin_view_permissions` static map
2. `infer_permission_from_custom_tabs/1` — looks up by tab `live_view:` config
3. `infer_permission_key_from_module/1` — pattern-match on `PhoenixKit.Modules.*`
4. `ModuleRegistry.get_module_key_for_namespace/1` — pattern-match on top-level `PhoenixKit<Plugin>`

This ordering is meaningful: a static-map override beats a custom-tabs
mapping, which beats core-namespace inference, which beats
plugin-namespace lookup. The PR's own commit message documents the
sequence, but the function itself only has the inline comment on
`:1169-1171` for inference.

A 4-line docstring on `permission_key_for_admin_view/1`:

```elixir
@doc """
Resolve a LiveView module to its permission key.

Resolution order (first non-nil wins):
1. `@admin_view_permissions` map (core admin views)
2. Tab-declared `live_view:` (modules registering admin_tabs)
3. `PhoenixKit.Modules.<X>.Web.*` namespace inference
4. Plugin top-level namespace via `ModuleRegistry`

Returns `nil` for genuinely unknown views — caller's fail-closed default applies.
"""
```

…would make the contract obvious without anyone having to chase
`infer_permission_*` helpers.

**Where:** `lib/phoenix_kit_web/users/auth.ex:1149-1162`

### NITPICK — Verification gap: no integration test exercises the *redirect* path

The new tests assert that `permission_key_for_admin_view/1` returns
the right key for each branch. They do *not* assert that
`enforce_admin_view_permission/2` passes a custom-role user through
to the LV when the registered plugin's key matches their role grants.
That's the actual user-visible bug.

The PR body's "Live verification on a parent app via Tidewave" closes
that gap empirically, but the next time someone refactors
`enforce_admin_view_permission/2` and accidentally inverts a guard,
the unit tests won't catch it. A `DataCase`-backed integration test
that:

1. Registers a fake plugin (the same `PhoenixKitFakePluginFixture`)
2. Creates a custom role with `"fake_plugin"` permission
3. Mounts `PhoenixKitFakePluginFixture.Web.Index` as that role
4. Asserts the redirect is *not* triggered

…would close the loop. Out of scope for the immediate hotfix; worth
a follow-up.

## What's good

- **`with` + pin pattern is the right Elixir shape.** The
  `with [^top_namespace] <- Module.split(mod), key when is_binary(key)
  <- safe_call(...) do key else _ -> nil end` is exactly the
  "happy path threads `{:ok, _}`-ish data; anything else falls
  through" idiom from elixir-thinking. No nested case, no `cond`,
  no `if is_binary do ... else nil end`.
- **The `[^top_namespace]` exact-arity pin.** The PR body's repro
  (`get_module_key_for_namespace("PhoenixKit") => "db"` because
  `PhoenixKit.Modules.DB` happened to be the first registered module
  whose `Module.split` started with `"PhoenixKit"`) is the exact
  shape of bug that `[^top_namespace | _]` would have hidden in
  production. The single-segment match is correct and
  regression-pinned by the third test.
- **`all_modules/0` reads from `:persistent_term`.** No GenServer
  call on the hot path of every admin LiveView mount + permission
  check. The cost of `get_module_key_for_namespace/1` is a list
  iteration with `Module.split/1` per element; for ~20 registered
  modules in a real deployment, that's microseconds.
- **Removing the unreachable `_ -> nil` clause.** `Module.split/1`
  always returns a non-empty list of binaries (raises ArgumentError
  for malformed input, never returns `[]`), so the old fallthrough
  was dead code. The PR catches it explicitly — Dialyzer-strict will
  thank the next person.
- **`@doc false def` rather than a magic test-only macro.** Keeps the
  test seam visible at the function definition site rather than
  hiding it in a `Mix.env() == :test` branch. Easy to find, easy to
  reason about.
- **Auto-discovery of any new plugin.** Once a parent app installs
  `phoenix_kit_<anything>` and the module registers, custom roles
  with `<anything>` permission grants get access automatically — no
  core PR needed to extend the static `@admin_view_permissions` map.
  This is the right shape for the long-term plugin extension model
  the workspace is moving toward (cf. PR #518's DB extraction, which
  follows the same auto-discovery pattern).
