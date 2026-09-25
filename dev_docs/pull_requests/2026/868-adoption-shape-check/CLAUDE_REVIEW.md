# PR #868 — Add PhoenixKit.Migrations.Adoption for module table adoption shape checks

- **Author:** Tymofii Shapovalov (@timujinne)
- **Merged:** 2026-09-25 (`ce8a44159`), refs #862
- **Reviewer:** Claude (post-merge)
- **Files:** `lib/phoenix_kit/migrations/adoption.ex` (new), `test/phoenix_kit/migrations/adoption_test.exs` (new), `dev_docs/guides/2026-09-05-module-table-extraction-guide.md`

## Verdict

Sound, and adds no new comparison logic. The module wraps `Repair.Probe`/`Repair.Differ`
without changing them. I checked the claims that matter against the source:

- `Differ.compare(:table | :extension | :seed, _, _)` always returns `:match`,
  so the class/kind cross-check is needed and not paranoia.
- `Differ.reason_not_null/3` skips `%{not_null: true, default: nil}`, and
  `not_null_gap_reason/3` fills that gap correctly for adoption.
- `@required_catalog_keys` matches what each `Probe.lookup/2` clause pattern-matches
  on. `:index` needs only `:name`, as the PR says.
- `:seed` is rejected on purpose, because `Probe.lookup/2` returns `nil` for a
  string check.
- `raw_table_comment/3` reads `pg_class`/`pg_namespace` with the schema anchor,
  following the prefix-safe rules. It doesn't touch `information_schema`, so a
  low-privilege role doesn't turn a conflict into `:ok`.

Fixed after the merge: two findings. One is left on record.

## Findings

### BUG - MEDIUM — search_path save/restore could land on different pooled connections — FIXED

`with_preserved_search_path/2` ran `SHOW search_path`, `Probe.snapshot/2` and the
restoring `set_config` as three separate `repo.query!` calls. Inside a migration
transaction they share one connection. Called outside a transaction (a mix
task, IEx, a module's own preflight), each call could check out a *different*
pooled connection. The saved value was then written at session level onto an
unrelated connection, and the connection `Probe` had `RESET` was never
restored. That is the leak the helper was written to prevent.

**Fix:** the helper now runs everything inside one `repo.checkout/1`. Checkouts
nest, so `Probe.snapshot/2`'s own checkout reuses the connection, and inside a
migration nothing changes. There's no regression test: the Ecto sandbox gives
every query in a test one connection, so the pooled case can't be reproduced
there.

### BUG - MEDIUM (test portability) — the privilege test fails on a DB role without CREATEROLE — FIXED

The follow-up commit made the low-privilege test "portable" by running
`CREATE ROLE` inline. On a role without CREATEROLE/superuser, such as this
workspace's `beamlab_test` or any managed/shared Postgres, it fails with
`42501 permission denied to create role`. That makes a clean tree look like it
has a regression.

**Fix:** `test_helper.exs` now asks `pg_roles` whether `current_user` has
`rolcreaterole OR rolsuper`. It uses an unboxed run, before any test checks
out a connection. If the role has neither, tests tagged `:requires_createrole`
are excluded and a banner says so. The privilege test carries that tag. On
CI's `postgres:16` superuser it still runs; here it shows up as `1 excluded`,
not as a failure.

### NITPICK — restore is session-level even if the caller's search_path was `SET LOCAL` — NOT FIXED

`set_config('search_path', saved, false)` restores at session level. If a
caller had set `SET LOCAL search_path` inside its migration transaction, the
local value outlives the transaction on that connection. `Probe`'s own `RESET`
already has the same session-level effect. Handling it properly means tracking
both values (session and local), which is more machinery than an edge case no
current caller hits deserves. Left on record.

### NITPICK — documentation volume

The moduledoc is about 460 lines for about 170 lines of code. It's accurate,
and I checked the parts that matter, but a lot of it records the PR's own
review history ("was tried and dropped", "live-reproduced") rather than the
contract. It could be tightened in a later pass. I didn't cut it, because the
guide links into specific sections.

## Also

- Added the `### Added` entry to `CHANGELOG.md` → `## Unreleased`. The PR
  didn't add one.
- `mix test test/phoenix_kit/migrations/adoption_test.exs` (real DB): 38 tests,
  0 failures, 1 excluded (`:requires_createrole`).
