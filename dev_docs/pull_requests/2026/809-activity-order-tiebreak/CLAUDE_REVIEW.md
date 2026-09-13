# PR #809 — Fix Activity.list/1 and recent/1 losing order on tied timestamps

**Author:** timujinne (`core-activity-order-tiebreak`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Correct, minimal, well tested. No changes needed.

## Summary of the PR

`Activity.list/1` and `Activity.recent/1` now sort by `desc: inserted_at, desc: uuid`,
so rows with the same `inserted_at` come back in a stable order. Two tests
cover it: an integration test that inserts rows with identical timestamps, and
a DB-free test that compiles the query to SQL and checks the `ORDER BY`.

## Verified

- **No other timestamp ordering in the module.** The remaining `order_by`s in
  `activity.ex` sort the distinct filter-option lists (mode, module, action,
  resource_type).
- **Planner cost.** `ORDER BY inserted_at DESC, uuid DESC LIMIT n` can still use
  the `inserted_at` index, with an incremental sort on PG13+. No new index is
  needed.
- **The swapped repo in the SQL test cannot leak into other tests.** The module
  is `async: false`, and ExUnit runs sync modules only after all async ones.

## NITPICK — "truly-last" overclaims inside a single millisecond

UUIDv7 only orders by creation time down to the millisecond. Within one
millisecond, the order depends on the generator's random/counter bits. The
tiebreak is **deterministic**, which is what the bug needed, but the test's
"truly-last entry" wording promises more than that. The tests use distinct
milliseconds, so they are correct as written.
