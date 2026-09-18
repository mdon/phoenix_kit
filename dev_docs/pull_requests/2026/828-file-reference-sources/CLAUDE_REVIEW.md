# PR #828 — Storage: host-registered file reference sources for orphan detection

**Author:** Timujeen (`feat/file-reference-sources`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

2 files: `lib/modules/storage/storage.ex` gains
`config :phoenix_kit, :file_reference_sources` — `{module, function}` /
`{module, function, args}` entries returning dynamics, plus `{table, column}` and
`{table, :jsonb_key, key}` shorthands — appended to the orphan query; a new
`test/integration/storage/file_reference_sources_test.exs` covers both forms
against a real scratch table.

## Verdict

Sound, and it lands on the right seam. One IMPROVEMENT fixed (a doc/code mismatch
with a destructive failure mode); the rest are notes.

What holds up:

- **The hook covers all three entry points.** `find_orphaned_files/1`,
  `count_orphaned_files/1` and `file_orphaned?/1` all build on the single
  `orphaned_files_query/0`, so registering a source protects the listing, the
  count *and* the `DeleteOrphanedFileJob` re-check at execution time — which is
  the one that actually decides whether bytes are deleted.
- **The rescue is placed to be useful.** `apply_reference_source_mfa/4` returns
  the *original* `query` on a raise, not a half-built one: `acc` is local to the
  reduce, so a source that raises on its third dynamic contributes none of its
  first two. A partially-applied source would be worse than a skipped one.
- **The shorthands quote properly.** `identifier(^table)` / `identifier(^column)`
  is the right tool — table and column names come from host config and cannot be
  parameterised, and `identifier` quotes them rather than interpolating.
- **Clause ordering is correct.** `{table, column}` is guarded on
  `is_binary(table)`, so `{MyApp.Media, :file_reference_sources}` (atom, atom)
  falls through to the MFA clause as intended, and `{"tbl", :jsonb_key, "k"}`
  cannot be mistaken for `{module, function, args}` (that clause requires
  `is_atom(module)`).
- Both shorthands handle NULL correctly: `NULL::text = uuid` is NULL, not true,
  so the row does not match and the file stays orphaned. Right answer.

## IMPROVEMENT - HIGH — the doc promised a `NOT EXISTS` wrapper the code never applies *(fixed)*

The moduledoc said each returned expression "is appended to the orphan query with
`NOT EXISTS`". It is not: `apply_reference_source_mfa/4` ANDs the dynamic onto the
`where` verbatim. The example directly below it writes its own
`NOT EXISTS (...)` fragment, so the doc contradicted its own sample.

A host that believed the prose and returned a positively-phrased
`EXISTS (SELECT 1 FROM my_orders o WHERE o.file_uuid = ?)` would invert the whole
query: every file the host *does* reference becomes the orphan set, and
`DeleteOrphanedFileJob` deletes exactly the live files the hook exists to
protect. The hook's failure mode is silent and destructive, so the contract has to
be unambiguous in the prose, not only in the sample.

Fixed in both the moduledoc and the private `file_reference_sources/0` comment:
each expression must itself be the negative test, core wraps nothing, and the
consequence of getting it backwards is stated. The two shorthands build their own
`NOT EXISTS` and are unaffected.

## Note — the rescue covers query *build*, not query *execution*

`apply_reference_source_mfa/4` catches a source that raises while producing its
dynamics. It cannot catch a dynamic that builds fine and whose SQL is wrong — a
typo'd column, a table that exists with a different shape — because that raises
inside `repo().all/aggregate/exists?` at the call site, long after this function
returned. Such a source takes down orphan detection entirely rather than being
skipped with a warning.

Not worth fixing here: wrapping every orphan read in a rescue would mean deciding
what an orphan query that *failed* should answer, and both available answers are
bad (`true` deletes files on a typo, `false` silently stops all cleanup). The
`{table, column}` / `{table, :jsonb_key, key}` shorthands exist precisely so a
host does not have to hand-write SQL, and they are pre-validated against
`information_schema`. Worth knowing when reading the "skipped with a warning
instead of failing the query" promise in the moduledoc — it holds for the
registration, not for the SQL.

## Note — one `information_schema` round trip per shorthand, per orphan query

`host_table_exists?/1` runs its own `SELECT 1 FROM information_schema.tables` for
every `{table, column}` / `{table, :jsonb_key, key}` entry on every orphan query,
on top of the one `existing_optional_tables/0` already runs. `file_orphaned?/1` is
called once per file by `DeleteOrphanedFileJob`, so a host with three shorthands
pays three extra round trips per file cleaned up.

Left alone: cleanup is a background, low-volume path, and the natural fix (fold
the host names into `existing_optional_tables/0`'s single query) would couple a
function that deliberately filters `phoenix_kit_%` to host-supplied names. Worth
revisiting only if a host registers shorthands in bulk.

## NITPICK — an atom table in a shorthand misroutes to the MFA clause

`{:my_app_orders, :featured_uuid}` — a plausible typo for the documented
`{"my_app_orders", "featured_uuid"}` — matches the `{module, function}` clause
instead, tries `apply(:my_app_orders, :featured_uuid, [])`, and is skipped with a
`file_reference_sources ... raised` warning. The warning names the module and does
say the source was skipped, so it is diagnosable; the message just points at the
wrong shape. Not worth a guard.

## Pre-existing, out of scope — orphan detection is not prefix-safe

Unrelated to this PR, found while checking it against the repo's prefix rules
(`dev_docs/guides/2026-07-27-prefix-safe-migrations.md`): `orphaned_files_query/0`
names core's tables in raw SQL fragments (`phoenix_kit_users`,
`phoenix_kit_cat_items`, …) with no schema qualification, and
`existing_optional_tables/0` hardcodes `table_schema = 'public'`. On a
named-schema install the existence probe returns nothing, every optional check is
skipped, and the base check's unqualified `phoenix_kit_users` fragment resolves
through `search_path`. This PR's `host_table_exists?/1` follows the same
`'public'` convention, which is defensible for *host* tables (a host's own tables
normally do live in `public` even when PhoenixKit is prefixed) — so the new code
is consistent with its surroundings rather than adding to the problem. The
underlying gap is a separate change touching every fragment in the function.
