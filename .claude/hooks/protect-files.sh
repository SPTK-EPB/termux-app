#!/bin/bash
# Hook: PreToolUse for Edit|Write — block edits to protected files
# Protected patterns: applied migrations, CI workflows, lock files, generated files.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE_PATH" ] && exit 0

# --- Lock files (should be managed by package managers, not direct edits) ---
case "$(basename "$FILE_PATH")" in
  package-lock.json|bun.lockb|yarn.lock|pnpm-lock.yaml)
    echo "Blocked: $(basename "$FILE_PATH") should not be edited directly. Run the package manager instead." >&2
    exit 2
    ;;
esac

# --- CI/CD workflows (warn, allow with approval) ---
if echo "$FILE_PATH" | grep -qE '\.github/workflows/.*\.yml$'; then
  echo "Warning: CI workflow file (.github/workflows/) — ensure this change is intentional." >&2
fi

# --- Applied D1 migrations (immutable once deployed) ---
# Pattern: migrations/NNNN_*.sql or drizzle/NNNN_*.sql
if echo "$FILE_PATH" | grep -qE '(migrations|drizzle)/[0-9]{4}_.*\.sql$'; then
  echo "Blocked: applied migration files are immutable. Create a new migration instead." >&2
  exit 2
fi

# --- Generated files ---
if echo "$FILE_PATH" | grep -qE '(\.wrangler/|\.next/|dist/|\.astro/)'; then
  echo "Blocked: generated/build output files should not be edited directly." >&2
  exit 2
fi

exit 0
