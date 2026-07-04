#!/bin/bash
# Hook: PreToolUse for Bash — block dangerous commands
# Shared pattern across all SPTK projects.
#
# CC-owned FLEET hook (cc#327): this CC-home copy at ~/.claude/hooks/validate-bash.sh
# is the CANONICAL source. scaffold-new-repo.sh pulls it into new repos, and
# propagate-fleet-hook.sh --hook validate-bash.sh re-syncs existing repos from it.
# Edit HERE, not per-repo.
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block git add of secret files. Templates (.env.example / .env.sample /
# .env.template) are explicitly allowed — they document the schema without
# exposing real secrets.
#
# The `secrets-` alternative is anchored to a path-token start — (^|[/[:space:]])secrets- —
# so a filename that merely CONTAINS the substring (e.g. check-required-secrets-test.sh,
# where `secrets-` is preceded by a hyphen) is not blocked, while a real secrets-*.env,
# a whitespace-preceded `git add secrets-prod.txt`, or config/secrets-prod.txt still is (cc#327).
# NOTE: the whitespace alternative is load-bearing — a bare `^` cannot match after the
# unavoidable `git add ` prefix, so `(^|/)` alone would miss a root-level `secrets-foo.txt`.
if echo "$COMMAND" | grep -qE 'git add.*((^|[/[:space:]])secrets-|\.env|copilot_homelab|\.pem|credentials)'; then
  # Strip known-safe template suffixes, then re-check. If the only matches
  # were templates, the stripped command is clean and we allow.
  STRIPPED=$(echo "$COMMAND" | sed -E 's/\.env\.(example|sample|template)//g')
  if echo "$STRIPPED" | grep -qE 'git add.*((^|[/[:space:]])secrets-|\.env|copilot_homelab|\.pem|credentials)'; then
    echo "Blocked: cannot stage secret files (secrets-*, .env*, .pem, credentials). Use .gitignore. Templates (.env.example / .env.sample / .env.template) are allowed." >&2
    exit 2
  fi
fi

# Block bare --force / -f on git push, allow --force-with-lease (safer by design:
# refuses if remote has advanced since last fetch).
# Pattern matches `--force` followed by non-hyphen-or-EOL (so --force-with-lease
# is NOT blocked) OR ` -f` followed by space/EOL (combined short flags like -fv
# are intentionally not matched per issue #259 scope).
if echo "$COMMAND" | grep -qE 'git push.*(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))'; then
  echo "Blocked: force push (--force / -f) not allowed. Use --force-with-lease for rebase-and-push on feature branches." >&2
  exit 2
fi

# Block refspec force-push to main/master regardless of form.
# Matches `+main`, `+master`, `+<src>:main`, `+<src>:master`, `+refs/heads/main`, etc.
if echo "$COMMAND" | grep -qE 'git push.*\+([^[:space:]]*:)?(refs/heads/)?(main|master)([[:space:]]|$|:)'; then
  echo "Blocked: refspec force-push to main/master not allowed." >&2
  exit 2
fi

# Block dangerous rm targets
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|~|\$HOME)'; then
  echo "Blocked: dangerous rm -rf target." >&2
  exit 2
fi

exit 0
