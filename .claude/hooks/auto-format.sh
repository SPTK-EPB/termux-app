#!/bin/bash
# Hook: PostToolUse for Edit|Write — auto-format with Prettier
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Skip if no file path
[ -z "$FILE_PATH" ] && exit 0

# Only format known file types
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.mjs|*.jsx|*.json|*.css|*.astro|*.html) ;;
  *) exit 0 ;;
esac

# Walk up directory tree to find nearest Prettier
DIR=$(dirname "$FILE_PATH")
while [ "$DIR" != "/" ] && [ "$DIR" != "." ]; do
  if [ -x "$DIR/node_modules/.bin/prettier" ]; then
    "$DIR/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
    exit 0
  fi
  DIR=$(dirname "$DIR")
done

# Fallback: try project root node_modules
if [ -x "node_modules/.bin/prettier" ]; then
  node_modules/.bin/prettier --write "$FILE_PATH" 2>/dev/null
fi

exit 0
