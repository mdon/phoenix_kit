# PR #763 — Fix stale disk read in `fix_supervisor_ordering` during update

**Author:** timujinne (`p013-reorder-supervisors`) · **Merged:** 2026-08-28 · **Reviewed:** 2026-08-29

## Verdict

Correct. No findings.

## What the PR does

`fix_supervisor_ordering/1` decided `:correct` / `:needs_fix` from
`File.read!("lib/<app>/application.ex")`. Igniter does not flush a step's
writes to disk before the next step runs, so that read was blind to edits
already staged in the Igniter buffer. Replaced with
`Igniter.exists?/2` + `Igniter.include_existing_file/2` +
`Rewrite.source!/2 |> Rewrite.Source.get(:content)`.

## Verification

- **The trigger is real.** Two earlier steps in the same pipeline stage stage
  `application.ex` edits before this runs:
  `ApplicationSupervisor.add_supervisor/1` (`phoenix_kit.update.ex:146`) and
  `ObanConfig.add_oban_supervisor/1` (`:2050`), both via
  `Igniter.Project.Application.add_new_child/3`, which only touches the buffer.
  The call site at `:392` even carries the comment "This must run AFTER
  add_oban_supervisor" — so the ordering the fix depends on is the intended one.
- **The failure mode described is reachable.** A disk read on a host whose
  `application.ex` has neither line yet returns content matching
  `validate_supervisor_positions/4`'s trivial heads
  (`(nil, nil, nil, _) -> :cannot_determine`, `(repo, nil, nil, _) -> :correct`),
  so the check reports "fine" while the buffer being written is misordered.
- **Rebinding is correct.** `igniter = Igniter.include_existing_file(...)` is
  rebound inside the `if`, and every branch of the `case` returns that rebound
  value, not the parameter.
- **The `rescue` returning the original `igniter` is right,** not a bug: the
  rebinding is scoped to the `if` block, so the error path discards partial
  work and continues — which is what a best-effort advisory check should do.
- **`Rewrite.Source.get(source, :content)` is the correct arity** through the
  pipe, and the I103 precedent (`fix_ueberauth_providers_config/1`,
  `:1609`) reads content the same way, via `Igniter.update_file/3`'s source.
  Using `include_existing_file/2` instead is appropriate here because this
  path is read-only.
- **`Igniter.exists?/2` replacing `File.exists?/1`** is required for the same
  reason as the read: it must see buffer-created files.
- Making the function public with `@doc false` + a `@spec` matches the I103
  precedent for exposing an end-to-end-only test seam.

## Test coverage

`test/mix/tasks/phoenix_kit_update_supervisor_ordering_test.exs` (188 lines)
drives a real, non-test-mode Igniter against a real temp directory — the only
way this defect is observable, since a pure-content unit test cannot reproduce
"buffer disagrees with disk".
