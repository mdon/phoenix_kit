# FOLLOW_UP — PR #582 (generalize AI translation)

Triaged 2026-06-14 during the core quality sweep (Phase 1, last-5-Max-PRs scope).
Reviewer: `CLAUDE_REVIEW.md`.

## N/A — code removed from core

Every file this PR reviewed was **removed from core on 2026-06-08** (commit
`26080e90` "Remove AI translation pipeline from core (moved to phoenix_kit_ai)",
plus `b2aa6046` / `36e5fedb`); the modules now live in `phoenix_kit_ai`. No core
surface remains for any finding:

- 429 retry classification (`translate_worker.ex`) — module moved.
- credo `--strict` on `translations_test.exs:90` — test moved.
- `find_ai_translatable/1` rescans modules — re-homed to `PhoenixKitAI.Translatables`.
- app-level dedup TOCTOU (`translations.ex:360`) — module deleted.
- fixed modal id `ai-translation-modal` (`ai_translate.ex`) — component moved.
- timeout comment / unprefixed dedup query — same modules, gone from core.

If any of these are still live, the follow-up belongs in `phoenix_kit_ai`'s PR
docs, not core. The retained migrations (`phoenix_kit_ai_endpoints` /
`_prompts`) carried no review findings.

## Open

None.
