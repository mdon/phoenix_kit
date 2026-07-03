# Bug: switch-URL helper crashes (`Path.join([])`) on a bare-locale path

**For:** the agent maintaining `phoenix_kit`.
**From:** Langust. Found against `phoenix_kit` **1.7.151** in `deps/phoenix_kit`, 2026-06-15.

**Status:** FIXED in phoenix_kit **1.7.152** (2026-06-15). `remove_locale_from_path/1` now
returns `/` when the path is only a locale segment (empty `rest`), so `Path.join/1` is never
called with `[]`. Locale detection was kept narrow (2-char base / 5-char dialect) rather than
switching to `looks_like_locale?/1`, so a real 3-char page segment (`/faq`) isn't mis-stripped.
`Core.LanguageSwitcher.strip_locale_from_path/2` was checked — it pattern-matches the bare
case to `/` and never calls `Path.join`, so it needed no change. Langust can drop the
`current_path="/"` workaround.

## Symptom

Rendering the language switcher (the in-menu list of `user_dropdown` / `guest_dropdown`,
and likely `Core.LanguageSwitcher`) on a page whose path is a **bare locale segment** —
e.g. `/ru`, `/fr` — raises and 500s the page:

```
** (FunctionClauseError) no function clause matching in Path.join/1
```

Langust hit this on its localized landing route `/:locale` (e.g. `/ru`). Learner pages
like `/ru/learn/it` are fine — only the bare `/<locale>` case breaks.

## Root cause

`UserDashboardNav.generate_language_switch_url/2` → `remove_locale_from_path/1`
(`lib/phoenix_kit_web/components/user_dashboard_nav.ex`, ~line 272):

```elixir
defp remove_locale_from_path(path) do
  case String.split(path, "/", trim: true) do
    [segment | rest] when byte_size(segment) in [2, 5] ->
      if String.length(segment) == 2 or
           (String.length(segment) == 5 and String.contains?(segment, "-")) do
        "/" <> Path.join(rest)          # <-- rest == [] for a bare "/ru"
      else
        path
      end

    _ ->
      path
  end
end
```

For `path = "/ru"`: `String.split("/ru", "/", trim: true) => ["ru"]`, so `segment = "ru"`,
`rest = []`. `byte_size("ru") == 2` and `String.length("ru") == 2`, so it calls
`Path.join([])` — and `Path.join/1` has no clause for an empty list → `FunctionClauseError`.

(Any 2-char or 5-char-with-dash bare segment triggers it: `/en`, `/fr`, `/en-GB`, …)

## Fix

Handle the empty-`rest` case — a path that is *only* a locale segment should reduce to
`"/"`. E.g.:

```elixir
[segment | rest] when byte_size(segment) in [2, 5] ->
  if looks_like_locale?(segment) do
    case rest do
      [] -> "/"
      _ -> "/" <> Path.join(rest)
    end
  else
    path
  end
```

(or guard with `rest != []`, or `Path.join(["/" | rest])`). Please apply the same guard
anywhere else a locale prefix is stripped and the remainder is fed to `Path.join/1`
(e.g. `Core.LanguageSwitcher` `strip_locale_from_path/2` / `resolve_url/3` if it has the
same shape).

## Severity / workaround

Crashes any host with a bare `/:locale` root/landing route — increasingly likely now that
1.7.150+ encourages locale-prefixed landings. Langust's interim workaround: pass
`current_path="/"` (the landing's canonical path) to the widget instead of the bare
`/:locale`, which both avoids the crash and yields the correct `/ru`, `/fr`, … switch
links. We'll drop the workaround once the guard ships.
