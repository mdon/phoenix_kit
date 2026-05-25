# PR #565 — Follow-up

PR is merged into `dev` (merge commit `2a12a536`, version bump landed in
`babaa68d` → 1.7.117 then `a140dc20` → 1.7.118 then `babaa68d` → 1.7.119).
Companion `CLAUDE_REVIEW.md` in this folder.

## Fixed (post-merge, on `dev`)

- **NITPICK #2 (empty-section asymmetry — trailing-empty marker).**
  `(.+?)` → `(.*?)` in `extract_section/3` so a present-but-empty
  *trailing* marker (`...\n---BODY---` at end-of-string) captures `""`
  — matching how an empty *middle* section already resolves via the
  marker-shape post-process guard — instead of failing the regex floor
  and getting reported in `missing_fields`. An entirely absent marker
  still returns `nil` → `missing_fields`, so the "model forgot a
  marker" signal is preserved. Greedy `\s*` always eats the newline
  before an inter-marker boundary, so the empty match only succeeds at
  `\z` — no risk to mid-document fields with content. (commit `79f6dc5e`)
- **MEDIUM (extraction divergence).** Added a `KEEP IN SYNC` comment
  at the inline OpenAI extract pointing to
  `PhoenixKitAI.Completion.extract_content/1`, so the deliberate
  second source of truth doesn't silently drift. (commit `79f6dc5e`)
- **Two regression tests** pinning the asymmetry fix:
  trailing-empty → `""`, absent-trailing → `missing_fields`. (commit
  `79f6dc5e`)

## Skipped (with rationale)

- **NITPICK #3 (`show_info` should be gated on `show_header`).** The
  info tooltip annotates the header title and has no sensible anchor
  without a visible header. Rendering a floating tooltip with no
  anchor would be worse UX than no tooltip. Resolution: documentation,
  not code. Already noted in the docstring's `show_info` description.

## Files touched

| File | Change |
| --- | --- |
| `lib/modules/ai/translation.ex` | `(.+?)` → `(.*?)`; added `KEEP IN SYNC` comment |
| `test/phoenix_kit/modules/ai/translation_test.exs` | +2 regression tests |
| `dev_docs/pull_requests/2026/565-translation-followups-tabledefault-class-attr/CLAUDE_REVIEW.md` | Updated with applied fixes + skip rationale |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — no issues
- `mix dialyzer` — 0 errors, 163/163 ignores match
- `mix test test/phoenix_kit/modules/ai/translation_test.exs` — 26/26 pass

## Open

None.
