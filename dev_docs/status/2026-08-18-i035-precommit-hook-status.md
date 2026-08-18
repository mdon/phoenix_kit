# I035 - Pre-commit hook failure diagnosis: status at pause

**Last Updated**: 2026-08-18 (paused by owner, ~2.5h, pending limit rollback or further word)
**Branch**: `security-integrations-encryption-key`
**Full report**: `dev_docs/investigations/2026-08-17-precommit-hook-misattributed-failure.md`

Written so that resuming needs no reconstruction from memory.

## The task, in one line

`.git/hooks/pre-commit` ended every failed quality run with "Please fix credo
issues before committing", whatever had actually failed - usually an
OOM-killed analyzer. Teach it to tell findings from kills, without swallowing
output.

## Done

* **Hook rewritten and installed** at `.git/hooks/pre-commit`
  (sha256 `52f3d606b09084a3...`). Diagnosis lives in one shared function
  (`report_failure` + `run_step`); all three steps - compile, docs, quality -
  use it, so no copies to drift apart.
* **All branches verified by reproduction**, not by reading: real credo
  findings, real memory starvation via `ulimit -v` (two variants, exit 1 and
  134), stubbed SIGKILL, counter fixture, killed compile, clean pass.
* **Field-confirmed**: a real `git commit` was blocked by a real OOM kill -
  exit 137 with the cgroup counter advancing by 1. Verbatim output is in the
  report. Four lines above the verdict, credo had reported
  `11137 mods/funs, found no issues` - the exact lie the old message told.
* **Container limit raised 4 GiB -> 35 GiB** after measuring what a PLT rebuild
  actually needs (>2.4 GB free; five runs, parallelism ruled out as a lever).
  Applied live, no restart, no line killed.
* **Report committed**: `ca4fca74`, 919 lines, self-contained - it carries the
  diff, the verbatim OOM output, the measurements and the full hook text.
* **Proposal written** for making hook installation reproducible from the repo
  (tracked `.githooks/` + `core.hooksPath`, with a pasteable
  `mix phoenix_kit.doctor` check). Proposal only - the core repo's owner decides.

* **Re-verified after the limit change**: the hook reads `memory.max` at run
  time rather than carrying a hardcoded figure - with the limit at 35 GiB it
  now prints `memory limit 35.0 GiB`. Checked by driving the installed hook
  with a stubbed kill, not by reading the code.

## Not done / open

* **The proposal is not implemented.** Nothing under `.githooks/` exists;
  `core.hooksPath` is unset. Deliberate: it is the repo owner's call.
* **The hook is still untracked**, so it lives in one directory on one machine.
  The report carries a byte-exact copy, but a copy does not install itself.
  This is the single biggest loose end.
* **PLT rebuilds remain expensive and frequent** - any merge touching `mix.lock`
  triggers one, and this branch took two within an hour. Raising the limit made
  them survivable, not cheap. `priv/plts/` still does not exist, so the
  configured `plt_file:` in `mix.exs` is not the file actually used.

## Where exactly this was interrupted

Nothing was mid-flight. The last action completed cleanly: commit `ca4fca74`
passed all three hook steps (dialyzer 1m36s, `done (passed successfully)`), the
working tree was clean, and the pause arrived before anything new was started.

## Read this first when resuming

**If the container limit was rolled back to 4 GiB, the hook will block commits
again** - and it will say so correctly, naming the memory limit rather than
credo. That is the fix working, not a regression. Options in that case, in the
order they should be considered: wait for a quiet window, raise the limit again,
or prebuild the PLT. Do **not** reach for `--no-verify`: the hook catches real
problems, and a bypass in the history outlives the reason for it.

## Watch-outs specific to this container

* `.git/hooks/` is shared by all worktrees of this repo (`core.hooksPath` unset),
  so editing the hook affects every line at once. Replace it atomically
  (temp file + `mv`) and check its hash first.
* The cgroup OOM counter is container-wide; a neighbour's OOM moves it. It may
  corroborate a memory verdict but must never be its sole basis. The hook is
  written that way on purpose.
* Several lines commit to this branch under the same git identity. **Never leave
  anything staged between commands** - work staged with `git add` was swept into
  another line's commit (`ec1ebb81`) within 30 seconds. Commit by explicit path
  in one step.
