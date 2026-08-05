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
#
# KNOWN RESIDUALS deferred to cc#418 (cc#417 T3 panel — documented gaps, NOT accidents; this is a
# best-effort tripwire, .gitignore is the real control): command-position anchoring (a `git add`
# inside a quoted literal / `echo 'git add .env'` still false-blocks; a secret named after `;&|` in
# a compound is handled, but a per-segment `-C` in a multi-invocation chain resolves the LAST one);
# global options before the subcommand (`git -c x=y add`, `--git-dir=`); bulk forms `git add *`
# / `:/` / `..` / combined-flag `-Af` / forced `git add -f -A` (stages *ignored* files, invisible to
# the untracked scan); the push guards' own quoted-literal / `git -C repo push` gaps; and a two-tier
# `permissionDecision:"ask"` escape hatch for low-confidence classes. See cc#418.
export LC_ALL=C
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')

# ─── The secret-filename alternation (single source of truth) ────────────────
# One SECRET_RE var, reused by the string-detect grep AND the bulk-add untracked scan (cc#417) so
# the two paths can never drift. Most alternatives are bounded by `([^[:alnum:]]|$)` (a filename
# merely CONTAINING the substring is NOT blocked); the common-word tokens `.key` and the `id_*`
# SSH keys are END-anchored (`([[:space:]"']|$)`) instead — see below.
#
#   (^|[/[:space:]])secrets-  — path-token start (secrets-*.env, config/secrets-x, root-level add).
#         Un-blocks a filename that merely contains `-secrets-` (check-required-secrets-test.sh).
#   \.env(rc|s)?([^[:alnum:]]|$)  — .env / .env.local / secrets.env / .envrc / .envs/; un-blocks
#         .envelope / .environment (ADM #1666/#1667).
#   copilot_homelab  — literal SSH key name.
#   \.pem / credentials  — bounded (cc#416, ADM #1667 panel): un-blocks credentialsProvider.ts /
#         x.pemander.ts; still blocks server.pem, credentials.json, .git-credentials (the
#         `credentials` substring at EOL), server.pem.bak, bare credentials. TRADEOFF (GPT-F3):
#         character-based not semantic — a credentials<ALNUM> name is an accepted false-NEGATIVE.
#         NOTE (kimi-F4): a token+DOT name (crypto.pem.test.ts) STAYS blocked — structurally ==
#         credentials.json, so no BOUNDED pattern can un-block it without un-blocking a real secret.
#   id_(rsa|dsa|ed25519|ecdsa)([[:space:]"']|$)  — SSH private keys (cc#417). END-anchored (EOL /
#         whitespace / quote) NOT `([^[:alnum:]]|$)`: a private key filename is EXACTLY `id_rsa` with
#         no extension, so end-anchoring blocks it while EXEMPTING the matching PUBLIC key
#         `id_rsa.pub` (a `.` after id_rsa → not blocked). Public keys are safe to commit; the
#         cc#417 panel (gpt-F8) flagged the .pub over-block. Accepted false-neg: `id_rsa_backup`
#         (underscore after) is not blocked — rare; .gitignore is the real control.
#   \.key([[:space:]"']|$)  — TLS/PEM private keys (server.key, certs/tls.key). END-anchored, NOT
#         `([^[:alnum:]]|$)`: "key" is a COMMON word, so a `.key.<ext>` MIDDLE token (i18n.key.ts,
#         bpy.types.Key.rst, cache.key.json) is a routine non-secret. cc#417 panel (gpt-F8/x-ai) +
#         empirical fleet hits confirmed this over-block. End-anchoring blocks `X.key` (real keys end
#         there) but allows `.key.<ext>`. Accepted false-neg: `server.key.bak` (dot after) unblocked.
#   \.(p12|pfx|ppk|keystore|jks|htpasswd|pgpass|netrc|tfstate|pypirc)([^[:alnum:]]|$)  — PKCS12 /
#         PuTTY keys, Java/Android keystores, htpasswd/pgpass/netrc credential files, Terraform
#         STATE (.tfstate — plaintext resolved secrets, always gitignored), pypi token (.pypirc).
#         Accepted safe-direction over-blocks: a committed Android debug.keystore, a test *.jks.
#   EXCLUDED by design: `.npmrc` — a committed .npmrc is usually legitimate config (registry/engine
#         flags); empirically the fleet commits one (lokalmeny site/.npmrc). The auth-token case is
#         left to .gitignore. `.tfvars` — DROPPED (cc#417 panel, ≥3 reviewers): commonly committed
#         as ordinary non-secret Terraform config; hard-blocking it erodes trust. Same rationale as
#         .npmrc; the secret-tfvars case is .gitignore's job.
SECRET_RE='(^|[/[:space:]])secrets-|\.env(rc|s)?([^[:alnum:]]|$)|copilot_homelab|\.pem([^[:alnum:]]|$)|credentials([^[:alnum:]]|$)|id_(rsa|dsa|ed25519|ecdsa)([[:space:]"'"'"']|$)|\.key([[:space:]"'"'"']|$)|\.(p12|pfx|ppk|keystore|jks|htpasswd|pgpass|netrc|tfstate|pypirc)([^[:alnum:]]|$)'

# ─── The `git add`/`git stage` invocation anchor ─────────────────────────────
# `git([[:space:]]+-C[[:space:]]+<dir>)?[[:space:]]+(add|stage)` recognises the staging subcommand
# even when it is (cc#417): the `stage` synonym, preceded by the global `-C <dir>` flag, or written
# with extra whitespace INCLUDING TABS (`[[:space:]]+`, not ` +` — kimi-F6). It does NOT match
# `add`/`stage` as a WORD elsewhere (git commit -m "add the .env note") because the subcommand must
# sit immediately after `git ` / `git -C <dir> `. `[^;&|]+` for the -C value stays in the segment.
GIT_ADD_ANCHOR='git([[:space:]]+-C[[:space:]]+[^;&|]+)?[[:space:]]+(add|stage)'

# ─── Detection 1: an explicit secret FILENAME in a git add/stage command ─────
# `[^;&|]*` (NOT `.*`, cc#417 kimi-F1 / cc#334 precedent): the secret must be in the SAME command
# segment as the staging subcommand, so `git add -A && git commit -m "explain .env"` does NOT block
# on the secret appearing in the COMMIT MESSAGE. Templates (.env.example/.sample/.template) allowed.
# Detection is case-INSENSITIVE (-qiE, kimi-F1): macOS/BSD ship a case-insensitive filesystem, so
# `git add KEY.PEM` / `Credentials.json` must block.
if printf '%s' "$COMMAND" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*(${SECRET_RE})"; then
  # Strip EXACT template basename tokens (.env.example/.env.sample/.env.template), bounded on BOTH
  # sides — leading (^|space|/) and trailing (space|quote|EOL) — looping so ADJACENT templates both
  # strip. Only a complete basename token is removed, never the substring inside a longer name
  # (cc#416 panel F1/F2): .env.example.bak / prod.env.example / .env.exampleSecret all STAY blocked.
  # printf '%s' (not echo) avoids -n/-e/backslash mangling. Strip is case-SENSITIVE so .env.SAMPLE
  # is NOT stripped → stays blocked (safe direction).
  STRIPPED="$COMMAND"
  while :; do
    NEW=$(printf '%s' "$STRIPPED" | sed -E "s#(^|[[:space:]/])\.env\.(example|sample|template)([[:space:]\"']|\$)#\1\3#")
    [ "$NEW" = "$STRIPPED" ] && break
    STRIPPED="$NEW"
  done
  if printf '%s' "$STRIPPED" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*(${SECRET_RE})"; then
    # Best-effort tripwire — .gitignore is the real control. Template basenames pass THIS hook;
    # whether they actually stage depends on the repo's .gitignore (cc#416 finding #3).
    echo "Blocked: refusing to stage a likely secret file (secrets-*, .env*, .pem, credentials, SSH/TLS/keystore keys, .tfstate). Best-effort tripwire — .gitignore is the real control. Template basenames (.env.example/.sample/.template) pass this hook, but git may still ignore them per your .gitignore (typically only .env.example is un-ignored)." >&2
    exit 2
  fi
fi

# ─── Detection 1c: bulk-add (-A / --all / bare . / ./) — no filename in string ─
# `git add -A|--all|.` stages untracked files without naming them, so Detection 1 cannot see the
# secret. Scan the repo with `git ls-files -o --exclude-standard -z` (cc#417, kimi-F12): lists
# UNTRACKED, non-ignored files, is LOCK-FREE (no index refresh like `git status`, so no fsmonitor /
# NFS stall and no lock contention), and `-z` emits raw NUL-delimited paths (no display-quoting of
# odd names — gpt-F10). Block only if a secret-named untracked file is present. `-u`/`-am` are NOT
# covered — they stage only already-tracked changes, never a NEW untracked secret. gitignored files
# are excluded (--exclude-standard), so a correctly-ignored secret never false-blocks. FAIL-OPEN:
# not-a-repo / no-git / timeout → allow. Trailing boundary `([[:space:];&|]|$)` (kimi-F3) so
# `git add -A;cmd` is still recognised.
BULK_RE="${GIT_ADD_ANCHOR}"'[^;&|]*[[:space:]](-A|--all|\.(/)?)([[:space:];&|]|$)'
if printf '%s' "$COMMAND" | grep -qiE "$BULK_RE"; then
  # Resolve the target repo the way the real command would: base at the tool cwd, then apply the
  # command's own `-C <dir>` (git chains -C; a relative -C resolves against the base). NOTE (cc#418):
  # a greedy last-`-C` extraction — one bulk-add invocation per command assumed.
  CDIR=$(printf '%s' "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
  LS=(ls-files -o --exclude-standard -z)
  # An EXPLICIT pathspec is required: `git ls-files` from a subdir implicitly scopes to that subdir,
  # but `git add -A`/`--all` stage REPO-WIDE regardless of cwd — use `:/` (repo-root magic pathspec)
  # so a subdir `git add -A` still sees a root secret (else: false-negative). A bare `.`/`./` add IS
  # cwd-scoped, so scope the scan to `.` — a secret ELSEWHERE in the repo must not block a
  # `cd sub && git add .` that could never stage it (kimi-F5).
  if printf '%s' "$COMMAND" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*[[:space:]](-A|--all)([[:space:];&|]|$)"; then
    LS+=(-- :/)
  else
    LS+=(-- .)
  fi
  GB=(git -C "$CWD"); [ -n "$CDIR" ] && GB+=(-C "$CDIR")
  TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 3)
  # Pipe the -z output straight through tr → grep; do NOT capture via $(...). Command substitution
  # STRIPS NUL bytes, which both defeats `tr '\0' '\n'` AND concatenates adjacent filenames — a
  # false-negative: `.env\0app.ts` becomes `.envapp.ts`, and the bounded `.env` no longer matches.
  # FAIL-OPEN: if git errors/times out, grep sees nothing → exit 1 → no block.
  if "${TO[@]}" "${GB[@]}" "${LS[@]}" 2>/dev/null | tr '\0' '\n' | grep -qiE "$SECRET_RE"; then
    echo "Blocked: bulk 'git add' (-A/--all/.) would stage an UNTRACKED secret-named file (secrets-*, .env*, .pem, credentials, SSH/TLS/keystore keys, .tfstate). Best-effort tripwire — .gitignore is the real control. To proceed: add the file to .gitignore (if it is a real secret) or remove it from the working tree. Renaming will not help — an explicit 'git add <name>' of the same file is blocked too." >&2
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
# (cc#418 residual: a `git push` inside a quoted literal still false-fires; `git -C repo push`
#  bypasses — both deferred to the shared-anchor refactor.)
if printf '%s' "$COMMAND" | grep -qE 'git push[^;&|]*(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))'; then
  echo "Blocked: force push (--force / -f) not allowed. Use --force-with-lease for rebase-and-push on feature branches." >&2
  exit 2
fi

# Block refspec force-push to main/master regardless of form.
# Matches `+main`, `+master`, `+<src>:main`, `+<src>:master`, `+refs/heads/main`, etc.
# Same `[^;&|]*` command-segment scoping as the force-flag check above (cc#334).
if printf '%s' "$COMMAND" | grep -qE 'git push[^;&|]*\+([^[:space:]]*:)?(refs/heads/)?(main|master)([[:space:]]|$|:)'; then
  echo "Blocked: refspec force-push to main/master not allowed." >&2
  exit 2
fi

# Block dangerous rm targets. Uses [[:space:]] (NOT `\s` — a GNU-grep extension that is DEAD on
# macOS/BSD grep, silently disabling this guard on the exact fleet the case-insensitivity comment
# targets — cc#417 kimi-F7). Matches -rf / -fr / -r -f / -f -r flag forms, and $HOME / ${HOME}.
# The `\$\{?HOME\}?` is a LITERAL regex token matching the string `$HOME`/`${HOME}` (single quotes
# correct → SC2016 false positive).
# shellcheck disable=SC2016
if printf '%s' "$COMMAND" | grep -qE 'rm[[:space:]]+(-[[:alpha:]]*[rR][[:alpha:]]*f|-[[:alpha:]]*f[[:alpha:]]*[rR]|-[rR][[:space:]]+-f|-f[[:space:]]+-[rR])[[:space:]]+(/|~|\$\{?HOME\}?)'; then
  echo "Blocked: dangerous rm -rf target." >&2
  exit 2
fi

exit 0
