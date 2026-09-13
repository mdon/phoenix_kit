# PR #806 — Fix module status consumers folding ahead-of-code into up-to-date

**Author:** timujinne (`i166-classify-ahead`) · **Merged:** 2026-09-13 · **Reviewed:** 2026-09-13 (post-merge)

## Verdict

Sound. Every consumer of `Migrations.Modules` statuses was updated, and the
tests pin each combination. One operational consequence is recorded below and
deliberately left unchanged.

## Summary of the PR

- `Modules.classify/2` returns a new `:ahead_of_code` when `installed > target`
  (previously `:up_to_date`), and a new `Modules.ahead_of_code/1` filter is added.
- `StatusReport.next_action/3` returns `{:modules_ahead_of_code, names}` when
  nothing is pending. When something is pending, the ahead modules are added to
  the `:update` reasons instead.
- `status`, `doctor` (`:warn`) and `update` report the ahead modules and no
  longer print them as up to date.

## Verified

- **No consumer was missed.** `rg MigrationModules\.|Migrations\.Modules` over
  `lib/` finds only `status`, `doctor`, `update` and `StatusReport`. All four
  handle the new status, including `update`'s post-migrate verification
  (`verify_module_migrations/2`) and `format_module_version/1`. No admin
  LiveView reads these statuses, and no sibling `phoenix_kit_*` package
  references `Migrations.Modules`.
- **`classify/2` clause order.** `0 == 0` still hits `:up_to_date` before the
  `classify(0, target)` → `:not_installed` clause, same as before.

## IMPROVEMENT - MEDIUM — `status --exit-code` now fails a rollback deploy (not changed)

`exit_code/2` returns 1 for every non-`Ready` action, so a deploy script gated on
`mix phoenix_kit.status --exit-code` now **refuses to proceed after rolling code
back** past a module migration. Before this PR that case exited 0. Two things
make this worth flagging:

- It is inconsistent with core's own schema. `get_installation_status/1` still
  maps `version >= target_version` to `{:up_to_date, _}`, so core being ahead of
  code exits 0 while a module being ahead exits 1.
- `doctor` treats the same state as `:warn`, not `:fail`.

**Not changed:** the task's moduledoc defines `--exit-code` as "exit non-zero
unless `Next` is `Ready`". The PR follows that contract and its tests assert it
(`phoenix_kit_status_test.exs`, "a module ahead of code → 1"). Whether a
rollback should pass the gate is a product call. If it should, the fix is one
`exit_code({:modules_ahead_of_code, _}, _) -> 0` clause plus a doc line, and core
should then get the same `:ahead_of_code` treatment for consistency.

## NITPICK — `format_modules_summary/1` hides pending/ahead when any module is unreadable

That summary line takes the `failed != []` branch first, which is pre-existing.
The `Next:` line and `--verbose` still show everything, so this is left as is.
