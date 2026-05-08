# PR #515 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code (post-merge).

## Fixed (pre-existing)

The reviewer themselves landed the post-merge follow-up commit
described in `CLAUDE_REVIEW.md`'s "Follow-up commit on `dev`" section.
All four items on that list are present in current code:

- ~~**IMPROVEMENT - MEDIUM: `Runner.runner_opts` lacked regression
  coverage for prefix forwarding.** Now exposed as `runner_opts/1`
  (`lib/phoenix_kit/migration.ex:303-304`) — pure function over the
  prefix arg. Three pinning assertions in
  `test/phoenix_kit/migration_test.exs:54` (`describe "Runner.runner_opts/1
  (prefix forwarding)"`) cover `nil` → `[]`, `"auth"` → `[prefix:
  "auth"]`, `"tenant_42"` → `[prefix: "tenant_42"]`. A future
  "simplification" of `runner_opts/1` to always return `[]` would
  fail CI.~~
- ~~**NITPICK: `@spec ensure_current/2 :: :ok` doesn't surface the
  raise-on-failure contract.** Added `## Return contract` section to
  the moduledoc (`migration.ex:231`) noting "Failures (advisory-lock
  contention, migration crashes, connection errors) propagate as
  raises from `Ecto.Migrator.up/4`; `ensure_current/2` does not wrap
  them in `{:error, _}`."~~
- ~~**NITPICK: PR body framing pinned the blame on a pattern core
  itself wasn't using.** Cosmetic — the bug analysis was correct,
  just the surface area was broader than the description implied.
  Both list-of-tuples and path forms exhibited the staleness bug.
  No code change needed.~~
- ~~**NITPICK: `lib/phoenix_kit/migrations/postgres.ex` doc-block
  ordering.** Acknowledged as continuing a pre-existing convention
  (V77 was already out of order). Out of scope for this PR.~~
- ~~**NITPICK: `schema_migrations` row accumulates per `mix test`
  invocation.** Acknowledged in the PR body — cosmetic noise
  acceptable for the test-DB use case (~250 rows/year on a
  developer machine, ~292 years of bigint headroom).~~

Plus `mix.exs` `@version` already at `1.7.105` per the post-merge
follow-up.

## Skipped

None.

## Files touched

None in this triage — every actionable item was addressed in the
reviewer's own post-merge follow-up commit before this triage ran.

## Verification

OAuth test suite passes (21 / 21) on a touch-up unrelated to this PR.
Migration suite continues to apply V1 → V111 cleanly via the
`ensure_current/2` helper this PR introduced (verified via the
catalogue's `mix test` boot — `Applying PhoenixKit V110→V111` log line
confirms the helper picks up newly-shipped Vxxx migrations).

## Open

None.
