# PR #815 — Media reorganizer: engine, Source contract, module callback and mix task

**Author:** timujinne (`feat/media-reorganizer`) · **Merged:** 2026-09-16 · **Reviewed:** 2026-09-16 (post-merge)

## Verdict

Solid. The PR already went through four review rounds (27 commits) and the
engine is defensive in the right places: every apply runs in its own
transaction against a `FOR UPDATE` re-read of the folder, plan-time counts are
re-verified before and after the write, `Storage.update_folder/2`'s cycle guard
and the partial unique index are relied on rather than re-implemented, and a
source raising/throwing/exiting never halts the run. No correctness bug that
writes the wrong data was found. One reporting inaccuracy was fixed post-merge;
the rest are documentation drift and deliberate non-fixes.

## Summary of the PR

- `PhoenixKit.Modules.Storage.Reorganizer` — collects plans from every enabled
  module's `Source`, drops no-ops, and (with `apply?: true`) applies each
  `:move` / `:trash` / `:report` action in its own transaction; renders a
  fixed-width summary table plus a details section.
- `Reorganizer.Action` — validates/normalizes the plain-map action shape
  (forward-compatible: unknown keys are dropped with one warning per key-set).
- `Reorganizer.Source` — behaviour plus the full design contract for module
  implementations.
- `PhoenixKit.Module.media_reorganizer/0` optional callback (default `nil`) and
  `ModuleRegistry.all_media_reorganizers/0` (enabled modules only).
- `mix phoenix_kit.media.reorganize` — dry-run by default, `--apply`,
  repeatable `--source`, `--pending-days`; options validated before
  `app.start`; exit 1 when `--apply` leaves a `:failed`/`:conflict`.

## Findings

### IMPROVEMENT - MEDIUM — A back-fill hid its own rename/restore from the summary (fixed)

`outcome_for/3` collapses every successful move into one headline atom, and
any action carrying `after_move` is always `:backfilled`. `summarize_group/1`
derived the `renamed` and `restored` columns from that atom only, so a
back-filled action that also renamed and/or un-trashed its folder counted `0`
in both columns, and on `--apply` the details section (which lists `:restored`
outcomes) omitted a restore done by a back-fill. Back-fill is the common case
for pointer-bearing modules, so the summary understated exactly the writes an
owner most wants to see.

**Fix:** `do_move/2` now also records an engine-internal
`changes: [:moved | :renamed | :restored]` list of what the write actually
changed. `renamed`/`restored` count from it; the details section also lists any
action whose changes include `:restored`. Outcome atoms are unchanged (sibling
modules and tests match on them). `:changes` is not in `Action`'s known keys,
so a `Source` cannot inject it. Tests: "a back-filled move still counts its
rename and restore in the summary", "an in-place back-fill records no folder
changes".

### NITPICK — Moduledoc claimed `on_conflict: :report` pre-checks the name (fixed)

The moduledoc said the engine SELECTs for a collision before writing for both
modes ("`on_conflict: :report` just checks"). Only `:suffix` pre-checks;
`:report` lets the single `UPDATE` hit the unique constraint and maps the
changeset error to `:conflict`. Behaviour is correct — the doc was reworded.

### NITPICK — Wrong comment on trashing a folder with already-trashed children (fixed)

`child_folder_count/1`'s comment said already-trashed children keep their
`trashed_at` when the parent is trashed. `Storage.do_trash_folder/1`'s subtree
`update_all` has no `is_nil(trashed_at)` guard, so they (and their files) are
re-stamped with the parent's timestamp. The PR itself notes this elsewhere
(`restore_subtree_if_needed/1`); the comment now agrees.

### NITPICK — Target parent is checked without a lock (not fixed)

`verify_target_parent/1` reads the target parent with a plain `get_folder`, so
a concurrent `trash_folder` of that parent between the check and the `UPDATE`
could leave a moved folder live under a trashed parent. Not fixed: the task is
an operator-run one-off, and a `FOR SHARE` lock on the parent (taken after the
child's `FOR UPDATE`) could deadlock against `do_trash_folder/1`'s one-statement
subtree `update_all`, whose row-lock order is unspecified — trading a race
nobody hits in practice for a new failure mode.

### NITPICK — `safe_resolve_source/2` rescues but doesn't catch throw/exit (not fixed)

A module's `module_key/0` that `throw`s or `exit`s would still crash `--source`
key resolution. Callbacks that do either are pathological; `safe_plan/3` (the
path real source code runs through) already catches all three.

## Verified non-issues

- **Cycles:** a `parent_uuid` inside the folder's own subtree returns
  `{:error, :cycle}` from `Storage.update_folder/2` → `:failed`, covered by a test.
- **Case-sensitivity of the name pre-check:** the unique index is
  `(name, COALESCE(parent_uuid, zero-uuid)) WHERE trashed_at IS NULL` — plain
  case-sensitive `name`, matching `name_taken?/3`'s `==`.
- **Constraint mapping:** `Folder.changeset/2` declares
  `unique_constraint([:name, :parent_uuid])`, so the error lands on `:name`
  with `constraint: :unique`, as `unique_name_conflict?/1` expects.
- **`trashed_at` equality in the subtree restore:** both `Folder` and
  `StorageFile` use `:utc_datetime`, and `do_trash_folder/1` truncates to the
  second, so the equality match is exact.
