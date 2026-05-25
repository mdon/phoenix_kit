# Follow-up — PR #554 (PR #552 follow-ups + locale-path dedup)

## Fixed (Batch 1 — 2026-05-25)

- ~~**IMPROVEMENT-MEDIUM** — `redirect_invalid_locale/2` called `prefixless_primary?()` twice.~~ `lib/phoenix_kit_web/users/auth.ex:1987-1994` now reads the flag once and destructures the segment/suffix pair. Beyond the minor perf win, the single read eliminates a torn-read risk if a concurrent setting flip lands between the two evaluations.
- ~~**IMPROVEMENT-MEDIUM** — `LocalePath` moduledoc said "three rules", listed four.~~ `lib/modules/sitemap/locale_path.ex:7` now reads "four rules:" to match the numbered list below.
- ~~**NITPICK** — `auth_locale_test.exs` mixed setter styles in cleanup.~~ `test/integration/users/auth_locale_test.exs:36-42` `on_exit` now uses `Languages.set_default_language_no_prefix(false)` (mirroring the `setup` block in the `setting ON` describe), so any future cache/invalidation logic the typed setter wires up runs in cleanup too.

## Partially fixed (intentional residue documented)

- **NITPICK** — `prefixless_primary_safe?()` duplicates the `mix_task_context?()` sentinel. The original review acknowledged this is intentional ("settings-cache-status sentinel is the same regardless of caller"). Left as-is — restating ≠ wrong, and consolidation is a future call.
- **NITPICK** — `LocalePath.emit_prefix?(nil, _)` rationale is in the moduledoc, not inline. The function's `nil` clause at `lib/modules/sitemap/locale_path.ex:40` is documented in moduledoc rule 1 ("No language supplied → no prefix"). Future callers passing `nil` as "use site default" would not find the explanation right at the clause, but the moduledoc carries it. Left as-is to avoid duplicating the rule across two places that could drift.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_web/users/auth.ex` | Single read + tuple destructure in `redirect_invalid_locale/2` |
| `lib/modules/sitemap/locale_path.ex` | Moduledoc rule count: "three" → "four" |
| `test/integration/users/auth_locale_test.exs` | `on_exit` cleanup uses `Languages.set_default_language_no_prefix/1` |

## Verification

- `mix compile --warnings-as-errors` clean (via `phoenix_kit_parent`)

## Open

None.
