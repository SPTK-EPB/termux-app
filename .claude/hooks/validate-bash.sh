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
#
# The span between `git push` and the force flag is `[^;&|]*` (NOT `.*`, cc#334):
# `.*` is greedy across the WHOLE line, so an unrelated `-f` in a chained segment
# (`git push -u origin b && rm -f /tmp/x`, or `grep -f`, `cp -f`, `tar -f`, `ln -f`)
# tripped the block. `[^;&|]*` cannot cross a command separator, so the force flag
# must belong to THIS `git push` invocation. A real force-push in a LATER segment
# still blocks because grep re-anchors on the second `git push`.
if echo "$COMMAND" | grep -qE 'git push[^;&|]*(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))'; then
  echo "Blocked: force push (--force / -f) not allowed. Use --force-with-lease for rebase-and-push on feature branches." >&2
  exit 2
fi

# Block refspec force-push to main/master regardless of form.
# Matches `+main`, `+master`, `+<src>:main`, `+<src>:master`, `+refs/heads/main`, etc.
# Same `[^;&|]*` command-segment scoping as the force-flag check above (cc#334) so a
# stray `+main` in an unrelated chained segment doesn't false-fire.
if echo "$COMMAND" | grep -qE 'git push[^;&|]*\+([^[:space:]]*:)?(refs/heads/)?(main|master)([[:space:]]|$|:)'; then
  echo "Blocked: refspec force-push to main/master not allowed." >&2
  exit 2
fi

# Block dangerous rm targets. The `\$HOME` is a LITERAL regex token matching the
# string `$HOME` in a command (e.g. `rm -rf $HOME`), not a shell expansion — the
# single quotes are correct here, so SC2016 is a false positive.
# shellcheck disable=SC2016
if echo "$COMMAND" | grep -qE 'rm\s+-rf\s+(/|~|\$HOME)'; then
  echo "Blocked: dangerous rm -rf target." >&2
  exit 2
fi

exit 0
