# Follow-up: PR #572 — V125 project statuses

Triaged 2026-06-03 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Skipped (with rationale)

Both findings are `NITPICK`s confirmed still-present but intentional:

- **`v125_test.exs` uses `async: false`** (`test/phoenix_kit/migrations/v125_test.exs:27`)
  — matches the sibling V-migration test precedent (all `vNNN_test.exs` run
  non-async against the shared migration DB). Left for consistency.
- **`schema_for/1` is a one-line identity passthrough** — kept for symmetry
  with the neighbouring `prefix_str/1` helper; harmless.

## Open

None.
