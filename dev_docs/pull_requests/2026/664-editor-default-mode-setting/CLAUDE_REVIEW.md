# PR #664 — Site-wide Default Editor Mode setting (+ leaf 0.3.2)

**Author:** alexdont
**Reviewer:** Claude Opus 5
**Date:** 2026-07-27
**Verdict:** ✅ APPROVE WITH ONE FIX — already merged. The feature is correct and
fail-safe; one MEDIUM maintainability finding (a three-way duplicated
allowlist whose docstring claimed to be a single source) fixed post-merge.

---

## Summary

Adds an admin-editable `editor_default_mode` setting (Hybrid / Visual /
Markdown / HTML) under a new "Content Editor" section on
`/admin/settings`, plus `PhoenixKit.Settings.get_editor_mode/0` which returns
the mode as an atom ready to hand to Leaf's `mode` attr. Also bumps `leaf` to
0.3.2 (hex pin + the CDN pin in `priv/static/assets/phoenix_kit.js` moved in
lockstep — verified).

Small, well-shaped change. The setting follows the established pattern exactly:
a default in `Settings.get_defaults/0`, a field + `validate_inclusion` on the
`SettingsForm` embedded schema, an entry in `get_setting_options/0`, and a form
block matching the surrounding markup (including the `<.unsaved_hint>` dirty
tracking other settings use). No migration is needed — the settings LV merges
`get_defaults/0` over the DB rows, so the picker shows "Hybrid" on an install
that has never saved the key.

## Files changed (5)

| File | Change |
|---|---|
| `lib/phoenix_kit/settings/setting.ex` | +3 — field, cast, `validate_inclusion` |
| `lib/phoenix_kit/settings/settings.ex` | +42 — default, `editor_mode_options/0`, `get_editor_mode/0` |
| `lib/phoenix_kit_web/live/settings.html.heex` | +41 — "Content Editor" section |
| `mix.lock` / `priv/static/assets/phoenix_kit.js` | leaf 0.3.2 |

---

## Findings

### IMPROVEMENT - MEDIUM — the editor-mode list existed in three places, one of which claimed to be the single source

The same four modes were written out independently in:

1. `Settings.editor_mode_options/0` — the picker's `{label, value}` tuples;
2. `Setting.SettingsForm.changeset/2` — `validate_inclusion(:editor_default_mode,
   ["hybrid", "visual", "markdown", "html"])`;
3. `Settings.get_editor_mode/0` — the `case` clauses coercing string → atom.

`editor_mode_options/0`'s own docstring said it was the "Single source for the
`editor_default_mode` entry in `get_setting_options/0` and for validating
`get_editor_mode/0`" — which was not true of either (2) or (3).

The drift is quiet in both directions. Adding a mode to (1) and (2) but not (3)
means the changeset accepts it, the picker offers it, the admin saves it, and
`get_editor_mode/0` silently coerces it back to `:hybrid` — a setting that
appears to save and then does nothing. Adding it to (1) alone means the picker
offers a value the changeset rejects.

**Fixed.** Introduced a single `@editor_modes` list of
`{stored value, Leaf atom, label}` in `PhoenixKit.Settings`. `editor_mode_options/0`
derives the picker tuples from it, a new `editor_modes/0` exposes the value
allowlist (which `Setting`'s `validate_inclusion` now calls), and
`get_editor_mode/0` resolves via `List.keyfind/3` instead of hand-written
clauses. The head entry is the default, so `@default_editor_mode` derives too.
Adding a mode is now a one-line change. `Setting → Settings` is a runtime call
inside a function body, so it introduces no compile-time cycle.

---

## Recorded, not fixed

- **`get_editor_mode/0` has no call site in core.** Nothing in `lib/` renders a
  Leaf editor with it — the consumers are the external `phoenix_kit_comments` /
  `phoenix_kit_publishing` modules, which have to adopt it. That is a reasonable
  library API, but the setting's help text says it "Applies site-wide wherever
  the rich-text editor is rendered (posts, comments)", which only becomes true
  once those modules read it. Worth softening the copy, or tracking the module
  adoption, so an admin who flips it on a core-only install isn't confused by it
  having no visible effect.

- **Raw `<select>` rather than `<.select>`.** The new block hand-rolls the
  select markup. It matches every other picker in `settings.html.heex`
  verbatim, so this is consistency with the file rather than a defect — noting
  only because AGENTS.md prefers the core form components in new code, and this
  whole template is a candidate for that sweep.

## Verification performed

- **No migration needed.** `Live.Settings.mount/3` does
  `Map.merge(Settings.get_defaults(), Settings.list_all_settings())`, so
  `@settings["editor_default_mode"]` and `@saved_settings[...]` are populated
  and the `selected=` comparison works on an install with no stored row.
  `get_editor_mode/0` also passes its own default to `get_setting_cached/2`.

- **`reset_to_defaults` round-trips the new key** — it writes
  `Settings.get_defaults()` wholesale, which now carries `editor_default_mode`,
  and the value passes its own `validate_inclusion`.

- **leaf pin is consistent** — `mix.lock` and the CDN URL in
  `priv/static/assets/phoenix_kit.js` both moved to 0.3.2; no third copy of the
  version exists in the repo.

## Gate

`mix precommit` (format + `compile --warnings-as-errors` + `credo --strict` +
dialyzer) — see the release commit.

---

## Second-pass review (Grok) — 2026-07-27

**Scope:** Meta-review of the findings and post-merge fix above (commit
`be0505e5`, release 1.7.214), not a full re-read of the original PR. Verified
the single-source refactor against the current tree.

**Verdict on this review:** ✅ Finding and fix hold. No release-blocking
residuals.

### Confirmed

- **IMPROVEMENT MEDIUM (three allowlists)** — Real maintainability footgun. The
  silent `:hybrid` coercion path when the picker/changeset accept a value that
  `get_editor_mode/0` does not map is a quiet production-shaped failure, not
  just style.
- **Fix** — `@editor_modes` → `editor_mode_options/0` / `editor_modes/0` /
  `List.keyfind` in `get_editor_mode/0` is clean. `Setting`'s
  `validate_inclusion` calling `PhoenixKit.Settings.editor_modes/0` at runtime
  (function body, not module attribute) correctly avoids a compile-time cycle.
  Docstring on `editor_mode_options/0` no longer overclaims a single source it
  did not own.
- **Recorded items** — No core call site for `get_editor_mode/0` (consumers are
  external modules), and raw `<select>` matching the rest of
  `settings.html.heex`, are both fair. Softening the help text until modules
  adopt the API remains a good follow-up.

### Additional findings (not fixed here)

- **NITPICK — residual hard-coded default.** `@default_editor_mode` is derived
  from the head of `@editor_modes` and used by `get_editor_mode/0`, but
  `get_defaults/0` still hardcodes `"editor_default_mode" => "hybrid"`, and the
  unknown-value fallback in `get_editor_mode/0` is a literal `:hybrid`. Reordering
  `@editor_modes` (or changing the default) would leave those two sites behind.
  Wire both to `@default_editor_mode` / the list head atom when next touching
  this code.
- **NITPICK — no unit test locking the single source.** A one-liner that
  asserts `editor_mode_options/0` values == `editor_modes/0` and that every
  value round-trips through the coercion path would make the three-way-drift
  class of bug fail the suite if someone reintroduces a hand-kept copy. Low
  priority given the refactor already collapsed the three lists.

### Gate (second pass)

- Tree inspection only (no dedicated unit tests for this setting). Shipped in
  the same 1.7.214 release as the #665 fixes; hex + `v1.7.214` tag present.
