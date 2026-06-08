# PR #586 — Remove AI translation pipeline from core (move to phoenix_kit_ai)

**Verdict:** Clean, well-scoped removal. Merged to `main` (1bb86493) on 2026-06-08. Compiles
with `--warnings-as-errors`; no dangling references in `lib/`, `test/`, `config/`, `priv/`, or
`assets/`. Findings below are follow-ups, not blockers.

## What was verified

- **No dangling code refs.** `AITranslate*`, `PhoenixKit.Modules.AI*`, `ai_translatables`,
  `all_ai_translatables`/`find_ai_translatable`, `TranslateWorker`, `ai_path` — all gone from
  live code; only historical CHANGELOG mentions remain (correct).
- **`safe_call/3` not orphaned** — still used by ~25 other callbacks in `module_registry.ex`.
- **Behaviour cleanup complete** — `ai_translatables/0` removed from the `@callback`, the
  `@optional_callbacks` list, the `__using__` default impl, *and* the `@optional_callbacks`
  re-declaration inside `__using__`. No half-removal.
- **AI migrations retained in core** — `phoenix_kit_ai_endpoints`/`_prompts` chain still present
  (V58/V61/V73/V74/V85 etc.), matching the stated "core owns the versioned chain" intent.
- **`language_switcher`'s `ai_translate` attr kept** — fully parameterized, AI-agnostic; host
  supplies the event names via `event_name(@ai_translate)`. Correct to keep in core.
- **Docs updated consistently** — README and the `language_switcher` moduledoc rewired from
  `PhoenixKit.Modules.AI.*` to `PhoenixKitAI.*`.

## Findings

### IMPROVEMENT - MEDIUM — Breaking public-API removal with no CHANGELOG `### Removed` entry

The entire pipeline was documented as **public, newly-added API** only days before:
- `1.7.130` (2026-06-04) added `PhoenixKit.Modules.AI.{Translatable,Translations,TranslateWorker}`,
  the `PhoenixKit.Module.ai_translatables/0` callback, and
  `ModuleRegistry.all_ai_translatables/0` / `find_ai_translatable/1`.
- `1.7.132` (2026-06-07) added `PhoenixKitWeb.Components.AITranslate.Embed`.

This PR removes all of it plus `PhoenixKitWeb.Components.AITranslate{,.FormGlue,.FormBinding}` and
`Routes.ai_path/0` — with no version bump and no `### Removed` note. Consumers float on `~>`
minimums, so any external consumer outside the coordinated repo set (publishing/catalogue/projects)
would hit an undocumented breaking removal on their next `mix deps.update`.

Project convention is that CHANGELOG entries are written against the bumped `@version`, which
doesn't exist yet — so the PR's "release is the maintainer's call" framing is legitimate. The ask
is just: **when the maintainer cuts the release, include a `### Removed` / breaking note** covering
these modules, the `ai_translatables/0` callback, the two `ModuleRegistry` functions, and
`Routes.ai_path/0`, so the float-to-minimum story is documented rather than implicit.

### NITPICK — Verify the moduledoc pointer `PhoenixKitAI.Translations.available?/0`

`lib/phoenix_kit_web/components/core/language_switcher.ex:163` now reads "hosts that gate on
`PhoenixKitAI.Translations.available?/0`". Two small notes:
1. The PR body says discovery re-homes to `PhoenixKitAI.Translatables` (a scan over
   `ModuleRegistry.all_modules/0`). Confirm `available?/0` actually lives on `Translations` and not
   `Translatables` in the plugin — otherwise this is a dead pointer. Doc-only, low risk.
2. It's a core component docstring naming an optional plugin module — a downward reference. Purely
   informational ("convenient for hosts that gate on…"), so acceptable, but if a generic phrasing
   exists it would keep core docs plugin-agnostic.
