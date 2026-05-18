# PR #531 Review — Add admin sidebar i18n, wide-screen settings, complete Estonian catalog

**Reviewer:** CLAUDE (Opus 4.7)
**Verdict:** REQUEST_CHANGES — one HIGH-severity user-visible i18n bug + one MEDIUM PO maintenance bug.
**Scope:** 7 commits, 23 files, +3,967 / -2,587. Wires `gettext_backend` on 24 core admin tabs, completes the Estonian catalog (1142/1143), widens 8 settings pages, adds a card-view toggle to the Custom Fields table, and wraps core `badge.ex` / `time_display.ex` / General Settings / sitemap / languages strings in `gettext`.

## Summary by commit

| Commit | Subject | Notes |
|---|---|---|
| c5fd5bae | Tab gettext_backend + card-view Custom Fields | OK with caveats (see #3, #4) |
| 373478f5 | Tab msgids + ET catalog completion | OK |
| 3ea70ec1 | Widen settings pages | OK (see #6) |
| d867cb57 | Widen module settings | OK |
| 1fe0ad78 | Wrap badge.ex + time_display.ex | **HIGH bug** (see #1); also fixes pre-existing RU mistranslations |
| 24ceec90 | Widen General Settings + wrap /admin/modules/languages | **MEDIUM PO bug** (see #2) |
| afcc281a | Wrap sitemap settings (75 calls) | **MEDIUM PO bug** (see #2) |

---

## BUG — HIGH

### 1. `"Active"` badge in users table left untranslated while adjacent `"Inactive"` is wrapped

`lib/phoenix_kit_web/live/users/users.html.heex:277-282` after this PR:

```heex
<%= if user.is_active do %>
  <span class="badge badge-outline badge-xs h-auto">Active</span>
<% else %>
  <span class="badge badge-error badge-xs h-auto">
    {gettext("Inactive")}
  </span>
<% end %>
```

The diff explicitly wraps `"Inactive"` (the false branch) but leaves `"Active"` (the true branch) raw in the same `if/else`. Result on a non-English locale: the badge will read translated "Mitteaktiivne / Неактивен" for inactive users, but plain English "Active" for active users on the same page. This is in the main `/admin/users` listing — a heavily-trafficked admin page.

**Fix:** wrap to `{gettext("Active")}`. The msgid `"Active"` already exists in all catalogs (`Aktiivne`, `Активен`, etc. — verified in the ET diff at line where existing `Active` was translated to `Aktiivne`), so no PO file changes required.

---

## BUG — MEDIUM

### 2. 73 of 94 new PO entries lack `#:` source references (pot/en/ru/et default.po)

The two later batches added in commits **24ceec90** ("Languages" — 21 msgids) and **afcc281a** ("Sitemap" — 52 msgids) append entries to the `.pot` and `.po` files without `#: source/file.heex:line` lines, e.g.:

```po
msgid "Summary"
msgstr "Сводка"

msgid "Languages Enabled"
msgstr "Включенные языки"
...
```

By contrast, the earlier batch in commit **373478f5** (9 tab-label msgids) and the badge/time batch in **1fe0ad78** (8 msgids) **do** include refs:

```po
#: lib/phoenix_kit/dashboard/admin_tabs.ex:148
#, elixir-autogen, elixir-format
msgid "Activity"
msgstr "Активность"
```

The afcc281a commit message claims: *"56 new msgids appended manually with #: source refs"* — but the diff shows they were appended **without** refs. Same applies to the 24ceec90 commit message claim of *"21 new msgids appended manually with #: source refs"*.

**Impact:** when someone next runs `mix gettext.extract --merge` against the codebase (which extracts these strings from the HEEX templates — they all use `gettext(...)`), gettext-merge will either:
- Add the missing `#:` refs (in which case the changes will then need re-committing), OR
- Mark the existing entries as duplicates of the freshly-extracted entries and emit warnings.

Either way the PO files are not in a "clean post-extract" state, which the PR's test plan implies they should be (`mix gettext.merge clean: 1151 unchanged, 0 new, 0 removed` was claimed for ET).

**Fix:** add the `#:` ref lines back, e.g.:

```po
#: lib/phoenix_kit_web/live/modules/languages.html.heex:23
#, elixir-autogen, elixir-format
msgid "Summary"
msgstr "Сводка"
```

(Easiest path: run `mix gettext.extract --merge` once, then re-translate the freshly-blanked ru/et entries — they'll all match the existing translations in this PR by msgid.)

Note the same affects all four files: `priv/gettext/default.pot`, `priv/gettext/en/LC_MESSAGES/default.po`, `priv/gettext/ru/LC_MESSAGES/default.po`, `priv/gettext/et/LC_MESSAGES/default.po`.

---

## IMPROVEMENT — MEDIUM

### 3. Custom Fields card-mode label-format inconsistency

`lib/phoenix_kit_web/live/settings/users.html.heex:367-389` `card_fields` callback:

```elixir
[
  %{label: gettext("Key:"), value: field["key"]},
  %{label: gettext("Type"), value: field["type"]},
  %{label: gettext("Required"), value: ...},
  %{label: gettext("Status"), value: ...},
  %{label: gettext("User Access"), value: ...}
]
```

`Key:` has a trailing colon, the other four do not. In card mode this renders as "Key: my_field / Type my_field / Required Yes / Status Enabled / User Access User Editable" — visually uneven.

**Fix:** either drop the colon on `"Key:"` (preferred, matches other labels and avoids a new msgid lookup if `"Key"` isn't already in the catalog) or add colons to the other four (worse, requires four new msgids).

### 4. Table-mode action buttons lost their mobile text fallback labels

Diff at `users.html.heex:454-472` (table-mode action buttons) removes:

```heex
- <.icon name="hero-eye" class="w-3 h-3 hidden sm:inline" />
- <span class="sm:hidden whitespace-nowrap">{gettext("Disable")}</span>
+ <.icon name="hero-eye" class="w-3 h-3" />
```

Before: mobile users (`< sm`) saw a text label; desktop saw an icon with `data-tip` tooltip.
After: all viewports see icon-only with `data-tip`. On touchscreens, `tooltip` (daisyUI hover-only) does not appear, so mobile users see a row of three indistinguishable ghost-icon buttons.

The PR introduces the card-view toggle as the intended mobile UX (`card_actions` slot has visible labels), so a user *can* switch — but the table view remains the default and unfriendly on touch. Either:
- (a) Restore the `sm:hidden` text spans inside the table cells, OR
- (b) Auto-default the table to card view on small viewports via the toggleable component's responsive behavior (if supported).

Same icon-only regression in the table-mode Edit and Delete buttons.

### 5. `format_expiration/1` still renders English month names

`lib/phoenix_kit_web/components/core/time_display.ex:208`:

```elixir
defp format_expiration(date) do
  Calendar.strftime(date, "%B %d, %Y")
end
```

The PR wrapped the `nil` branch (`gettext("No expiration")`) but left the date-formatting branch hard-coded to a US-English month-name format. On `et`/`ru` locales this will render e.g. "May 11, 2026" instead of "11.05.2026" or "11 мая 2026". Pre-existing, out of scope for this PR's stated goal — but worth a follow-up issue, since the file has now been touched for i18n and a future reader will assume it's fully localized.

---

## NITPICK

### 6. Removed `flex justify-center` wrapper in `seo.html.heex`

`lib/phoenix_kit_web/live/settings/seo.html.heex` drops both `max-w-3xl` and the `flex justify-center` wrapper. The card now spans full width. The page contains only one toggle, so a full-width card has a lot of empty real-estate on wide screens. Consider keeping a soft cap (e.g., `max-w-4xl mx-auto` like the integration form bumps to) for aesthetic purposes. Minor visual call.

### 7. Russian translation collapse

Two distinct msgids collapse to the same RU translation:

| msgid | ru msgstr |
|---|---|
| `Languages Enabled` | `Включенные языки` |
| `Enabled Languages` | `Включенные языки` |

Same in ET: both → `Lubatud keeled` / variations. The English source distinguishes "Languages Enabled" (stat-card noun) from "Enabled Languages" (section heading); the translations don't. Acceptable but reduces editorial nuance. Consider `Количество включённых языков` for the stat label vs. `Включённые языки` for the section.

### 8. ET `%{count}h ago` → `%{count} t tagasi` uses a single-letter "t"

Modern Estonian UIs usually use `h` (hour) or the full word `tundi`. A bare `t` reads as "t" the letter, not "tunni". Compare with `%{count} min tagasi` which uses the conventional abbreviation. Suggest `%{count} h tagasi` for consistency.

### 9. `"%{count}s/m/h/d ago"` are plain `gettext`, not `ngettext`

For ru/et these are grammatically odd at `count = 1` ("1 päeva tagasi" reads as "1 day-genitive ago"; should be "1 päev tagasi" for the singular). The commit message explicitly notes this is deferred: *"need ngettext / structural rewrites that don't belong in this pass."* Acceptable scope decision.

### 10. Hardcoded `confirm()` text remains English

`onclick="return confirm('Are you sure you want to delete this field?')"` in both the table-mode and card-mode Delete buttons in `users.html.heex`. Pre-existing, but two clean spots within the file being touched. A `gettext` interpolation here would close out the page's i18n coverage.

### 11. Commit-message claim mismatch

The afcc281a and 24ceec90 commit messages assert that msgids were *"appended manually with #: source refs"*. The diffs show otherwise (see #2). Update the commit body or re-commit with refs to keep the audit trail honest.

---

## What's good

- **Tab gettext-backend wiring is uniform and complete** — the helper-function change in `admin_subtab/8` covers 12 subtabs; the 7 inline `%Tab{}` literals are individually updated; 6 built-in modules (`jobs`, `seo`, `sitemap`, `languages`, `maintenance`, `referrals`) are all wired. Consistent pattern.
- **The two pre-existing wrong RU translations were caught and fixed in passing** (`"Inactive"` was *"Неактивные пользователи"* plural-stat-card text used in singular-badge context; `"Disabled"` was *"Отключенные аккаунты"* plural-noun used as a button label). Both now correct: `"Неактивен"`, `"Отключено"`. Plus `"Disable"` fixed from *"Отключенные аккаунты"* to imperative `"Отключить"`.
- **HEEX hygiene clean** — `<%!-- --%>` comments throughout, no HTML comment leakage, all tags balanced after the structural moves in `seo.html.heex` and `settings.html.heex`.
- **Widescreen pass is targeted** — `max-w-xs` caps on short numeric inputs (sample rate, retention, etc.) deliberately preserved per commit message. Verified no `max-w-xs` removals in the sitemap diff. Grid layouts (`grid-cols-1 md:grid-cols-2 gap-6`) added where two short selects/inputs sit side-by-side. Reasonable.
- **`max-w-prose` added to inline alert-info / alert-warning panels** in users.html.heex — keeps explanatory copy readable instead of stretching across the full container. Nice touch.
- **`max-w-4xl` instead of removing the cap entirely on the integration form steps** — sensible compromise. Same pattern would benefit `seo.html.heex` (see #6).
- **Custom Fields table → toggleable card-view** mirrors the existing pattern from `integrations.html.heex`. The `:toolbar_title` / `:toolbar_actions` / `:card_actions` slot usage is conventional. The standalone "Add Custom Field" button beneath the table is correctly retired in favor of the toolbar variant.
- **ET catalog completion** is solid — sampled translations (`Salvesta`, `Tühista`, `Kustuta`, `Muuda`, `Kohustuslik`, `Lubatud`, `Tehinguline`, etc.) are accurate, glossary anchors are preserved, placeholders (`%{count}`, `%{provider}`, `%{role_name}`, `%{language}`, etc.) preserved across all sampled entries — no placeholder drops detected.
- **Pre-existing `<urlset>` markers in sitemap copy** are preserved as literal text in both ru and et translations — the HEEX `{...}` interpolation will HTML-escape them at render time, so they'll display as `&lt;urlset&gt;` to users. Correct.

---

## Test plan additions (suggested)

The PR test plan flags `[ ] Visual check of admin sidebar in ru/et locale` and `[ ] Visual check of each /admin/settings/* page on wide screen` as still TODO. To these, add:

- Visit `/admin/users` on ru/et and confirm both Active **and** Inactive badges translate (catches #1).
- Run `mix gettext.extract --merge` on the branch; verify it reports `0 new, 0 removed` (will surface #2 if unresolved).
- Toggle `/admin/settings/users` Custom Fields card view on mobile; verify all four action buttons render with visible labels (regression check for #4).
- Verify card view on a 320px viewport doesn't truncate `User Editable` / `Admin Only` (the `whitespace-nowrap` keeps them on one line in the table; need to confirm card mode handles this too).

---

## Verdict

**REQUEST_CHANGES** — issue #1 is a one-line visible-string fix; issue #2 needs a 73-entry catalog touch-up (or single `mix gettext.extract --merge` followed by re-paste of the new ru/et translations). Once those land, the rest is solid and the PR is ready.
