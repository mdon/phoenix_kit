# Bug: guest/user dropdown doesn't highlight the current language on the default locale

**For:** the agent maintaining `phoenix_kit`.
**From:** Langust. Found against `phoenix_kit` **1.7.152** in `deps/phoenix_kit`, 2026-06-15.

**Status:** FIXED in phoenix_kit **1.7.152** (re-released 2026-06-15, within Hex's overwrite
grace window — same version, no bump). `language_menu_section/1` now computes each row's
`active?` by comparing base codes (`DialectMapper.extract_base(language.code) ==
DialectMapper.extract_base(@current_locale)`), so `en` / `en-GB` / `en-US` all match and the
default locale highlights. Works whether the caller passes a base or a dialect. No app change
needed.

## Symptom

In `UserDashboardNav.user_dropdown` / `guest_dropdown`, the in-menu language list does
**not** mark the current language as active when the page is on the **default locale**
(English, path `/`). Other locales (`/ru`, `/fr`) highlight fine; only the default doesn't.

## Root cause

The list highlights with a **full-dialect equality** check
(`user_dashboard_nav.ex` ~lines 245 and 255):

```elixir
if language.code == @current_locale, do: ...active...
```

- `language.code` is the **enabled dialect** — here `["fr-FR", "it", "ru", "en-GB", "et"]`.
- On the default page, phoenix_kit assigns `@current_locale = DialectMapper.resolve_dialect(default_base)`
  = `resolve_dialect("en")` = **`"en-US"`** (hardcoded in `DialectMapper`).
- English is enabled as **`"en-GB"`**, so `"en-GB" == "en-US"` → `false` → not highlighted.

Two compounding issues:
1. **Dialect equality instead of base.** `resolve_dialect("en")` returns a *fixed* `en-US`
   regardless of which English dialect is actually enabled (`en-GB`), so they never match.
2. **Attr/code mismatch.** The `:current_locale` attr is documented as "base code of the
   active locale" (`user_dashboard_nav.ex:41`), but the code compares it against
   `language.code` (a dialect). A caller that follows the doc and passes a base (`"en"`,
   `"fr"`) would mis-highlight too (`"fr-FR" == "fr"` is false).

Verified values:

```
Routes.get_default_admin_locale()            => "en"
DialectMapper.resolve_dialect("en")          => "en-US"
Languages.get_enabled_languages |> codes     => ["fr-FR", "it", "ru", "en-GB", "et"]
```

## Fix

Compare by **base code**, like `Core.LanguageSwitcher` already does
(`language["base_code"] == @current_base`). In `user_dashboard_nav.ex` (both the `~= @current_locale`
sites, signed-in and guest):

```elixir
active? = DialectMapper.extract_base(language.code) == DialectMapper.extract_base(@current_locale)
```

This makes `en-GB` / `en-US` / `en` all resolve to base `en` and match, fixes every dialect
(`fr-FR` vs `fr`), and is robust whether the caller passes a base or a dialect — which also
reconciles the attr doc (line 41) with the behavior.

(Alternatively, `resolve_dialect/1` could return the *enabled* dialect for a base rather
than a hardcoded one, but the base-comparison fix is simpler and matches the standalone
switcher.)

## App side (Langust)

We currently pass phoenix_kit's `@current_locale` (the dialect) to the widget; that
coincidentally highlights `ru`/`fr` but not the English default. No clean app-side
workaround exists (passing the base would break the dialect-coded entries until the
comparison is base-aware), so this is the component's to fix. After the base-comparison
fix, highlighting works for all locales including the default with no app change.
