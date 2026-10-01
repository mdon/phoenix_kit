# PRs #887, #889, #890 — review

Merged 2026-10-01 (`61b68ea26`, `636441022`, `a8a3f6991`) · **Author:** timujinne · **Reviewer:** Claude

| PR | Title |
|---|---|
| #887 | Add Markdown bodies, shared headers and footers, layout groups and branding to file emails |
| #889 | Fix a dialect locale preference rendering core's default copy in English |
| #890 | Add the email accent colour field, an email registry and an admin email preview |

**Verdict:** no defect in the code. The one real problem was outside it: the three PRs added
~69 strings and never ran `mix gettext.extract`, so the `.pot` was stale and none of the new
admin copy existed in any locale. Fixed here. The rest are recorded nitpicks.

**Gate:** the PRs' own tests — `test/phoenix_kit/email`, `test/integration/email`, the
`email_preview`/`email_sending` LiveView tests, `recipient_locale`, `render` — 265 tests +
9 doctests + 43 LiveView tests, 0 failures.

## IMPROVEMENT - MEDIUM — the new copy was never extracted (all three PRs) — FIXED

`mix gettext.extract --check-up-to-date` failed on `main`. The merge reported **48 new
messages and 21 reworded (fuzzy)** per locale: the Email preview page, the Branding tab, the
eight core email labels/descriptions. Without the round-trip the strings render in English in
every locale; with a bare `--merge` they arrive as fuzzy carry-overs that Gettext **serves**
(`Layout` → es "usted" / et "sina", `Logo` → "Cierre de sesión" / "Väljalogimine",
`Branding` → "Warnung", `Text` → "Weiter", `Part` → "Port", `Host file` → "Test ebaõnnestus").

Fix: extract + merge, all 69 msgids translated by hand in de, es, et, fr, it, pl, ru (bindings
checked against each msgid; terminology from each catalogue, not from the fuzzy matches), the
inert fuzzy flags in `en` cleared. Re-running `extract --merge` is a byte-for-byte no-op and
`--check-up-to-date` passes. de/fr (53), es/it/pl (77) still carry **older** untranslated
singulars from earlier releases — not from these PRs; et and ru are at 0.

## #887 — `Content`, `Layout`, `Markdown`, `Branding`

Read against the real source of truth, and probed with a scratch script (not committed):

- **Resolution order** (`@html_order`/`@text_order`) matches the table in the moduledoc and the
  guide; a blank part (and Markdown that renders to nothing) gives way to the next entry.
- **Placeholders in Markdown.** `[Go]({{url}})`, `![alt {{x}}]({{url}})`, `{{a}}{{a}}` in a
  target, `{{{raw}}}` vs `{{escaped}}`, a placeholder in a heading / table cell / quote / list
  item / code span / code block all render correctly; `javascript:` through a placeholder drops
  the link and keeps the label (HTML and text); `MAILTO:` and padded targets are handled; an
  `&` in a target is attribute-escaped once. The nonce/token scheme has no double substitution.
- **`layout.txt`** with a trailing newline is fine — `Templates.render/4` trims the `layout`
  part before `Layout.valid_group?/1` sees it.
- **Branding values** reach a `style`/`src` only through `normalize_color/1` /
  `valid_logo_url?/1`.

**NITPICK — a bare `{{url}}` paragraph is text, not a link.** `{{confirmation_url}}` alone on a
line (the shape of core's old plain-text bodies) renders as `https://…` text in the HTML,
because at render time the placeholder is a word, not an address; `<{{url}}>` prints the angle
brackets. Most clients auto-link it, and `[label]({{url}})` is the right spelling. Documented in
the guide now ("Buttons"); not changed — turning a bare placeholder into a link would make the
meaning of `{{url}}` depend on its neighbours.

**NITPICK — `Branding.logo_url/0` is two reads per send** (`get_file` + `list_file_instances`),
uncached by design ("a changed setting shows in the next email"). Auth mail is low-volume; if a
module sends in bulk through `send_from_template/4` it is worth a short TTL then.

## #889 — `RecipientLocale.gettext_locale/1`

Correct. `locale` → its Gettext spelling (`pt-BR` → `pt_BR`) → base language, against
`Gettext.known_locales/1`; `""`/`"-"` fall to `"en"`; the web (`put_gettext_locale/2`) and
`in_locale/2` now share it.

**NITPICK — the "shared by everything rendered for a recipient" claim was too broad.**
`digest_worker`/`delivery_worker` still pass `RecipientLocale.base/1` (split on `-`, no
downcase) into `in_locale/2`, so a `pt-BR` user's digest reads `pt` even where a `pt_BR`
catalogue exists. No divergence today — core ships base-language catalogues only. The doc comment
now says so; `base/1` is left as it is, since its result is also written into the channel
envelope.

## #890 — Catalog, CoreTemplates, EmailPreview, accent colour

- The move of every default into `CoreTemplates` is verbatim (msgids and bodies diffed against
  the removed closures), so the send and the preview share one function.
- `Catalog.preview/3` goes through `Content.resolve_with_sources/5`; it records no template
  usage, sends nothing, and a raising module `defaults`/`variables` becomes `{:error, _}`.
- `EmailPreview`: `email`/`lang` are matched against the known lists (no free-form value reaches
  a path or a query); the HTML is an `<iframe srcdoc sandbox="">` — no script, no same-origin;
  gated by `settings` in the admin-gate map; every `phx-change` form has an id.
- Accent colour: only `#rrggbb` is saved (blank clears, and `email_accent_color` is on the
  allowed-blank list so the first empty save works); the swatch's inline style only ever carries
  a normalised value.

**NITPICK — queries in `mount/3`.** `Catalog.entries/0` (module registry), `Languages`,
`Settings.get_project_title/0` run in `mount`, which LiveView calls twice. They are cache
reads and match the sibling settings pages; the render (the expensive part) is correctly in
`handle_params`. Left.

**NITPICK — `title={path}` on the sources table** carries the absolute server path as a
tooltip, while the cell shows the project-relative one. Admin-only (`settings`); left.

## Release

2.44.0 — new features on top of the published 2.43.1 (Hex latest at the start of this review).
