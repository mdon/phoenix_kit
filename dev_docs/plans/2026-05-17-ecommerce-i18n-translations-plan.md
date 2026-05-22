# Plan: ecommerce module i18n — translate admin UI content (ru/et)

**Date:** 2026-05-17
**Status:** Approved, in execution
**Repos:** `phoenix_kit` core (`/app`, branch `dev`) + `phoenix_kit_ecommerce` (`/root/projects/phoenix_kit_ecommerce`, branch `main`)
**Locales:** English (msgid source), Russian (`ru`), Estonian (`et`)

## Goal

The ecommerce admin sidebar menu translates correctly, but the module's internal admin
page content (page headers, subheaders, buttons, on-page tab titles, quick-action-bar
titles, flash/toast messages) renders untranslated English on `ru`/`et` locales. Make
the in-scope admin content translate for `ru` and `et`.

## Root cause

`mix gettext.extract` walks only core's `lib/`, never deps. Strings called from
`phoenix_kit_ecommerce` via the shared `PhoenixKitWeb.Gettext` backend never reach
`priv/gettext/default.pot`, so they have no catalog entry and fall back to the raw
English msgid.

The sidebar works because tab labels use a *separate* module-owned backend
(`PhoenixKitEcommerce.Gettext`) with its own manually-maintained, already-translated
`priv/gettext` (9 tab labels in ru/et). That subsystem is correct and **out of scope** —
do not touch it.

Established fix pattern (mirrors `legal_gettext_manifest.ex`,
`projects_gettext_manifest.ex`, `comments_gettext_manifest.ex`): a manifest module in
core re-emits the module's `gettext(...)` calls so the extractor records them into core's
POT, where translations are then filled.

## Scope

**IN (this iteration) — admin UI + flash, ~85 distinct msgids:**

Admin LiveViews/components/templates only:
- `products.ex`, `categories.ex`, `imports.ex`, `import_show.ex`,
  `shipping_methods.ex`, `carts.ex`, `settings.ex`, `product_form.ex`,
  `shipping_method_form.ex`, `category_form.ex`, `dashboard.ex` (+ their `.html.heex`)
- Page titles (`assign(:page_title, ...)`), `<h1>`/subheader text, buttons,
  quick-action-bar titles, inline labels/placeholders, all `put_flash(...)` messages
- Already-wrapped-but-untranslated admin msgids: `"Delete this category?"`,
  `"View Details"`, `"Retry"`

**OUT (deferred to a later iteration — customer-facing):**
- `user_orders.ex` / `user_orders.html.heex`
- `user_order_details.ex` / `user_order_details.html.heex`
- Storefront: `checkout_page.ex`, `cart_page.ex`, `shop_catalog.ex`,
  `catalog_category.ex`, `catalog_product.ex`, `product_detail.ex`

**Already translated in core — zero work:** `"Delete"`, `"Edit"`, `"Remove"`,
`"View"`, `"Retry"` resolve at runtime via the existing core catalog. (Verify `"Retry"`
is genuinely already present; if not it joins the in-scope set.)

**Hard rules (CLAUDE.local.md):** never edit `@version` in `mix.exs`, never edit
`CHANGELOG.md` — in **both** repos. No AI/Claude attribution in commits/PRs.

## Single source of truth

The core manifest is a **manual list**; its msgids must be byte-identical to what is
wrapped in ecommerce. Phase 1 produces the canonical inventory; Phase 2 mirrors it
exactly. One implementer carries both phases sequentially to prevent drift.

## Phases

### Phase 1 — `phoenix_kit_ecommerce` repo: wrap admin strings

1. **Build canonical inventory.** Grep every in-scope admin file for hardcoded
   user-visible strings (page_title, flash, HEEX headers/buttons/QAB/labels) +
   the 3 already-wrapped admin msgids. Produce an exact, deduplicated msgid list
   (this list drives Phase 2). Save it to the plan's working notes.
2. **Wrap strings.** Replace literals with `gettext("...")`. Plurals → `ngettext`.
   Interpolations → `gettext("Edit %{title}", title: title)` (never string-build
   then wrap). Backend already correct via `shop_web.ex` (`use Gettext, backend:
   PhoenixKitWeb.Gettext` lines 12/59) — **no backend change**.
3. **Verify build.** `mix compile` (warnings-as-errors), `mix format`,
   `mix credo --strict` in the ecommerce checkout.
4. **mix.exs guard.** Confirm committed dep stays `{:phoenix_kit, "~> 1.7"}`; if a
   local `path: "/app"` override exists it must remain uncommitted.
5. **Commit** (no `@version`/CHANGELOG). Descriptive message, ≤70-char subject.

### Phase 2 — core `/app`: manifest + extract + translations

1. **Create `lib/phoenix_kit_web/ecommerce_gettext_manifest.ex`** mirroring
   `legal_gettext_manifest.ex` exactly: `@moduledoc false`, Scope comment (admin UI +
   flash IN; customer order/storefront pages OUT), "Refreshing the list" grep recipe,
   `use Gettext, backend: PhoenixKitWeb.Gettext`, `def __extract__/0` listing every
   canonical msgid from Phase 1 (interpolated entries with dummy bindings, plural
   pairs as `ngettext`).
2. **Extract.** Run `mix gettext.extract --merge` **from `/app`** (implementer only —
   destructive working-tree op). Regenerates `priv/gettext/default.pot` and merges
   `#:`-ref'd blank entries into every locale `.po`.
3. **Translate.** Fill `ru` and `et` msgstrs in
   `priv/gettext/{ru,et}/LC_MESSAGES/default.po`. Preserve every `%{var}`. Reuse
   existing core glossary translations for shared words (no divergent ru/et for words
   core already translates). de/es/fr/it/pl stay empty (core convention); `en` per
   core convention (matches existing PO files post-extract).
4. **Verify build.** `mix compile`, `mix format`, `mix credo --strict` in `/app`.
   Do **not** hand-edit PO files or append entries without `#:` refs (PR #531 bug #2).
5. **Commit** (no `@version`/CHANGELOG). Descriptive message.

### Phase 3 — review (reviewer agent, Opus, two-stage single pass)

- **Stage 1 spec:** every in-scope admin string wrapped? manifest msgids byte-match
  Phase 1? no out-of-scope creep (customer pages untouched)? `%{}` placeholders intact
  end-to-end? sidebar backend untouched?
- **Stage 2 quality:** ru/et accuracy + glossary consistency; `ngettext` used for
  plurals; PO `#:` refs present (no PR #531 bug #2); no `@version`/`CHANGELOG` diff in
  either repo; no AI attribution; credo/format clean.
- Reviewer must NOT run `git checkout -- / reset --hard / restore / clean` or
  `mix gettext.extract --merge`. Implementer commits a checkpoint before review.
- Fail → SendMessage file:line issues directly to implementer → fix → targeted re-review.

### Phase 4 — live verification on Decor 3D Print

Test app: `decor_3d_print`, port 4001, ecommerce installed, MCP
`decor-shop-tidewave`, TMUX pane `phoenixkit:1.1`.

1. `mix compile` ecommerce + core; `mix deps.compile phoenix_kit --force` in
   decor_3d_print; restart server in TMUX `phoenixkit:1.1`.
2. Locale `ru` → walk every in-scope admin page (products, categories, imports,
   shipping methods, carts, settings, and the form pages) → confirm headers,
   subheaders, buttons, on-page tab titles, QAB titles render Russian; trigger flash
   paths (delete/save/error) and confirm flash text is Russian.
3. Repeat for `et`.
4. Confirm English (source) unbroken.
5. Confirm sidebar still translates (regression check on the untouched subsystem).

## PR coupling

Two independent PRs (both fork `timujinne` → upstream `BeamLabEU`):
- **PR-A** ecommerce → `main`. Mergeable alone (adds gettext wrapping; English
  fallback is harmless without PR-B).
- **PR-B** core → `dev`. Delivers the catalog.
- Hard coupling is **msgid string identity**, managed via the canonical list — not
  merge order. Both must be deployed together to see translations.

## Risks / watch-items

| Risk | Mitigation |
|---|---|
| msgid drift between repos | one implementer, sequential; Phase 2 mirrors Phase 1 list verbatim; reviewer byte-checks |
| PO files without `#:` refs (PR #531 bug #2) | mandatory `mix gettext.extract --merge` workflow, never hand-edit PO |
| Placeholder drop in ru/et | reviewer checks every `%{var}` end-to-end |
| Accidental touch of working sidebar backend | scope rule explicit; reviewer regression-checks sidebar |
| `@version`/CHANGELOG edit | hard rule in both agent briefs; reviewer greps staged diff |
| Destructive op by reviewer | reviewer brief forbids it; checkpoint commit before review |

## Phase 1 — canonical inventory

253 msgids extracted (estimate was ~85; actual count higher due to comprehensive
coverage of all form labels, placeholders, option modal strings, import wizard steps,
and 23 additional non-ecommerce strings from Media/Comments/Storage that were also
new in this extraction run).

**Ecommerce admin LiveViews covered:**
`dashboard.ex`, `carts.ex`, `categories.ex`, `category_form.ex`, `products.ex`,
`product_form.ex`, `imports.ex`, `import_show.ex`, `settings.ex`,
`shipping_methods.ex`, `shipping_method_form.ex`

**Phase 1 commit (phoenix_kit_ecommerce, branch main):** `9ad956d`
**Phase 2 commit (phoenix_kit core, branch dev):** `4c1056eb`

ngettext pairs:
- `ngettext("1 category", "%{count} categories", n)`
- `ngettext("1 product", "%{count} products", n)`

Interpolated entries (sample): `Edit %{name}`, `Edit %{title}`, `Import: %{filename}`,
`Import started: %{filename}`, `Import failed: %{reason}`, `Retrying import: %{filename}`,
`%{count} carts total`, `%{count} categories updated to %{status}`,
`%{count} products updated to %{status}`, `Migrate %{count} Products`,
`Move %{count} selected products to a category`, `Cancelled %{count} pending migration jobs`,
`Started migration for %{count} products`, `Set parent for %{count} selected categories`,
`Update status for %{count} selected categories`, `Update status for %{count} selected products`,
`Filter '%{key}' added`, `Filter for '%{key}' already exists`, `Option '%{key}' created`,
`Value '%{value}' added`, `Value '%{value}' added to '%{key}'`,
`Value '%{value}' already exists`, `Value '%{value}' already exists in '%{key}'`.

## Self-review (writing-plans)

- **Goal testable?** Yes — Phase 4 walks every in-scope page in ru/et on a live app.
- **Scope creep?** Customer pages + storefront explicitly OUT; sidebar OUT.
- **Ordering sound?** Phase 1 must precede Phase 2 (manifest mirrors canonical list);
  Phase 3 after both; Phase 4 last.
- **Reversible?** Both changes are additive (gettext wrapping + new manifest + PO
  entries); no migrations, no schema, no data changes.
- **Unknowns?** Exact final msgid count (~85 estimate) resolved by Phase 1 step 1;
  `"Retry"` core-presence to be verified, low impact either way.
