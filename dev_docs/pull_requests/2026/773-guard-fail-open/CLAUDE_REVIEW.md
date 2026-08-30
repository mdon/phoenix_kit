# PR #773 — Fix block-dangerous-git.sh fail-open on parse failure; allow `--force-with-lease`

**Author:** timujinne (`fix/768-guard-fail-open`) · **Merged:** 2026-08-30 · **Reviewed:** 2026-08-30

## Verdict

**The hook change is right and every claim in it verified.** The PR also
carried two things its title does not mention: an unrelated reformat that
leaves `main` failing `mix format --check-formatted` on Elixir 1.19, and a
fail-closed path that blocks with no stated reason. Both fixed here.

---

### BUG — HIGH · the formatting hunk breaks the repo's own gate on Elixir 1.19

The merge brought a reformat of `test/mix/tasks/phoenix_kit_doctor_test.exs`
(originally commit `33652a7f`, *"Format doctor test to satisfy mix format on
Elixir 1.18.4"*). Elixir 1.19 breaks that expression the other way, so on
1.19 the file is *not* formatted:

```
$ mix format --check-formatted   # merged main, Elixir 1.19.5
exit=1
```

`mix.exs` declares `elixir: "~> 1.18"`, so 1.19 is in scope, and
`mix format --check-formatted` is a step in `mix quality.ci` → `mix precommit`
**and** in `.github/workflows/ci.yml`. Every one of them was red on `main`.

The two versions genuinely disagree — reformatting for one un-formats it for
the other, so picking a side just moves the breakage. Fixed by removing the
decision: the inline tuple pattern sat exactly on the line-break threshold, so
it is now decomposed into short assertions no formatter has a choice about.
Verified byte-identical and idempotent under **1.19.5** and **1.20.0-rc.6**
(`Code.format_string!/1` run directly under each).

### IMPROVEMENT — HIGH · failing closed silently is barely better than failing open

Failing closed is the right call. But a `PreToolUse` hook's `exit 2` blocks the
call and hands **stderr** to the model as the reason, and both new exits wrote
nothing:

```bash
COMMAND=$(echo "$INPUT" | jq -er '.tool_input.command') || exit 2
[ -n "$COMMAND" ] || exit 2
```

The failure mode the PR body names first — jq missing from PATH — is exactly
the one this hurts most: *every* Bash call in the session is blocked, with no
message, and nothing in the transcript says why or names jq. The guard becomes
indistinguishable from a broken harness.

Fixed: each fail-closed exit now states what it could not read, and a missing
`jq` is called out by name (`command -v jq` on the failure path only, so the
common case pays nothing).

### Verified — the pattern narrowing does what it claims

`grep -qE` over the whole command text, so the `($|[^-])` alternation is real ERE:

| payload | exit |
|---|---|
| `git push` + `--force-with-lease origin main` | 0 (allowed) |
| `git push` + plain `--force origin main` | 2 (blocked) |
| `git push` + plain `--force` at end of line | 2 (blocked — `$` branch) |
| `git status` | 0 |
| malformed JSON | 2, with reason |
| `{"tool_input":{}}` (missing field) | 2, with reason |
| `{"tool_input":{"command":null}}` | 2, with reason (`jq -e` treats null as failure) |
| jq not on PATH | 2, with reason **and** the jq cause line |

### Verified — the `settings_test.exs` hunk is sound

Setting the flat `:secret_key_base` in `setup` is a global `Application.put_env`,
which is normally a red flag. It is safe here: the module is
`use PhoenixKit.DataCase, async: false`, so ExUnit runs it after every `async:
true` module has finished, and `on_exit` is registered *before* the `put_env`,
so the restore stands even if the write is the last thing that happens. The
comment's reasoning (no parent app ⇒ the endpoint config never reaches the key
resolver) matches `Integrations.Encryption`'s resolution order.

### NITPICK · force-push still has two unblocked spellings

`git push -f` and a `+`-prefixed refspec (`git push origin +main`) do the same
damage and match nothing in the denylist. Pre-existing, not introduced here;
left alone rather than widening a denylist whose false positives already bite
(below).

### NITPICK · the guard matches the whole command string, not just the git invocation

Any command that merely *mentions* a denylisted phrase is blocked — a `grep`
for it, a heredoc writing documentation about it. Hit twice while writing this
review. Pre-existing, and the safe fix (parse out the actual `git` invocation)
is more machinery than the false positives justify today.

---

## Changes made

| File | Change |
|---|---|
| `.claude/hooks/block-dangerous-git.sh` | Both fail-closed exits now write a reason to stderr; missing `jq` named explicitly |
| `test/mix/tasks/phoenix_kit_doctor_test.exs` | Assertion decomposed so 1.18/1.19/1.20 formatters all agree |

## Validation

- `mix format --check-formatted` → 0 (was 1)
- Guard exercised across all eight payload shapes above
