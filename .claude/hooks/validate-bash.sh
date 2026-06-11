#!/bin/bash
# Hook: PreToolUse for Bash — block dangerous commands
# Shared pattern across all SPTK projects
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block git add of secret files. Templates (.env.example / .env.sample /
# .env.template) are explicitly allowed — they document the schema without
# exposing real secrets.
if echo "$COMMAND" | grep -qE 'git add.*(secrets-|\.env|copilot_homelab|\.pem|credentials)'; then
  # Strip known-safe template suffixes, then re-check. If the only matches
  # were templates, the stripped command is clean and we allow.
  STRIPPED=$(echo "$COMMAND" | sed -E 's/\.env\.(example|sample|template)//g')
  if echo "$STRIPPED" | grep -qE 'git add.*(secrets-|\.env|copilot_homelab|\.pem|credentials)'; then
    echo "Blocked: cannot stage secret files (secrets-*, .env*, .pem, credentials). Use .gitignore. Templates (.env.example / .env.sample / .env.template) are allowed." >&2
    exit 2
  fi
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
