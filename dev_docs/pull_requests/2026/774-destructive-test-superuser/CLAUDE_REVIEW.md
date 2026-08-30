# PR #774 — Make the destructive doctor test run without superuser

**Author:** timujinne (`fix/769-destructive-test-superuser`) · **Merged:** 2026-08-30 · **Reviewed:** 2026-08-30

## Verdict

**The goal is right and achieved — but the mechanism chosen to reach it
silently retargeted the test at a different branch of the function under
test.** Fixed here, keeping the superuser-free property.

The diagnosis is correct and reproduced: `ALTER TABLE ... DISABLE TRIGGER ALL`
needs superuser because Postgres reserves the FK's internal
`RI_ConstraintTrigger`, so the test could not pass under the unprivileged-role
model `config/test.exs` documents.

---

### BUG — MEDIUM · `NOT VALID` moves the orphan into the clause that was never at risk

`check_orphaned_fk_refs/1` reads `pg_constraint.convalidated` per FK
(`fk_validation_state/5`, `phoenix_kit.doctor.ex:1453`) and hands the result to
`classify_fk_check/6`, which branches on it:

| validation state | orphans | clause | reported as |
|---|---|---|---|
| `:validated` | `> 0` | `phoenix_kit.doctor.ex:1243` | `:existing_orphan` |
| `{:not_valid, _}` | `> 0` | `phoenix_kit.doctor.ex:1224` | `:validate` |
| `:absent` | `> 0` | `phoenix_kit.doctor.ex:1230` | `:create` |

The old `DISABLE TRIGGER ALL` left the constraint **validated**, so the planted
orphan exercised the `:validated` clause — the one whose own comment calls it
*"the single most common validation shape ... exactly the one this function
couldn't report on"* before the widening fix. Re-adding the constraint
`NOT VALID` moves the same row to the `:validate` clause, which predates that
fix and was never the branch in danger.

The assertion could not tell the difference:

```elixir
assert {:fail, message} = DoctorTask.check_orphaned_fk_refs("public")
assert message =~ "phoenix_kit_user_oauth_providers.user_uuid"
```

All three clauses put that same `table.column` in the message
(`fk_orphan_lines/1`, `phoenix_kit.doctor.ex:1365`). So the test stayed green
while the branch it exists to hold went uncovered end-to-end — the
`:validated` clause could have been deleted outright and this file would not
have noticed.

**Fix — `ALTER CONSTRAINT ... DEFERRABLE INITIALLY DEFERRED`.** Altering an
existing FK's deferrability is plain table-owner DDL, `convalidated` stays
`true`, and the deferred referential check fires only at `COMMIT` — which never
arrives, because `DataCase` rolls this test's sandbox transaction back. The
orphan is real and unmatched for the whole life of the check, sitting behind a
constraint Postgres still reports as fully validated: the exact production
shape (`:existing_orphan`) the test was written for.

Verified live on **PostgreSQL 18.4** as role `beamlab_test` (no `CREATEDB`, no
`SUPERUSER`, owning the tables it migrated):

```
 conname | convalidated | condeferrable | condeferred      orphans
---------+--------------+---------------+-------------    ---------
 fk_zz   | t            | t             | t                      1
```

Two assertions added so the branch cannot drift again: a direct
`convalidated` probe, and a match on the `:existing_orphan` wording
(`"constraint IS validated but orphans exist anyway"`) rather than the
table.column alone.

### NITPICK · stale moduledoc

The moduledoc still listed `ALTER TABLE ... DISABLE/ENABLE TRIGGER` among the
DDL this module runs; no test had done that since this PR. Corrected to
`ALTER TABLE ... ALTER CONSTRAINT`.

### Verified — two things the PR got right that were worth checking

- **No schema drift.** The re-added definition
  (`REFERENCES phoenix_kit_users(uuid) ON DELETE CASCADE`) matched V135's
  original byte-for-byte (`v135.ex:7348`), so nothing was quietly reshaped.
- **No `NOT VALID` contamination.** `PhoenixKit.DataCase` wraps each test in a
  sandbox transaction and Postgres DDL is transactional, so the dropped/re-added
  constraint never outlived the test. Worth confirming, because a leaked
  `NOT VALID` on `fk_user_oauth_providers_user_uuid` would have changed the
  result of every other doctor test in the shared database.

---

## Changes made

| File | Change |
|---|---|
| `test/mix/tasks/phoenix_kit_doctor_orphaned_fk_destructive_test.exs` | Plant the orphan behind a still-validated constraint via deferred RI; assert `convalidated` and the `:existing_orphan` wording; moduledoc corrected |

## Validation

`PGDATABASE=beamlab_test mix test test/mix/tasks/phoenix_kit_doctor_orphaned_fk_destructive_test.exs`
→ **4 tests, 0 failures**, as an unprivileged role — the property PR #774 set out to get.
