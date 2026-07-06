# PR #617 — Expose hidden sitemap settings in admin UI, add source settings extension point

- **Branch:** `timujinne/feat/sitemap-settings-ui-coverage`
- **Author:** timujeen
- **Merge:** `d9069792` (feature commit `46b08dae`)
- **Version:** bumps `@version` 1.7.174 → 1.7.175, CHANGELOG entry present.
- **Reviewer:** Claude (Opus 4.8)

## Summary

Adds an **Advanced** section to `/admin/settings/sitemap` exposing four Router
Discovery / static settings that previously had storage keys but no UI
(`sitemap_router_discovery_exclude_patterns`, `sitemap_protected_pipelines`,
`sitemap_custom_urls`, `sitemap_static_routes`), and introduces an optional
`Source.sitemap_settings_schema/0` callback so a sitemap source can declare its
own boolean/string/integer settings and have them rendered + persisted on the
core page without the core knowing about it ahead of time.

**Overall: solid, well-tested PR.** Validation mirrors the collection-time
contract (`invalid_patterns/1` ↔ `compile_patterns/2`, pinned by a test),
pipeline names are restricted to identifier-safe chars before `String.to_atom`,
the extension write path is key-whitelisted against the declared schema (no
arbitrary Settings key can be written from the form), and a malformed source
schema is caught rather than crashing the page for every admin. No
CRITICAL/HIGH bugs found. One MEDIUM robustness gap fixed; the rest are notes.

## Findings

### IMPROVEMENT - MEDIUM — `toggle_extension_setting` crashed on a boolean field with a non-boolean default — FIXED

`lib/modules/sitemap/web/settings.ex` — `handle_event("toggle_extension_setting", ...)`

The render path (`read_extension_field/1`) already rescues, so a source that
declares `%{type: :boolean, default: nil}` (or any non-boolean default) renders
fine. But the toggle handler read the current value with
`Settings.get_boolean_setting(key, default)` **directly**, and that function
guards on `is_boolean(default)`. A non-boolean default therefore raised
`FunctionClauseError` inside `handle_event` and killed the LiveView the moment
an admin clicked the toggle.

- **Why it matters:** the entire point of the PR is *third-party* sources
  declaring schemas, and `settings_field.default` is typed `term()` — inviting
  exactly this mistake. No built-in source hits it today (the companion
  entities schema uses `default: true`), so impact is latent, not live.
- **Fix applied:** route the toggle's current-value read through the same
  rescue-protected `read_extension_field/1` (`current = read_extension_field(field) == true`),
  matching the render path. A non-boolean default is now treated as `false`
  instead of crashing.
- **Test added:** `settings_extension_schema_test.exs` → new `BadDefaultSource`
  fixture + "renders and toggles without crashing the settings page".

### IMPROVEMENT - MEDIUM — Settings reads happen in `mount/3` (pre-existing pattern; not changed)

`lib/modules/sitemap/web/settings.ex` — `mount/3`

The PR adds several settings reads to `mount/3`: the four `*_text/0` helpers use
the **uncached** `Settings.get_setting/1`, and `build_extension_sources/1` reads
one setting per declared field. `mount/3` runs twice (HTTP + WS), so these run
twice per page load.

- **Why it matters (little, here):** this is an admin-only, low-traffic page and
  it already read settings in `mount` before this PR (`include_registration?`,
  `publishing_split_by_group?`, `get_module_enabled_status`), so the PR follows
  the existing shape rather than introducing a new anti-pattern. The boolean/
  integer extension reads go through the cache; only the raw `*_text/0` reads are
  uncached.
- **Not fixed:** moving the whole block to `handle_params/3` would be the
  by-the-book fix, but it's out of scope for this PR and the payoff on an admin
  settings page is negligible. Recorded so it's on the books.

### NITPICK — Integer extension save is lenient

`handle_event("save_extension_setting", ..., %{type: :integer})` uses
`Integer.parse/1`, which accepts a trailing tail: `"10 items"` → stores `"10"`
and flashes success, silently discarding `" items"`. Consider rejecting when the
remainder is non-empty so the admin knows their input was truncated. Low impact
(admin-only, no built-in integer field yet).

### NITPICK — Advanced / extension fields go stale across tabs

On save, `bump_and_broadcast/2` broadcasts `:source_changed` on
`"sitemap:settings"`, which the page is subscribed to. The generic
`handle_info({:sitemap_settings_changed, %{type: type}})` handler refreshes
`config` + `sitemap_version` but **not** `extension_sources` or the four
`*_text` assigns. A second admin with the page open won't see the new
field values until reload. Consistent with how the page already handles other
setting broadcasts (they don't refresh form fields either), so this is a
pre-existing limitation the PR simply inherits.

### NITPICK — Test placement / categorization

- `test/integration/sitemap/router_discovery_validation_test.exs` is pure logic
  (`use ExUnit.Case`, no DB) but lives under `test/integration/`. Per CLAUDE.md
  unit tests belong in `test/modules/`. It still runs everywhere (no
  DataCase/ConnCase), so it's a filing nit, not a functional one.
- In `settings_extension_schema_test.exs`, the `build_extension_sources/1`
  describe block needs no DB but the file `use PhoenixKitWeb.ConnCase`, so those
  pure tests get tagged `:integration` and are excluded when PostgreSQL is
  absent. Minor.

### NITPICK / by-design — Exclude-patterns pre-fill is an opt-out footgun

The exclude-patterns textarea is pre-filled with the *effective* defaults (~30
patterns). Because a saved list **replaces** the built-in defaults entirely
(documented in the help text and `default_exclude_patterns/0`), an admin who
opens Advanced and clicks Save without editing silently freezes today's defaults
and opts the site out of any exclude patterns PhoenixKit adds in future
versions. This is a deliberate tradeoff — the author chose pre-fill precisely to
avoid the *worse* footgun of saving an empty list (which would un-exclude
`/admin`, `/api`, etc.). Sensible; noted so the tradeoff is on record. (Auth
pipelines still protect genuinely sensitive routes regardless via
`protected_by_route_info?/1`.)

## Cross-checks performed (no issue)

- `invalid_patterns/1` uses the same `Regex.compile/1` as `compile_patterns/2` →
  a pattern accepted by the UI cannot be silently dropped at collection time.
  Pinned by `router_discovery_validation_test.exs`.
- Protected-pipeline round trip: UI writes JSON strings → `get_custom_protected_pipelines/0`
  decodes + `safe_to_atom/1`; `invalid_pipeline_names/1`'s
  `~r/^[a-zA-Z_][a-zA-Z0-9_]*$/` matches the identifier space `String.to_atom/1`
  needs. ✓
- `sitemap_custom_urls` / `sitemap_static_routes` JSON shape (array of objects,
  string keys) matches `Static.get_custom_urls_config/0` / `get_static_routes_config/0`
  and `build_*_entry/4`'s `Map.get(config, "path")`. ✓
- Extension write path (`toggle_extension_setting` / `save_extension_setting`) is
  key-whitelisted via `find_extension_field/2` against the declared schema — no
  arbitrary Settings key is writable from the form. ✓
- `bump_and_broadcast/2` matches the existing inline save tail (invalidate cache,
  bump `sitemap_version`, broadcast) and adds cache invalidation the older
  `interval_changed` path omitted. ✓
