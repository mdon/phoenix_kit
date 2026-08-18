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
| 5 | SIGKILL, OOM confirmed | **counter fixture** (`OOM_EVENTS_FILE`) | 137 | "kernel recorded 1 OOM kill ... did not fit into the container memory limit" |
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

## Still open

* The "SIGKILL + confirmed OOM" branch (row 5) is proven by a counter fixture.
  A live sample from the object-storage-provider line should be run through the
  installed hook and attached here when that line is active again.
* Not touched, and worth its own task: `priv/plts/` does not exist, so every
  `mix dialyzer` in this container starts a PLT build that cannot finish inside
  4 GiB. The hook now explains this honestly instead of blaming credo, but the
  underlying situation is unchanged - `mix quality` cannot pass here as long as
  the PLT has to be built inside the limit.

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
