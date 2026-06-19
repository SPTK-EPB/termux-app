#!/bin/bash
# Hook: PostToolUse for Edit|Write — auto-format, gated on CI-fmt-enforcement (cc#303).
#
# CC-owned FLEET hook. Each repo's .claude/hooks/auto-format.sh is a verbatim copy
# of this file (scaffold-new-repo.sh pulls it from here; propagate.sh re-syncs it).
#
# Why gate: running a formatter on a repo whose CI does NOT gate formatting
# reformats pre-existing drift (or applies tool defaults that fight the repo's
# hand-formatting), producing gratuitous whole-file churn and the
# revert-and-reapply-via-Bash loop (dugnad-agent #138/#139, ADM #673). The ONLY
# signal that guarantees auto-formatting yields a small, repo-consistent diff is
# "CI keeps this repo formatted" — i.e. a `<fmt> --check` step in the repo's
# .github/workflows. Config-presence (ADM#673's interim JS signal) is the wrong
# gate for Rust (rustfmt.toml may be absent yet fmt-by-convention, OR present yet
# CI never --checks), so gate uniformly on CI enforcement instead. Where CI does
# not enforce, the hook is a deliberate no-op (the repo's files are either already
# formatted on-save — so a format would be a no-op anyway — or carry drift a
# format would churn). Resumes formatting automatically if/when the repo adds a
# `--check` CI step.
#
# Override for testing: set AUTO_FORMAT_CI_STUB=enforce|skip to bypass workflow
# detection (enforce = pretend CI enforces; skip = pretend it does not).
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Nearest ancestor of $1 that contains .github/ or .git (the repo root).
find_repo_root() {
  local dir
  dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd) || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "$dir/.github" ] || [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# 0 if any workflow yaml under <root>/.github/workflows matches ERE $2.
ci_enforces() {
  local root="$1" pat="$2"
  case "${AUTO_FORMAT_CI_STUB:-}" in
    enforce) return 0 ;;
    skip) return 1 ;;
  esac
  [ -d "$root/.github/workflows" ] || return 1
  grep -rlE "$pat" "$root/.github/workflows" \
    --include='*.yml' --include='*.yaml' >/dev/null 2>&1
}

ROOT=$(find_repo_root "$FILE_PATH") || exit 0

case "$FILE_PATH" in
  *.rs)
    # rustfmt only if CI runs a fmt check: `cargo fmt --check`, `cargo fmt --all -- --check`,
    # `cargo fmt -- --check`, `rustfmt --check`, etc. (any `fmt ... --check` on one line).
    ci_enforces "$ROOT" 'fmt[[:space:]].*--check' || exit 0
    command -v rustfmt >/dev/null 2>&1 || exit 0
    # Match CI's edition where discoverable (bare `rustfmt FILE` defaults to 2015).
    edition=$(grep -m1 -oE 'edition[[:space:]]*=[[:space:]]*"[0-9]+"' "$ROOT/Cargo.toml" 2>/dev/null | grep -oE '[0-9]+')
    if [ -n "$edition" ]; then
      rustfmt --edition "$edition" "$FILE_PATH" 2>/dev/null
    else
      rustfmt "$FILE_PATH" 2>/dev/null
    fi
    ;;
  *.ts|*.tsx|*.js|*.mjs|*.cjs|*.jsx|*.json|*.css|*.scss|*.astro|*.vue|*.svelte|*.html|*.md|*.yaml|*.yml)
    # prettier only if CI runs prettier --check / -c / format:check / biome check|ci
    ci_enforces "$ROOT" 'prettier[[:space:]]+(-c\b|--check)|format:check|fmt:check|format[[:space:]]+--[[:space:]]+--check|biome[[:space:]]+(ci|check|format[[:space:]].*--check)' || exit 0
    DIR=$(dirname "$FILE_PATH")
    while [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
      if [ -x "$DIR/node_modules/.bin/prettier" ]; then
        "$DIR/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
        exit 0
      fi
      DIR=$(dirname "$DIR")
    done
    [ -x "$ROOT/node_modules/.bin/prettier" ] && "$ROOT/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
    ;;
  *)
    exit 0
    ;;
esac

exit 0
