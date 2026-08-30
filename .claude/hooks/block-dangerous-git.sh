#!/bin/bash

INPUT=$(cat)

# Fail CLOSED, and say why. A PreToolUse hook's exit 2 blocks the call and
# feeds STDERR back to the model as the reason — exiting 2 silently blocks
# every Bash call in the session with no diagnosable cause, which is what a
# missing `jq` looks like from the inside.
if ! COMMAND=$(echo "$INPUT" | jq -er '.tool_input.command'); then
  echo "BLOCKED: the git guard could not read .tool_input.command from the hook payload" >&2
  command -v jq >/dev/null 2>&1 ||
    echo "Cause: 'jq' is not on PATH. Install jq, or this guard blocks every Bash call." >&2
  exit 2
fi

if [ -z "$COMMAND" ]; then
  echo "BLOCKED: the git guard read an empty .tool_input.command; refusing to assume it is safe" >&2
  exit 2
fi

DANGEROUS_PATTERNS=(
  "git reset --hard"
  "git clean -fd"
  "git clean -f"
  "git branch -D"
  "git checkout \."
  "git restore \."
  "push --force($|[^-])"
  "reset --hard"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    echo "BLOCKED: '$COMMAND' matches dangerous pattern '$pattern'. The user has prevented you from doing this." >&2
    exit 2
  fi
done

exit 0
