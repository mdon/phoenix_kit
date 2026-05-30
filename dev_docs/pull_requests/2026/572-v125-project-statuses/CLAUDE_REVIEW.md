# PR #572 — V125: project workflow statuses table + columns + external_id

**Reviewer:** Claude (Opus 4.8)
**State:** MERGED into `dev` (2026-05-30). Review is post-merge; findings are follow-up candidates.
**Scope:** 1 new migration (`V125`), migration-dispatch bump (124 → 125 + moduledoc), 1 schema-pin test file.

## Verdict

Solid, correctly-wired migration. Auto-dispatched via `Module.concat([__MODULE__, "V125"])` on the zero-padded version — no manual registration needed. Genuinely idempotent (`CREATE TABLE IF NOT EXISTS`, `DO $$ ... IF NOT EXISTS` column/constraint guards, guarded index creates) and the `down/0` reverses in clean order (drop indexes → drop FK → drop columns → drop table → reset marker to `124`).

The one thing worth verifying on a migration that FKs into another table — **does the FK target exist on every host at this version?** — checks out: `status_entity_uuid` references `phoenix_kit_entities(uuid)`, and `phoenix_kit_entities` is created unconditionally in **core** V17, with its `uuid` column + unique index `phoenix_kit_entities_uuid_idx` added unconditionally in **core** V40. So `REFERENCES phoenix_kit_entities(uuid)` is always a valid (unique-backed) FK target — no missing-table / non-unique-target failure on any host. The 11-test fresh-migrate run passing is consistent with this.

No CRITICAL/HIGH/MEDIUM findings. A couple of nitpicks only.

---

## Verified correct

- **FK delete rules match intent and tests.** `phoenix_kit_project_statuses.project_uuid` → `ON DELETE CASCADE` (`confdeltype = 'c'`); `phoenix_kit_projects.status_entity_uuid` → `ON DELETE SET NULL` (`'n'`). Both pinned by `fk_delete_rule/1` assertions. Cement rows die with the project; deleting a catalog entity degrades the project to the default, never cascades. Correct.
- **Slug stored on `current_status_slug` (not a row UUID).** The right call — the addressed table flips from live catalog rows (pre-start) to cemented local rows (post-start) at the cement boundary, so a row-UUID FK would be wrong by construction. The unique `(project_uuid, slug)` index makes the cemented side slug-addressable. Behaviorally pinned by the "enforces slug uniqueness within a project" test (second insert raises `Postgrex.Error`).
- **`source_entity_data_uuid` intentionally has no FK.** Documented: the catalog lives in the optional `phoenix_kit_entities` package and the snapshot must outlive its source row. Bare UUID is correct here.
- **Prefix safety.** Index and constraint names are unqualified, but Postgres scopes index/constraint names to the table's schema, so the unqualified names cannot collide across multi-prefix installs sharing one database. `information_schema` / `pg_indexes` guards are all keyed on `schemaname/table_schema = '#{schema}'`. Consistent with the existing V-migration style.
- **`down/0` doesn't explicitly drop the two `phoenix_kit_project_statuses` indexes** — fine, `DROP TABLE` cascades them.

---

## NITPICK — test could be `async: true`

`v125_test.exs` uses `use PhoenixKit.DataCase, async: false`. Every assertion is either a read against `information_schema`/`pg_catalog` or a sandbox-rolled-back insert — no global state is touched, so `async: true` would be safe and faster. Sibling V-tests (V106/V107/V112) set the same `async: false`, so this matches precedent; flag only.

## NITPICK — `schema_for/1` is an identity-ish passthrough

`defp schema_for("public"), do: "public"` / `defp schema_for(prefix), do: prefix` returns its argument in both clauses, existing only to mirror `prefix_str/1`'s two-clause shape. A one-liner `defp schema_for(prefix), do: prefix` would read the same. Harmless; keeps symmetry with the sibling helper. Flag only.

## Note (not a finding) — schema-pin tests assert state, not the migration's own `up/down`

As the test moduledoc states, `V125.up/down` can't run outside an `Ecto.Migrator` runner, so these tests pin the *post-V125 shape* produced by `ensure_current/2` at boot rather than exercising `up/0`/`down/0` directly, and the `down/0` round-trip was verified by an out-of-sandbox script. This is the established pattern for V-migration tests in this repo — calling it out only so the coverage boundary is on the record: a `down/0` regression would not be caught by CI, only by the manual round-trip.
