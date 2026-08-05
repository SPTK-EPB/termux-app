#!/bin/bash
# Hook: PreToolUse for Bash — block dangerous commands.
# Shared pattern across all SPTK projects.
#
# CC-owned FLEET hook (cc#327): this CC-home copy at ~/.claude/hooks/validate-bash.sh
# is the CANONICAL source. scaffold-new-repo.sh pulls it into new repos, and
# propagate-fleet-hook.sh --hook validate-bash.sh re-syncs existing repos from it.
# Edit HERE, not per-repo.
#
# cc#418 ARCHITECTURE: segment-split + command-position dispatch (was: whole-string grep).
# The command is split into shell segments (quote-aware). Each segment is classified:
#   • UNCERTAIN (unbalanced quotes / contains $() or backtick / command-token is a shell-runner like
#     bash/sh/eval/source/xargs) → run the LEGACY whole-string checks on the segment. This can only
#     BLOCK on a proven pattern, so it is never WORSE than the pre-cc#418 hook, and it preserves the
#     exotic true-positives (`bash -c 'git add .env'`, `$(git push --force)`) that command-position
#     anchoring would otherwise turn into false-negatives (cc#418 panel kimi-F2).
#   • CLEAN → command-position token dispatch. A `git`/`*/git` token → anchor-free git checks (the
#     subcommand is parsed from argv, so `git -c k=v add`, `git --git-dir=… add`, `git -C repo push
#     --force` are now caught — cc#418 gpt#1/kimi-F1). An `rm` token → the rm-danger check. ANY other
#     token (echo/printf/cat/…) → SKIP: this is the false-positive fix — `echo 'git add .env'` and
#     `git commit -m "…git push --force…"` no longer false-block (cc#418 gpt#2/gpt#8).
# The refactor is strictly COVERAGE-PRESERVING: the only behavior CHANGES vs the old hook are the
# intended FP removals on clean non-git/non-push segments (verified by a differential harness that
# diffs old-hook vs new-hook decisions over a corpus).
#
# Portability: bash 3.2-compatible (no ${v,,}, no associative arrays, no 4.x-isms) and BSD/macOS-grep
# safe (no `\s`; [[:space:]]/[[:alnum:]] pinned to ASCII by LC_ALL=C). FAIL-OPEN: if jq is ABSENT the
# hook allows (empty COMMAND → exit 0) — acceptable for a best-effort tripwire; .gitignore is the real
# control.
#
# KNOWN RESIDUALS deferred to a cc#418 follow-up (documented gaps, NOT accidents):
#   • Forced-bulk IGNORED scan: `git add -f -A` staging a *gitignored* secret is still invisible (the
#     porcelain scan uses --exclude-standard). The correct fix is a glob-targeted `git ls-files -o -i`
#     which needs a SECRET_GLOBS parity list; deferred.
#   • cd/pushd tracking: `cd repo && git add -A` scans the tool cwd, not `repo`.
#   • Bulk forms `git add *` and `git add ..` are NOT treated as bulk (FP-edge / rare).
#   • Wrappers with flags (`sudo -u x git`, `nice -n 5 git`) are not stripped → false-negative.
#   • Escape-hatch `permissionDecision:"ask"` tier and file-CONTENT secret detection: separate surfaces.
export LC_ALL=C
IFS=$' \t\n'                    # pin field-splitting (a caller's exotic IFS must not desync tokenizing)
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# char-walk is O(n^2) in pure bash (~62ms@2000, ~216ms@4000, ~800ms@8000 chars); a command longer
# than this falls back to the O(n) whole-string legacy grep (correct, just less precise anchoring).
MAXLEN=4000

# ─── The secret-filename alternation (single source of truth) ────────────────
# Reused by the CLEAN git-add check, the LEGACY backstop, AND the bulk porcelain scan so the paths
# can never drift. Most alternatives are bounded by ([^[:alnum:]]|$); common-word `.key` and the
# `id_*` SSH keys are END-anchored ([[:space:]"']|$). See cc#416/cc#417 for the full rationale.
SECRET_RE='(^|[/[:space:]])secrets-|\.env(rc|s)?([^[:alnum:]]|$)|copilot_homelab|\.pem([^[:alnum:]]|$)|credentials([^[:alnum:]]|$)|id_(rsa|dsa|ed25519|ecdsa)([[:space:]"'"'"']|$)|\.key([[:space:]"'"'"']|$)|\.(p12|pfx|ppk|keystore|jks|htpasswd|pgpass|netrc|tfstate|pypirc)([^[:alnum:]]|$)'

# git add/stage anchor + force/refspec/rm patterns — used by the LEGACY backstop (whole-string).
GIT_ADD_ANCHOR='git([[:space:]]+-C[[:space:]]+[^;&|]+)?[[:space:]]+(add|stage)'
FORCE_RE='git push[^;&|]*(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))'
REFSPEC_RE='git push[^;&|]*\+([^[:space:]]*:)?(refs/heads/)?(main|master)([[:space:]]|$|:)'
RM_RE='rm[[:space:]]+(-[[:alpha:]]*[rR][[:alpha:]]*f|-[[:alpha:]]*f[[:alpha:]]*[rR]|-[rR][[:space:]]+-f|-f[[:space:]]+-[rR])[[:space:]]+(/|~|\$\{?HOME\}?)'
# Anchor-FREE force/refspec (run on parsed `git push` args in the clean dispatch — gpt#1/kimi-F1):
FORCE_ARGS_RE='(--force([^-]|$)|(^|[[:space:]])-f([[:space:]]|$))'
REFSPEC_ARGS_RE='\+([^[:space:]]*:)?(refs/heads/)?(main|master)([[:space:]]|$|:)'

MSG_SECRET="Blocked: refusing to stage a likely secret file (secrets-*, .env*, .pem, credentials, SSH/TLS/keystore keys, .tfstate). Best-effort tripwire — .gitignore is the real control. Template basenames (.env.example/.sample/.template) pass this hook, but git may still ignore them per your .gitignore (typically only .env.example is un-ignored)."
MSG_BULK="Blocked: bulk 'git add' (-A/--all/.) would stage an UNTRACKED secret-named file (secrets-*, .env*, .pem, credentials, SSH/TLS/keystore keys, .tfstate). Best-effort tripwire — .gitignore is the real control. To proceed: add the file to .gitignore (if it is a real secret) or remove it from the working tree. Renaming will not help — an explicit 'git add <name>' of the same file is blocked too."
MSG_FORCE="Blocked: force push (--force / -f) not allowed. Use --force-with-lease for rebase-and-push on feature branches."
MSG_REFSPEC="Blocked: refspec force-push to main/master not allowed."
MSG_RM="Blocked: dangerous rm -rf target."

# ─── Template-basename strip (loop to fixpoint) ──────────────────────────────
# Removes EXACT .env.example/.sample/.template basename tokens, bounded on both sides, so a template
# passes while .env.example.bak / prod.env.example / .env.exampleSecret STAY blocked. Case-sensitive.
strip_templates() {
  local s="$1" new
  while :; do
    new=$(printf '%s' "$s" | sed -E "s#(^|[[:space:]/])\.env\.(example|sample|template)([[:space:]\"']|\$)#\1\3#")
    [ "$new" = "$s" ] && break
    s="$new"
  done
  printf '%s' "$s"
}

# ─── Bulk porcelain scan ─────────────────────────────────────────────────────
# scan_untracked <base_cwd> <pathspec> [extra -C values...] → exit 0 if a secret-named UNTRACKED
# (non-ignored) file is present under the pathspec, else 1. LOCK-FREE (`git ls-files -o`), -z-robust
# (pipe straight to tr; never $() which strips NULs — cc#417), FAIL-OPEN on any git error/timeout.
scan_untracked() {
  local base="$1" pathspec="$2"; shift 2
  local -a gb=(git -C "$base") v
  for v in "$@"; do gb+=(-C "$v"); done
  local -a to=()
  if command -v timeout >/dev/null 2>&1; then to=(timeout 3)
  elif command -v gtimeout >/dev/null 2>&1; then to=(gtimeout 3); fi   # macOS+brew coreutils (qwen)
  "${to[@]}" "${gb[@]}" ls-files -o --exclude-standard -z -- "$pathspec" 2>/dev/null | tr '\0' '\n' | grep -qiE "$SECRET_RE"
}

# ─── LEGACY whole-string checks (backstop for UNCERTAIN segments) ────────────
# Exactly the pre-cc#418 detection logic, run on one segment (or the whole COMMAND on length-cap /
# global unbalanced quotes). Exits 2 to BLOCK. Greedy last-`-C` bulk resolution = legacy semantics.
run_legacy() {
  local text="$1" cwd="$2" stripped cdir pathspec
  if printf '%s' "$text" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*(${SECRET_RE})"; then
    stripped=$(strip_templates "$text")
    if printf '%s' "$stripped" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*(${SECRET_RE})"; then echo "$MSG_SECRET" >&2; exit 2; fi
  fi
  local BULK_RE="${GIT_ADD_ANCHOR}"'[^;&|]*[[:space:]](-A|--all|\.(/)?)([[:space:];&|]|$)'
  if printf '%s' "$text" | grep -qiE "$BULK_RE"; then
    cdir=$(printf '%s' "$text" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+).*/\1/p' | head -1)
    if printf '%s' "$text" | grep -qiE "${GIT_ADD_ANCHOR}[^;&|]*[[:space:]](-A|--all)([[:space:];&|]|$)"; then pathspec=':/'; else pathspec='.'; fi
    if [ -n "$cdir" ]; then scan_untracked "$cwd" "$pathspec" "$cdir" && { echo "$MSG_BULK" >&2; exit 2; }
    else scan_untracked "$cwd" "$pathspec" && { echo "$MSG_BULK" >&2; exit 2; }; fi
  fi
  printf '%s' "$text" | grep -qE "$FORCE_RE" && { echo "$MSG_FORCE" >&2; exit 2; }
  printf '%s' "$text" | grep -qE "$REFSPEC_RE" && { echo "$MSG_REFSPEC" >&2; exit 2; }
  printf '%s' "$text" | grep -qE "$RM_RE" && { echo "$MSG_RM" >&2; exit 2; }
  return 0
}

# ─── Quote-aware segment splitter ────────────────────────────────────────────
# Splits on TOP-LEVEL (unquoted) operators ; && || | & and newline, tracking '…' and "…" so an
# operator INSIDE quotes does not split. Redirect operators >& <& &> |& are not treated as splits.
# Populates SEGS[] and sets SPLIT_UNBALANCED=1 if a quote is left open (→ whole-string legacy path).
SEGS=(); SPLIT_UNBALANCED=0
split_segments() {
  local s="$1" n i ch nx pv cur="" q="" esc=0
  n=${#s}; i=0; SEGS=()
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    # Backslash escape (gemini#2): outside quotes and inside "…", a \ makes the next char literal, so
    # \" does not close a double-quote and \& / \' do not split/open — preventing a spurious
    # unbalanced-quote fallback that would re-FP `echo "… \"… git add .env"`. Single-quote has no
    # escape in shell, so \ inside '…' is left literal (esc not set there).
    if [ "$esc" -eq 1 ]; then cur+="$ch"; esc=0; i=$((i+1)); continue; fi
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$ch" = "\\" ]; then cur+="$ch"; esc=1; i=$((i+1)); continue; fi
      cur+="$ch"; [ "$ch" = "$q" ] && q=""; i=$((i+1)); continue
    fi
    if [ "$ch" = "\\" ]; then cur+="$ch"; esc=1; i=$((i+1)); continue; fi
    case "$ch" in "'"|'"') q="$ch"; cur+="$ch"; i=$((i+1)); continue ;; esac
    nx="${s:$((i+1)):1}"; pv=""; [ "$i" -gt 0 ] && pv="${s:$((i-1)):1}"
    # redirects: >& <& &>  and the pipe-both |&  → do NOT split
    if [ "$ch" = "&" ] && [ "$nx" = ">" ]; then cur+="$ch"; i=$((i+1)); continue; fi          # &>
    if [ "$ch" = "&" ] && { [ "$pv" = ">" ] || [ "$pv" = "<" ]; }; then cur+="$ch"; i=$((i+1)); continue; fi  # >& <&
    if [ "$ch" = "&" ] && [ "$nx" = "&" ]; then SEGS+=("$cur"); cur=""; i=$((i+2)); continue; fi   # &&
    if [ "$ch" = "|" ] && [ "$nx" = "&" ]; then SEGS+=("$cur"); cur=""; i=$((i+2)); continue; fi   # |&  (pipe)
    if [ "$ch" = "|" ] && [ "$nx" = "|" ]; then SEGS+=("$cur"); cur=""; i=$((i+2)); continue; fi   # ||
    if [ "$ch" = ";" ] || [ "$ch" = "|" ] || [ "$ch" = "&" ] || [ "$ch" = $'\n' ]; then SEGS+=("$cur"); cur=""; i=$((i+1)); continue; fi
    cur+="$ch"; i=$((i+1))
  done
  SEGS+=("$cur")
  [ -n "$q" ] && SPLIT_UNBALANCED=1
}

# ─── Command-position token of a CLEAN segment ───────────────────────────────
# Strips (to fixpoint) leading whitespace, transparent shell SYNTAX prefixes (! ( { if while until
# then do elif) and leading VAR=value assignments. Sets CMD_TOKEN to the first surviving token's
# basename (so /usr/bin/git → git) and CMD_REST to the segment starting AT that token (so parse_git
# sees `git …` even behind an `if`/`!` prefix). Called directly (NOT in $()) so the globals propagate.
# NOTE: command-EXECUTING wrappers (sudo/time/env/xargs/…) are NOT stripped here — they are routed to
# the legacy backstop by segment_uncertain (they exec their argument, so the inner git/rm must be
# caught the same way `bash -c` is; stripping them would miss the with-flags form `sudo -u x git`).
CMD_TOKEN=""; CMD_REST=""
cmd_token() {
  local s="$1" first
  while :; do
    s="${s#"${s%%[![:space:]]*}"}"
    case "$s" in
      '!'*) s="${s#'!'}"; continue ;;
      '('*) s="${s#'('}"; continue ;;
      '{'*) s="${s#'{'}"; continue ;;
      'if '*|'if	'*)       s="${s#if}"; continue ;;
      'while '*|'while	'*) s="${s#while}"; continue ;;
      'until '*|'until	'*) s="${s#until}"; continue ;;
      'then '*|'then	'*)   s="${s#then}"; continue ;;
      'do '*|'do	'*)       s="${s#do}"; continue ;;
      'elif '*|'elif	'*)   s="${s#elif}"; continue ;;
    esac
    first="${s%%[[:space:]]*}"
    case "$first" in
      [A-Za-z_]*=*) s="${s#"$first"}"; continue ;;                 # VAR=value assignment
    esac
    break
  done
  s="${s#"${s%%[![:space:]]*}"}"
  CMD_REST="$s"
  first="${s%%[[:space:]]*}"
  case "$first" in */*) first="${first##*/}" ;; esac
  CMD_TOKEN="$first"
}

# ─── Is a CLEAN segment UNCERTAIN? (→ legacy backstop) ───────────────────────
# Uses CMD_TOKEN (set by a prior cmd_token call on the same segment) for the shell-runner check.
segment_uncertain() {
  local s="$1" lt
  # shellcheck disable=SC2016  # literal $( and ` in the pattern are intentional, not expansions
  case "$s" in *'$('*|*'`'*) return 0 ;; esac                      # command substitution
  # Leading git-repo-selection env assignment points the real command at a repo the scan can't model
  # (gpt#5) — treat as uncertain so the backstop's named-secret detection still fires and the bulk
  # case fails open (unsupported form) rather than scanning the WRONG repo.
  lt="${s#"${s%%[![:space:]]*}"}"
  case "$lt" in GIT_DIR=*|GIT_WORK_TREE=*|GIT_INDEX_FILE=*|GIT_COMMON_DIR=*) return 0 ;; esac
  # Command-EXECUTING wrappers + shell-runners exec their argument, so a git/rm inside must be caught
  # via the legacy backstop (it can only block on a proven pattern → coverage-preserving). Pure
  # consumers (echo/printf/cat/grep/…) are NOT here → they SKIP (the false-positive fix).
  case "$CMD_TOKEN" in
    -*) return 0 ;;   # a flag as the command token means the strip/parse desynced → backstop (gemini#4)
    bash|sh|dash|zsh|ksh|mksh|eval|source|.|xargs|env|command|exec|sudo|doas|time|timeout|nohup|stdbuf|setsid|ionice|nice|chrt|taskset|watch) return 0 ;;
  esac
  return 1
}

# ─── Quote-aware argv tokenizer (quotes STRIPPED) ────────────────────────────
# `read -r -a` splits on whitespace ignoring quotes, so `git -C "my repo" add` desyncs the subcommand
# and `git add "secrets-keys.txt"` leaves a `"` before `secrets-` that breaks SECRET_RE's leading
# boundary (qwen#1/gemini#3). This walks the string quote-aware and strips the quote chars, so a
# quoted path/operand becomes one clean token. Sets GTOKS[].
GTOKS=()
tokenize() {
  GTOKS=(); local s="$1" n i ch q="" cur="" started=0 esc=0
  n=${#s}; i=0
  while [ "$i" -lt "$n" ]; do
    ch="${s:$i:1}"
    if [ "$esc" -eq 1 ]; then cur+="$ch"; started=1; esc=0; i=$((i+1)); continue; fi
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$ch" = "\\" ]; then esc=1; i=$((i+1)); continue; fi
      if [ "$ch" = "$q" ]; then q=""; started=1; i=$((i+1)); continue; fi
      cur+="$ch"; started=1; i=$((i+1)); continue
    fi
    case "$ch" in
      "'"|'"') q="$ch"; started=1; i=$((i+1)); continue ;;
      \\) esc=1; i=$((i+1)); continue ;;
      ' '|'	')
        [ "$started" -eq 1 ] && { GTOKS+=("$cur"); cur=""; started=0; }
        i=$((i+1)); continue ;;
    esac
    cur+="$ch"; started=1; i=$((i+1))
  done
  [ "$started" -eq 1 ] && GTOKS+=("$cur")
}

# ─── Parse a CLEAN `git` segment's argv ──────────────────────────────────────
# Sets: GIT_SUB (subcommand), GC[] (all -C values, chained), GHAS_A (bulk flag before --), GARGS
# (post-subcommand arg string, for pattern-matching), GOPERANDS[] (non-flag operands).
# NOTE: `-f`/forced-bulk is NOT parsed here — the forced-IGNORED scan is a deferred cc#418 follow-up
# (needs a glob-targeted SECRET_GLOBS list; the naive drop-`--exclude-standard` scan is timeout-holed).
GIT_SUB=""; GC=(); GHAS_A=0; GARGS=""; GOPERANDS=()
parse_git() {
  GIT_SUB=""; GC=(); GHAS_A=0; GARGS=""; GOPERANDS=()
  tokenize "$1"; local -a toks=("${GTOKS[@]}")
  local i=1 n=${#toks[@]} t after_dd=0
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    if [ -z "$GIT_SUB" ]; then
      case "$t" in
        -C)  i=$((i+1)); [ "$i" -lt "$n" ] && GC+=("${toks[$i]}") ;;
        -C*) GC+=("${t#-C}") ;;
        -c)  i=$((i+1)) ;;
        -c*) : ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--super-prefix=*) : ;;
        --git-dir|--work-tree|--namespace|--exec-path|--super-prefix) i=$((i+1)) ;;
        -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks) : ;;
        --) : ;;
        -*) : ;;
        *) GIT_SUB="$t" ;;
      esac
    else
      if [ "$after_dd" -eq 1 ]; then GOPERANDS+=("$t"); GARGS+=" $t"; i=$((i+1)); continue; fi
      case "$t" in
        --) after_dd=1 ;;
        -A|--all) GHAS_A=1 ;;
        -[A-Za-z]*)
          case "$t" in *A*) GHAS_A=1 ;; esac ;;
        -*) : ;;
        *) GOPERANDS+=("$t") ;;
      esac
      GARGS+=" $t"
    fi
    i=$((i+1))
  done
}

# ─── Dispatch a CLEAN `git` segment (anchor-free) ────────────────────────────
git_dispatch() {
  local seg="$1" cwd="$2" stripped op is_bulk pathspec
  parse_git "$seg"
  case "$GIT_SUB" in
    add|stage)
      # Detection 1 (anchor-free): a named secret in the add's args.
      if printf '%s' "$GARGS" | grep -qiE "$SECRET_RE"; then
        stripped=$(strip_templates "$GARGS")
        if printf '%s' "$stripped" | grep -qiE "$SECRET_RE"; then echo "$MSG_SECRET" >&2; exit 2; fi
      fi
      # Bulk? -A/--all (or cluster) → repo-wide; bare . / ./ / :/ operand → scoped.
      is_bulk=0; pathspec=""
      if [ "$GHAS_A" -eq 1 ]; then
        is_bulk=1
        if [ "${#GOPERANDS[@]}" -gt 0 ]; then pathspec="${GOPERANDS[0]}"; else pathspec=':/'; fi
      else
        for op in "${GOPERANDS[@]}"; do
          case "$op" in
            :/) is_bulk=1; pathspec=':/'; break ;;
            .|./) is_bulk=1; pathspec='.'; break ;;
          esac
        done
      fi
      if [ "$is_bulk" -eq 1 ]; then
        if [ "${#GC[@]}" -gt 0 ]; then scan_untracked "$cwd" "$pathspec" "${GC[@]}" && { echo "$MSG_BULK" >&2; exit 2; }
        else scan_untracked "$cwd" "$pathspec" && { echo "$MSG_BULK" >&2; exit 2; }; fi
      fi
      ;;
    push)
      printf '%s' "$GARGS" | grep -qE "$FORCE_ARGS_RE" && { echo "$MSG_FORCE" >&2; exit 2; }
      printf '%s' "$GARGS" | grep -qE "$REFSPEC_ARGS_RE" && { echo "$MSG_REFSPEC" >&2; exit 2; }
      ;;
  esac
}

# ─── Main ────────────────────────────────────────────────────────────────────
# Join backslash-newline line-continuations first (kimi-F2a) so the splitter doesn't sever a git
# invocation from its argument. Global // is O(N) and bash-3.2-safe (gemini#1).
NL=$'\n'; COMMAND="${COMMAND//\\$NL/}"

# Length cap → whole-string legacy path (bounds char-walk latency on pathological input).
if [ "${#COMMAND}" -gt "$MAXLEN" ]; then run_legacy "$COMMAND" "$CWD"; exit 0; fi

split_segments "$COMMAND"
# Global unbalanced quote → segmentation untrustworthy → whole-string legacy path.
if [ "$SPLIT_UNBALANCED" -eq 1 ]; then run_legacy "$COMMAND" "$CWD"; exit 0; fi

for seg in "${SEGS[@]}"; do
  [ -z "${seg//[[:space:]]/}" ] && continue
  cmd_token "$seg"                      # sets CMD_TOKEN + CMD_REST
  if segment_uncertain "$seg"; then
    run_legacy "$seg" "$CWD"
    continue
  fi
  case "$CMD_TOKEN" in
    git) git_dispatch "$CMD_REST" "$CWD" ;;   # CMD_REST starts at the `git` token
    rm)  printf '%s' "$seg" | grep -qE "$RM_RE" && { echo "$MSG_RM" >&2; exit 2; } ;;
    *)   : ;;
  esac
done

exit 0
