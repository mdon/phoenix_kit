# PR #626: Modernize the admin settings pages

**Author**: @alexdont (Alexander Don)
**Reviewer**: @claude (Opus 4.8)
**Status**: ✅ Merged (post-merge review)
**Merge commit**: `62c9c72a` (feature tip `a0adc49b`)
**Date**: 2026-07-10

## Goal

A pure UI/UX modernization of the admin settings surface — no schema, migration,
or context-logic changes beyond two additive helpers. Five threads:

1. **Section grouping** — replace ad-hoc `<div class="divider">` headings with a
   reusable `<.section_header>` (icon + uppercase title + rule + optional
   actions slot).
2. **Dirty-only hints** — replace always-on "Selected: X | Saved: Y" echoes with
   a `<.unsaved_hint>` that renders *only* when a field diverges from its saved
   value.
3. **OAuth setup DRY** — collapse four hand-copied ~95-line provider instruction
   blocks (Google/Apple/GitHub/Facebook) into one `<.oauth_setup_instructions>`
   component with a `:steps` slot.
4. **Browser-Tab identity** — merge site-icon + default-tab-title into one group
   with a live browser-chrome preview; make the site icon and project logo
   default to each other (`get_site_icon_uuid/0` / `get_logo_uuid/0`).
5. **Localization** — wrap all storage-module flashes and page titles in
   `gettext`/`ngettext`; full `.pot` re-extract + ru/et translations for the new
   strings; drop a dead drag-drop `<script>`/`<style>` block.

## Verdict

**Clean, well-executed refactor — no correctness bugs found.** The mechanical
risks in a change this size (a moved form field silently dropped from the
`<form>`, a dirty-check that no longer fires, a helper that doesn't exist, a
gettext re-extract that blanks existing translations) were all checked and are
clean:

- Every settings field name (`site_url`, `default_tab_title`,
  `site_icon_file_uuid`, the three auth-branding uuids, week/tz/date/time)
  appears **exactly once** after the reorg — nothing duplicated or dropped, all
  still inside their `<.form>`.
- All new helper calls resolve: `get_current_date_example/1`,
  `get_current_time_example/1`, `site_host/0`, `get_option_label/2`,
  `get_timezone_label/2` are all defined in `settings.ex`. `<.section_header>` /
  `<.unsaved_hint>` are reachable via the global
  `import PhoenixKitWeb.Components.Core.FormSection` in `phoenix_kit_web.ex:160`;
  `<.oauth_setup_instructions>` is a local function in `authorization.ex`.
- The removed drag-drop script targeted `#upload-dropzone` / `#file-upload` —
  neither id exists anywhere in the storage settings template. Genuinely dead.
- gettext re-extract is a uniform reflow (+809/−622 identical across all nine
  locale files); ru **and** et (the two 100%-translated locales) have non-empty
  msgstr for the new strings, and the `ngettext` plural preserves `%{count}` in
  its translations.

One genuine **correctness improvement** ships here (see below): the Users-page
registration dirty-check now covers all four toggles instead of two.

Findings are all NITPICK / low-value hardening; nothing was changed in place.

## Positive notes

- **`unsaved_hint` on the registration group widened from 2 → 4 keys**
  (`users.html.heex`). The old hint compared only `allow_registration` +
  `track_registration_geolocation`, so flipping `registration_show_username` or
  `enable_organization_accounts` left the group looking clean. The new
  `Enum.any?` over all four keys fixes that stale-indicator gap. All four are
  real form fields with defaults in `settings.ex` — verified.
- **`data-confirm` added to both destructive resets** (General "Reset ALL
  settings", Dimensions "Reset to Defaults") — previously one-click-irreversible.
- **`ngettext` for the redundancy-copies flash** (`storage/web/settings.ex`)
  instead of an inline `if requested_copies == 1` — correct pluralization.

## Findings

### NITPICK — clipboard `onclick` interpolates the callback URL into inline JS

`lib/phoenix_kit_web/live/settings/authorization.ex` — `oauth_setup_instructions/1`:

```elixir
onclick={"navigator.clipboard.writeText('#{@callback_url}')"}
```

The copy-to-clipboard button builds a JS string literal by interpolating
`@callback_url`. A single quote (or `\`, newline, `</script>`) in the value would
break out of the string. **Not introduced by this PR** — the four pre-existing
provider blocks each had this exact line and the PR moved it verbatim into the
shared component. The value is `get_oauth_callback_url/2` = site-URL setting +
url_prefix + a hardcoded provider slug, i.e. admin-controlled, not end-user
input, so exploitability is near-nil.

**Deliberately not fixed** to avoid scope creep on an already-merged refactor,
but now that it lives in one place it's a cheap future hardening: drop the JS
interpolation and copy from the sibling `<code>` element's `textContent` (or a
`data-clipboard-text` attribute) via a small hook, which also removes the inline
`onclick` entirely.

### NITPICK — favicon fallback reads `auth_logo_file_uuid` *cached*, layout reads it *uncached*

`PhoenixKit.Settings.get_site_icon_uuid/0` resolves `site_icon_file_uuid` →
`auth_logo_file_uuid`, both via `get_setting_cached/2`. But `get_logo_uuid/0`
and the layout wrappers deliberately read `auth_logo_file_uuid` **uncached**
"so a logo change shows cluster-wide without a restart". So when only the logo is
set and it's serving as the favicon fallback, the favicon can lag the logo on
other nodes until the per-node cache refreshes.

This is a **documented, intentional** tradeoff (the moduledoc says the favicon is
"Cache-backed reads — the favicon renders in `<head>` on every page"), and a
stale tab icon is cosmetic. Recorded, not changed.

### IMPROVEMENT - LOW — new components have no test coverage

`section_header/1`, `unsaved_hint/1` (in `core/form_section.ex`) and
`oauth_setup_instructions/1` (in `authorization.ex`) ship untested. This is
consistent with — and folds into — the existing "Component test coverage for
`phoenix_kit_web/components/core/`" TODO in `CLAUDE.md`. Worth pinning in a
future component-coverage sweep: `unsaved_hint` renders nothing when
`dirty={false}`, renders the `— saved:` tail only when `saved` is non-empty; the
`oauth_setup_instructions` `:steps` slot renders inside the `<ol>`.

## Gate

`mix precommit` (compile `--warnings-as-errors` + `deps.unlock --check-unused` +
`quality.ci` = format check + `credo --strict` + dialyzer) — see chat for result.
