# PR #796 Review — V189: remove the dead `billing_default_currency` setting

**Author:** timujinne (Tymofii Shapovalov)
**Merged:** 2026-09-08, by fotkin (merge commit `3e2766da`)
**Files:** `lib/phoenix_kit/migrations/postgres/v189.ex` (new),
`lib/phoenix_kit/migrations/postgres.ex`, `lib/phoenix_kit/migrations/expected_schema.ex`,
`test/phoenix_kit/migrations/v189_test.exs` (new)

## Summary

Adds migration V189, a pure-data migration that deletes the `billing_default_currency`
row seeded into `phoenix_kit_settings` by V135. Nothing in `phoenix_kit`,
`phoenix_kit_billing`, or `phoenix_kit_ecommerce` reads that key — the actual base
currency is resolved from the `is_default = true` row of `phoenix_kit_currencies` via
`PhoenixKitBilling.get_default_currency/0`. Worse than unread, the seeded value
(`'EUR'`) contradicts that row's real default (`USD`) on live hosts. Follows V184's
`shop_currency` removal shape exactly: `DELETE` on `up`, `INSERT ... ON CONFLICT
("key") DO NOTHING` (V135's original statement, verbatim) on `down`.

## Verification performed

- Grepped this repo for `billing_default_currency` outside the migration files
  themselves — zero hits. Confirms the "nothing reads it" claim independently
  rather than trusting the PR description.
- Diffed `down_statements/1` against V135's original seed statement
  (`lib/phoenix_kit/migrations/postgres/v135.ex:10676-10680`) — identical
  key/module/value/value_json and `ON CONFLICT` clause.
- Ran `test/phoenix_kit/migrations/v189_test.exs` against the real Postgres
  instance (`beamlab_test`) — all 4 tests pass (up deletes, up is a no-op on an
  absent row, down restores, down never clobbers a hand-recreated value).
- Ran `test/integration/prefix_migration_test.exs` (full chain V135→V189 into a
  scratch schema) — passes, confirming no later version's SQL breaks on this
  one's output.
- Confirmed `@current_version` (188→189) and `chain_hash` in
  `expected_schema.ex` were both bumped, and the `ExpectedSchema` moduledoc
  comment for V189 correctly states "declares NO object" (a pure data
  migration needs no manifest regeneration, same class as V182/V184).
- Confirmed the migration doesn't touch V135's text itself — correctly reasoned
  in the moduledoc: V135's `execute/1` already ran on every existing host, so
  editing it would be a no-op for them while corrupting the hashed baseline for
  `mix phoenix_kit.release_check`.

## Findings

None. The migration is correct, matches the established V184 precedent
structure exactly, is independently verified (not just self-reported), and has
real-database test coverage for all four up/down/idempotency/preservation
cases.

## Verdict

**Approved, no changes required.**
