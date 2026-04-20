#!/bin/bash
# Hook: PreToolUse for Bash — block dangerous commands
# Shared pattern across all SPTK projects
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block git add of secret files
if echo "$COMMAND" | grep -qE 'git add.*(secrets-|\.env|copilot_homelab|\.pem|credentials)'; then
  echo "Blocked: cannot stage secret files (secrets-*, .env*, .pem, credentials). Use .gitignore." >&2
  exit 2
fi

# Block force push
if echo "$COMMAND" | grep -qE 'git push.*--force'; then
  echo "Blocked: force push not allowed. Use regular push." >&2
  exit 2
fi

# Block dangerous rm targets
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|~|\$HOME)'; then
  echo "Blocked: dangerous rm -rf target." >&2
  exit 2
fi

exit 0
