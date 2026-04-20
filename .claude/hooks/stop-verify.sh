#!/bin/bash
# Hook: Stop — verify tests pass before Claude marks work as done

INPUT=$(cat)

find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    [ -d "$dir/.git" ] && echo "$dir" && return
    dir=$(dirname "$dir")
  done
  echo "$PWD"
}

run_in() {
  local dir="$1"; shift
  (cd "$dir" && "$@" 2>&1)
}

ROOT=$(find_project_root)
FAILURES=""

# --- Vitest ---
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
    if [ $? -ne 0 ]; then
      LABEL=$(basename "$dir")
      [ "$dir" = "$ROOT" ] || [ "$dir" = "$ROOT/" ] && LABEL="root"
      FAILURES="${FAILURES}Vitest failed (${LABEL}):\n${OUTPUT}\n\n"
    fi
  fi
done

# --- Bun test ---
if [ -f "$ROOT/package.json" ] && grep -q '"test"' "$ROOT/package.json" 2>/dev/null; then
  if command -v bun >/dev/null 2>&1; then
    OUTPUT=$(run_in "$ROOT" bun test 2>&1)
    [ $? -ne 0 ] && FAILURES="${FAILURES}Bun test failed:\n${OUTPUT}\n\n"
  fi
fi

# No test suite found — pass silently
[ -z "$FAILURES" ] && exit 0

REASON=$(echo -e "$FAILURES" | head -30)
echo "{\"decision\": \"block\", \"reason\": \"Tests failed. Fix before marking done:\\n${REASON}\"}"
exit 0
