# PR #496 — feat: widget functionality

**Author:** mithereal · **Branch:** `dashboard-widgets` → `main` · **State:** OPEN
**Diff:** +140 / −2 across 3 files
**Prior context:** Same author, PR #488 (advanced user dashboard, closed) and PR #494 (dashboard widgets, closed without merge).

## TL;DR

Better scoped than #488/#494 (no fancy migrations, no advanced dashboard pages) but still **not mergeable**. The widget loader invents a parallel module-extension mechanism instead of using the existing `PhoenixKit.Module` behaviour, the loader is wired to nothing (dead code), and the unrelated `auth_router.ex` doc edit replaces a correct reference with a non-existent one.

Recommend: **request changes**, do not merge.

---

## Findings

### BUG — CRITICAL: `auth_router.ex` doc reference is wrong

`lib/phoenix_kit_web/auth_router.ex:6`

```diff
- Use `PhoenixKitWeb.Integration.phoenix_kit_routes/0` macro instead.
+ Use `PhoenixKitWeb.phoenix_kit_routes.phoenix_kit_routes/0` macro instead.
```

The original reference is correct — `phoenix_kit_routes/0` is defined at `lib/phoenix_kit_web/integration.ex:1124` inside `PhoenixKitWeb.Integration`. The "fix" replaces a real module path with a nonsense one (`PhoenixKitWeb.phoenix_kit_routes.phoenix_kit_routes/0`). Looks like accidental find-replace damage. **Revert this hunk** — it's also unrelated to the PR's stated goal.

### BUG — HIGH: Widget loader is wired to nothing

The PR description says "this allows us to have widgets on the template," but no template, LiveView, or dashboard module calls `Widget.load_all_widgets/0`, `get_widget/1`, or `get_by_module/1`. The whole `lib/phoenix_kit/dashboard/widget.ex` is dead code on this branch. Either (a) drop until there's a consumer, or (b) add the dashboard render-site that actually calls this.

### BUG — HIGH: Reinvents `PhoenixKit.Module` behaviour pattern

PhoenixKit already has a clean module-extension contract: `PhoenixKit.Module` has `@callback admin_tabs/0`, `settings_tabs/0`, `user_dashboard_tabs/0`, `notification_types/0`, `integration_providers/0` — all module-level callbacks with `defoverridable` defaults via `use PhoenixKit.Module`. Discovery uses persisted `@phoenix_kit_module` beam attributes (`lib/phoenix_kit/module_discovery.ex`).

This PR ignores all of that and introduces a parallel mechanism: a sibling `Widgets` submodule per module, discovered via `Module.concat(module_name, "Widgets")` (`widget.ex:130`). Two problems:

1. **Inconsistent with the rest of the codebase.** Every other module-contributed thing is a callback on the module itself, not a magic sibling submodule.
2. **`Module.concat/2` doesn't enforce a contract.** Anything named `*.Widgets` with a `widgets/0` arity-0 export gets picked up — no behaviour, no `@impl`, no compile-time check.

**Fix:** add `@callback widgets/0` to `PhoenixKit.Module` with a `defoverridable` default of `[]` (mirroring `notification_types/0`), then iterate enabled modules and call `mod.widgets()`. The whole `find_widgets_module` / `Code.ensure_compiled` dance disappears, the widget loader becomes ~20 lines, and external module authors learn one pattern, not two.

### BUG — HIGH: `module_enabled?/1` reimplements existing infra (worse)

```elixir
defp module_enabled?(module_name) do
  try do
    function_exported?(module_name, :enabled?, 0) && module_name.enabled?()
  rescue
    _ -> false
  end
end
```

`PhoenixKit.ModuleRegistry.safe_enabled?/1` (`module_registry.ex:82–88`) already does exactly this — and it logs the failure instead of swallowing it silently. `ModuleRegistry.enabled_modules/0` even returns the filtered list directly. Use it:

```elixir
PhoenixKit.ModuleRegistry.enabled_modules()
|> Enum.flat_map(&load_module_widgets/1)
```

The bare `rescue _ -> false` is also flagged by the Elixir thinking skill ("avoid `_ -> nil` catch-alls — they silently swallow unexpected cases").

### IMPROVEMENT — HIGH: Performance — every read does a full beam scan

`get_widget/1` and `get_by_module/1` both call `load_all_widgets/0`, which calls `ModuleDiscovery.discover_external_modules/0` — that walks `:application.loaded_applications/0`, hits each app's ebin dir, and re-checks every module's beam attributes. For a single widget lookup. `get_widget_count_by_module/0` does the same.

If widgets are ever rendered on a hot path (admin dashboard, every page load), this will show up. Either:

- Cache via `:persistent_term` keyed on `ModuleDiscovery.module_hash/0` (the same hash already used to drive router recompiles), or
- Build the widget list once in `ModuleRegistry` (where module enumeration is already done) and expose a getter.

### IMPROVEMENT — MEDIUM: Widget struct has no contract

`%Widget{}` defines `uuid, name, description, icon, value, module, enabled` but:

- No `@type t :: %__MODULE__{...}` declaration.
- No required-field enforcement (`@enforce_keys`). The docstring example shows widgets with only `uuid` and `value` set — is `name`/`icon` actually optional?
- `value: fn _ -> localized_function() end` — what's the argument? An assigns map? A socket? A user struct? Called when? Undocumented contract = footgun for module authors. At minimum: spell out the expected `value` arity and what it receives.
- The example uuid `"1234-5678-9012-3456"` isn't a valid UUID, and the rest of PhoenixKit uses UUIDv7 (`@primary_key {:uuid, UUIDv7, autogenerate: true}` per CLAUDE.md). If `uuid` is meant to be a stable identifier across deploys, it should be a developer-chosen string key (like `module_key`), not pretend-uuid. Consider renaming to `id` or `key`.

### IMPROVEMENT — MEDIUM: `get_by_module/1` semantics are wrong

```elixir
def get_by_module(params) do
  load_all_widgets()
  |> Enum.find(&(&1.module == params))
end
```

A module can contribute multiple widgets (the whole `Enum.flat_map` upstream presumes this), but `get_by_module` returns the *first match* via `Enum.find`. Either rename to `get_widgets_by_module/1` and use `Enum.filter`, or document why "first widget for module" is a useful operation. Also: `params` → `module_name` (the parameter is one module atom, not a params bag).

### IMPROVEMENT — MEDIUM: Bare `rescue e ->` in `load_module_widgets/1`

```elixir
rescue
  e -> Logger.error("Error loading widgets for module #{inspect(module_name)}: #{inspect(e)}")
       []
end
```

Catches everything including `Protocol.UndefinedError`, `ArgumentError`, etc. and degrades silently to `[]`. If a module author ships a buggy `widgets/0`, the developer gets a single log line instead of a crash at compile/test time. Match what `ModuleRegistry.safe_enabled?/1` does (rescue + log + `false`) only because that boundary is genuinely external; `widgets/0` is module-author code we control via behaviour — let it crash in dev/test and surface real bugs.

### NITPICK: `priv/templates/test_require_auth_live.ex`

The trailing-newline hunk is fine but unrelated to the PR — fold into a janitor commit or drop.

### NITPICK: Trailing blank line in `widget.ex`

```
defp find_widgets_module(module_name) do
  ...
end

end
```

There's a blank line between the last `end` of `find_widgets_module/1` and the module's closing `end`. `mix format` will strip it; `mix precommit` (the project gate per CLAUDE.md) will fail until then.

### NITPICK: Docstring example wouldn't compile

```elixir
defmodule PhoenixKit.Modules.AI.Widgets do
  def widgets do
    [
      %Widget{uuid: "1234-...", value: fn _ -> localized_function() end},
      ...
    ]
  end
end
```

`%Widget{...}` won't resolve — either alias `PhoenixKit.Dashboard.Widget` or use the full module name. `localized_function()` is undefined. The example as written would fail to compile if a user copy-pasted it.

---

## Comparison to prior PRs

| PR | Scope | Issue |
|---|---|---|
| #488 | Full "advanced user dashboard" with migrations & UI | Way too large; declined |
| #494 | Dashboard widgets + `mix phoenix_kit.gen.user.dashboard.advanced` task | Author asked for analysis, didn't follow up; closed |
| **#496** | Just the widget loader (138 LOC) | Smaller, but still architecturally off and not wired up |

The author has clearly trimmed scope from #488 → #496. Direction is right. But three rounds in, the loader still doesn't use the existing `PhoenixKit.Module` behaviour, isn't called from anywhere, and ships an unrelated broken doc edit. Worth one more round of feedback rather than just merging.

## Suggested response to author

1. Revert the `auth_router.ex` change — it's incorrect.
2. Add `@callback widgets/0` to `PhoenixKit.Module` with a `defoverridable []` default; drop the `Widgets` submodule pattern.
3. Use `PhoenixKit.ModuleRegistry.enabled_modules/0` instead of the local `module_enabled?/1`.
4. Wire the loader to an actual render site, or hold the PR until the consumer exists.
5. Define `@type t`, `@enforce_keys`, and a `value` contract (arity + arg semantics) on `%Widget{}`.
6. Run `mix precommit`.
