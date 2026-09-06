# PR #786 — Per-instant timezone helpers, a deprecation, and V185: permanent activities carry the settings history

**Author:** Max Don (`mdon`) · **Merged:** 2026-09-06 (`1e1d1088`)
**Scope:** 16 files, +1067/−72 · `TimeZone`, `Utils.Date`, `Activity`, `Settings`, V185
**Reviewed:** 2026-09-06, post-merge, on `main` at `1e1d1088`

Careful, well-argued work — the moduledocs explain *why* rather than restating
the code, and the risky claims turned out to be true when tested rather than
taken on trust. One real defect found and fixed.

---

## BUG - MEDIUM — batch settings writes take row locks in map iteration order

`settings.ex` · `add_batch_operations/4` **(fixed in this pass)**

`with_history/3` reads the row it is about to change under `lock("FOR UPDATE")`
so two racing writers cannot record the same "before". Correct on its own. But
the batch path takes one such lock **per key**, in the order
`Enum.reduce(settings_map, ...)` walks the map — and Erlang map iteration is not
a stable total order across maps:

- **≤ 32 keys** — a flatmap, iterated in *term order*.
- **> 32 keys** — a hashmap, iterated in *hash order*.

The same two keys come out reversed between the two. Demonstrated:

```
small map (2 keys):  ["aws_region", "site_url"]
large map (42 keys): ["site_url", "aws_region"]
>>> OPPOSITE relative order <<<
```

So two concurrent `update_settings_batch/2` calls whose key sets overlap — one
under 32 keys, one over — acquire the shared keys in opposite orders and
deadlock. Reachable: the admin settings pages each save a different subset of
keys, and a large page can clear 32 fields while a module writes two.

This is the same failure class as the role-row `FOR UPDATE` deadlocks fixed on
2026-08-12, arriving by a different route: there the problem was the lock mode,
here it is the lock *order*.

**Fix:** sort by key before the reduce, so every batch acquires in the same
order whatever its size. One line, plus a comment recording the flatmap/hashmap
hazard so the sort is not read as decorative and removed.

**Test:** `history_test.exs` → "a batch larger than a flatmap still records
every key" — 40 keys, which is the only thing in the suite that exercises the
hashmap branch at all. Note what it does *not* do: lock acquisition order is not
observable from outside a transaction, so the test pins the branch and the
recording, not the ordering itself. The comment carries that.

---

## Verified, not taken on trust

Each of these was a load-bearing claim in the PR description; each holds.

**`inserted_at` `timestamp(0)` → `timestamp` rewrites no rows.** The operational
risk in the whole migration — a rewrite means an exclusive lock over the full
activities table. Tested on a 1000-row table: `relfilenode` unchanged before and
after, so no rewrite and no scan. Claim correct.

**The pruner actually honours `permanent`.** `activity.ex:315` —
`where: e.inserted_at < ^cutoff and not e.permanent`. Without this the column
would be inert decoration.

**And `permanent` cannot be NULL.** `boolean NOT NULL DEFAULT false`, so existing
rows are backfilled to `false` by PostgreSQL. Worth stating because the pruner
predicate is `not e.permanent`: had the column been nullable, `not NULL` is NULL,
every pre-migration row would have stopped matching, and **the pruner would have
silently stopped pruning anything that predates V185.**

**`FOR UPDATE` on `phoenix_kit_settings` is not the role-deadlock class.**
Nothing FK-references that table, so no concurrent inserter takes `FOR KEY SHARE`
against it and `FOR NO KEY UPDATE` buys nothing here.

**The schema followed the migration.** `Entry`'s `timestamps` moved
`:utc_datetime` → `:utc_datetime_usec`. Had it not, Ecto would have truncated
every insert to the second and the microsecond ordering — the entire reason for
the column change — would have been defeated at the write.

**History does not publish from inside the transaction.** `record/3` inserts the
entry directly rather than through `Activity.log/1`, and `publish/1` runs after
commit, so subscribers never hear of a change that then rolls back. The comment
says so and the code matches.

**Restricted keys withhold both values**, on both sides of the change, and
`value_at/2` answers `nil` for them at every instant — including for periods when
the key *was* restricted and later stopped being. The natural bug here would be
`value_at/2` becoming the way around the withholding; it isn't.

---

## NITPICK — `for_viewer/1` matches any map

`for_viewer(%{} = user)` accepts any map, which is deliberate and documented
(module pages and test scopes carry partial users). Worth knowing that it also
silently accepts an unrelated struct — `for_viewer(some_setting)` returns the
site zone rather than failing. Given the stated goal of being *total*, that is
the right trade; noting it so nobody "fixes" it into a `%User{}` match and breaks
the partial-map callers the function exists for.

---

## Not changed

`same_group?/2` treating `Asia/Jerusalem` and `Europe/Athens` as one zone is
called out in the PR description and left alone. Correct call — Israel's switch
is two days off the EU's, below the group derivation's sampling step, and fixing
it means changing how groups are derived rather than patching a pair.
