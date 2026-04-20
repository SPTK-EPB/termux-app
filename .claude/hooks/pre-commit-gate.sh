#!/bin/bash
# Hook: PreToolUse for Bash — quality gate before git commit
# Auto-detects available lint/typecheck/test tools and runs them.
# Exit 2 = block the commit so Claude fixes issues first.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git commit commands
echo "$COMMAND" | grep -qE '^\s*git\s+commit' || exit 0

# Find project root (walk up from cwd looking for .git)
find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -d "$dir/.git" ] && echo "$dir" && return
    dir=$(dirname "$dir")
  done
  echo "$PWD"
}

ROOT=$(find_project_root)
ERRORS=""
WARNINGS=""

# Helper: run a command in a directory, capture output
run_in() {
  local dir="$1"; shift
  (cd "$dir" && "$@" 2>&1)
}

# --- Lint ---
if [ -f "$ROOT/eslint.config.js" ] || [ -f "$ROOT/eslint.config.mjs" ] || [ -f "$ROOT/.eslintrc.json" ] || [ -f "$ROOT/.eslintrc.js" ]; then
  if [ -x "$ROOT/node_modules/.bin/eslint" ]; then
    OUTPUT=$(run_in "$ROOT" node_modules/.bin/eslint . --max-warnings=0)
    [ $? -ne 0 ] && ERRORS="${ERRORS}ESLint failed:\n${OUTPUT}\n\n"
  fi
fi

# --- Type-check ---
# Astro projects
if [ -f "$ROOT/astro.config.mjs" ] || [ -f "$ROOT/astro.config.ts" ]; then
  if [ -x "$ROOT/node_modules/.bin/astro" ]; then
    OUTPUT=$(run_in "$ROOT" node_modules/.bin/astro check)
    [ $? -ne 0 ] && ERRORS="${ERRORS}astro check failed:\n${OUTPUT}\n\n"
  fi
# Plain TypeScript (Bun)
elif [ -f "$ROOT/tsconfig.json" ]; then
  if [ -x "$ROOT/node_modules/.bin/tsc" ]; then
    OUTPUT=$(run_in "$ROOT" node_modules/.bin/tsc --noEmit)
    [ $? -ne 0 ] && ERRORS="${ERRORS}tsc failed:\n${OUTPUT}\n\n"
  fi
fi

# --- Tests ---
# Vitest
for dir in "$ROOT" "$ROOT"/*/; do
  VITEST_CFG=""
  [ -f "${dir}vitest.config.ts" ] && VITEST_CFG="${dir}vitest.config.ts"
  [ -f "${dir}vitest.config.js" ] && VITEST_CFG="${dir}vitest.config.js"
  [ -z "$VITEST_CFG" ] && continue

  if grep -q 'vitest-pool-workers\|cloudflare:test' "$VITEST_CFG" 2>/dev/null; then
    continue
  fi

  if [ -x "${dir}node_modules/.bin/vitest" ]; then
    OUTPUT=$(run_in "$dir" node_modules/.bin/vitest run --reporter=verbose --exclude='**/e2e/**' --exclude='**/*.spec.ts')
    [ $? -ne 0 ] && ERRORS="${ERRORS}Vitest failed in $(basename "$dir"):\n${OUTPUT}\n\n"
  fi
done

# Bun test — use `bun run test` so package.json's test script (which may include
# `|| true` for repos without tests yet) takes precedence over Bun's native runner,
# which exits non-zero when no *.test.* files exist.
if [ -f "$ROOT/package.json" ] && grep -q '"test"' "$ROOT/package.json" 2>/dev/null; then
  if command -v bun >/dev/null 2>&1; then
    OUTPUT=$(run_in "$ROOT" bun run test 2>&1)
    [ $? -ne 0 ] && ERRORS="${ERRORS}Bun test failed:\n${OUTPUT}\n\n"
  fi
fi

# --- Report ---
if [ -n "$WARNINGS" ]; then
  echo "Pre-commit warnings (non-blocking):" >&2
  echo -e "$WARNINGS" >&2
fi

if [ -n "$ERRORS" ]; then
  echo "Pre-commit quality gate FAILED. Fix these issues before committing:" >&2
  echo "" >&2
  echo -e "$ERRORS" >&2
  exit 2
fi

exit 0
