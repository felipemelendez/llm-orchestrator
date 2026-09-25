#!/usr/bin/env bash
# cadence-ruling.sh — apply an agreed rule change as the next numbered ruling.
#
#   cadence-ruling.sh [--root <dir>] <patch-file> "<wording>"
#
# The person runs this in their own terminal. It applies the patch (made with
# `git diff`) to the protected files, re-records LOCK.sha256, and commits with
# the message "Ruling <N>: <wording>", where N is one more than the highest
# ruling in LAWS.md. The patch must add that ruling to LAWS.md. It asks for a
# typed confirmation on /dev/tty, which a shell with no terminal cannot open.
# Exit 0 when the ruling is committed, 1 when it is refused or undone.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/orch-cadence-check.sh"
LOCK_REL='docs/llm-orchestrator/LOCK.sha256'
LAWS_REL='docs/llm-orchestrator/LAWS.md'
SEC_START='<!-- ORCH:LAWS:START -->'
SEC_END='<!-- ORCH:LAWS:END -->'

STATE=checking
WORK=""
TOUCHED=""
BASE=""

say() { printf '%s\n' "$*"; }
refuse() { say "ruling refused: $1"; exit 1; }

# Put every touched file and the lock back to HEAD. Safe because the command
# refuses to start unless those files already match HEAD.
undo() {
  local f bad=""
  if [ -n "$BASE" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$BASE" ]; then
    git reset -q --soft "$BASE" || bad=" HEAD (it should be $BASE)"
  fi
  for f in $TOUCHED "$LOCK_REL"; do
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
      git checkout -q HEAD -- "$f" 2>/dev/null || bad="$bad $f"
    else
      git rm -q -f --cached --ignore-unmatch -- "$f" >/dev/null 2>&1 || bad="$bad $f"
      rm -f -- "$f" || bad="$bad $f"
    fi
  done
  if [ -n "$bad" ]; then
    say "ruling NOT undone: these files may still be changed or staged:$bad"
    say "Compare them with HEAD (git status, git diff HEAD) before doing anything else."
  else
    say "The change was undone; nothing changed."
  fi
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$STATE" = applied ]; then undo; rc=1; fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  exit "$rc"
}
trap finish EXIT
trap 'say ""; say "ruling stopped: interrupted."; exit 130' INT TERM

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }

# The file on stdin with its marked section replaced by one placeholder line.
outside_section() {
  awk -v s="$SEC_START" -v e="$SEC_END" '
    p == 0 && index($0, s) { print "@@ORCH:LAWS@@"; p = index($0, e) ? 2 : 1; next }
    p == 1 { if (index($0, e)) p = 2; next }
    { print }'
}

in_list() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# ---------- arguments ---------------------------------------------------------
ROOT=""
if [ "${1:-}" = "--root" ]; then ROOT="${2:-}"; shift 2; fi
[ $# -eq 2 ] || { say "usage: cadence-ruling.sh [--root <dir>] <patch-file> \"<wording>\""; exit 1; }
PATCH_IN="$1"; WORDING="$2"
[ -f "$PATCH_IN" ] || refuse "no patch file at $PATCH_IN"
[ -n "$WORDING" ] || refuse "the wording is empty"
case "$WORDING" in *$'\n'*) refuse "the wording must be one line" ;; esac

# ---------- only a person, in a terminal --------------------------------------
# Claude Code sets CLAUDECODE in its shells. The Codex names come from the
# Codex binary's strings; they were not observed in a live Codex shell.
for v in CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED; do
  [ -n "${!v:-}" ] && refuse "$v is set, so this shell belongs to an agent session. Run the command in your own terminal."
done
{ exec 3</dev/tty; } 2>/dev/null || refuse "no terminal. Run this command yourself, in your own terminal."

# ---------- the project -------------------------------------------------------
if [ -n "$ROOT" ]; then
  ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || refuse "cannot enter the --root directory"
else
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not inside a git repository"
fi
# A private copy, so the patch cannot change between the check and the apply.
WORK=$(mktemp -d) || refuse "cannot create a temporary directory"
chmod 700 "$WORK"
PATCH="$WORK/change.patch"
cp "$PATCH_IN" "$PATCH" || refuse "cannot copy $PATCH_IN"
PATCH_SHA=$(sha "$PATCH")
cd "$ROOT" || refuse "cannot enter $ROOT"

git show "HEAD:$LOCK_REL" > "$WORK/lock" 2>/dev/null || refuse "no $LOCK_REL is committed at HEAD, so there is no lock to amend"
ENTRIES=$( { bash "$CHECK" --root "$ROOT" --entries; awk '{ sub(/\r$/, ""); print substr($0, 67) }' "$WORK/lock"; } | grep -v '^$' | sort -u)
WHOLE=$(printf '%s\n' "$ENTRIES" | grep -v '#ORCH:LAWS$')
SECTIONS=$(printf '%s\n' "$ENTRIES" | grep '#ORCH:LAWS$' | sed 's/#ORCH:LAWS$//')

# ---------- what the patch touches --------------------------------------------
# Every file header must name one path on both sides: a rename or a copy is
# refused, and so is any part of the patch that has no git header.
HEADERS=$(awk '
  /^diff --git / {
    if (match($0, /^diff --git a\/[^ ]+ b\//) && substr($0, RLENGTH + 1) == substr($0, 14, RLENGTH - 16)) print substr($0, RLENGTH + 1)
    else print "BAD " $0
    next }
  /^(rename|copy) (from|to) / { print "BAD " $0 }' "$PATCH")
[ -n "$HEADERS" ] || refuse "the patch has no git file headers. Make it with git diff."
BADLINE=$(printf '%s\n' "$HEADERS" | grep '^BAD ' | head -1)
[ -z "$BADLINE" ] || refuse "the patch renames, copies or names two different paths: ${BADLINE#BAD }"
TOUCHED=$(printf '%s\n' "$HEADERS" | sort -u)
NUMSTAT=$(git apply --numstat "$PATCH" 2>/dev/null | cut -f3-) || refuse "git cannot read the patch"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  in_list "$f" "$TOUCHED" || refuse "the patch changes $f without a git file header"
done <<< "$NUMSTAT"
while IFS= read -r f; do
  [ "$f" = "$LOCK_REL" ] && refuse "the patch changes $LOCK_REL; this command re-records the lock itself"
  in_list "$f" "$WHOLE" || in_list "$f" "$SECTIONS" \
    || refuse "the patch changes $f, which is not a protected file"
done <<< "$TOUCHED"

# ---------- the tree must match HEAD ------------------------------------------
git diff --cached --quiet || refuse "changes are already staged. Commit or unstage them first."
PFILES=$(printf '%s\n' "$WHOLE" "$SECTIONS" "$LOCK_REL" | grep -v '^$' | sort -u)
# shellcheck disable=SC2086
DIRTY=$(git diff --name-only HEAD -- $PFILES)
# shellcheck disable=SC2086
[ -z "$DIRTY" ] || refuse "these protected files differ from HEAD: $(printf '%s ' $DIRTY)— commit or restore them first"

# ---------- the result, checked in a scratch index ----------------------------
export GIT_INDEX_FILE="$WORK/index"
git read-tree HEAD || refuse "cannot read HEAD"
git apply --cached "$PATCH" 2>/dev/null || refuse "the patch does not apply to the current files. Ask for a patch made against them."
HIGH=$(git show "HEAD:$LAWS_REL" 2>/dev/null | grep -oE 'Ruling [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
N=$(( ${HIGH:-0} + 1 ))
git show ":$LAWS_REL" 2>/dev/null | grep -qE "Ruling ${N}([^0-9]|$)" \
  || refuse "the patch does not add Ruling $N to $LAWS_REL"
while IFS= read -r f; do
  { in_list "$f" "$SECTIONS" && ! in_list "$f" "$WHOLE"; } || continue
  # A file new to HEAD may hold nothing but its marked section.
  if git cat-file -e "HEAD:$f" 2>/dev/null; then before=$(git show "HEAD:$f" | outside_section); else before="@@ORCH:LAWS@@"; fi
  if [ "$before" != "$(git show ":$f" 2>/dev/null | outside_section)" ]; then
    refuse "the patch changes $f outside its marked section, which is not a rule change"
  fi
done <<< "$TOUCHED"
unset GIT_INDEX_FILE

# ---------- confirm, apply, re-lock, commit -----------------------------------
say "Ruling $N: $WORDING"
say "patch sha256 $PATCH_SHA (a private copy of $PATCH_IN)"
git apply --stat "$PATCH"
printf 'Type "ruling %s" to apply this change, re-record the lock and commit: ' "$N"
IFS= read -r ANSWER <&3 || ANSWER=""
[ "$ANSWER" = "ruling $N" ] || refuse "the confirmation did not match. Nothing changed."

BASE=$(git rev-parse HEAD)
STATE=applied
git apply --index "$PATCH" || refuse "the patch did not apply."
bash "$CHECK" --root "$ROOT" --lock || refuse "the lock could not be re-recorded."
git add -- "$LOCK_REL" || refuse "the lock could not be staged."
git commit -q -m "Ruling $N: $WORDING" || refuse "the commit was refused."
if ! bash "$CHECK" --root "$ROOT" --audit HEAD > "$WORK/audit" 2>&1; then
  cat "$WORK/audit"
  refuse "the commit fails --audit, so it is being taken back."
fi
STATE=committed
say "Ruling $N committed as $(git rev-parse --short HEAD)."
