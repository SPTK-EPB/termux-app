#!/bin/bash
# Hook: PreToolUse for Bash — block dangerous commands
# Shared pattern across all SPTK projects.
#
# CC-owned FLEET hook (cc#327): this CC-home copy at ~/.claude/hooks/validate-bash.sh
# is the CANONICAL source. scaffold-new-repo.sh pulls it into new repos, and
# propagate-fleet-hook.sh --hook validate-bash.sh re-syncs existing repos from it.
# Edit HERE, not per-repo.
#
# LC_ALL=C pins [:alnum:]/[:space:] to ASCII so the regex bounds are locale-independent
# across the fleet (cc#416 panel, kimi-F6a). FAIL-OPEN property: if jq is ABSENT the hook
# allows (empty COMMAND → no match → exit 0) — acceptable for a best-effort tripwire, noted
# so it is a KNOWN property on a fleet-wide surface, not a surprise (kimi-F6c).
export LC_ALL=C
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
#
# The `\.env` alternative is bounded by `(rc|s)?([^[:alnum:]]|$)` (ADM #1666, #1667): a real
# env file has `.env` — optionally `.envrc` (direnv) or `.envs` (cookiecutter-django) —
# followed by end-of-token, a dot (`.env.local`), whitespace, a quote, `-`/`_`; never any
# OTHER alphanumeric. Unbounded `\.env` false-blocked filenames merely CONTAINING the
# substring (`sentryScrub.envelope.test.ts`, `foo.environment.ts`); an over-tight
# `\.env([^[:alnum:]]|$)` (no `(rc|s)?`) re-ALLOWED the secret-bearing `.envrc`/`.envs`
# conventions — the #1667 cross-family panel caught that loosening. The bound still blocks
# `.env`, `.env.local`, `secrets.env`, quoted `"foo.env"`, `.env-`/`.env_`, `.envrc`,
# `.envs/…`; still allows `.envelope`/`.environment`.
#
# The `\.pem` and `credentials` alternatives are bounded the SAME way (cc#416, from the
# ADM #1667 T2 panel) — `\.pem([^[:alnum:]]|$)` and `credentials([^[:alnum:]]|$)` — closing
# the same unbounded-substring defect the `.env` fix closed. The bound un-blocks the
# alnum-follows class (`credentialsProvider.ts`, `credentialsStore.ts`) while still blocking
# the common real-secret forms: `server.pem`, `certs/x.pem`, `server.pem.bak`,
# `credentials.json`, `google-credentials.json`, `.credentials`, bare `credentials`.
# TRADEOFF (cc#416 panel, GPT-F3): the bound is character-based, not semantic — it ALSO
# un-blocks a `credentials<alnum>` name that COULD be a real secret (`credentialsProduction.json`).
# That is an accepted false-NEGATIVE traded for the false-block fix; the guard is best-effort,
# .gitignore is the real control. NOTE (kimi-F4): a token-plus-DOT name (`crypto.pem.test.ts`,
# `foo.credentials.test.ts`) STAYS blocked — structurally identical to `credentials.json`, so no
# BOUNDED PATTERN can un-block it without un-blocking a real secret. A suffix-strip (like the
# template strip below) COULD un-block it; we chose not to add one (renaming a test file is
# cheaper than the added strip complexity/risk).
if echo "$COMMAND" | grep -qiE 'git add.*((^|[/[:space:]])secrets-|\.env(rc|s)?([^[:alnum:]]|$)|copilot_homelab|\.pem([^[:alnum:]]|$)|credentials([^[:alnum:]]|$))'; then
  # Strip EXACT template basename tokens (.env.example/.env.sample/.env.template), bounded on
  # BOTH sides — leading (^|space|/) and trailing (space|quote|EOL) — looping so ADJACENT
  # templates both strip without leading-boundary consumption. Only a complete basename token
  # is removed, never the substring inside a longer name (cc#416 panel F1/F2): `.env.example.bak`,
  # `.env.sample.secret`, `prod.env.example`, `foo.env.template`, `.env.exampleSecret` all STAY
  # blocked. `printf '%s'` (not echo) avoids -n/-e/backslash mangling of the command text (kimi-F6b).
  # Detection greps are case-INSENSITIVE (-qiE, kimi-F1): macOS/BSD ship a case-insensitive
  # filesystem by default, so `git add KEY.PEM`/`Credentials.json` must block. The strip stays
  # case-SENSITIVE so an uppercase `.env.SAMPLE` is NOT stripped → stays blocked (safe direction).
  STRIPPED="$COMMAND"
  while :; do
    NEW=$(printf '%s' "$STRIPPED" | sed -E "s#(^|[[:space:]/])\.env\.(example|sample|template)([[:space:]\"']|\$)#\1\3#")
    [ "$NEW" = "$STRIPPED" ] && break
    STRIPPED="$NEW"
  done
  if printf '%s' "$STRIPPED" | grep -qiE 'git add.*((^|[/[:space:]])secrets-|\.env(rc|s)?([^[:alnum:]]|$)|copilot_homelab|\.pem([^[:alnum:]]|$)|credentials([^[:alnum:]]|$))'; then
    # Best-effort tripwire — .gitignore is the real control. Template basenames pass THIS
    # hook; whether they actually stage depends on the repo's .gitignore (commonly only
    # `.env.example` is un-ignored via `!.env.example`, so `.env.sample`/`.env.template`
    # may still be ignored by git even though this hook permits them). cc#416 finding #3.
    echo "Blocked: refusing to stage a likely secret file (secrets-*, .env*, .pem, credentials). Best-effort tripwire — .gitignore is the real control. Template basenames (.env.example/.sample/.template) pass this hook, but git may still ignore them per your .gitignore (typically only .env.example is un-ignored)." >&2
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
