# PR #628 — Fix prefixed migrations: schema-qualified index names + cross-schema existence checks

**Author:** Max Don (`mdon`) · **Base:** `main` · **Merge:** `dc4f7c71` · **Reviewer:** Claude (Sonnet 5)
**Scope:** +153 / −21 over 11 files — two independent bug classes in the `--prefix` (named-schema) install path, plus a full-chain regression test.

Reviewed post-merge against `main`. This is a **correct, tightly-scoped fix** for real bugs that only manifest on prefixed (non-`public`-schema) installs — the default `public` path never exercised either broken branch, which is presumably how both bugs went unnoticed until now.

---

## BUG — CRITICAL / HIGH / MEDIUM

None found in the PR's own changes. Two pre-existing bugs are fixed correctly:

- **CREATE INDEX schema-qualification** (`v56.ex`, `v57.ex`, `v95.ex`, `uuid_fk_columns.ex`): the old code built `idx = "#{prefix}.#{index_name}"` and passed it to `CREATE INDEX IF NOT EXISTS #{idx} ON #{table}(...)`. Postgres's `CREATE INDEX` grammar takes a bare `name` for the index — it cannot be schema-qualified (the index always lands in its table's schema). For any prefixed install, this raised a syntax error and broke the migration chain outright. The fix drops the qualification and lets the *table* reference (`table_name`) carry the schema, which is correct. I checked `v56.ex`'s companion `drop_uuid_unique_indexes/2` (line 478), which still builds a dot-qualified name for `DROP INDEX` — that's intentionally untouched and correct, since `DROP INDEX` (unlike `CREATE INDEX`) explicitly accepts a schema-qualified name per the Postgres docs.
- **Cross-schema false-positive existence checks** (`v102.ex`, `v113.ex`, `v115.ex`, `v118.ex`, `v119.ex`, `v35.ex`, `v95.ex`): `pg_constraint` lookups filtered only on `conname`, and one `information_schema.columns` lookup filtered only on `table_name`. Since prefixed installs reuse identical table/constraint names across schemas, a same-named constraint or column already present in a *different* schema's table would make `NOT EXISTS` evaluate true and silently skip adding it in the current schema. Fixed by anchoring to `conrelid = '<prefix>.<table>'::regclass` (constraints) or `table_schema = '<escaped_prefix>'` (columns). Confirmed the `::regclass` casts are always safe here — every guarded table is created earlier in the same `up/1`, so the cast never hits a missing relation.
- **Completeness check:** grepped every `pg_constraint` and `information_schema.columns` existence check across all 140+ migration files — no remaining instance of either pattern lacks a schema/relation guard. Also checked the broader `pg_indexes` / `information_schema.tables` / `information_schema.table_constraints` checks elsewhere in the codebase (not touched by this PR): spot-checked several and they already scope on `schemaname`/`table_schema`, so this PR's target files were genuinely the outliers, not a sample of a larger unfixed class.

## Testing

`test/integration/prefix_migration_test.exs` runs the **full 142-version migration chain** into a scratch schema (`pk_prefix_migration_test`), then asserts:
- the version marker lands on the current version (chain didn't silently stop partway),
- the five indexes built at the once-broken `CREATE INDEX` call sites exist in the prefixed schema by name,
- 500+ total indexes exist in the schema (a low count would mean part of the chain silently skipped without erroring).

This is real regression coverage, not a narrow unit test — it's the only test in the suite that exercises the `--prefix` path end-to-end, and it would have caught both bug classes before this PR. The moduledoc's explanation of why it needs `Sandbox.mode(Repo, :auto)` (Ecto.Migrator's own runner process, V08's backfill query bypassing `put_dynamic_repo/1`) is accurate and matches `PhoenixKit.MigrationTest`'s documented sandbox constraints.

## Gate

`mix precommit` (compile `--warnings-as-errors` → `credo --strict` → `dialyzer`): **green**, no changes needed. `mix format` clean. PostgreSQL isn't available in this environment, so the new integration test wasn't executed here — nothing in the diff or the gate suggests it needs to be.
