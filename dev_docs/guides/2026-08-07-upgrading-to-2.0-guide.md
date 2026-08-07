# Upgrading to PhoenixKit 2.0 — the squashed migration chain

2.0 consolidates the versioned migration chain. `V01`..`V134` no longer exist as
individual modules; `V135` is a generated **baseline** that produces their
cumulative schema in one step, and `V136`..`V163` remain as ordinary deltas.
Nothing about your data changes because of the consolidation itself — but this
release also carries a **repair** for a long-standing defect, and that part does
change behavior. Read the whole page before upgrading a production database.

## In one paragraph

If your database is already at `V135` or above, the baseline never runs: the
version comment gates it exactly as it gates any other version, so upgrading is
an ordinary delta run. If your database is **below** `V135`, 2.0 refuses to
migrate it and tells you so — you must first upgrade on the last `1.7.x`
release (the **bridge**), which still carries the full chain, and only then move
the pin to `~> 2.0`. Separately, this release repairs schema damage that a
migration-ordering defect left on essentially every install created by
`mix phoenix_kit.install`; the repair adds constraints, and on a large database
that costs locks and a validation scan.

## Step by step

1. **Land on the bridge first.** On your current `1.7.x` pin, run
   `mix phoenix_kit.update` and confirm the version comment reaches `V135` or
   higher:

   ```sql
   SELECT obj_description('public.phoenix_kit'::regclass, 'pg_class');
   ```

   Use your schema name instead of `public` for a prefixed install.

2. **Confirm it on EVERY environment, not just one.** Development, staging and
   production each have their own database. A dependency bump travels with your
   code; the migration does not. Bumping the pin while production is still below
   the floor turns the deploy's migrate step into a `BelowFloorError` — loud and
   safe, but a failed deploy.

3. **Move the pin** to `{:phoenix_kit, "~> 2.0"}` and run
   `mix phoenix_kit.update` as usual.

4. **Run the repair in report mode first**, then for real:

   ```bash
   mix phoenix_kit.repair --dry-run      # reports only, changes nothing
   mix phoenix_kit.repair                # applies additive fixes
   ```

   `--dry-run` is opt-in: the bare command **writes**. Read the section below
   before running it against production.

## What the repair changes, and why it exists

`V56` and `V57` built the UUID foreign-key layer, and their existence checks
queried the database immediately while the DDL they depended on was still
queued. Any chain run that crossed those two versions inside one migrator
invocation — which is every install created by the installer, since it emits a
single unpinned wrapper for the whole chain — therefore silently skipped work:

- **~46 `*_uuid` columns** were left nullable instead of `NOT NULL`.
- **~67 of the 70 declared foreign keys** were never created at all.
- `phoenix_kit_comments.fk_comments_user_uuid` was missing, so `V72` added it
  later with a guessed `ON DELETE CASCADE`.

Incrementally-upgraded installs that crossed `V56`/`V57` in separate narrow
wrappers are unaffected. To see where you stand:

```sql
-- expect ~70 for a healthy install; a much lower number means the defect hit you
SELECT count(*) FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public' AND c.contype = 'f' AND c.conname LIKE 'fk\_%';
```

Three consequences you must plan for:

- **Comment deletion semantics change.** The comments foreign key is corrected
  from `ON DELETE CASCADE` to `ON DELETE SET NULL`, matching what `V56`/`V57`
  always declared and the convention of every sibling table (a like or a
  dislike is meaningless without its user and still cascades; a comment's
  content outlives its author and is blanked instead). If your application
  relied on deleting a user to delete their comments, that no longer happens —
  the rows survive with `user_uuid = NULL`. The comments module already types
  the field as nullable, so nothing raises.
- **Constraint creation costs locks.** Each missing foreign key is added
  `NOT VALID` first — a metadata-only change — and then validated. Validation
  takes `SHARE UPDATE EXCLUSIVE`, which does not block reads or writes but does
  scan the table. Across dozens of tables on a large database this is not
  instant; run it in a maintenance window, and never through PgBouncer in
  transaction-pooling mode (use a direct connection).
- **Nothing is forced onto live data.** `NOT NULL` is applied only where the
  column currently has zero `NULL` rows; otherwise the repair warns with the
  table, column and row count and leaves the column alone. Validation failures
  leave the constraint `NOT VALID` (new writes are still checked) and report the
  orphan count. The repair never deletes, never rewrites, and never backfills a
  live column.

## Named-schema (prefixed) installs

Two migrations name objects by embedding the schema prefix into the object name,
and the longest such name is 42 characters. With PostgreSQL's 63-byte identifier
limit that leaves **20 characters** for the prefix. A longer prefix is silently
truncated by PostgreSQL, after which the expected and actual index names differ
forever and the repair reports objects that are really there. 2.0 rejects a
prefix longer than 20 bytes at the entry points rather than letting you discover
this later.

## Rolling back

- `mix ecto.rollback` on a wrapper that targets a version **below** the floor
  clamps to the floor and says so; the version comment stays at the floor. Below
  the floor there is nothing to roll back to in this release — that is what the
  bridge is for.
- A full teardown (`PhoenixKit.Migrations.down(version: 0)`) still removes
  everything, baseline included. Shared extensions (`citext`, `pgcrypto`,
  `pg_trgm`) are deliberately left in place.
- The repair itself is not undone by a rollback: it restamps the version comment
  and leaves the constraints it created. Removing them is a manual decision.

## Known cosmetic divergence

A database built by the old chain in one shot retains `phoenix_kit_users.preferred_locale`
and its index — `V28` added the column and `V30`'s removal check ran before the
addition was flushed, so single-run installs kept it. The baseline does not
create it, and the repair treats it as optional in either direction. It is
unused by application code; leaving it is harmless.

## If something looks wrong

`mix phoenix_kit.doctor` reports version state, pool and PgBouncer topology, and
runs the repair's verify pass read-only. `mix phoenix_kit.repair --dry-run --json`
gives the machine-readable finding list. A finding tagged as a rendering-only
difference on an unverified PostgreSQL major is informational: two majors can
render the same expression differently, which is not drift.
