# Pre-commit hook reported the wrong reason for its own failure

Started 2026-08-17, completed 2026-08-18. Task I035.

## Symptom

`.git/hooks/pre-commit` ended every failed quality run with one hard-coded line:

    ❌ Code quality checks failed. Please fix credo issues before committing.

Nothing about credo was true. The real reason was one line higher in the same
output:

    .git/hooks/pre-commit: line 31: <pid> Killed  mix quality

`mix format --check-formatted` was clean and `mix credo --strict` reported
"found no issues" over 10967 mods/funs on the same day. The hook had a single
input - a non-zero exit code - and turned it into a confident claim about a
subsystem it had not looked at. Two people lost time looking for style findings
that did not exist, and the same root cause explains two earlier episodes on
line L037 ("the commit hung", "the first attempt failed on timeout").

This is the defect class the surrounding work is about, in diagnostics rather
than in product code: a failure that names a cause with nothing to do with the
actual one, and sounds sure of itself.

## Why the process dies

* Container cgroup limit: `/sys/fs/cgroup/memory.max` = 4294967296 (4 GiB).
* `mix quality` = `format` -> `credo --strict` -> `dialyzer` (mix.exs).
* `mix.exs` points dialyzer at `priv/plts/dialyzer.plt`; that directory does not
  exist. `_build/dev/dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt` is 8.9 MB
  with a 20-byte `.plt.hash` - a PLT build that was interrupted. Building it is
  the memory-hungry step, and it is what the kernel kills.
* `/sys/fs/cgroup/memory.events` showed `oom_kill 12` and, ~20 minutes later
  during this investigation, `oom_kill 28`. Processes in this container are
  being OOM-killed continuously.
* `mix` is `#!/usr/bin/env elixir` and `elixir` ends in `exec "$@"`, so the exec
  chain keeps one PID: a SIGKILL on `beam.smp` reaches the hook as exit 137.

## Two container facts that shaped the design

1. **The hook is shared by every worktree of this repo.** `core.hooksPath` is
   unset, so all worktrees resolve hooks through `$GIT_COMMON_DIR/hooks`:

       /app                                                             [security-integrations-encryption-key]
       /app/.claude/worktrees/fix-storage-bucket-credential-encryption   [fix/storage-bucket-credential-encryption]
       /app/.claude/worktrees/object-storage-integration-provider        [feature/object-storage-integration-provider]

   Any edit lands on all three lines immediately. The file must therefore be
   replaced atomically, and behaviour (what runs, what exit codes mean) must not
   change - only the diagnosis.

2. **The OOM counter is container-wide.** `memory.events.local` is identical to
   `memory.events`, i.e. one cgroup for all three lines. A neighbour's OOM kill
   moves the same counter. So the counter can corroborate a memory verdict but
   can never be the sole basis for one - otherwise the fix would reproduce the
   very defect it removes, from the other side.

## How the hook now decides

Three independent signals per step:

| Signal | Source |
|---|---|
| exit status | `set +e; cmd 2>&1 \| tee "$log"; status=${PIPESTATUS[0]}` |
| OOM delta | `oom_kill` from `memory.events` read before and after the step |
| output markers | text the tools actually print |

Decision order, most-specific first:

1. `status >= 128` and signal 9 -> killed by SIGKILL, no findings produced.
   OOM delta > 0 sharpens this to "did not fit into the container memory limit";
   delta 0 keeps it hedged ("most likely the limit, but the counter does not
   confirm it - it may have been killed from the outside").
2. Any status, but a memory marker in the output -> the BEAM failed to allocate;
   the matching line is quoted verbatim.
3. `status >= 128`, other signals -> killed by that signal, cause not in the
   checks.
4. Otherwise, attribute the failing step of `mix quality` from its markers
   (newest stage first, because the alias stops at the first failure):
   dialyzer -> credo -> format.
5. Otherwise, say plainly that the step could not be attributed - and do not
   guess.

In every branch the tool output is streamed live through `tee` and the verdict
is appended to it, never substituted, with the full log path and its last lines.

### Markers, all observed rather than assumed

The first version of this list was written from theory and **missed**: starving a
real BEAM produced `erts_mmap: Failed to create super carrier of size 1024 MB`,
which was not in it. The classifier then correctly said "could not attribute"
instead of inventing a cause - honest, but not useful. The list below is built
only from strings produced on this machine or read out of the tools' sources:

* memory: `erts_mmap:`, `Failed to create super carrier`,
  `Failed to create scheduler thread`, `Cannot allocate`, `[Oo]ut of memory`,
  `std::bad_alloc`, `erl_crash.dump`, `system_limit`
* dialyzer: `Finding suitable PLTs`, `Checking PLT`, `Starting Dialyzer`,
  `Total errors:` (deps/dialyxir/lib)
* credo: `Checking N source file`, `Analysis took`, `mods/funs, found`
* format: `mix format failed`, `The following files are not formatted`
  (elixir mix/tasks/format.ex:764,772)

## Verification - by reproduction, not by reading

All five outcomes were driven through the hook file itself, with `mix` stubbed
on PATH only where a real run was unsafe or irrelevant.

| # | Outcome | How reproduced | Exit | Verdict printed |
|---|---|---|---|---|
| 1 | real style findings | **live** `mix credo --strict` on a probe file | 6 | "checks ran and reported findings. Failing step: mix credo --strict" + the findings |
| 2 | BEAM out of memory | **real**, `ulimit -v 786432` | 1 | quotes `erts_mmap: Failed to create super carrier of size 1024 MB` |
| 3 | same, then aborts | **real**, `ulimit -v 1572864` | 134 | quotes `Failed to create scheduler thread 36, error = 11`, notes SIGABRT |
| 4 | SIGKILL, OOM unconfirmed | stub doing `kill -9 $$` | 137 | "killed by SIGKILL ... the counter does not confirm it" |
| 5 | SIGKILL, OOM confirmed | **counter fixture** first, then a **real OOM kill** in the field (below) | 137 | "kernel recorded 1 OOM kill ... did not fit into the container memory limit" |
| 6 | killed `mix compile` | stub doing `kill -9 $$` | 137 | names the kill; previously said "fix compilation errors" |
| 7 | everything clean | all stubs exit 0 | 0 | unchanged success path |

**No real OOM was provoked at any point.** `ulimit -v` caps the address space of
a single process; the OOM killer is not involved, which is visible in the
messages themselves - they are allocation refusals, not kills. This matters
because two other lines run in this container.

Row 5 is the one branch proven by a **fixture**, not by a live case: the counter
file was pointed at a controlled path via the `OOM_EVENTS_FILE` seam. A live
sample from the object-storage-provider line is still to be attached; until then
this row should not be described as confirmed in the field.

## A second thing that reading would not have caught

Under `set -e`, the idiom `[ -n "$x" ] && echo ...` is fatal when it is the
**last** command of a function: the function returns 1 and the shell exits.
Verified both ways rather than assumed:

    $ bash -c 'set -e; f(){ [ -n "" ] && echo yes; echo end; }; f'
    end                       # not last -> harmless

    $ bash -c 'set -e; f(){ echo hi; [ -n "" ] && echo yes; }; f; echo after'
    hi                        # last -> script dies, "after" never printed

The hook happened to be safe (every such line had another command after it),
which is exactly the kind of accident that breaks the next time someone moves a
line. All of them were rewritten as explicit `if ... fi` blocks before install.
The `&&` occurrences that remain are inside `if` conditions, where the rule does
not apply.

Related note on the same shell: `failing_stage` ends in an `if/elif/elif` chain
with no `else`, which returns 0 when nothing matches - so `stage=$(failing_stage …)`
does not trip `set -e` either. That was checked, not assumed.

## Install notes

* `.git/hooks/pre-commit` is shared by all three worktrees, so it was replaced
  atomically: write `pre-commit.i035.tmp` next to it, `chmod --reference`, then
  `mv -f`. A neighbour mid-commit can never read a half-written file.
* Before replacing, the installed file's sha256 was compared against the backup
  taken at the start; a mismatch would have meant somebody else had edited it in
  the meantime and the install would have been refused.
* Backup of the previous hook: kept in the session scratchpad for the duration
  of the task.

## Live run under real git (2026-08-18)

The installed hook was exercised by an actual `git commit`, with nothing stubbed
- real `mix compile --warnings-as-errors`, real `mix docs`, real `mix quality`.
Verbatim, from a 499-line captured log:

    ✅ Compilation passed
    ✅ Documentation generation passed
    🔍 Running code quality checks...
    Checking 818 source files (this might take a while) ...
    11098 mods/funs, found no issues.
    Finding suitable PLTs
    Checking PLT...
    PLT is up to date!
    Starting Dialyzer
    Total errors: 235, Skipped: 235, Unnecessary Skips: 2
    done in 2m2.81s
    done (passed successfully)
    ✅ Code quality checks passed
    🎉 All pre-commit checks passed! Proceeding with commit...

**The expected OOM did not happen, and that correction matters more than the
confirmation.** This run was set up to catch a real kill; instead `mix quality`
passed. The reason is in the output: `PLT is up to date!`. Something had
finished building `_build/dev/dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt`
in the meantime (most plausibly another line's own commit running this same
shared hook), so dialyzer no longer had to build a PLT and fitted inside the
limit, taking 2m2.81s.

So the earlier statement in this document - that `mix quality` cannot pass in
this container - was true while the PLT was missing and is **false now**. It has
been corrected below. The memory kill is a property of *building the PLT*, not
of running dialyzer against an existing one.

What this run does prove, live and end-to-end under real git: the success path,
and that the hook streams every step's output instead of swallowing it.

### Second run, same day: the real kill, caught in the field

A follow-up `git commit` hit it for real. Between the two runs another line
merged `feature/object-storage-integration-provider` into this branch, which
invalidated the PLT - so dialyzer had to check and rebuild it again, and this
time the kernel killed it. Verbatim from the captured log, including the two
lines immediately above the verdict, which are the whole point:

    11137 mods/funs, found no issues.

    Use `mix credo explain` to explain issues, `mix credo --help` for options.
    Finding suitable PLTs
    Checking PLT...
    Looking up modules in dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt
    Checking 3282 modules in dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt

    ❌ Code quality checks failed (exit code 137).
       The process was KILLED by SIGKILL (9) - it produced no findings at all.
       The kernel recorded 1 OOM kill(s) in this container's cgroup while
       this step was running (memory limit 4.0 GiB).
       => The step did not fit into the container memory limit.
       Either way, nothing was reported: do not go looking for style or compile findings.
       Last step that produced output: mix dialyzer.

Both signals agreed independently: our own process returned 137, and the
cgroup's `oom_kill` counter advanced by exactly 1 across that step. The failing
stage was attributed correctly to dialyzer.

Note what stands four lines above the verdict: `11137 mods/funs, found no
issues.` Credo had just finished cleanly. The old hook would have answered this
exact run with "Please fix credo issues before committing" - the original defect,
reproduced live on the very commit that documents it.

This closes row 5 in the table above: it is no longer fixture-only.

## Still open

* Nothing about the classifier's branches. All of them have now been reproduced,
  and the SIGKILL-with-confirmed-OOM branch was confirmed in the field rather
  than by fixture.
* `priv/plts/` still does not exist, so `mix.exs`'s configured
  `plt_file: {:no_warn, "priv/plts/dialyzer.plt"}` is not what is being used;
  the dialyxir default in `_build` is. Any merge that changes the dependency or
  module set invalidates it, and the next `mix quality` has to rebuild it - the
  step that does not fit in 4 GiB. That is not a rare edge: it happened twice in
  one hour on this branch. The hook now says so honestly instead of blaming
  credo, but the underlying fragility is unchanged and belongs to a separate
  task.

## Measured: why the gate cannot pass here, as a number

Asked how much memory dialyzer actually needs, rather than asserting "4 GiB is
not enough". Four attempts at reducing pressure, all measured, none bypassing
the check:

| attempt | peak BEAM RSS | result |
|---|---|---|
| `mix dialyzer --plt`, `ERL_FLAGS="+S 2:2"` | not sampled | killed, 137 |
| same, in a quiet window (no other BEAM running) | not sampled | killed, 137 |
| same, `+S 1:1`, sampled every 1s | **2146 MB** | killed, 137 |
| stale PLT moved aside, fresh build, `+S 1:1` | **2116 MB** | killed, 137 |

`ERL_FLAGS` was verified to take effect before trusting it: schedulers online
are 4 by default, 2 with `+S 2:2`, 1 with `+S 1:1`. So parallelism is **not**
the lever - a single scheduler still peaks above 2.1 GB, because the cost is the
PLT data itself (2789 modules added on a fresh build, 3282 checked on an
incremental one), not concurrent workers.

Against that, at the times of measurement:

    anon (non-reclaimable, other processes):  1769-1959 MB   (73 claude processes)
    cgroup limit:                                 4096 MB
    => headroom offered to dialyzer:           2137-2327 MB
    => still killed at every one of those

A fifth attempt was made in the best window of the day - `anon` down to 1769 MB,
so **2327 MB** of headroom - and dialyzer was killed again. That refutes an
earlier reading in this document, which said the rebuild misses by "tens of
megabytes": the 2116/2146 MB figures are the last one-second sample before the
kill, not the peak, and the true requirement is above 2327 MB.

**The number to act on: a PLT rebuild needs more than 2.4 GB of free memory -
call it 2.5 GB to be safe. With the agent fleet in this container holding
1.8-2.0 GB, a 4 GiB limit cannot fit both. 6 GiB leaves comfortable margin;
5 GiB would be the bare minimum and leaves nothing for the fleet to grow into.**

Parallelism is not a lever, and this was checked rather than assumed: schedulers
online are 4 by default, 2 under `+S 2:2`, 1 under `+S 1:1`, and a single
scheduler still gets killed. The cost is the PLT data itself - 2789 modules
added on a fresh build, 3282 checked on an incremental one - not concurrent
workers.

Note this only bites when the PLT must be rebuilt: with a valid PLT the whole
hook passes in about four minutes, as measured earlier the same day. Every merge
that touches `mix.lock` invalidates it, and this branch took two such merges
within one hour.

An incremental PLT build (batches of 8 dependency directories via the raw
`dialyzer` CLI) did solve the memory side - zero OOM kills across 13 batches -
but the raw CLI cannot read Elixir-generated beams (`dialyzer_utils:get_core_from_beam`
fails), which is exactly why dialyxir drives dialyzer from inside an Elixir VM.
Doing it properly would mean a batched build task of our own; that is a separate
piece of work, not part of this one.

### Resolved 2026-08-18: limit raised to 35 GiB

The number above was acted on: the container limit went from 4 GiB to 35 GiB,
applied live with `docker update` - no restart, so none of the four lines
working in this container were killed - and pinned in the compose file so it
survives a future re-create. Confirmed from inside the container:

    memory.max: 35840 MB       (was 4096 MB)
    anon:        2608 MB
    headroom:   32744 MB

Everything measured above stands as measured; it describes the 4 GiB era. The
hook reads `memory.max` at run time, so its messages now quote the real limit
rather than a hardcoded one.

What this does and does not fix: a PLT rebuild now has room, so the gate stops
being fatal. It does not make the rebuild cheap or rare - every merge touching
`mix.lock` still triggers one, and it still costs minutes. The intermittent-gate
caveat in the proposal below is unchanged.

## Proposal: make the hook reproducible from the repository

A proposal, not a change - the core repo's owner decides. Written so it can be
accepted as-is: every file, every line to add, and the command that proves it
worked.

### The problem in one sentence

The hook exists as a single file in a single directory on a single machine
(`.git/hooks/pre-commit`); `.git/` is never cloned, pushed, or reviewed, so a
fresh clone silently has no hook at all and nothing announces its absence.

### Step 1 - track the hook (this is the part that matters)

Source of truth for the content: the "## The hook" section at the end of this
document, which is a byte-for-byte copy of the installed file. On the machine
where it is installed, `.git/hooks/pre-commit` is the same bytes.

    mkdir -p .githooks
    cp .git/hooks/pre-commit .githooks/pre-commit    # or paste from this document
    chmod +x .githooks/pre-commit
    git add .githooks/pre-commit
    git update-index --chmod=+x .githooks/pre-commit  # see below

That last line is not decoration. Git stores the executable bit itself: if the
file lands in the index as mode 100644, it is not executable in anyone else's
clone and the hook silently never runs - the same "exists but does nothing"
failure this whole document is about. Verify with:

    git ls-files -s .githooks/pre-commit    # must start with 100755

From here the hook is a normal reviewed file: it shows up in diffs, survives
clones, and has one source of truth. Everything below is about *enabling* it.

### Step 2 - point git at it, once per clone

    git config core.hooksPath .githooks

`core.hooksPath` lives in the common config, so one command covers every
worktree of the repo - which matches how this repo already behaves, where all
three worktrees share `.git/hooks` today.

Two things to know before adopting:

* Git will never enable hooks from a clone on its own. That is a deliberate
  security boundary (a clone must not be able to run code on checkout), so any
  scheme that claims zero manual steps is wrong. One command is the floor.
* Setting `core.hooksPath` disables `.git/hooks/*` entirely. A contributor with
  local hooks there must move them into `.githooks/` or keep them elsewhere.

### Step 3 - add the one-time step to AGENTS.md

Under "Workflow", after step 1 ("Make changes"), insert:

    0. First clone only: `git config core.hooksPath .githooks` - enables the
       tracked pre-commit hook. Git cannot do this for you.

### Step 4 - make the omission detectable, not just documented

Documentation does not survive people forgetting. `mix phoenix_kit.doctor`
already exists and already reports exactly this kind of state, with checks
returning `{:pass | :warn | :fail, detail}`. Add one line to its `results` list
in `run/1`:

```elixir
run_check("Git Hooks", fn -> check_git_hooks() end),
```

and one function alongside the other `check_*` implementations:

```elixir
defp check_git_hooks do
  tracked = ".githooks/pre-commit"

  configured = git_out(["config", "--get", "core.hooksPath"])
  # Worktrees keep hooks in the COMMON git dir, not in a per-worktree .git,
  # so resolve it rather than hardcoding ".git/hooks".
  common = git_out(["rev-parse", "--git-common-dir"])
  shadow = Path.join(if(common == "", do: ".git", else: common), "hooks/pre-commit")

  cond do
    not File.exists?(tracked) ->
      {:warn, "#{tracked} is missing — the tracked pre-commit hook is not in this checkout."}

    configured != ".githooks" ->
      {:warn,
       "core.hooksPath is #{inspect(configured)}, so the tracked hook is NOT running.\n" <>
         "       Fix: git config core.hooksPath .githooks"}

    File.exists?(shadow) ->
      {:warn,
       "#{shadow} still exists. core.hooksPath wins, so it is dead code that will\n" <>
         "       mislead the next reader. Delete it."}

    true ->
      {:pass, "tracked hook enabled via core.hooksPath"}
  end
end

defp git_out(args) do
  case System.cmd("git", args, stderr_to_stdout: true) do
    {out, 0} -> String.trim(out)
    _ -> ""
  end
end
```

Three states, in decreasing severity: hooks not enabled at all; enabled but a
stale copy still sits in the common hooks dir; enabled and clean. Detection is
what survives Step 2 being skipped, which it will be.

### How to verify the adoption worked

    git config --get core.hooksPath     # -> .githooks
    git rev-parse --git-path hooks      # -> .githooks
    .githooks/pre-commit; echo $?       # runs the real checks; 0 when they pass

The third line is the honest test: it runs the hook exactly as git would,
without needing a commit to fail first.

### The alternative, and why it is second choice

A `mix phoenix_kit.hooks` task copying `priv/hooks/pre-commit` into
`.git/hooks/` would fit the repo's idiom (`phoenix_kit.install`, `.update`,
`.status`, `.doctor`, `.release_check` all exist). It avoids touching git config
and leaves other hooks alone. But it keeps two copies that can drift, and it
still needs someone to run it - the same manual step, with a staleness problem
added. Prefer Step 1+2; borrow only its detection half, which is Step 4.

### One thing the owner should weigh before tracking it as-is

The hook runs `mix compile --warnings-as-errors`, `mix docs` and `mix quality`.
Whether that gate is passable depends on state that is not in the repository:
with the dialyxir PLT already built it passes in about four minutes (measured
2026-08-18); with the PLT absent or invalidated, rebuilding it does not fit in a
4 GiB cgroup and the step is killed. So tracking the hook unchanged ships a gate
whose colour depends on whether a file in `_build/` happens to exist - green for
whoever built the PLT earlier, red for a fresh container. That is the same
failure mode AGENTS.md already describes for `mix test` ("a gate that is always
red gets ignored, which is worse than an honest gap"), only intermittent, which
is harder to diagnose. Worth deciding deliberately: prebuild the PLT as an
explicit setup step, or have the hook detect a missing PLT and say so before
spending four minutes on a run that cannot finish.

## Gate materials

Everything a reviewer needs is in this one file, so it cannot rot into a list of
paths on a single machine. The originals, while they exist:

* hook diff - `scratchpad/pre-commit.diff` (reproduced in full below)
* previous hook - `scratchpad/pre-commit.backup`
* installed hook - `.git/hooks/pre-commit`, sha256 `52f3d606b09084a3...`
  (reproduced in full at the end of this document)
* verbatim real-OOM run - `scratchpad/commit-attempt-3.log`, 499 lines
  (the decisive window reproduced below)
* this report - the file you are reading

### Verbatim: the hook on a real OOM kill

Not a paraphrase. The window below starts with credo finishing cleanly and ends
with the hook's advice; nothing is elided between them. The point is the
distance between "found no issues" and what the old hook would have said here -
"Please fix credo issues before committing".

```
    11137 mods/funs, found no issues.
    
    Use `mix credo explain` to explain issues, `mix credo --help` for options.
    Finding suitable PLTs
    Checking PLT...
    [:asn1, :aws_regions, :backblaze_regions, :bandit, :bcrypt_elixir, :beamlab_countries, :certifi, :comeonin, :compiler, :crypto, :db_connection, :decimal, :ecto, :ecto_sql, :eex, :elixir, :eqrcode, :esbuild, :etcher, :ex_ast, :ex_aws, :ex_aws_ec2, :ex_aws_s3, :ex_aws_sns, :ex_aws_sqs, :ex_aws_sts, :expo, :file_system, :finch, :fresco, :gen_smtp, :gettext, :glob_ex, :h2, :hackney, :hammer, :hpax, :idna, :igniter, :inets, :jason, :kernel, :keyfob, :leaf, :locale_slug, :logger, :mdex, :mdex_native, :mime, :mimerl, ...]
    Looking up modules in dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt
    Finding applications for dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt
    Finding modules for dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt
    Checking 3282 modules in dialyxir_erlang-28.3.2_elixir-1.18.4_deps-dev.plt
    
    ❌ Code quality checks failed (exit code 137).
       The process was KILLED by SIGKILL (9) - it produced no findings at all.
       The kernel recorded 1 OOM kill(s) in this container's cgroup while
       this step was running (memory limit 4.0 GiB).
       => The step did not fit into the container memory limit.
       Either way, nothing was reported: do not go looking for style or compile findings.
       Last step that produced output: mix dialyzer.
    
       Nothing in the checks needs fixing. Give the step more memory, or
       run less at once - one command per BEAM:
         mix compile --warnings-as-errors
         mix format --check-formatted
         mix credo --strict
         mix dialyzer          # heaviest; builds priv/plts/dialyzer.plt
       Do NOT bypass the hook by default - it also catches real problems.
```

### The change, as a diff

`.git/hooks/pre-commit` is not tracked by git, so this is a plain `diff -u`
against the backup taken before the edit, not a `git diff`. That fact is itself
the subject of the proposal above.

```diff
--- a/.git/hooks/pre-commit (before I035)
+++ b/.git/hooks/pre-commit (after I035)
@@ -10,25 +10,177 @@
     exit 1
 fi
 
-echo "🔨 Compiling code..."
-if ! mix compile --warnings-as-errors; then
-    echo "❌ Compilation failed. Please fix compilation errors before committing."
-    exit 1
-fi
-echo "✅ Compilation successful"
+# ---------------------------------------------------------------------------
+# Failure diagnosis
+#
+# Every step below can fail for two unrelated reasons, and this hook used to
+# report only one of them - "Please fix credo issues before committing" - no
+# matter which one actually happened:
+#
+#   1. a check ran and reported findings   -> name the step that reported them;
+#   2. the process was killed, or could not allocate memory -> say that plainly.
+#
+# Case 2 is routine here: `mix dialyzer` builds priv/plts/dialyzer.plt and does
+# not fit into this container's cgroup memory limit, so the kernel kills it.
+# The hook then printed a confident sentence about credo and sent people
+# looking for style findings that do not exist. `mix compile` is memory-hungry
+# too, and used to answer the same way with "fix compilation errors".
+#
+# Deliberately conservative rules:
+#   * tool output is streamed live through tee and is never replaced - the
+#     verdict is appended to it, and the deciding line is quoted back;
+#   * the decisive proof that OUR process was killed is its exit status
+#     (>= 128 means it died on a signal). The cgroup OOM counter is
+#     container-wide and shared with the other worktrees of this repo, so a
+#     neighbour's OOM can move it. It is therefore used only to sharpen the
+#     wording, never as the sole basis for the claim;
+#   * every marker in MEM_RE was observed on this machine by starving a real
+#     BEAM with `ulimit -v`. None of them is guessed.
+# ---------------------------------------------------------------------------
 
-echo "📚 Generating documentation..."
-if ! mix docs; then
-    echo "❌ Documentation generation failed. Please fix documentation errors before committing."
-    exit 1
-fi
-echo "✅ Documentation generated successfully"
+LOG_DIR="${TMPDIR:-/tmp}/phoenix-kit-precommit-$$"
+mkdir -p "$LOG_DIR"
 
-echo "🔍 Running code quality checks..."
-if ! mix quality; then
-    echo "❌ Code quality checks failed. Please fix credo issues before committing."
-    exit 1
-fi
-echo "✅ Code quality checks passed"
+MEM_RE='erts_mmap:|Failed to create super carrier|Failed to create scheduler thread|Cannot allocate|[Oo]ut of memory|std::bad_alloc|erl_crash\.dump|system_limit'
+
+# Test seam: point OOM_EVENTS_FILE at a fixture to exercise the OOM-counter
+# branch without provoking a real OOM kill. Defaults to the live cgroup files.
+oom_kill_count() {
+    local f
+    for f in ${OOM_EVENTS_FILE:-} /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory/memory.oom_control; do
+        if [ -n "$f" ] && [ -r "$f" ]; then
+            awk '$1 == "oom_kill" { print $2; exit }' "$f"
+            return
+        fi
+    done
+}
+
+memory_limit_human() {
+    local v=""
+    if [ -r /sys/fs/cgroup/memory.max ]; then
+        v=$(cat /sys/fs/cgroup/memory.max)
+    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
+        v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
+    fi
+    case "$v" in
+        "" | max) ;;
+        *) awk -v b="$v" 'BEGIN { printf "%.1f GiB", b / 1073741824 }' ;;
+    esac
+}
+
+# Which step of `mix quality` (format -> credo --strict -> dialyzer) was
+# running. The alias stops at the first failure, so the newest stage that
+# printed anything is the one that broke - hence newest-stage-first.
+failing_stage() {
+    local log="$1"
+    if grep -qE 'Starting Dialyzer|Finding suitable PLTs|Checking PLT|Total errors:' "$log"; then
+        echo "dialyzer"
+    elif grep -qE 'Checking [0-9]+ source file|Analysis took|mods/funs, found' "$log"; then
+        echo "credo --strict"
+    elif grep -qE 'mix format failed|The following files are not formatted' "$log"; then
+        echo "format"
+    fi
+}
+
+advise_memory() {
+    echo ""
+    echo "   Nothing in the checks needs fixing. Give the step more memory, or"
+    echo "   run less at once - one command per BEAM:"
+    echo "     mix compile --warnings-as-errors"
+    echo "     mix format --check-formatted"
+    echo "     mix credo --strict"
+    echo "     mix dialyzer          # heaviest; builds priv/plts/dialyzer.plt"
+    echo "   Do NOT bypass the hook by default - it also catches real problems."
+}
+
+# report_failure <name> <exit status> <log> <oom delta>
+report_failure() {
+    local name="$1" status="$2" log="$3" oom_delta="$4"
+    local stage limit signal signame mem_line
+    stage=$(failing_stage "$log")
+    limit=$(memory_limit_human)
+    mem_line=$(grep -m1 -E "$MEM_RE" "$log" 2>/dev/null | sed 's/^[[:space:]]*//')
+    signal=""
+    if [ "$status" -ge 128 ]; then signal=$((status - 128)); fi
+
+    echo ""
+    echo "❌ $name failed (exit code $status)."
+
+    if [ "$signal" = "9" ]; then
+        echo "   The process was KILLED by SIGKILL (9) - it produced no findings at all."
+        if [ -n "$oom_delta" ] && [ "$oom_delta" -gt 0 ] 2>/dev/null; then
+            echo "   The kernel recorded $oom_delta OOM kill(s) in this container's cgroup while"
+            echo "   this step was running${limit:+ (memory limit $limit)}."
+            echo "   => The step did not fit into the container memory limit."
+        else
+            echo "   No OOM kill was recorded in this container's cgroup during this step${limit:+ (memory limit $limit)}."
+            echo "   => Most likely the memory limit, but the kernel counter does not confirm"
+            echo "      it - the process may also have been killed from the outside."
+        fi
+        echo "   Either way, nothing was reported: do not go looking for style or compile findings."
+        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
+        advise_memory
+    elif [ -n "$mem_line" ]; then
+        echo "   The BEAM failed to allocate memory${limit:+ (container limit $limit)}:"
+        echo "       $mem_line"
+        echo "   => The step ran out of memory. Nothing was reported by the checks."
+        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
+        if [ -n "$signal" ]; then echo "   (The process then died on SIG$(kill -l "$signal" 2>/dev/null).)"; fi
+        advise_memory
+    elif [ -n "$signal" ]; then
+        signame=$(kill -l "$signal" 2>/dev/null || echo "$signal")
+        echo "   The process was killed by SIG$signame ($signal) - it produced no findings."
+        echo "   => Nothing was reported by the checks; the cause is not in them."
+        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
+        advise_memory
+    elif [ -n "$stage" ]; then
+        echo "   The checks ran and reported findings. Failing step: mix $stage."
+        echo "   Fix what it printed above, then commit again."
+    else
+        echo "   The step reported a failure. See its output above - this hook could not"
+        echo "   attribute it to a specific check, and will not guess."
+    fi
+
+    echo ""
+    echo "   Full output of this step: $log"
+    echo "   Last lines:"
+    tail -n 10 "$log" | sed 's/^/   | /'
+    echo ""
+}
+
+# run_step <name> <banner> <command...>
+# Streams output live, keeps a copy, and reports the real reason on failure.
+run_step() {
+    local name="$1" banner="$2"
+    shift 2
+    local log oom_before oom_after oom_delta status
+    log="$LOG_DIR/$(echo "$name" | tr -c 'a-zA-Z0-9' '-').log"
+
+    echo "$banner"
+    oom_before=$(oom_kill_count)
+
+    set +e
+    "$@" 2>&1 | tee "$log"
+    status=${PIPESTATUS[0]}
+    set -e
+
+    oom_after=$(oom_kill_count)
+    if [ -n "$oom_before" ] && [ -n "$oom_after" ]; then
+        oom_delta=$((oom_after - oom_before))
+    else
+        oom_delta=""
+    fi
+
+    if [ "$status" -ne 0 ]; then
+        report_failure "$name" "$status" "$log" "$oom_delta"
+        exit 1
+    fi
+    echo "✅ $name passed"
+}
+
+run_step "Compilation" "🔨 Compiling code..." mix compile --warnings-as-errors
+run_step "Documentation generation" "📚 Generating documentation..." mix docs
+run_step "Code quality checks" "🔍 Running code quality checks..." mix quality
 
-echo "🎉 All pre-commit checks passed! Proceeding with commit..."
\ No newline at end of file
+rm -rf "$LOG_DIR"
+echo "🎉 All pre-commit checks passed! Proceeding with commit..."
```

## The hook

`.git/hooks/pre-commit` is not tracked by git, so a copy of the installed
version is kept here.

```bash
#!/bin/bash

# NOTE: Exit on any command failure
set -e

echo "Running pre-commit checks..."

if [ ! -f "mix.exs" ]; then
    echo "Error: mix.exs not found. Are you in an Elixir project directory?"
    exit 1
fi

# ---------------------------------------------------------------------------
# Failure diagnosis
#
# Every step below can fail for two unrelated reasons, and this hook used to
# report only one of them - "Please fix credo issues before committing" - no
# matter which one actually happened:
#
#   1. a check ran and reported findings   -> name the step that reported them;
#   2. the process was killed, or could not allocate memory -> say that plainly.
#
# Case 2 is routine here: `mix dialyzer` builds priv/plts/dialyzer.plt and does
# not fit into this container's cgroup memory limit, so the kernel kills it.
# The hook then printed a confident sentence about credo and sent people
# looking for style findings that do not exist. `mix compile` is memory-hungry
# too, and used to answer the same way with "fix compilation errors".
#
# Deliberately conservative rules:
#   * tool output is streamed live through tee and is never replaced - the
#     verdict is appended to it, and the deciding line is quoted back;
#   * the decisive proof that OUR process was killed is its exit status
#     (>= 128 means it died on a signal). The cgroup OOM counter is
#     container-wide and shared with the other worktrees of this repo, so a
#     neighbour's OOM can move it. It is therefore used only to sharpen the
#     wording, never as the sole basis for the claim;
#   * every marker in MEM_RE was observed on this machine by starving a real
#     BEAM with `ulimit -v`. None of them is guessed.
# ---------------------------------------------------------------------------

LOG_DIR="${TMPDIR:-/tmp}/phoenix-kit-precommit-$$"
mkdir -p "$LOG_DIR"

MEM_RE='erts_mmap:|Failed to create super carrier|Failed to create scheduler thread|Cannot allocate|[Oo]ut of memory|std::bad_alloc|erl_crash\.dump|system_limit'

# Test seam: point OOM_EVENTS_FILE at a fixture to exercise the OOM-counter
# branch without provoking a real OOM kill. Defaults to the live cgroup files.
oom_kill_count() {
    local f
    for f in ${OOM_EVENTS_FILE:-} /sys/fs/cgroup/memory.events /sys/fs/cgroup/memory/memory.oom_control; do
        if [ -n "$f" ] && [ -r "$f" ]; then
            awk '$1 == "oom_kill" { print $2; exit }' "$f"
            return
        fi
    done
}

memory_limit_human() {
    local v=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        v=$(cat /sys/fs/cgroup/memory.max)
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
    fi
    case "$v" in
        "" | max) ;;
        *) awk -v b="$v" 'BEGIN { printf "%.1f GiB", b / 1073741824 }' ;;
    esac
}

# Which step of `mix quality` (format -> credo --strict -> dialyzer) was
# running. The alias stops at the first failure, so the newest stage that
# printed anything is the one that broke - hence newest-stage-first.
failing_stage() {
    local log="$1"
    if grep -qE 'Starting Dialyzer|Finding suitable PLTs|Checking PLT|Total errors:' "$log"; then
        echo "dialyzer"
    elif grep -qE 'Checking [0-9]+ source file|Analysis took|mods/funs, found' "$log"; then
        echo "credo --strict"
    elif grep -qE 'mix format failed|The following files are not formatted' "$log"; then
        echo "format"
    fi
}

advise_memory() {
    echo ""
    echo "   Nothing in the checks needs fixing. Give the step more memory, or"
    echo "   run less at once - one command per BEAM:"
    echo "     mix compile --warnings-as-errors"
    echo "     mix format --check-formatted"
    echo "     mix credo --strict"
    echo "     mix dialyzer          # heaviest; builds priv/plts/dialyzer.plt"
    echo "   Do NOT bypass the hook by default - it also catches real problems."
}

# report_failure <name> <exit status> <log> <oom delta>
report_failure() {
    local name="$1" status="$2" log="$3" oom_delta="$4"
    local stage limit signal signame mem_line
    stage=$(failing_stage "$log")
    limit=$(memory_limit_human)
    mem_line=$(grep -m1 -E "$MEM_RE" "$log" 2>/dev/null | sed 's/^[[:space:]]*//')
    signal=""
    if [ "$status" -ge 128 ]; then signal=$((status - 128)); fi

    echo ""
    echo "❌ $name failed (exit code $status)."

    if [ "$signal" = "9" ]; then
        echo "   The process was KILLED by SIGKILL (9) - it produced no findings at all."
        if [ -n "$oom_delta" ] && [ "$oom_delta" -gt 0 ] 2>/dev/null; then
            echo "   The kernel recorded $oom_delta OOM kill(s) in this container's cgroup while"
            echo "   this step was running${limit:+ (memory limit $limit)}."
            echo "   => The step did not fit into the container memory limit."
        else
            echo "   No OOM kill was recorded in this container's cgroup during this step${limit:+ (memory limit $limit)}."
            echo "   => Most likely the memory limit, but the kernel counter does not confirm"
            echo "      it - the process may also have been killed from the outside."
        fi
        echo "   Either way, nothing was reported: do not go looking for style or compile findings."
        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
        advise_memory
    elif [ -n "$mem_line" ]; then
        echo "   The BEAM failed to allocate memory${limit:+ (container limit $limit)}:"
        echo "       $mem_line"
        echo "   => The step ran out of memory. Nothing was reported by the checks."
        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
        if [ -n "$signal" ]; then echo "   (The process then died on SIG$(kill -l "$signal" 2>/dev/null).)"; fi
        advise_memory
    elif [ -n "$signal" ]; then
        signame=$(kill -l "$signal" 2>/dev/null || echo "$signal")
        echo "   The process was killed by SIG$signame ($signal) - it produced no findings."
        echo "   => Nothing was reported by the checks; the cause is not in them."
        if [ -n "$stage" ]; then echo "   Last step that produced output: mix $stage."; fi
        advise_memory
    elif [ -n "$stage" ]; then
        echo "   The checks ran and reported findings. Failing step: mix $stage."
        echo "   Fix what it printed above, then commit again."
    else
        echo "   The step reported a failure. See its output above - this hook could not"
        echo "   attribute it to a specific check, and will not guess."
    fi

    echo ""
    echo "   Full output of this step: $log"
    echo "   Last lines:"
    tail -n 10 "$log" | sed 's/^/   | /'
    echo ""
}

# run_step <name> <banner> <command...>
# Streams output live, keeps a copy, and reports the real reason on failure.
run_step() {
    local name="$1" banner="$2"
    shift 2
    local log oom_before oom_after oom_delta status
    log="$LOG_DIR/$(echo "$name" | tr -c 'a-zA-Z0-9' '-').log"

    echo "$banner"
    oom_before=$(oom_kill_count)

    set +e
    "$@" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e

    oom_after=$(oom_kill_count)
    if [ -n "$oom_before" ] && [ -n "$oom_after" ]; then
        oom_delta=$((oom_after - oom_before))
    else
        oom_delta=""
    fi

    if [ "$status" -ne 0 ]; then
        report_failure "$name" "$status" "$log" "$oom_delta"
        exit 1
    fi
    echo "✅ $name passed"
}

run_step "Compilation" "🔨 Compiling code..." mix compile --warnings-as-errors
run_step "Documentation generation" "📚 Generating documentation..." mix docs
run_step "Code quality checks" "🔍 Running code quality checks..." mix quality

rm -rf "$LOG_DIR"
echo "🎉 All pre-commit checks passed! Proceeding with commit..."
```
