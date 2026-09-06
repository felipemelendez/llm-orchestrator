#!/usr/bin/env bash
# LLM Orchestrator — Codex's deny rules for the cadence lock set. Claude Code
# denies the locked FILES natively; Codex has no such rule, so this PreToolUse
# hook (matchers Bash and apply_patch) is that one layer and nothing else: a
# command or a patch header that names a locked file and is not one plain read
# is refused with exit 2 and the way out printed.
# It does NOT guard directories, the marked laws section, links, variables or a
# path assembled at runtime — the alarm names those: the session-start line, the
# end-of-turn verdict, the commit-msg hook, --audit in CI. The accepted cost,
# stated once: with no tokenizer here a locked path inside a pipeline or a
# redirect refuses even as a read (cat <path> | jq .); read it as cat <path>. A
# newline inside the command is an operator like the rest: a multi-line payload
# that names a locked file is refused. With no python3 the command cannot be
# read precisely, so the hook fails closed: the raw payload is searched for the
# locked names and a hit is refused, whatever the verb.
# UNVERIFIED against a live Codex, both kept: whether a PreToolUse hook fires
# inside a Codex subagent, and whether a matcher can be aimed at a patch's
# target path rather than at the tool.
# bash 3.2; never set -e (a non-2 exit reads as a hook error and the tool call
# then runs); every path ends in exit 0 or exit 2.
set -uo pipefail
set -f
export LC_ALL=C
PROJ="${CODEX_PROJECT_DIR:-$PWD}"; PROJ="${PROJ%/}"
CJ="$PROJ/docs/llm-orchestrator/cadence.json"
[ -f "$CJ" ] || exit 0
tr -d '\n' < "$CJ" | grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' || exit 0

# The unlock is honoured from the environment only. A file that persists it is
# a disarmed lock: the unlock stops counting and the refusal says where it is.
PERSIST=""
if [ "${ORCH_CADENCE_UNLOCK:-}" = "1" ]; then
  for f in "${HOME:-}/.codex/config.toml" "$PROJ/.codex/config.toml" "$PROJ/.claude/settings.json"; do
    if [ -f "$f" ] && grep -q ORCH_CADENCE_UNLOCK "$f" 2>/dev/null; then PERSIST="$f"; fi
  done
  [ -n "$PERSIST" ] || exit 0
fi
[ -t 0 ] && exit 0
PAY=$(cat); TOOL=""; TEXT=""; NOPY=""
if command -v python3 >/dev/null 2>&1; then
  DEC=$(printf '%s' "$PAY" | python3 -c 'import json,sys
try: d = json.load(sys.stdin); ti = d["tool_input"]
except Exception: sys.exit(3)
ti = ti if isinstance(ti, dict) else {}
v = ti.get("command") or ti.get("patch") or ""
if isinstance(v, list) and all(isinstance(x, str) for x in v): v = " ".join(v)
sys.stdout.write(str(d.get("tool_name") or "") + "\n" + (v if isinstance(v, str) else json.dumps(v)))') || exit 0
  TOOL=${DEC%%$'\n'*}; TEXT=${DEC#*$'\n'}
else
  NOPY=1; TEXT=$(printf '%s' "$PAY" | tr -d '\n\r')
fi
[ -n "$TEXT" ] || exit 0; TEXTL=$(printf '%s' "$TEXT" | tr 'A-Z' 'a-z')
while case "$TEXTL" in *[$'\n\r']) TEXTL=${TEXTL%?} ;; *) false ;; esac; do :; done
# The lock set: six fixed files plus every lock_extra entry, relative and
# absolute under the project root, matched case-folded as a plain substring so a
# path glued inside an option (curl -o<path>) is caught for free; plus the four
# distinctive basenames, which count only as a whole path component (before:
# start, whitespace, a quote, = or /; after: end, whitespace, a quote or );|&><),
# so outlaws.md and cadence.json.bak are ordinary work — but a quoted word is
# bounded like an operand, so a basename inside a message still counts.
EXTRA=$(tr -d '\n' < "$CJ" | sed -n 's/.*"lock_extra"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '" ' | tr ',A-Z' ' a-z')
PL=$(printf '%s' "$PROJ" | tr 'A-Z' 'a-z'); NEEDLES=()
for r in docs/llm-orchestrator/laws.md docs/llm-orchestrator/cadence.json docs/llm-orchestrator/lock.sha256 \
         .claude/settings.json .githooks/commit-msg .githooks/orch-cadence-check.sh $EXTRA; do
  NEEDLES+=("$r" "$PL/$r")
done
BASE=(laws.md cadence.json lock.sha256 orch-cadence-check.sh); BB=$' \t\n\r\'"=/'; AA=$' \t\n\r\'");|&><'
basehit() { local t=" $1 " n; for n in "${BASE[@]}"; do
  case "$t" in *[$BB]"$n"[$AA]*) HIT="$n"; return 0 ;; esac; done; return 1; }
refuse() {
  printf 'cadence lock: "%s" would change %s, and a change to this file is a ruling, not an edit.\n' "$1" "$2" >&2
  printf 'Read it with one plain command (cat %s) — no pipe, no redirect, nothing else on the line — or start the session with ORCH_CADENCE_UNLOCK=1 in its environment.\n' "$2" >&2
  [ -n "$PERSIST" ] && printf 'The unlock is set, but %s persists it: a persisted unlock is a disarmed lock, so it is not honoured. Pass it per session instead.\n' "$PERSIST" >&2
  [ -n "$NOPY" ] && printf 'python3 is not on the PATH, so this hook cannot read the command precisely; a call that names a locked file is refused — read the file from your own shell, or install python3.\n' >&2
  exit 2
}
if [ "$TOOL" = apply_patch ]; then
  while IFS= read -r ln; do
    ln=${ln#"${ln%%[![:blank:]]*}"}
    case "$ln" in '*** add file:'*|'*** delete file:'*|'*** update file:'*|'*** move to:'*) p=${ln#*: } ;; *) continue ;; esac
    for n in "${NEEDLES[@]}"; do case "$p" in *"$n"*) refuse "${ln%%:*}" "$p" ;; esac; done
    basehit "$p" && refuse "${ln%%:*}" "$p"
  done <<< "$TEXTL"
  exit 0
fi
HIT=""; for n in "${NEEDLES[@]}"; do case "$TEXTL" in *"$n"*) HIT="$n"; break ;; esac; done
[ -n "$HIT" ] || basehit "$TEXTL"
[ -n "$HIT" ] || exit 0
[ -n "$NOPY" ] && refuse "a tool call this hook cannot read" "$HIT"
case "$TEXTL" in *'|'*|*';'*|*'&'*|*'$'*|*'`'*|*'('*|*')'*|*'>'*|*'<'*|*'{'*|*'}'*|*$'\n'*|*$'\r'*) refuse "${TEXTL%% *}" "$HIT" ;; esac
set -- $TEXTL
case " cat head tail less more wc grep egrep fgrep rg diff cmp shasum sha256sum md5 md5sum stat ls file jq " in *" ${1:-} "*) exit 0 ;; esac
[ "${1:-}" = git ] && case " status log diff show blame ls-files cat-file rev-parse grep " in *" ${2:-} "*) exit 0 ;; esac
refuse "${1:-}" "$HIT"
