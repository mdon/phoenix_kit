# Per-Module i18n with Gettext

**Translate sidebar tab labels, group labels, and tooltips inside your PhoenixKit module.**

This guide shows how each PhoenixKit module owns its own Gettext backend, ships its own `.po` files, and registers admin/settings/dashboard tabs with `gettext_backend:` so labels translate at render time according to the user's locale. Applies to **every** module that exposes UI — both new modules being authored from day 1 and existing modules being uplifted to `phoenix_kit ~> 1.8`.

---

## Quick Start

```elixir
# 1. Create the module's Gettext backend
defmodule PhoenixKitProjects.Gettext do
  use Gettext.Backend, otp_app: :phoenix_kit_projects
end

# 2. In mix.exs
def application, do: [extra_applications: [:logger, :gettext]]

defp deps do
  [
    {:phoenix_kit, "~> 1.8"},
    {:gettext, "~> 1.0"}
  ]
end

# 3. Register tabs with gettext_backend
@impl PhoenixKit.Module
def admin_tabs do
  [
    Tab.new!(
      id: :admin_projects,
      label: "Projects",
      icon: "hero-folder",
      path: "projects",
      priority: 400,
      level: :admin,
      permission: "projects",
      group: :admin_modules,
      gettext_backend: PhoenixKitProjects.Gettext
    )
  ]
end

# 4. Extract msgids and fill translations
# $ mix gettext.extract --merge
# Edit priv/gettext/ru/LC_MESSAGES/default.po
#   msgid "Projects"
#   msgstr "Проекты"
```

---

## What core gives you (PhoenixKit ≥ 1.8)

`PhoenixKit.Dashboard.Tab` and `PhoenixKit.Dashboard.Group` accept two optional fields:

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `gettext_backend` | `module()` or `nil` | `nil` | Module that owns the Gettext catalogue for this tab/group. `nil` keeps the raw label. |
| `gettext_domain` | `String.t()` | `"default"` | Gettext domain to look the msgid up in. |

Sidebar / `AdminSidebar` / `TabItem` components automatically route every label and tooltip render through:

- `Tab.localized_label/1`
- `Tab.localized_tooltip/1`
- `Group.localized_label/1`

Each helper:

1. Returns `nil` if the underlying field (`label` / `tooltip`) is `nil` — divider tabs and unlabeled groups stay safe.
2. Returns the raw string if `gettext_backend` is `nil` — backwards compatible.
3. Otherwise calls `Gettext.dgettext(backend, domain, msgid)` against the **process locale** of the LiveView. Locale is set per request by the parent app's locale plug or on-mount hook. **Modules must not set the locale themselves.**

---

## Why each module owns its own backend

When a module ships as a separate Hex package, it cannot rely on the parent application's `PhoenixKitWeb.Gettext` — that backend belongs to the core library, not to your package. Each module ships its own `.po` files in its own `priv/gettext/` and registers translations with `gettext_backend: PhoenixKit<X>.Gettext`. The parent app sets the user's locale once per request; every module's backend then independently looks up its own msgids in its own catalogue.

This also matches the `dynamic_children/2` callback contract: arity-2 dynamic-children functions already receive the current locale, but using `gettext_backend:` on returned `%Tab{}` structs is more declarative and avoids manual `Gettext.put_locale/2` juggling.

---

## Setup checklist

| # | Step | Where |
|---|------|-------|
| 1 | Bump `{:phoenix_kit, "~> 1.8"}` | `mix.exs` |
| 2 | Add `:gettext` to `extra_applications` (verify) | `mix.exs` |
| 3 | Create the module's own Gettext backend | `lib/phoenix_kit_<x>/gettext.ex` |
| 4 | Replace every `use Gettext, backend: PhoenixKitWeb.Gettext` with the module's own backend | `grep -rl "PhoenixKitWeb.Gettext" lib/` |
| 5 | Run `mix gettext.extract --merge` | shell |
| 6 | For each target locale: `mix gettext.merge priv/gettext --locale <loc>` | shell |
| 7 | Set `gettext_backend:` (and `gettext_domain:` if needed) on **every** `%Tab{}` and `%Group{}` registration | `admin_tabs/0`, route module |
| 8 | Fill `priv/gettext/<locale>/LC_MESSAGES/default.po` with translations | manual |
| 9 | Add a smoke test (see [Test pattern](#test-pattern)) | `test/` |
| 10 | Bump module version, publish to Hex | `mix.exs`, `mix hex.publish` |

---

## Step-by-step setup

### A. Create the Gettext backend

```elixir
# lib/phoenix_kit_<x>/gettext.ex
defmodule PhoenixKit<X>.Gettext do
  @moduledoc """
  Gettext backend for phoenix_kit_<x>.

  Locale is set per-request by the parent application; this module's only
  responsibility is owning the catalogues under `priv/gettext/`.
  """
  use Gettext.Backend, otp_app: :phoenix_kit_<x>
end
```

`use Gettext.Backend, otp_app: ...` is the **`Gettext 0.26+` form**. The older `use Gettext, otp_app: ...` style is deprecated; do not use it.

### B. `mix.exs`

```elixir
def application do
  [
    extra_applications: [:logger, :gettext]   # :gettext is required at runtime
  ]
end

defp deps do
  [
    {:phoenix_kit, "~> 1.8"},
    {:gettext, "~> 1.0"}
  ]
end
```

### C. Switch existing `use Gettext` calls

Find every file in your module that currently uses the parent app's backend:

```bash
grep -rl "PhoenixKitWeb.Gettext" lib/
```

Replace:

```elixir
# Before
use Gettext, backend: PhoenixKitWeb.Gettext

# After
use Gettext, backend: PhoenixKit<X>.Gettext
```

This is mandatory before `hex.publish` — your published package must not reference the parent app's backend.

### D. Wire your tabs and groups

Every `%Tab{}` and `%Group{}` registered by your module's `admin_tabs/0`, `settings_tabs/0`, `user_dashboard_tabs/0`, or `dynamic_children/2` callback must carry the backend:

```elixir
@impl PhoenixKit.Module
def admin_tabs do
  [
    Tab.new!(
      id: :admin_projects,
      label: "Projects",
      icon: "hero-folder",
      path: "projects",
      priority: 400,
      level: :admin,
      permission: "projects",
      group: :admin_modules,
      gettext_backend: PhoenixKit<X>.Gettext,
      gettext_domain: "default"     # optional — "default" is the default
    ),
    Tab.new!(
      id: :admin_projects_new,
      label: "New Project",
      path: "projects/new",
      priority: 410,
      level: :admin,
      permission: "projects",
      parent: :admin_projects,
      gettext_backend: PhoenixKit<X>.Gettext
    )
  ]
end
```

Groups, when your module contributes them:

```elixir
%Group{
  id: :projects_section,
  label: "Project management",
  priority: 400,
  collapsible: true,
  gettext_backend: PhoenixKit<X>.Gettext
}
```

### E. `dynamic_children/2` — locale-aware children

If your tab uses `dynamic_children:` to render child tabs at runtime (e.g. one tab per project), implement the **arity-2** form. Children only need the backend set on items whose labels are msgids; user-supplied data stays raw:

```elixir
%Tab{
  id: :admin_projects,
  label: "Projects",
  # ... other fields ...
  dynamic_children: fn _scope, _locale ->
    PhoenixKit.RepoHelper.repo().all(Project)
    |> Enum.map(fn project ->
      %Tab{
        id: :"admin_project_#{project.id}",
        label: project.name,        # raw user-supplied — no translation needed
        path: "projects/#{project.id}",
        parent: :admin_projects,
        level: :admin,
        permission: "projects"
        # gettext_backend NOT set — project names are user data, not msgids
      }
    end)
  end
}
```

> **Rule of thumb:** set `gettext_backend:` only when `label`/`tooltip` is a fixed English msgid that lives in your `.po` files. User-supplied content (project names, document titles, customer names) stays raw.

### F. Dividers and group headers

`Tab.divider/1` and `Tab.group_header/1` accept the same options:

```elixir
Tab.divider(
  priority: 150,
  label: "Account",
  gettext_backend: PhoenixKit<X>.Gettext
)

Tab.group_header(
  id: :reports_header,
  label: "Reports",
  priority: 500,
  gettext_backend: PhoenixKit<X>.Gettext
)
```

### G. Tooltips

Tooltips translate via the same backend automatically — set `tooltip:` to the msgid alongside `gettext_backend:` and the sidebar's `title=` attribute will render the translated text:

```elixir
Tab.new!(
  id: :admin_projects,
  label: "Projects",
  tooltip: "Manage all projects",   # msgid for tooltip translation
  path: "projects",
  gettext_backend: PhoenixKit<X>.Gettext
)
```

### H. Extract msgids and fill translations

```bash
# Generate / update the .pot (template)
mix gettext.extract

# Merge new msgids into each locale's .po
mix gettext.merge priv/gettext --locale en
mix gettext.merge priv/gettext --locale ru
mix gettext.merge priv/gettext --locale et
```

Edit `priv/gettext/<locale>/LC_MESSAGES/default.po`:

```po
#: lib/phoenix_kit_<x>/<x>.ex
msgid "Projects"
msgstr "Проекты"

#: lib/phoenix_kit_<x>/<x>.ex
msgid "New Project"
msgstr "Новый проект"

#: lib/phoenix_kit_<x>/<x>.ex
msgid "Manage all projects"
msgstr "Управление всеми проектами"
```

For `en`: `msgstr` should equal `msgid` (gettext's "no translation needed" convention; without it, gettext returns the empty string for `en` and your label disappears).

---

## Greenfield module example

Full minimal module with i18n built in from day 1:

```elixir
# lib/phoenix_kit_<x>/<x>.ex
defmodule PhoenixKit<X> do
  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.{Tab, Group}

  @impl PhoenixKit.Module
  def module_key, do: "<x>"

  @impl PhoenixKit.Module
  def module_name, do: "<X> Module"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "<x>",
      label: "<X>",
      icon: "hero-folder",
      description: "<short description>"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_<x>,
        label: "<X>",
        icon: "hero-folder",
        path: "<x>",
        priority: 400,
        level: :admin,
        permission: "<x>",
        group: :admin_modules,
        gettext_backend: PhoenixKit<X>.Gettext
      )
    ]
  end
end
```

```elixir
# lib/phoenix_kit_<x>/gettext.ex
defmodule PhoenixKit<X>.Gettext do
  @moduledoc "Gettext backend for phoenix_kit_<x>."
  use Gettext.Backend, otp_app: :phoenix_kit_<x>
end
```

---

## Retrofitting an existing module

For each existing `phoenix_kit_<x>` module being uplifted to 1.8:

- [ ] `mix.exs` — bump `{:phoenix_kit, "~> 1.8"}`
- [ ] `mix.exs` — confirm `:gettext` is in `extra_applications`
- [ ] Create `lib/phoenix_kit_<x>/gettext.ex` with `use Gettext.Backend, otp_app: :phoenix_kit_<x>`
- [ ] `grep -rl "PhoenixKitWeb.Gettext" lib/` returns **zero** results
- [ ] Run `mix gettext.extract --merge`
- [ ] `priv/gettext/{en,ru,et,…}/LC_MESSAGES/default.po` exist and `en/default.po` has `msgstr` = `msgid` for every entry
- [ ] Every `Tab.new!`, `%Tab{}`, `Tab.divider/1`, `Tab.group_header/1`, `%Group{}`, `Group.new/1` in your module sets `gettext_backend:`
- [ ] `dynamic_children:` callbacks return tabs with `gettext_backend:` set (when labels are msgids, not user data)
- [ ] One smoke test passes (see [Test pattern](#test-pattern))
- [ ] `mix test` and `mix gettext.extract --merge --check-up-to-date` clean
- [ ] CHANGELOG entry, version bump, `mix hex.publish`

---

## Test pattern

A single smoke test per module is sufficient — core's tests already cover the localization machinery itself:

```elixir
defmodule PhoenixKit<X>.I18nSmokeTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Tab

  setup do
    original = Gettext.get_locale(PhoenixKit<X>.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKit<X>.Gettext, original) end)
    :ok
  end

  test "admin tab labels translate to ru" do
    Gettext.put_locale(PhoenixKit<X>.Gettext, "ru")

    [tab | _] = PhoenixKit<X>.admin_tabs()

    # Replace with the actual translation you put in ru/default.po
    assert Tab.localized_label(tab) == "Проекты"
  end

  test "admin tab labels fall back to msgid for an unknown locale" do
    Gettext.put_locale(PhoenixKit<X>.Gettext, "xx")

    [tab | _] = PhoenixKit<X>.admin_tabs()
    assert Tab.localized_label(tab) == tab.label
  end
end
```

`async: false` is required because `Gettext.put_locale/2` mutates the calling process's process dictionary; `on_exit` restores it cleanly.

---

## Common pitfalls

❌ **Do NOT** call `Gettext.put_locale/2` from inside your module — locale is a request-scoped concern owned by the parent app.

❌ **Do NOT** translate before passing to PhoenixKit core APIs that persist data. For example, `Tab.label` is the source of the row label that `Permissions.register_custom_key/2` writes to the database. Translating it before registration would corrupt the canonical key store. Pass the raw msgid; rendering localizes.

❌ **Do NOT** invent a custom domain unless you actually have multiple. `"default"` is the convention; switch to a domain-per-area only when one `default.po` becomes too noisy.

❌ **Do NOT** keep `use Gettext, backend: PhoenixKitWeb.Gettext` in published code. That backend belongs to PhoenixKit core and won't be mounted in every consumer app the same way.

❌ **Do NOT** set `gettext_backend:` on dynamically-generated user-data labels (project names, document titles). These are not msgids; gettext would return the raw string anyway, but the field still wastes a Gettext call per render.

❌ **Do NOT** ship without `mix gettext.extract --merge` — stale `.pot` means newly added msgids never reach `.po` and translators have nothing to translate.

---

## Where this fits in the rollout

| Phase | Repo | What |
|-------|------|------|
| 1 ✅ | `phoenix_kit` (core) | Released `1.8.0` with `gettext_backend` / `gettext_domain` API |
| 2 ⏳ | each `phoenix_kit_<x>` package | Apply this guide. Pilot: `phoenix_kit_projects` |
| 3 ⏳ | parent apps | Drop ETS-patching hacks; pass `gettext_backend:` to their own tabs |

Phase 2 modules are independent of one another — they can be migrated in parallel by different developers, one PR per repo. Phase 3 happens at any point after phase 1 ships, regardless of phase 2 progress.

---

## Reference

- [`PhoenixKit.Dashboard.Tab`](https://hexdocs.pm/phoenix_kit/PhoenixKit.Dashboard.Tab.html) — `localized_label/1`, `localized_tooltip/1`, `divider/1`, `group_header/1`
- [`PhoenixKit.Dashboard.Group`](https://hexdocs.pm/phoenix_kit/PhoenixKit.Dashboard.Group.html) — `localized_label/1`
- [Gettext docs](https://hexdocs.pm/gettext/) — `dgettext`, `Gettext.Backend`, `mix gettext.extract`, `mix gettext.merge`
