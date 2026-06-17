# Migration Squash Verification Harness

MAINTAINER-ONLY tooling for the PhoenixKit V1→V110 migration squash.

**All files here are excluded from the hex package** (`mix.exs` `files:` whitelist
is `~w(lib priv mix.exs README.md LICENSE CHANGELOG.md)` — `dev_docs` is not
listed).

---

## Background

PhoenixKit ships Oban-style versioned migrations: `@initial_version 1`,
`@current_version 135`, each `lib/phoenix_kit/migrations/postgres/vNN.ex` a
self-contained Ecto.Migration module. The squash:

- Introduces a new **baseline module `v110.ex`** that captures the full schema
  produced by running V01..V110 in one shot.
- Sets `@initial_version` to `110` (the **floor**).
- Fresh installs run V110 then V111..V135. Existing installs already past V110
  skip straight to V111..V135.
- This corresponds to version bump **2.0.0** (major: intentional fork divergence
  from upstream BeamLabEU/phoenix_kit; the squash will not merge cleanly into
  upstream's migration lineage).

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `PGHOST` | yes | Direct Postgres host (bypass pgbouncer). Example: `172.18.0.6` |
| `PGPORT` | yes | Direct Postgres port. Example: `5432` |
| `PGUSER` | yes | Database user with CREATEDB / CREATEROLE on target host |
| `PGPASSWORD` or `PGPASSFILE` | yes | Credentials |
| `PGDATABASE` | Mode A | Target database for clean-database mode |
| `PK_SQUASH_SCHEMA` | Mode B | Schema name for throwaway-schema mode (default: `pk_squash_test`) |
| `MIX_ENV` | yes | Must be `test` (uses `PhoenixKit.Test.Repo` with env-overridden config) |

---

## Two DB Modes

### Mode A — Clean Database

A database whose `public` schema is completely empty (no extensions installed by
other users, no stray tables). The harness runs the full migration range into the
`public` prefix, then `pg_dump -n public`.

```
PGHOST=172.18.0.6 PGPORT=5432 PGUSER=postgres PGPASSWORD=xxx \
PGDATABASE=pk_squash_fresh \
MIX_ENV=test mix run dev_docs/squash/verify.exs --mode a
```

**Safety**: the harness does NOT create or drop the database itself. You must
pre-create `pk_squash_fresh` with an empty public schema (e.g.
`createdb pk_squash_fresh`). After the run the harness drops objects it created
within `public` but NEVER drops the extensions (citext, pgcrypto, pg_trgm) or
`uuid_generate_v7()` — those live in `public` and are shared objects.

### Mode B — Throwaway Schema

Uses a non-public schema so you can run against any existing database. The
harness creates the schema, runs migrations with `create_schema: false`, dumps
`-n <schema>`, and then `DROP SCHEMA <schema> CASCADE`.

```
PGHOST=172.18.0.6 PGPORT=5432 PGUSER=postgres PGPASSWORD=xxx \
PGDATABASE=your_existing_db \
PK_SQUASH_SCHEMA=pk_squash_test \
MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b
```

**Safety**: `uuid_generate_v7()` and the three extensions live in `public` and
are NOT inside the throwaway schema. `DROP SCHEMA CASCADE` only removes the
objects inside the schema — extensions and public functions are unaffected.
Extensions must exist before running migrations with this mode (create them once:
`CREATE EXTENSION IF NOT EXISTS citext; pgcrypto; pg_trgm;`).

---

## Scripts

### `repo_helper.ex`

Shared module that starts a Postgrex/Ecto repo wired from env vars at runtime.
Loaded by the `.exs` scripts via `Code.require_file/2`.

### `verify.exs`

Orchestrates the four scenarios:

1. **Fresh equivalence**: Run OLD V01..V135 into schema A; run NEW V110..V135
   into schema B. Normalize both dumps and assert byte-identical.
2. **Existing install**: Migrate OLD to V110 in schema A; apply NEW up() (must
   only run V111..V135); result must be identical to reference dump at V135.
3. **Below-floor guard**: If an install is at V109, the new code must refuse and
   print a clear error (not silently run the squash-baseline on top of existing
   objects).
4. **Down**: After scenario 1, call down() on the NEW code and verify all tables
   are gone (or at target version if partial rollback).

Run:
```bash
MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b
```

### `generate_baseline.exs`

Runs OLD V01..V110 into a target schema, pg_dump the result, and transforms the
dump into `lib/phoenix_kit/migrations/postgres/v110.ex` (the baseline module).

**REQUIRES A LIVE DB** — the generate step cannot run without Postgres.

```bash
MIX_ENV=test mix run dev_docs/squash/generate_baseline.exs
```

After running, review the generated file carefully before committing. The
generator emits TODO markers where manual review is needed.

---

## Floor and Version Context

- **Floor**: V110 — the lowest version deployed in production at squash time.
  hydroforce_prod version must be confirmed before finalising this floor.
  If hydroforce_prod is below V110, lower the floor accordingly and re-run.
- **Package version**: `2.0.0` (major bump signals intentional fork divergence).
- **Baseline self-stamp**: `v110.ex`'s `up/1` ends with
  `COMMENT ON TABLE {prefix}.phoenix_kit IS '110'` — so a single-step
  fresh install via the new baseline sets the version correctly without the
  multi-step orchestrator overriding it.

---

## Safety Rules

1. **NEVER drop public extensions or functions.** `citext`, `pgcrypto`,
   `pg_trgm`, and `uuid_generate_v7()` live in `public` and may be used by
   other schemas / applications sharing the same Postgres cluster.
2. **NEVER run against a production database.** All scenarios use isolated
   test databases or throwaway schemas.
3. **NEVER modify `lib/` migration files directly.** The generate script
   writes to `lib/phoenix_kit/migrations/postgres/v110.ex` — that is the only
   `lib/` write, and it only happens when you explicitly run
   `generate_baseline.exs`.
4. The harness is **DB-requiring** — it cannot be executed without a live
   Postgres connection. Steps marked `[DB]` fail gracefully without one.
