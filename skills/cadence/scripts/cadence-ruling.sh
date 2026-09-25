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
# Exit 0 when the ruling is committed, 1 when it is refused (nothing changed).
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/orch-cadence-check.sh"
LOCK_REL='docs/llm-orchestrator/LOCK.sha256'
LAWS_REL='docs/llm-orchestrator/LAWS.md'

refuse() { echo "ruling refused: $1"; exit 1; }

ROOT=""
if [ "${1:-}" = "--root" ]; then ROOT="${2:-}"; shift 2; fi
[ $# -eq 2 ] || { echo "usage: cadence-ruling.sh [--root <dir>] <patch-file> \"<wording>\""; exit 1; }
PATCH="$1"; WORDING="$2"
[ -f "$PATCH" ] || refuse "no patch file at $PATCH"
PATCH="$(cd "$(dirname "$PATCH")" && pwd)/$(basename "$PATCH")"
[ -n "$WORDING" ] || refuse "the wording is empty"
case "$WORDING" in *$'\n'*) refuse "the wording must be one line" ;; esac

{ exec 3</dev/tty; } 2>/dev/null || refuse "no terminal. Run this command yourself, in your own terminal."

[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not inside a git repository"
cd "$ROOT" || refuse "cannot enter $ROOT"

git show "HEAD:$LOCK_REL" > /dev/null 2>&1 || refuse "no $LOCK_REL is committed at HEAD, so there is no lock to amend"
PROTECTED=$(git show "HEAD:$LOCK_REL" | awk '{ sub(/\r$/, ""); e = substr($0, 67); sub(/#ORCH:LAWS$/, "", e); print e }')

FILES=$(git apply --numstat "$PATCH" 2>/dev/null | cut -f3-)
[ -n "$FILES" ] || refuse "$PATCH is not a patch git can read"
while IFS= read -r f; do
  printf '%s\n' "$PROTECTED" | grep -qxF -- "$f" || refuse "the patch changes $f, which is not a protected file"
done <<< "$FILES"

git diff --cached --quiet || refuse "changes are already staged. Commit or unstage them first."
git apply --check --index "$PATCH" 2>/dev/null \
  || refuse "the patch does not apply to the current files. Ask for a patch made against them."
git diff --quiet -- "$LOCK_REL" || refuse "$LOCK_REL has uncommitted changes"

HIGH=$(git show "HEAD:$LAWS_REL" 2>/dev/null | grep -oE 'Ruling [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
N=$(( ${HIGH:-0} + 1 ))

echo "Ruling $N: $WORDING"
git apply --stat "$PATCH"
printf 'Type "ruling %s" to apply this change, re-record the lock and commit: ' "$N"
IFS= read -r ANSWER <&3 || ANSWER=""
[ "$ANSWER" = "ruling $N" ] || refuse "the confirmation did not match. Nothing changed."

undo() {
  git apply -R --index "$PATCH" 2>/dev/null
  git checkout -q HEAD -- "$LOCK_REL" 2>/dev/null
  refuse "$1 Nothing changed."
}

git apply --index "$PATCH" || undo "the patch did not apply."
git show ":$LAWS_REL" 2>/dev/null | grep -qE "Ruling ${N}([^0-9]|$)" \
  || undo "the patch does not add Ruling $N to $LAWS_REL."
bash "$CHECK" --root "$ROOT" --lock || undo "the lock could not be re-recorded."
git add -- "$LOCK_REL" || undo "the lock could not be staged."
git commit -q -m "Ruling $N: $WORDING" || undo "the commit was refused."
echo "Ruling $N committed as $(git rev-parse --short HEAD)."
