# PR #762 — Fix repair reporting two composite-key PRIMARY KEYs as missing

**Author:** timujinne (`i095-repair-manifest-kind`) · **Merged:** 2026-08-28 · **Reviewed:** 2026-08-29

## Verdict

Correct on both halves. One convention gap, fixed here.

## What the PR does

Two things, deliberately independent:

1. **Class-A fix (the manifest).** `phoenix_kit_shop_product_slugs_pkey` and
   `phoenix_kit_shop_category_slugs_pkey` were hand-authored alongside V171 as
   `kind: :index` / `class: :index` with an index-shaped `{171, ...}` revision.
   They are PRIMARY KEY constraints on a composite natural key `(lang, value)`.
   Rewritten to `id: "constraint:<table>.<name>"`, `kind`/`class: :constraint`,
   with a constraint-shaped revision.
2. **Class-B fix (the probe).** `@indexes_sql`'s `AND con.oid IS NULL` moved
   out of the `WHERE` into an Elixir-side partition, so `p`/`u`-backed rows
   land in a new `snapshot.constraint_backed_indexes` map instead of being
   dropped. `lookup/2`'s `kind: :index` clause falls back to it.

## Verification

- **The bug was real and permanent.** A `p`/`u`-backed index is never listed in
  `snapshot.indexes` by construction, and `lookup/2`'s `:index` clause only
  consulted that map — so both objects read `:missing` on every run, on every
  install, and repair could never make them stop.
- **The new revision shape matches what the probe actually produces.**
  `constraints/2` (`probe.ex:392`) builds
  `%{type, definition, columns, foreign_table, foreign_columns, on_delete,
  on_update}`; the new revisions carry exactly those, and `definition:
  "PRIMARY KEY (lang, value)"` is what `pg_get_constraintdef/1` returns. Byte-
  identical in shape to the pre-existing `constraint:phoenix_kit.phoenix_kit_pkey`
  entry (`expected_schema.ex:804`).
- **`Differ.compare(:constraint, %{type: "p"}, _)`** (`differ.ex:196`) compares
  `:columns` only — satisfied.
- **`create: nil` is genuinely inert.** `Executor.create_action/2` dispatches on
  `class` and rebuilds every `:constraint` from `shape` via
  `ShapeSql.constraint_create/5`, never reading `object.create`
  (`executor.ex:85-91`). The moduledoc's claim to that effect checks out.
- **The new snapshot key is additive and safe.** `Probe.snapshot/2`'s only
  consumer is `Probe.lookup/2` (via `repair.ex:259,296`) — no code iterates the
  snapshot generically, so a new map cannot leak into a drift or orphan report.
  The fallback reads `Map.get(snapshot, :constraint_backed_indexes, %{})`, so a
  hand-built snapshot missing the key still works.
- **Changing `class` changes creation order** (`Scope.class_rank/1`,
  `scope.ex:70`) — from index rank to constraint rank, which is the correct
  order for these objects.
- **`id` is report-text only** — never persisted to a ledger — so renaming both
  ids has no migration or state consequence.
- **`chain_hash` correctly NOT restamped:** no `v*.ex` file is touched, and the
  hash stamps that file set.
- The moduledoc's self-correction (that the generator would *not* reproduce the
  bad `kind`, because `Catalog`'s own indexes query carried the same
  `contype IN ('p','u')` exclusion a week before V171 was written) is
  internally consistent with the code as it stands.

## Findings

### IMPROVEMENT - MEDIUM — the manifest edit is absent from the file's own running log

`lib/phoenix_kit/migrations/expected_schema.ex`

The header of `expected_schema.ex` is a strict, dated log of every
post-generation manifest edit — V167, V171, V175, V181, and the V180
post-publish fix each have an entry explaining what changed and why, and
whether `chain_hash` was restamped. The file opens with **"DO NOT EDIT,
regenerate"**, so that log is the only record distinguishing a sanctioned
hand-edit from drift.

This PR changed two manifest objects and added no entry. It is also the one
edit in the file's history that **rewrites a `{171, ...}` revision in place**,
where the stated convention (V167/V175/V181 notes, and the `revisions:` bullet
in "Conventions") is to append. Rewriting is right here — nothing about the
database object ever changed, the declaration was wrong from the moment it was
written, and the object's identity changed with it, so there is no earlier
shape for a reader to select — but that reasoning existed nowhere in the file,
which is exactly what the log is for.

**Fixed:** added a `CORRECTED 2026-08-29 (PR #762)` entry to the header log
recording what changed, why an appended revision would have been wrong, why
`create: nil` is inert, and why `chain_hash` is not restamped.

## Not fixed (deliberate)

The `kind: :index` → `constraint_backed_indexes` fallback rescues *presence*
detection but, as its own doc says, would still repair a genuinely absent
object into the wrong kind (`class: :index` rebuilds a bare
`CREATE INDEX IF NOT EXISTS`, with no PRIMARY KEY semantics). Making `class`
follow the fallback would be a much larger change to `Executor`'s dispatch for
a case that no longer exists in the manifest. The limitation is documented at
the call site; leaving it is the right call.
