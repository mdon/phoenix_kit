# CLAUDE_REVIEW — ecommerce i18n (Phase 3, two-stage single pass)

> **RE-REVIEW (commit `f60ac3a5`): PASS.** All blockers resolved. Targeted
> re-check: ru & et each 344/344 added present, **0 fuzzy, 0 placeholder
> mismatch, 0 empty, 0 missing `#:` ref**. The 91 previously-fuzzy entries now
> carry correct ecommerce-sense translations (e.g. `Delete Product`→"Удалить
> продукт/Kustuta toode", `No categories found`→"Категории не найдены"); the 4
> placeholder fixes are correct in var **and** meaning; both `ngettext` blocks
> filled (ru 3-form / et 2-form, `%{count}` preserved). Fix commit scope clean
> (only ru/et PO; no mix.exs/CHANGELOG; no AI attribution; `#:` refs intact).
> Phase 4 (elixir-debugger) unblocked. — Original FAIL report retained below.

---

**Verdict: FAIL** (Stage 1 fails → Stage 2 gathered for a single fix cycle)
*(superseded by RE-REVIEW PASS above)*

- Spec: `dev_docs/plans/2026-05-17-ecommerce-i18n-translations-plan.md`
- ecommerce `9ad956d` (branch `main`), core `4c1056eb` (branch `dev`)
- Reviewed: 2026-05-17

---

## Verdict summary

The structural work is **excellent**: the manifest msgid set is **byte-identical**
to what is wrapped in the 11 ecommerce admin files (zero drift), no out-of-scope
creep, sidebar untouched, all hard rules respected, build clean. ~253 entries were
hand-translated to good quality.

It FAILS because the translation pass is **incomplete**: `mix gettext.extract --merge`
left **91 `#, fuzzy` auto-merged entries per locale** (identical msgid set in ru and
et) plus **both `ngettext` plural blocks broken**. Gettext **ignores `#, fuzzy`
entries at runtime** — so those 91 strings + the 2 plural strings render **English**,
which directly defeats the task goal ("make in-scope admin content translate for
ru/et"). Several fuzzy entries also break `%{}` interpolation.

---

## Stage 1 — Spec compliance

| # | Check | Result |
|---|-------|--------|
| 1.1 | No out-of-scope creep (ecommerce) | **PASS** |
| 1.2 | Sidebar subsystem untouched | **PASS** |
| 1.3 | Manifest byte-matches wrapped source | **PASS** |
| 1.4 | Manifest shape mirrors legal manifest | **PASS** (3 NITPICKs) |
| 1.5 | `%{}` placeholders intact end-to-end | **FAIL** |
| 1.6 | 23 non-ecommerce entries classification | **LEGITIMATE (a)** — but counts misreported |

### 1.1 Out-of-scope creep — PASS
`git show --stat 9ad956d` = exactly the 11 in-scope admin `.ex` files. OUT files
(`user_orders`, `user_order_details`, `checkout_page`, `cart_page`, `shop_catalog`,
`catalog_category`, `catalog_product`, `product_detail`) untouched. **The only
`.html.heex` files in ecommerce `lib/` are the two OUT-of-scope customer order
templates** (`user_orders.html.heex`, `user_order_details.html.heex`); the 11 admin
LiveViews use inline `~H` — so "(+ their .html.heex)" in the plan is moot, no missed
HEEX coverage.

### 1.2 Sidebar untouched — PASS
No `PhoenixKitEcommerce.Gettext` backend, no ecommerce `priv/gettext` in `9ad956d`.

### 1.3 Manifest ↔ source byte-match — PASS
Extracted every `gettext`/`ngettext` msgid from the 11 ecommerce files and from
`__extract__/0`: **326 gettext + 2 ngettext on BOTH sides, ZERO missing, ZERO extra.**
The single-source-of-truth invariant is perfectly satisfied.

Note: the plan's `## Phase 1 — canonical inventory` is a *summary* ("253 msgids
extracted") + 2 ngettext pairs + ~22 interpolated samples, **not** a full byte list,
so a literal manifest↔plan byte-diff is not possible. Spot-checked all 2 ngettext
pairs + all ~22 interpolated samples against the manifest — every one matches
byte-for-byte. The substantive invariant (manifest == wrapped source) is exact.

### 1.4 Manifest shape — PASS, 3 NITPICKs
`@moduledoc false`, scope comment, grep refresh recipe, `use Gettext, backend:
PhoenixKitWeb.Gettext`, `def __extract__/0`, dummy bindings on interpolated entries,
plurals as `ngettext` — all present, mirrors `legal_gettext_manifest.ex`.

- **NITPICK** L47 `# credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks`
  targets the wrong check — `__extract__/0` is a plain function body, not a `quote`
  block. Harmless but mistargeted; legal manifest needs no such disable.
- **NITPICK** Scope comment (L20–21) says customer/storefront OUT but does **not**
  explicitly state the sidebar `PhoenixKitEcommerce.Gettext` subsystem is OUT (brief
  1.4 asked for "sidebar OUT" in the comment).
- **NITPICK** Ordering is not strict `sort -u`: `=`-leading (L50–51) first, then
  A–Z, then a–z, then `%{…}`-leading (L378–386), then ngettext. The grep recipe
  produces strict ASCII order (`%` < `=` < `A` < `a`). Cosmetic — extraction is
  order-independent — but the recipe won't reproduce this ordering.

### 1.5 Placeholders intact — FAIL
3 fuzzy ru/et entries change the interpolation variable, so a de-fuzzy as-is would
break `Gettext` interpolation (binding provides one var, msgstr references another):

| msgid | ru/et msgstr placeholder | expected |
|---|---|---|
| `Are you sure you want to delete %{count} products? This action cannot be undone.` | `%{role_name}` | `%{count}` |
| `Are you sure you want to delete %{count} categories? This action cannot be undone.` | `%{role_name}` | `%{count}` |
| `Up to %{max} files, max %{size}MB each` | `%{count}`, `%{size}` | `%{max}`, `%{size}` |
| `Permanently delete '%{name}'? This cannot be undone.` | `%{count}` | `%{name}` |

(All four are within the 91 fuzzy set — fixing fuzzy correctly resolves these.)

### 1.6 Non-ecommerce entries — LEGITIMATE (scenario a), counts misreported
Actual POT delta vs `4c1056eb~1`: **+344 added, −16 removed** (not "253/23").

- **294** added entries reference **only** `ecommerce_gettext_manifest.ex` (manifest-driven).
- **50** added entries reference **real core source files**, all with valid `#:`
  refs (none hand-added, none from the manifest):
  - `lib/phoenix_kit_web/components/media_browser.ex` ×18
  - `lib/phoenix_kit_web/components/annotation_composer.ex` ×16
  - `lib/phoenix_kit_web/components/media_browser.html.heex` ×7
  - `lib/phoenix_kit_web/live/settings/integration_form.html.heex` ×6
  - `lib/modules/storage/web/settings.html.heex` ×2
  - `lib/phoenix_kit_web/components/core/integration_picker.ex` ×1

These are incidental pre-existing-but-unextracted core strings caught by the normal
`mix gettext.extract` walk of core's own `lib/`. **This is scenario (a) —
legitimate.** Not scope creep, not manifest bloat (manifest == ecommerce source
exactly), not hand-added. The implementer's reported "253" is in fact the count of
**non-fuzzy** entries they translated; "23" undercounts the 50 incidental core
strings.

**−16 removed** (`Manage Users`, `Activity`, `General`, `Authorization`,
`Dimensions`, `Live Sessions`, `Folder created/deleted/name`, integration-form
strings, etc.): confirmed **zero** gettext-family references remain in core source
for any of them → correct stale-POT cleanup by `mix gettext.extract`, **not** a
PR-introduced regression. (They had prior ru translations, but are no longer
extractable static calls — self-healing is exactly why the plan mandates the extract
workflow.) Informational only.

---

## Stage 2 — Code quality (gathered for one-shot fix cycle)

| # | Check | Result |
|---|-------|--------|
| 2.1 | `#:` refs on all added entries (PR#531 bug#2) | **PASS** (0 without refs in POT/ru/et) |
| 2.2 | ru/et accuracy + glossary | **FAIL** (91 fuzzy/locale) |
| 2.3 | `ngettext` for plurals | **FAIL** (both pairs broken) |
| 2.4 | HARD RULES (both repos) | **PASS** |
| 2.5 | Build hygiene (format/credo) | **PASS** |

### 2.1 PO `#:` refs — PASS
**0** added entries lack a `#:` ref in `default.pot`, `ru`, or `et`. PR #531 bug #2
does **not** regress. All 344 present in ru and et.

### 2.2 ru/et accuracy — FAIL (blocker)
**91 `#, fuzzy` added entries per locale** (identical msgid set ru≡et) carry
`msgmerge` auto-guesses from unrelated strings. Gettext does not use fuzzy entries →
they render **English**. Many are semantically wrong even ignoring fuzzy semantics:

- `Delete Product` → "Удалить бакет" / "Kustuta bucket" (delete *bucket*)
- `Delete this category?` → "Удалить это соединение" / "Kustuta see ühendus" (*connection*)
- `Failed to delete product` → "Не удалось удалить роль" / "Rolli kustutamine…" (*role*)
- `No categories found` → "Роли не найдены" / "Rolle ei leitud" (*roles*)
- `Total Products` → "Всего бакетов" / "Buckete kokku" (*buckets*)
- `Create a new product` → "Создать новую учетную запись" / "Loo konto" (*account*)
- `Search categories...` → "Поиск интеграций..." / "Otsi integratsioone..." (*integrations*)
- `Product title` → "Название проекта" / "Projekti pealkiri" (*project title*)
- `Time` → "Часовой пояс" / "Ajavöönd" (*timezone*); `Handle` → "и" / "ja" (*and*)
- … full list: `fuzzy_fix_list.txt` (91 entries, ru+et current values).

The non-fuzzy ~253 spot-check is **good** (e.g. `%{count} categories updated to
%{status}` → `%{count} категорий переведено в статус %{status}` — placeholders and
meaning correct), so the fix scope is bounded to the 91 + the 2 plural blocks, **not
a full retranslation**.

de/es/fr/it/pl: 3–5 added entries non-empty (e.g. `Failed to update filter`) —
`msgmerge`-preserved prior translations of identical msgids, benign/informational
(plan's "stay empty" is idealized). `en`: 0 non-empty — PASS (core convention).

### 2.3 ngettext plurals — FAIL (blocker)
- `1 category` / `%{count} categories`: `msgstr[]` **all empty** in ru AND et.
- `1 product` / `%{count} products`: `#, fuzzy`; ru `[0..2]`="продукт" ×3,
  et `[0..1]`="toode" ×2 — no `%{count}`, wrong plural agreement.

ru needs **3** plural forms, et needs **2** (msgstr arity already correct; only
content/fuzzy-flag wrong). Both category/product count displays render English.

### 2.4 HARD RULES — PASS
`git show 9ad956d -- mix.exs CHANGELOG.md` empty; `git show 4c1056eb -- mix.exs
CHANGELOG.md` empty. No AI/Claude attribution in either commit message. ecommerce
committed dep = `{:phoenix_kit, "~> 1.7"}` (no `path:` override).

### 2.5 Build hygiene — PASS
`mix format --check-formatted` exit 0 in **both** repos (manifest + 11 ecommerce
files). `mix credo --strict` on the manifest: "found no issues".

---

## Required fixes (→ implementer)

1. **De-fuzzy + correctly translate the 91 entries** (`fuzzy_fix_list.txt`) in
   **both** `priv/gettext/ru/LC_MESSAGES/default.po` and
   `priv/gettext/et/LC_MESSAGES/default.po`: replace each `msgstr` with an accurate
   ru/et translation and remove the `fuzzy` flag from the `#,` line. Reuse the
   existing core glossary for shared words (grep current PO for the word).
2. **Fix the 4 placeholder mismatches** (§1.5) as part of (1) — msgstr must use the
   exact `%{}` vars of the msgid (`%{count}`, `%{max}`+`%{size}`, `%{name}`).
3. **Fill both `ngettext` blocks**: `1 category`/`%{count} categories` and
   `1 product`/`%{count} products` in ru (`[0]`,`[1]`,`[2]`) and et (`[0]`,`[1]`)
   with correct count-bearing plural forms; remove the `fuzzy` flag from the
   product pair.
4. Do **not** re-run `mix gettext.extract --merge` unless source changed — edit the
   PO `msgstr`/flag lines only (preserve `#:` refs). Re-run `mix format` +
   `mix credo --strict` after.

NITPICKs (optional, non-blocking): manifest L47 credo-disable mistargeted; add
explicit "sidebar OUT" to the scope comment.

After fixes, SendMessage `reviewer` "fixed" → targeted re-review of the 91 + 2
plural blocks + the 4 placeholders only.
