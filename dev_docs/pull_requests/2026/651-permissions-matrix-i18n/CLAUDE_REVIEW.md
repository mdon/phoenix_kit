# PR #651: Add localized module labels to the admin permissions matrix

**Author**: @timujinne
**Reviewer**: @claude (Sonnet 5)
**Status**: ✅ Reviewed, no changes needed
**Date**: 2026-07-20

## Goal

The admin permissions matrix (`/admin/roles`, `/admin/permissions`) rendered
every module's permission label via `Permissions.module_label/1` — always
English, even when the sidebar tab for that same module already renders
translated via `Tab.localized_label/1`. This PR adds
`Permissions.localized_module_label/1` and swaps every render call site to
it, following the same `{gettext_backend, gettext_domain}` resolution
`PhoenixKit.Dashboard.Tab` already uses for sidebar labels:

- Core sections and registered feature modules translate through the
  library's own `PhoenixKitWeb.Gettext` (`"default"` domain) unless the
  module declares its own backend via the new `:gettext_backend` /
  `:gettext_domain` keys on `permission_metadata/0`.
- Sub-permission keys inherit the parent module's backend (registry-driven
  via `parent_key/1`, never string-split).
- Custom keys (including tab-auto-registered ones) carry their own backend
  via the same new options on `register_custom_key/2`; config-driven admin
  tabs forward their existing `gettext_backend`/`gettext_domain` into the
  custom key `Dashboard.Registry.auto_register_custom_permission/1`
  registers for them, so a tab's sidebar label and its permission-matrix
  label translate identically.
- A bad `gettext_backend` (not a loaded module, or not actually a Gettext
  backend — no `__gettext__/1`) is rejected at registration time with a
  `Logger.warning`, in both `register_custom_key/2` and
  `ModuleRegistry.permission_gettext/0` — so one misconfigured module can't
  raise from `dgettext/3` at render time and take down the whole matrix.
- `auth.ex`'s "module is not enabled" flash now wraps the localized label
  in its own translated sentence (`"%{label} module is not enabled"` as a
  msgid) instead of interpolating a translated name into a hardcoded
  English frame.
- New msgids added by hand across all locale `.po` files + `.pot`
  (`Maintenance`, `DB`, `Dashboards`, the flash sentence) — correctly, per
  the new moduledoc note: `mix gettext.extract` can't discover a label that
  only exists as data in `permission_metadata/0`, so any module label not
  already carried as a sidebar-tab msgid needs its msgid added by hand.

## Verified correct (no action needed)

- `label_gettext/1`'s resolution order (core → registered module → parent
  via `parent_key/1` → custom) exactly mirrors `module_label/1`'s own
  fallback order, so `localized_module_label/1` never picks a different
  *source* of label than `module_label/1` — only translates what's already
  selected. Checked in particular that `parent_key/1` is registry-driven
  (`Enum.any?(subs, &(&1.key == key))`), not string-split, so a dotted
  custom key that merely *looks* like `"module.something"` without being a
  declared sub-permission correctly falls through to
  `custom_label_gettext/1` instead of wrongly inheriting the module's
  backend.
- `ModuleRegistry.permission_gettext/0` and `register_custom_key/2`'s
  `validate_gettext_backend/2` both guard identically (`Code.ensure_loaded?`
  + `function_exported?(backend, :__gettext__, 1)`), so a bad backend is
  caught at both of the two paths that can introduce one (module metadata,
  custom-key registration) rather than only one.
- The `"Dashboards"` msgid (plural, distinct from the already-existing
  singular `"Dashboard"` sidebar-tab msgid) traces to a real external
  module (`phoenix_kit_dashboards`, per the commit message) that ships no
  gettext backend of its own — not a stray/typo'd entry; confirmed no
  in-repo label actually reads `"Dashboards"` because none needs to.
- Test coverage (`localized_module_label/1` describe block) exercises the
  real matrix: core-label translation, no-translation fallback, custom key
  with a working backend, custom key with no backend, tab-driven
  `nil` passthrough (the auto-register path always passes the keys, so a
  tab without gettext config must not gain a bogus backend), and both
  invalid-backend rejection paths (non-module, atom-without-`__gettext__`).
- `mix precommit` (format + compile --warnings-as-errors + credo --strict +
  dialyzer) passes clean on the merged tree; no formatting or type-spec
  issues introduced.

## Noted, not fixed

Nothing found worth flagging — small, well-scoped, and the resolution
logic was checked against the pre-existing `module_label/1` and
`Tab.localized_label/1` to confirm it's actually consistent with both,
not just documented to be.
