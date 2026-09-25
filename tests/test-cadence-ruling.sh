#!/usr/bin/env bash
# Tests for skills/cadence/scripts/cadence-ruling.sh: the one command a person
# runs in their own terminal to apply an agreed rule change as a numbered ruling.
#
# Usage: bash tests/test-cadence-ruling.sh
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OUT="$TMP/out.txt"
P="$TMP/proj"; LAWS="$P/docs/llm-orchestrator/LAWS.md"

mkdir -p "$P/docs/llm-orchestrator" "$P/.claude" "$P/.githooks"
printf '# Laws\n\nRuling 3 — the third one.\n' > "$LAWS"
printf '{ "schema": 1, "enabled": true, "workflow": "proportional", "lock_extra": [] }\n' > "$P/docs/llm-orchestrator/cadence.json"
printf '{ "permissions": { "deny": [] } }\n' > "$P/.claude/settings.json"
printf 'readme\n' > "$P/README.md"
cp "$CHECK" "$P/.githooks/orch-cadence-check.sh"
cp "$ROOT/skills/cadence/references/commit-msg" "$P/.githooks/commit-msg"
git -C "$P" init -q
git -C "$P" config core.hooksPath .githooks
bash "$CHECK" --root "$P" --lock >/dev/null
git -C "$P" add -A && git -C "$P" commit -qm 'chore: arm the cadence' >/dev/null 2>&1
BASE=$(git -C "$P" rev-parse HEAD)

make_patch() { # <file> <text to append> <patch file>
  printf '%s\n' "$2" >> "$P/$1"
  git -C "$P" diff > "$3"
  git -C "$P" checkout -q -- "$1"
}
make_patch docs/llm-orchestrator/LAWS.md 'Ruling 4 — the fourth one.' "$TMP/ruling4.patch"
cp "$TMP/ruling4.patch" "$TMP/mixed.patch"
make_patch README.md 'more' "$TMP/readme.patch"
cat "$TMP/readme.patch" >> "$TMP/mixed.patch"

ruling() { # <typed text> <patch> — runs the command in a pseudo-terminal
  python3 "$TTY" type "$1" bash "$RULING" --root "$P" "$2" "the fourth one" > "$OUT" 2>&1
}
unchanged() { [ "$(git -C "$P" rev-parse HEAD)" = "$1" ] && [ -z "$(git -C "$P" status --porcelain)" ]; }

printf '\n== refusals ==\n'
python3 "$TTY" none bash "$RULING" --root "$P" "$TMP/ruling4.patch" "the fourth one" > "$OUT" 2>&1; RC=$?
if [ "$RC" = 1 ] && grep -q 'no terminal' "$OUT" && unchanged "$BASE"; then ok "refuses with no terminal"
else fail "no terminal" "rc=$RC $(cat "$OUT")"; fi

ruling $'ruling 4\n' "$TMP/mixed.patch"; RC=$?
if [ "$RC" = 1 ] && grep -q 'README.md, which is not a protected file' "$OUT" && unchanged "$BASE"; then
  ok "refuses a patch that touches a file outside the protected set"
else fail "unprotected file" "rc=$RC $(cat "$OUT")"; fi

ruling $'yes\n' "$TMP/ruling4.patch"; RC=$?
if [ "$RC" = 1 ] && grep -q 'did not match' "$OUT" && unchanged "$BASE"; then ok "refuses a wrong confirmation"
else fail "wrong confirmation" "rc=$RC $(cat "$OUT")"; fi

printf '\n== applies, re-locks and commits ==\n'
ruling $'ruling 4\n' "$TMP/ruling4.patch"; RC=$?
SUBJECT=$(git -C "$P" log -1 --format=%s)
if [ "$RC" = 0 ] && [ "$SUBJECT" = "Ruling 4: the fourth one" ] && unchanged "$(git -C "$P" rev-parse HEAD)"; then
  ok "commits \"Ruling 4: the fourth one\" with a clean tree"
else fail "ruling commit" "rc=$RC subject=$SUBJECT $(cat "$OUT")"; fi
git -C "$P" show HEAD:docs/llm-orchestrator/LAWS.md | grep -q 'Ruling 4 — the fourth one.' \
  && ok "the commit carries the patched laws" || fail "patched laws" "LAWS.md at HEAD lacks Ruling 4"
bash "$CHECK" --root "$P" --verdict | grep -q 'lock OK' \
  && ok "the lock was re-recorded" || fail "re-lock" "$(bash "$CHECK" --root "$P" --verdict)"
bash "$CHECK" --root "$P" --audit HEAD > "$OUT" 2>&1 \
  && ok "the commit passes --audit" || fail "audit" "$(cat "$OUT")"
HEAD4=$(git -C "$P" rev-parse HEAD)

ruling $'ruling 5\n' "$TMP/ruling4.patch"; RC=$?
if [ "$RC" = 1 ] && grep -q 'does not apply' "$OUT" && unchanged "$HEAD4"; then ok "refuses a stale patch"
else fail "stale patch" "rc=$RC $(cat "$OUT")"; fi

make_patch docs/llm-orchestrator/LAWS.md 'An unnumbered change.' "$TMP/norule.patch"
ruling $'ruling 5\n' "$TMP/norule.patch"; RC=$?
if [ "$RC" = 1 ] && grep -q 'does not add Ruling 5' "$OUT" && unchanged "$HEAD4"; then
  ok "refuses a patch that does not record the ruling, and undoes it"
else fail "unrecorded ruling" "rc=$RC $(cat "$OUT")"; fi

printf '\n== the lock still refuses a direct edit ==\n'
printf 'Ruling 5 — slipped in.\n' >> "$LAWS"
python3 "$TTY" none bash "$CHECK" --root "$P" --lock > "$OUT" 2>&1; RC=$?
if [ "$RC" = 1 ] && grep -q 'no terminal' "$OUT"; then ok "--lock over an existing lock refuses with no terminal"
else fail "--lock no terminal" "rc=$RC $(cat "$OUT")"; fi
git -C "$P" add docs/llm-orchestrator/LAWS.md
if ! git -C "$P" commit -qm 'Ruling 5: slipped in' > "$OUT" 2>&1 && [ "$(git -C "$P" rev-parse HEAD)" = "$HEAD4" ]; then
  ok "the commit-msg hook refuses a direct edit without a re-recorded lock"
else fail "direct edit" "$(cat "$OUT")"; fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf '%d checks passed (cadence ruling).\n' "$PASS"; exit 0; fi
printf '%d passed, %d failed.\n' "$PASS" "$FAIL"; exit 1
