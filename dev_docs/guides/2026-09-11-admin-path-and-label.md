# Renameable admin segment (`admin_path`) and admin wording (`admin_panel_label`)

## The admin segment is renameable — keep writing `/admin`

`config :phoenix_kit, admin_path: "/backoffice"` (compile-time, `config.exs`
only) moves the whole admin area inside the mount prefix. **`/admin` stays the
canonical name in code** — never write the configured value anywhere. The
substitution lives in exactly two inverse functions:

| Direction | Function | Reached from |
|---|---|---|
| emit (canonical → real) | `Routes.apply_admin_segment/1` | `Routes.path/2`, `Routes.admin_path/2`, and the route table via `Integration.rewrite_admin_segment/1` |
| read (real → canonical) | `Routes.canonical_admin_path/1` | `Tab.normalize_path/1`, `AdminNav.parse_admin_path/1`, `LayoutWrapper.admin_page?/1`, the language switcher |

Consequences worth remembering:

- A module package needs **zero** changes to honour a rename — its tabs use
  relative paths and its links go through `Routes.path/1`.
- Anything comparing an incoming request path to a path written in code must
  canonicalise first, or it silently matches nothing (dead tab highlighting).
- **`Routes.admin_area_path?/1` is the supported way to ask "does this REAL URL
  land in the admin area?"** — it strips the mount prefix, allows a locale
  segment, and compares by segment against the configured value. Use it instead
  of `String.contains?(path, "/admin/")`, which gets `/administrators`, a host
  page at `/shop/admin`, and every renamed host wrong. Pair it with
  `local_path?/1` when allowlisting a client-supplied redirect target — that is
  the one that rejects `//evil.com`. It also backs core's own `skip_admin`
  redirect-loop guard, which is why it must read the configured segment.
- The value is validated (one lowercase segment, not one core already owns) and
  raises on a bad value rather than compiling into a router that 404s.
- Tests that flip it must do so in the **sync** phase (`async: false`, inside
  `setup_all`/a test). It is cached in `:persistent_term`, and `mix test` loads
  test files in parallel — a flip in a file body leaks into other files' router
  compilation. See `test/phoenix_kit/utils/admin_segment_test.exs`.

## Renaming the segment also renames the WORDING

`admin_path` moves the URL; `admin_panel_label` decides what the admin area is
*called* in the admin header chip and the account-menu entry. Leave the label
unset and it is **derived from the segment**, so the two cannot drift:

    config :phoenix_kit, admin_path: "/backoffice"
    # URL /backoffice, header "Backoffice", menu "Backoffice"

- **Ten presets**, each a real `gettext/1` msgid translated in every shipped
  locale: `:admin_panel` (default), `:dashboard`, `:backoffice`, `:console`,
  `:control_panel`, `:workspace`, `:portal`, `:my_account`, `:management`,
  `:studio`. Canonical table: `PhoenixKit.Config.admin_label_presets/0`.
- **Override** with `admin_panel_label: :workspace`. A plain string
  (`"Acme HQ"`) also works and is the escape hatch — but is **not translated**:
  one string for every visitor in every language. That is why the list is
  closed and why neither form is an operator field on `/admin/settings`, where
  the settings checkbox stays show/hide.
- A segment matching no preset (`/x7q`) keeps the translated "Admin Panel"
  rather than inventing a label from the URL.
- ⚠️ Unlike `admin_path`, an unrecognised value **does not raise** — this is
  cosmetic and a typo must not take the admin area down in production. It logs
  once (naming the valid presets) and falls back to the derivation.
- Adding a preset means BOTH `@admin_label_presets` in `PhoenixKit.Config` and
  a `preset_text/1` clause in `PhoenixKitWeb.Components.Core.AdminLabel` — the
  msgid must be a literal `gettext/1` call or extraction misses it and it
  ships untranslated. `admin_segment_test.exs` walks the list and fails if a
  clause is missing. Then translate the new msgid in all seven locales.
- `mix phoenix_kit.install` / `.update` write the whole list into the host's
  `config/config.exs` as a **comment block**
  (`PhoenixKit.Install.AdminLabelConfig`), so the vocabulary is in front of a
  developer at the moment they go to change it. Idempotent, and skipped once
  the host has an uncommented `admin_panel_label:`.
