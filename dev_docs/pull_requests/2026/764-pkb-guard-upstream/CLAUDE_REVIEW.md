# PR #764 — Add a repository-level guard against tests pointed at a live database

**Author:** timujinne (`pkb-guard-upstream`) · **Merged:** 2026-08-28 · **Reviewed:** 2026-08-29

## Verdict

Correct and well-scoped. No findings.

## What the PR does

`PhoenixKit.Test.LiveDatabaseGuard.check!/1`, called from `test_helper.exs`
before anything touches the database, raises if the resolved test database
name looks like a non-test environment: a `_dev` / `_development` / `_prod` /
`_production` / `_staging` suffix (case-insensitive), or an exact name listed
in `PHOENIX_KIT_TEST_DB_DENYLIST`.

## Verification

- **It does not break the `PGDATABASE` escape hatch,** which is the point of
  the design. `config/test.exs` honors `PGDATABASE` precisely so the suite can
  run on a role without `CREATEDB`; a scratch name (`beamlab_test`,
  `ci_runner_42`, a UUID throwaway) passes untouched. A rule requiring a
  `_test` suffix would have broken exactly that case, and the moduledoc says
  so explicitly.
- **The guard runs before the `psql -lqt` existence probe** and before
  `ensure_current/2`, so a refused name never reaches a connection — the
  ordering the fix depends on.
- **It reads the already-resolved name** from
  `Application.get_env(:phoenix_kit, PhoenixKit.Test.Repo)[:database]`, not
  `PGDATABASE` itself, so it cannot drift from `config/test.exs`'s own
  fallback logic. Correct call.
- `downcased in extra_denylist()` works on the returned `MapSet` — outside a
  guard, `in/2` is `Enum.member?/2`, and `MapSet` implements `Enumerable`.
- The residual risk (a live database named with no environment signal, e.g.
  bare `acme`) is stated in the moduledoc rather than hidden, with the
  denylist as the opt-in remedy.
- The moduledoc's rejection of the `SchemaOwnerGuard` marker-comment approach
  is sound: a never-stamped live dev database reads as `:ok` under that scheme,
  which is the exact case this guard exists to catch.

## Note

`database == "" -> :ok` passes an empty name through. Harmless — `config/test.exs`
always resolves to a non-empty name, and an empty one fails at connect anyway.
