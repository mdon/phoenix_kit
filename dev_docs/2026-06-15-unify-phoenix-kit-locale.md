# Go all-in on phoenix_kit's locale: unify the learner language switch

**Date:** 2026-06-15
**Status:** UNBLOCKED (2026-06-15) — the phoenix_kit gap is fixed; app-side integration
below can proceed on the **URL-only** approach (no cookie; add a `/:locale` landing route).
The referenced `2026-06-15-phoenix-kit-anonymous-locale-spec.md` was never written and is
now moot — the gap turned out to be narrower than diagnosed and was fixed directly in core
rather than spec'd. Details:

- *"Switcher auth-gated in the user widget"* — only the **user** dropdown
  (`UserDashboardNav.user_dropdown`) is auth-only. The standalone
  `PhoenixKitWeb.Components.Core.LanguageSwitcher.language_switcher_dropdown` is fully
  anonymous-capable (this doc's §4 already plans to use it), so this was never a real
  blocker.
- *"404s on `/`"* — the real gap, now **fixed in phoenix_kit**:
  `Routes.path("/", locale: "ru")` emitted `/ru/` (trailing slash), and Phoenix routers
  don't match a trailing slash, so a parent app's `/:locale` landing route 404'd. Core now
  emits `/ru` (no trailing slash) — see `locale_prefixed_path/3` in
  `lib/phoenix_kit/utils/routes.ex`, tested in `test/phoenix_kit/utils/routes_test.exs`.
  phoenix_kit deliberately keeps **URL-as-truth** (session/cookie locale removed in PR #551,
  the "sticky locale" bug), so anonymous landing persistence is purely the URL: the app
  declares a `/:locale` landing and the switcher's `/ru` link now resolves to it.

Only the "Présent" card-label fix from this line of work had previously shipped.
**Author:** Dmitri + Claude

## Decision (2026-06-15)

- Use **phoenix_kit's** header widgets (user menu + language switcher), and route **all**
  language switching through phoenix_kit's locale system — the learner's reading language
  = phoenix_kit's `current_locale`. Cues, chrome, and phoenix_kit's own UI all follow it.
- **Landing page** language = logged-in user's preferred locale → browser `Accept-Language`
  → English.
- Already shipped this turn: the conjugation-help card label now uses the per-language
  tense label (`@card.grammar.tense` → "Presente" for it, "Présent" for fr), not a
  hardcoded "Présent".

## Background: two locale systems today

| | Our learner locale | phoenix_kit locale |
|---|---|---|
| Source | `:ui_lang` URL segment (`/:ui_lang/learn/:target`) | `:locale` URL segment / `params["locale"]` |
| Drives | cue language (`meaning_cue`) + chrome (`LangustWeb.Gettext` via `RestoreLocale`) | `PhoenixKitWeb.Gettext` + **global** gettext + `current_locale(_base)` assigns |
| Codes | base (`en/et/ru/fr/it`) | base in URL, **dialect** internally (`en-GB`, `fr-FR`, …) |

The two are independent today. "All-in" = collapse the learner locale onto phoenix_kit's.

## Feasibility findings (verified 2026-06-15)

- `Routes.path("/learn/it", locale: "ru")` → `/ru/learn/it` — phoenix_kit's switcher
  produces our learner URLs correctly (our `:ui_lang` segment is already locale-shaped).
- `Routes.path("/", locale: "ru")` → `/ru/` — **no such route**; the switcher breaks on
  the landing page. → landing needs separate handling (see §Landing).
- Enabled locales are dialects: `["fr-FR","it","ru","en-GB","et"]`; phoenix_kit sets the
  **global** gettext locale to the dialect (`fr-FR`). Our `.po`s are base-keyed (`fr`),
  so a base→our-backend hook is still required (gettext won't fall back dialect→base).
- phoenix_kit attaches a `:phoenix_kit_locale_handler` `handle_event` hook in
  `phoenix_kit_mount_current_scope` (the on_mount already on all our live_sessions), so
  the switcher's `phoenix_kit_set_locale` event is handled for free.

## Plan

### 1. Route param `:ui_lang` → `:locale`

Rename the segment in the learner + stats scopes so phoenix_kit's locale plumbing engages
(`params["locale"]` → `current_locale_base`/global gettext, switcher URL generation):

```
/:locale/learn/:target      (PracticeLive)
/:locale/stats[/:target]    (Stats*)
```

The URL shape is unchanged for users (`/ru/learn/it` still works) — only the param name
changes. Update every reader: `practice_live.ex` and the stats LVs read `params["locale"]`
(was `"ui_lang"`); internal links (`home_live` start/target links, the stats↔practice
links) keep the `/#{code}/...` shape (now a locale prefix).

### 2. Keep a base-code hook for `LangustWeb.Gettext`

`RestoreLocale` stays (renamed concept) but reads `params["locale"]` and sets
`LangustWeb.Gettext` to the **base** code (our `.po` keys). phoenix_kit handles its own +
global (dialect) locale. So both backends end up on the same language, base-vs-dialect
notwithstanding.

### 3. Cue language follows the locale

`meaning_cue`/`word_meaning` already take a `ui_lang` arg; the practice mount passes
`params["locale"]` into it. No context change — just the source of the value.

### 4. Header: phoenix_kit components

Replace, in `Layouts.frontend`:
- custom `lang_switcher` → `PhoenixKitWeb.Components.Core.LanguageSwitcher.language_switcher_dropdown`
  (anonymous-capable; uses `current_locale` + `current_path`). This is the one switcher for
  everyone and drives the locale through phoenix_kit.
- custom `user_corner` → `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown`
  (avatar + Admin/Dashboard/Settings/Log out). Its built-in language list is redundant with
  the standalone switcher — acceptable, or pass options to suppress it if supported.

`Layouts.frontend` must receive `current_locale` + `current_path` (both already produced by
phoenix_kit's on_mount: `current_locale`, and `url_path` from the routing hook). Thread them
from each LV into the layout.

### 5. Landing page (`/`) — the wart

The landing has no `:locale` segment, and `Routes.path("/", locale: x)` → `/x/` (404). So:

- **Locale source:** logged-in `user.preferred_locale` → `Accept-Language` (parsed, first
  enabled match) → `en`. Resolve in `home_live mount`, set `LangustWeb.Gettext` to the base.
- **Switcher on landing:** the phoenix_kit dropdown would emit `/x/` links. Options
  (pick at review):
  1. **Hide the switcher on the landing page** (it's a splash; language is auto-detected and
     the visitor picks a learn-target which carries them into a localized `/:locale/learn/...`).
     Simplest, recommended.
  2. Add a prefixless-friendly landing handler that accepts an optional `?lang=` and sets a
     cookie / preferred locale. More work, lets visitors switch on the splash.

Recommendation: **(1)** for this pass — auto-detect + the target picker is the entry point.

### 6. Cleanup

- `Learning.ui_language_options/2` and `ui_language_codes/0` may become unused once the
  header uses phoenix_kit's switcher (it lists enabled languages itself). Audit callers;
  remove if dead (home_live still needs target-language list, which is `list_practiceable_languages`, not UI languages — keep that).
- Drop `RestoreLocale`'s `@locales` hardcode in favour of the enabled set if convenient.

## Blast radius / risks

- **Routing rename** touches: router, `practice_live`, `stats_dashboard_live`,
  `stats_language_live`, `home_live` links, `RestoreLocale`. Mechanical but wide.
- **Dialect vs base**: keep our base-code hook; don't rely on the global dialect locale for
  `LangustWeb.Gettext`.
- **Landing switcher** URL breakage → resolved by §Landing (1).
- phoenix_kit's `user_dropdown` is auth-only (anonymous → "Login" button); the standalone
  switcher covers anonymous language switching, so no regression.

## Out of scope

- Translating phoenix_kit's own UI strings (its gettext, separate).
- Per-dialect content (we stay base-code: en/et/ru/fr/it).
