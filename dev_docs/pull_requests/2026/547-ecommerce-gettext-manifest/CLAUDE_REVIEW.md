# PR #547 Review — Add ecommerce gettext manifest and ru/et translations

**Author:** Tymofii Shapovalov (timujinne) · **Base:** `dev` · **State:** MERGED 2026-05-18

## Scope

+21197 / -3034. Almost entirely i18n data: PO/POT regeneration across 9 locales,
a new ecommerce gettext manifest, two one-line label fixes, the media selector
modal translated, plus carried-over review docs for PR #4 and PR #531.

## Verdict

Sound, low-risk change. Code surface is tiny and correct. No runtime bug. Two
items below are accuracy/consistency cleanups, not blockers — left for Tim since
they touch the manifest's intended design. **Not actioned in this review.**

> Note: an earlier draft of this review flagged a MEDIUM `gettext`/`ngettext`
> runtime mismatch. That finding is **withdrawn** — verified against
> `/workspace/phoenix_kit_ecommerce`: the string in question is not used by
> ecommerce at all (see Finding 1).

---

## Findings

### NITPICK — `"%{count} selected"` in the manifest is not an ecommerce string

`ecommerce_gettext_manifest.ex:389` declares `gettext("%{count} selected", count: 0)`.
Verified: this string does not appear anywhere in `phoenix_kit_ecommerce`
(neither as a `gettext` call nor as raw template text). It belongs solely to
core's `media_selector_modal.html.heex:38`, which already emits it via
`ngettext`. The extractor merges both into one plural POT entry (confirmed in
`default.pot` / `ru/.../default.po`), so behavior is correct — the manifest line
is simply redundant and inconsistent (`gettext` vs the modal's `ngettext`).
Harmless; could be dropped.

### IMPROVEMENT - MEDIUM — moduledoc "Refreshing the list" procedure is inaccurate

The manifest is **forward-looking**: it declares ~250 ecommerce admin strings,
but `phoenix_kit_ecommerce` currently has only ~30 `gettext` calls in
`web/*.ex`. Verified that strings like `"Add Product"`, `"Shopping Carts"`,
`"Image Migration"` exist in ecommerce as **raw, un-wrapped template text**
(e.g. `dashboard.ex:48`, `carts.ex:93`, `imports.ex:887`). The manifest pre-loads
translations into core's POT so they are ready once ecommerce wraps the strings.

That strategy is fine, but the moduledoc's `grep '(gettext|ngettext)\("..."'`
refresh command returns only ~7 strings against today's ecommerce source —
following it literally would delete most of the manifest. The moduledoc should
state the manifest is forward-looking and that the grep only catches the
already-wrapped subset.

(Consequently, a manifest-vs-source drift-guard test is **not** viable yet — it
would fail ~250-vs-7 by design until ecommerce completes its i18n wrapping.)

### NITPICK — `layout_wrapper.ex` "Admin" → "Admin Panel" is a label change

`gettext("Admin")` became `gettext("Admin Panel")`, changing rendered text and
orphaning existing "Admin" translations. PR body lists this as an intentional
"label fix"; it now matches `user_dashboard_nav.ex`. Just noting it's a behavior
change inside an i18n PR.

---

## Positives

- `media_selector_modal` i18n is correct: interpolation untouched, `ngettext`
  used properly so ru/pl get real plural forms.
- ru and et fully translated — **0 fuzzy entries remain** (PR claims 91 fixed);
  spot-checked ecommerce strings ("Add Product", "Shopping Carts", "Image
  Migration") all populated.
- `EcommerceGettextManifest` correctly `@moduledoc false` / `@doc false`, never
  called at runtime — a clean extraction-only target.
- No DB/LiveView lifecycle changes; nothing touches mount/handle_params.
