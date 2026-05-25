# Follow-up — PR #557 (AI translation language switcher + ai_translate)

## No findings

All review items either fixed pre-existing via post-merge follow-up commits or rolled into PR #558. Re-verified against current code (`modal-to-native-dialog` branch) on 2026-05-25.

## Fixed (pre-existing — verified, no new work needed)

- ~~**BUG-HIGH** — Dialyzer failed on `PhoenixKitAI.ask_with_prompt/4`.~~ Resolved post-merge by adding `{"lib/modules/ai/translation.ex", :unknown_function}` to `.dialyzer_ignore.exs:85` (the compile-time `Code.ensure_loaded?/1` guard at `translation.ex:72` masks the function from dialyzer's view, hence the ignore).
- ~~**NITPICK** — Bulk-handler doc example re-enqueued in-flight jobs.~~ `lib/modules/ai/language_switcher.ex:170` now says "enqueue one job per *actionable* (missing minus in_flight) language".
- ~~**NITPICK** — Case-insensitive marker regex missing `i` flag.~~ Fixed in commit `2d0a3660` — `lib/modules/ai/translation.ex:346` now has `/si` flags.

## N/A

- **IMPROVEMENT-MEDIUM** — `completed` key documented but unused. The misleading key was doc-dropped post-merge; `language_switcher.ex:147` no longer lists it in the shape.
- **NITPICK** — Empty `fields` map wastes AI request. Scope of PR #558.

## Open

None.
