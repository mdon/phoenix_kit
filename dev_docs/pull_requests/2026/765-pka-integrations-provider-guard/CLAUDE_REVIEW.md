# PR #765 — Fix `add_connection` accepting unregistered provider keys

**Author:** timujinne (`pka-integrations-provider-guard`) · **Merged:** 2026-08-28 · **Reviewed:** 2026-08-29

## Verdict

The fix is correct and closes a real hole. It also promotes a pre-existing
cache defect from cosmetic to blocking, which is fixed here.

## What the PR does

`Integrations.add_connection/4` resolves the provider once
(`Providers.get(provider_key)`), rejects `nil` with a new
`{:error, :unknown_provider}`, and passes the resolved provider (not the key)
to `Providers.scopes_of/1`.

Verified correct:

- `Providers.scopes_of/1` has both a `%{}` and a `is_binary(key)` clause
  (`providers.ex:136-137`), so passing the resolved map is supported, and the
  guard above it makes the map non-nil — the `%{}` head can't be reached with
  something unintended.
- The hole was real: without the check, `Providers.get/1` returning `nil` made
  `scopes_of/1` fall through to `normalize_scopes(nil)` → `[:system]`, which
  a `:system` add passes trivially. A tampered `select_provider` event could
  birth a settings row for a provider that was never installed, and
  `list_connections/1` would report it as real.
- Both call sites tolerate the new atom: `integration_form.ex:178` and
  `my_integration_form.ex:158` each have a catch-all `{:error, _}` clause. No
  `CaseClauseError`.
- The `@spec` was widened to include `:unknown_provider`.

## Findings

### BUG - MEDIUM — a late-registered module's providers are invisible, and #765 turns that into a hard failure

`lib/phoenix_kit/integrations/providers.ex:70` · `lib/phoenix_kit/module_registry.ex`

`Providers.all/0` caches `builtin_providers() ++ external_providers()` in
`persistent_term` with no TTL. `external_providers/0` reads
`ModuleRegistry.all_modules/0`, which is itself
`:persistent_term.get(@pterm_key, [])` — **defaulting to `[]` before the
registry GenServer's `init/1` has run.**

`Providers.clear_cache/0` exists and its own docs say "Call this when modules
are added or removed at runtime." Nothing in `lib/` ever did: the only callers
were four test files, which each hand-call it around a fixture module. So
every runtime path that changes the module set left the provider cache stale
forever:

- `ModuleRegistry.rescan/0` — documented as the deterministic path the parent
  app calls from `Application.start/2` after `Supervisor.start_link/2`, for
  "late-loading `:phoenix_kit_<x>` deps whose beams are only available after
  PhoenixKit's own supervision tree is up", and wired in automatically by
  `mix phoenix_kit.install` / `.update`. This is the expected path, not an
  edge case.
- `ModuleRegistry.register/1` — the documented runtime registration API.
- Dev hot-reload after recompiling a module package (the rescan doc's own
  stated second use).

Before #765 this degraded softly: an unknown key still passed the scope check
via the `[:system]` default, so the connection could be created and only the
picker labels were wrong. After #765 `add_connection/4` returns
`{:error, :unknown_provider}` and the UI shows "Could not add integration" —
**a legitimately installed provider cannot be connected at all until the VM
restarts in a lucky order.**

Severity is MEDIUM rather than HIGH because every `Providers` caller is
request-time (LiveViews and context functions — no boot-time warmer exists),
so the cache normally warms on the first admin page hit, after the parent's
`rescan/0`. The reachable triggers are a runtime `register/1`, a manual
`rescan/0` on an existing app, and dev hot-reload.

**Fixed:** `PhoenixKit.ModuleRegistry` now calls
`Providers.clear_cache/0` from a private `invalidate_module_derived_caches/0`
in the `:register` / `:unregister` / `:rescan` `handle_call` clauses — only on
the branches where the module set actually changed (a no-op `register` of a
known module and a `rescan` that finds nothing still skip it). `Providers.all/0`'s
doc no longer tells callers to do this by hand.

**Test:** `test/phoenix_kit/module_registry_test.exs` → `describe "provider
cache invalidation"` warms the cache without the fixture, registers a module
exporting `integration_providers/0`, and asserts the provider appears in
`Providers.all/0` and `Providers.get/1` **without any manual
`clear_cache/0`** — plus the reverse on `unregister`. Runs without PostgreSQL.

### NITPICK — untranslated error text leaks an internal atom

`lib/phoenix_kit_web/live/settings/integration_form.ex:183` renders
`"Failed: #{inspect(reason)}"`, so the new atom surfaces to an admin as
`Failed: :unknown_provider` — untranslated, unlike every neighbouring branch.
Pre-existing, not introduced here, and the sibling LV
(`my_integration_form.ex`) already does the right thing with a gettext
catch-all. Not fixed — changing it is a UX call outside this PR's scope.

## Cross-repo note

External module packages that call `Integrations.add_connection/4` for their
own provider keys now depend on those keys being registered at call time.
Core has no such caller (the only two are the LiveViews); a module running its
`migrate_legacy/0` before its own registration would newly fail. Cannot be
verified from this repo.
