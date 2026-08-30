# PR #775 — Scope the format hook to the edited file instead of the whole project

**Author:** timujinne (`fix/770-format-hook-scope`) · **Merged:** 2026-08-30 · **Reviewed:** 2026-08-30

## Verdict

**Correct, and every condition it calls load-bearing actually is — each one
re-verified against the hook itself.** One claim in the comments is half wrong
on the Elixir this repo runs, and it hides a real typo in `.formatter.exs`.
Fixed here.

---

### Verified — all five behaviours, exercised directly

| scenario | result |
|---|---|
| misformatted file inside the project | formatted |
| a second misformatted file inside the project | untouched (the actual bug #770 reported) |
| `priv/templates/*.ex`, passed directly | untouched |
| file outside `$CLAUDE_PROJECT_DIR` | untouched |
| `$CLAUDE_PROJECT_DIR` unset | nothing formatted, no whole-project fallback |

`os.path.commonpath` over `os.path.realpath` of both sides is the right
containment check — a string prefix compare would pass a sibling directory
sharing the project's name prefix, and realpath closes the symlink-out route.

### IMPROVEMENT — MEDIUM · `:exclude` is not dead; `:excludes` is real, and the repo has a typo

The hook comment and commit message assert:

> An explicit `mix format <path>` argument bypasses .formatter.exs's :inputs
> AND :exclude entirely (Mix never reads :exclude — it is a dead key)

Half right, and the wrong half matters. The repo's `.formatter.exs` said
`exclude:` (**singular**), which Mix has never read — but **Elixir 1.19 added
`:excludes`** (plural), and this repo runs 1.19.5 with `elixir: "~> 1.18"`:

```
# elixir/1.19.5/lib/mix/lib/mix/tasks/format.ex:36
* `:excludes` (a list of paths and patterns) (since v1.19.0) - specifies the
  files to exclude from the list of inputs to this task.
```

So the comment reads as "there is no such feature, don't look for one", when in
fact the feature exists and this repo's spelling of it is a typo. The stated
intent — *"Exclude template files that contain EEx syntax"* — was never
enforced on the bare `mix format` path either; `priv/templates` was safe only
because no `:inputs` pattern happened to reach it, which is precisely the
accident the PR body itself identifies.

Fixed: `.formatter.exs` now says `excludes:`, and the hook comment states the
mechanism correctly.

**The hook's own skip stays load-bearing, and the comment now says why.**
`:excludes` is consulted only in `expand_dot_inputs/4` (`format.ex:641`), the
no-argument path. An explicit path goes through `expand_args/5`
(`format.ex:607`), which consults neither `:inputs` nor `:excludes`. So a hook
that just forwarded the edited path would still format a template — exactly the
regression the PR guarded against, and now for a documented reason rather than
an incorrect one.

### NITPICK · a relative `file_path` would resolve against the hook's CWD

`os.path.realpath(file_path)` resolves a relative path against the hook process's
working directory, not `$CLAUDE_PROJECT_DIR`. Harmless today (payloads carry
absolute paths) and it fails *safe* — the containment check rejects it and the
file is skipped — so left as-is rather than adding a branch for a shape that
does not occur.

---

## Changes made

| File | Change |
|---|---|
| `.formatter.exs` | `exclude:` → `excludes:` (the key Mix actually reads since 1.19), with a note on why the hook still needs its own skip |
| `.claude/hooks/format-edited-file.sh` | Condition 2's comment corrected: names `expand_args/5` vs `expand_dot_inputs/4` instead of claiming `:exclude` does not exist |

## Validation

`mix format` under the corrected key → clean, `priv/templates` untouched;
`mix format --check-formatted` → 0.
