#!/bin/bash
# PostToolUse hook for Write|Edit — formats ONLY the file that was just
# edited (see #770: bare `mix format`, no argument, formats every file
# `.formatter.exs` :inputs matches, not just the one this tool call
# touched; that collateral diff is indistinguishable from the intended
# change in `git status`).
#
# Three conditions below are load-bearing, do not remove:
#
#  1. Parsed with python3, not jq — jq is not guaranteed to be present
#     (see block-dangerous-git.sh, a separate issue, for that failure mode).
#  2. priv/templates is skipped explicitly. An explicit `mix format <path>`
#     argument goes through Mix.Tasks.Format's `expand_args/5`, which never
#     consults :inputs OR :excludes — only the no-argument `expand_dot_inputs/4`
#     path filters on :excludes (a real key since Elixir 1.19; the repo's
#     .formatter.exs said `exclude:` and was silently ignored until it was
#     corrected). So the skip has to live here regardless.
#  3. The target is checked to be inside $CLAUDE_PROJECT_DIR via
#     os.path.commonpath over os.path.realpath of both sides — not a string
#     prefix compare, which a sibling directory sharing a name prefix would
#     pass incorrectly. An explicit path argument also removes the
#     repo-relative containment bare `mix format` had implicitly; without
#     this check the hook could rewrite any .ex/.exs/.heex anywhere on disk
#     using this project's formatter settings. If $CLAUDE_PROJECT_DIR is
#     unset, the hook formats nothing — it does not fall back to
#     whole-project behaviour.

INPUT=$(cat)

TARGET=$(echo "$INPUT" | python3 -c '
import json, os, sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

file_path = (payload.get("tool_input") or {}).get("file_path")
if not file_path:
    sys.exit(0)

project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
if not project_dir:
    sys.exit(0)

project_real = os.path.realpath(project_dir)
target_real = os.path.realpath(file_path)

if os.path.commonpath([project_real, target_real]) != project_real:
    sys.exit(0)

rel = os.path.relpath(target_real, project_real)
rel_parts = rel.split(os.sep)
if rel_parts[:2] == ["priv", "templates"]:
    sys.exit(0)

if not rel.endswith((".ex", ".exs", ".heex")):
    sys.exit(0)

print(target_real)
')

[ -n "$TARGET" ] || exit 0

cd "$CLAUDE_PROJECT_DIR" && mix format "$TARGET"
exit 0
