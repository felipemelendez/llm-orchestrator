#!/usr/bin/env bash
# Tests for skills/cadence/scripts/cadence-ruling.sh: the one command a person
# runs in their own terminal to apply an agreed rule change as a numbered ruling.
# (The file name avoids "cadence-ruling.sh" so the deny rule the init writes for
# that command does not match the suite.)
#
# Usage: bash tests/test-ruling-command.sh
# Exit codes: 0 = all checks passed, 1 = at least one failed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULING="$ROOT/skills/cadence/scripts/cadence-ruling.sh"
CHECK="$ROOT/skills/cadence/scripts/orch-cadence-check.sh"
TTY="$ROOT/tests/lib/terminal.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

for t in git python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'FAIL: %s is required\n' "$t"; exit 1; }
done

# The suite runs inside agent sessions; the command refuses those on purpose.
unset CLAUDECODE CODEX_THREAD_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OUT="$TMP/out.txt"
P="$TMP/proj"; LAWS="$P/docs/llm-orchestrator/LAWS.md"; LOCKF="$P/docs/llm-orchestrator/LOCK.sha256"

mkdir -p "$P/docs/llm-orchestrator" "$P/.claude" "$P/.githooks"
printf '# Laws\n\nRuling 3 — the third one.\n' > "$LAWS"
printf '{ "schema": 1, "enabled": true, "workflow": "proportional", "lock_extra": [] }\n' > "$P/docs/llm-orchestrator/cadence.json"
printf '{ "permissions": { "deny": [] } }\n' > "$P/.claude/settings.json"
printf 'readme\n' > "$P/README.md"
printf 'intro\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\ntail\n' > "$P/AGENTS.md"
cp "$CHECK" "$P/.githooks/orch-cadence-check.sh"
cp "$ROOT/skills/cadence/references/commit-msg" "$P/.githooks/commit-msg"
git -C "$P" init -q
git -C "$P" config core.hooksPath .githooks
bash "$CHECK" --root "$P" --lock >/dev/null
git -C "$P" add -A && git -C "$P" commit -qm 'chore: arm the cadence' >/dev/null 2>&1
BASE=$(git -C "$P" rev-parse HEAD)

make_patch() { # <patch file> <file> <text to append> [<file> <text>...]
  local out="$1"; shift
  while [ $# -gt 0 ]; do printf '%s\n' "$2" >> "$P/$1"; shift 2; done
  git -C "$P" add -N . 2>/dev/null
  git -C "$P" diff > "$out"
  git -C "$P" reset -q
  git -C "$P" checkout -q -- .
  git -C "$P" clean -qfd
}
R4='Ruling 4 — the fourth one.'
SECTION=$'<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->'
make_patch "$TMP/ruling4.patch" docs/llm-orchestrator/LAWS.md "$R4"
make_patch "$TMP/mixed.patch"   docs/llm-orchestrator/LAWS.md "$R4" README.md more
make_patch "$TMP/outside.patch" docs/llm-orchestrator/LAWS.md "$R4" AGENTS.md 'a new tail line'
git -C "$P" mv README.md docs/llm-orchestrator/README.md
git -C "$P" diff -M --cached > "$TMP/rename.patch"; git -C "$P" reset -q --hard
git -C "$P" rm -q README.md
git -C "$P" diff --cached > "$TMP/delete.patch"; cat "$TMP/ruling4.patch" >> "$TMP/delete.patch"; git -C "$P" reset -q --hard

ruling() { # <typed text> <patch> — runs the command in a pseudo-terminal
  python3 "$TTY" type "$1" bash "$RULING" --root "$P" "$2" "the fourth one" > "$OUT" 2>&1
}
unchanged() { [ "$(git -C "$P" rev-parse HEAD)" = "$1" ] && [ -z "$(git -C "$P" status --porcelain)" ]; }
refused() { # <label> <rc> <expected text> <head>
  if [ "$2" = 1 ] && grep -qF -- "$3" "$OUT" && unchanged "$4"; then ok "$1"; else fail "$1" "rc=$2 $(cat "$OUT")"; fi
}

printf '\n== refusals before anything changes ==\n'
python3 "$TTY" none bash "$RULING" --root "$P" "$TMP/ruling4.patch" "w" > "$OUT" 2>&1
refused "refuses with no terminal" $? 'no terminal' "$BASE"
CLAUDECODE=1 python3 "$TTY" type $'ruling 4\n' bash "$RULING" --root "$P" "$TMP/ruling4.patch" "w" > "$OUT" 2>&1
refused "refuses inside a Claude Code shell (CLAUDECODE=1)" $? 'CLAUDECODE is set' "$BASE"
ruling $'ruling 4\n' "$TMP/mixed.patch"
refused "refuses a patch that touches a file outside the protected set" $? 'README.md, which is not a protected file' "$BASE"
ruling $'ruling 4\n' "$TMP/rename.patch"
refused "refuses a rename (its source is checked too)" $? 'renames, copies' "$BASE"
ruling $'ruling 4\n' "$TMP/delete.patch"
refused "refuses deleting a file outside the protected set" $? 'README.md, which is not a protected file' "$BASE"
ruling $'ruling 4\n' "$TMP/outside.patch"
refused "refuses a change to AGENTS.md outside its marked section" $? 'outside its marked section' "$BASE"
printf 'x\n' >> "$P/docs/llm-orchestrator/cadence.json"
ruling $'ruling 4\n' "$TMP/ruling4.patch"; RC=$?
git -C "$P" checkout -q -- docs/llm-orchestrator/cadence.json
refused "refuses while a protected file differs from HEAD" "$RC" 'differ from HEAD' "$BASE"
ruling $'yes\n' "$TMP/ruling4.patch"
refused "refuses a wrong confirmation" $? 'did not match' "$BASE"

printf '\n== undo after the lock is written ==\n'
mkdir -p "$TMP/failhooks"; printf '#!/bin/sh\nexit 1\n' > "$TMP/failhooks/commit-msg"; chmod +x "$TMP/failhooks/commit-msg"
git -C "$P" config core.hooksPath "$TMP/failhooks"
cp "$LOCKF" "$TMP/lock.before"
ruling $'ruling 4\n' "$TMP/ruling4.patch"
refused "a refused commit is undone: HEAD and the tree unchanged" $? 'nothing changed' "$BASE"
cmp -s "$TMP/lock.before" "$LOCKF" && ok "and the lock is unchanged" || fail "lock after undo" "the lock differs"
# The hook's parent is git and git's parent is the command: stop the command
# while its commit is being made, then let the commit land.
printf '#!/bin/sh\nkill -TERM "$(ps -o ppid= -p "$PPID" | tr -d " ")"\nexit 0\n' > "$TMP/failhooks/commit-msg"
ruling $'ruling 4\n' "$TMP/ruling4.patch"; RC=$?
if [ "$RC" != 0 ] && grep -q 'interrupted' "$OUT" && grep -q 'nothing changed' "$OUT" && unchanged "$BASE"; then
  ok "an interruption after the commit takes the commit back"
else fail "interrupted" "rc=$RC $(cat "$OUT")"; fi
git -C "$P" config core.hooksPath .githooks

printf '\n== applies, re-locks and commits ==\n'
( cd "$TMP" && python3 "$TTY" type $'ruling 4\n' bash "$RULING" --root proj "$TMP/ruling4.patch" "the fourth one" ) > "$OUT" 2>&1; RC=$?
SUBJECT=$(git -C "$P" log -1 --format=%s)
if [ "$RC" = 0 ] && [ "$SUBJECT" = "Ruling 4: the fourth one" ] && unchanged "$(git -C "$P" rev-parse HEAD)"; then
  ok "with a relative --root, commits \"Ruling 4: the fourth one\" with a clean tree"
else fail "ruling commit" "rc=$RC subject=$SUBJECT $(cat "$OUT")"; fi
grep -qF "patch sha256 $(shasum -a 256 "$TMP/ruling4.patch" | awk '{print $1}')" "$OUT" \
  && ok "the prompt shows the patch's sha256" || fail "sha shown" "$(cat "$OUT")"
git -C "$P" show HEAD:docs/llm-orchestrator/LAWS.md | grep -qF "$R4" \
  && ok "the commit carries the patched laws" || fail "patched laws" "LAWS.md at HEAD lacks Ruling 4"
bash "$CHECK" --root "$P" --verdict | grep -q 'lock OK' \
  && ok "the lock was re-recorded" || fail "re-lock" "$(bash "$CHECK" --root "$P" --verdict)"
bash "$CHECK" --root "$P" --audit HEAD > "$OUT" 2>&1 \
  && ok "the commit passes --audit" || fail "audit" "$(cat "$OUT")"
HEAD4=$(git -C "$P" rev-parse HEAD)

ruling $'ruling 5\n' "$TMP/ruling4.patch"
refused "refuses a stale patch" $? 'does not apply' "$HEAD4"
make_patch "$TMP/norule.patch" docs/llm-orchestrator/LAWS.md 'An unnumbered change.'
ruling $'ruling 5\n' "$TMP/norule.patch"
refused "refuses a patch that does not record the ruling" $? 'does not add Ruling 5' "$HEAD4"
make_patch "$TMP/claude5.patch" docs/llm-orchestrator/LAWS.md 'Ruling 5 — a CLAUDE.md section.' CLAUDE.md "$SECTION"
ruling $'ruling 5\n' "$TMP/claude5.patch"; RC=$?
if [ "$RC" = 0 ] && git -C "$P" show HEAD:docs/llm-orchestrator/LOCK.sha256 | grep -q 'CLAUDE.md#ORCH:LAWS$'; then
  ok "a protected path not yet in the lock (a new CLAUDE.md section) is accepted and locked"
else fail "new protected path" "rc=$RC $(cat "$OUT")"; fi
HEAD5=$(git -C "$P" rev-parse HEAD)

printf '\n== the lock still refuses a direct edit ==\n'
printf 'Ruling 6 — slipped in.\n' >> "$LAWS"
python3 "$TTY" none bash "$CHECK" --root "$P" --lock > "$OUT" 2>&1; RC=$?
if [ "$RC" = 1 ] && grep -q 'no terminal' "$OUT"; then ok "--lock over an existing lock refuses with no terminal"
else fail "--lock no terminal" "rc=$RC $(cat "$OUT")"; fi
git -C "$P" add docs/llm-orchestrator/LAWS.md
if ! git -C "$P" commit -qm 'Ruling 6: slipped in' > "$OUT" 2>&1 && [ "$(git -C "$P" rev-parse HEAD)" = "$HEAD5" ]; then
  ok "the commit-msg hook refuses a direct edit without a re-recorded lock"
else fail "direct edit" "$(cat "$OUT")"; fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf '%d checks passed (ruling command).\n' "$PASS"; exit 0; fi
printf '%d passed, %d failed.\n' "$PASS" "$FAIL"; exit 1
