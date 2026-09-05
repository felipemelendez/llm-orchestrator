#!/usr/bin/env bash
# Tests for skills/cadence/scripts/orch-cadence-check.sh.
#
# The invariant chain this suite pins:
#   - the verdict REPORTS and never blocks (exit 0 in every state);
#   - the lock is a manifest of CONTENT, so a change inside the marked section
#     of CLAUDE.md/AGENTS.md is CHANGED while a change outside it is not;
#   - a second START marker cannot be used to hide an edit (a decoy pair
#     defeats a last-block extractor, so the first pair is the only pair);
#   - `--lock` is the only writer and refuses without the unlock, and refuses
#     outright when a settings file in scope PERSISTS the unlock (a persisted
#     unlock is not an unlock, it is a disarmed lock);
#   - the git layer runs at `commit-msg` (the only hook git hands a message
#     file) and a stale lock cannot ride in under a ruling either.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${ROOT}/skills/cadence/scripts/orch-cadence-check.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}

command -v git >/dev/null 2>&1 || skip_suite test-cadence-check 'git unavailable'
[[ -f "$CHECK" ]] || { printf '%s✗%s %s\n' "$RED" "$RESET" "missing script: $CHECK"; \
  printf '%sFAIL: test-cadence-check — 0 passed, 1 failed.%s\n' "$RED" "$RESET"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The unlock scope includes $HOME/.claude/settings.json, so HOME is isolated:
# the operator's own settings must never decide this suite's outcome.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
# GIT_CONFIG_NOSYSTEM plus an isolated HOME keeps a system or user git config
# (signing, hooksPath, templates) from deciding what these fixtures do.
export GIT_CONFIG_NOSYSTEM=1
GIT_ID=(-c user.email=cadence@test -c user.name=cadence)
OUT="$TMP/out.txt"; ERR="$TMP/err.txt"

run() { # run <root> <args...>  -> stdout in $OUT, stderr in $ERR, echoes rc
  local p="$1"; shift
  bash "$CHECK" --root "$p" "$@" > "$OUT" 2> "$ERR"; echo $?
}

mkproj() { # mkproj <dir>
  local p="$1"
  mkdir -p "$p/docs/llm-orchestrator" "$p/.claude"
  printf '# Laws\n\nRuling 1 — the first one.\nRuling 3 — the third one.\n' > "$p/docs/llm-orchestrator/LAWS.md"
  printf '%s\n' '{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",' \
    '  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:", "lock_extra": [] }' > "$p/docs/llm-orchestrator/cadence.json"
  printf '{ "permissions": { "deny": [] } }\n' > "$p/.claude/settings.json"
  printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\ntail\n' > "$p/CLAUDE.md"
  printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\ntail\n' > "$p/AGENTS.md"
}

has() { grep -qF -- "$2" "$1"; }

printf '%s== version and usage ==%s\n' "$DIM" "$RESET"
RC=$(bash "$CHECK" --version > "$OUT" 2>"$ERR"; echo $?)
if [[ "$RC" == "0" ]] && has "$OUT" '0.8.0'; then ok "--version prints 0.8.0"; else fail "--version" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(bash "$CHECK" > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" != "0" ]] && ok "no mode is a usage error (rc=$RC)" || fail "usage" "expected non-zero"

printf '\n%s== cadence off ==%s\n' "$DIM" "$RESET"
P="$TMP/off"; mkdir -p "$P"
RC=$(run "$P" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'cadence: off'; then ok "no cadence.json, no LAWS.md → 'cadence: off', exit 0"; else fail "off verdict" "rc=$RC out=$(cat "$OUT")"; fi
mkdir -p "$P/docs/llm-orchestrator"; printf '# Laws\n' > "$P/docs/llm-orchestrator/LAWS.md"
RC=$(run "$P" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'cadence: LAWS.md present, cadence.json absent'; then ok "LAWS.md alone → the cadence-init line"; else fail "laws-only verdict" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(run "$P" --lock); [[ "$RC" == "1" ]] && ok "--lock refuses off-mode (exit 1)" || fail "--lock off" "expected 1, got $RC"
RC=$(run "$P" --landing X-1); [[ "$RC" == "1" ]] && ok "--landing refuses off-mode (exit 1)" || fail "--landing off" "expected 1, got $RC"
printf 'msg\n' > "$TMP/m.txt"
RC=$(run "$P" --commit-msg "$TMP/m.txt"); [[ "$RC" == "0" ]] && ok "--commit-msg is inert off-mode (exit 0)" || fail "--commit-msg off" "expected 0, got $RC"
printf '%s\n' '{ "enabled": false }' > "$P/docs/llm-orchestrator/cadence.json"
RC=$(run "$P" --verdict)
if has "$OUT" 'cadence: off'; then ok "enabled:false → 'cadence: off'"; else fail "enabled false" "out=$(cat "$OUT")"; fi

printf '\n%s== verdict states ==%s\n' "$DIM" "$RESET"
P="$TMP/proj"; mkproj "$P"
RC=$(run "$P" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'cadence: LAWS.md (ruling 3)' && has "$OUT" 'lock UNARMED'; then
  ok "armed mode, no lock → '(ruling 3) · lock UNARMED'"; else fail "unarmed verdict" "out=$(cat "$OUT")"; fi
RC=$(run "$P" --lock)
LOCKF="$P/docs/llm-orchestrator/LOCK.sha256"
if [[ "$RC" == "0" && -f "$LOCKF" ]]; then ok "--lock writes LOCK.sha256"; else fail "--lock write" "rc=$RC"; fi
if grep -qE '^[0-9a-f]{64}  docs/llm-orchestrator/LAWS\.md$' "$LOCKF" \
   && grep -qE '^[0-9a-f]{64}  CLAUDE\.md#ORCH:LAWS$' "$LOCKF" \
   && grep -qE '^[0-9a-f]{64}  AGENTS\.md#ORCH:LAWS$' "$LOCKF"; then
  ok "lock format: '<sha256>  <path>' with #ORCH:LAWS section entries"; else fail "lock format" "$(cat "$LOCKF")"; fi
if ! grep -q 'LOCK.sha256' "$LOCKF"; then ok "LOCK.sha256 is not in its own manifest"; else fail "self-listing" "the lock lists itself"; fi
if [[ "$(cut -c67- "$LOCKF")" == "$(cut -c67- "$LOCKF" | LC_ALL=C sort)" ]]; then ok "lock entries sorted by path (byte order)"; else fail "lock sort" "$(cat "$LOCKF")"; fi
RC=$(run "$P" --verdict)
if has "$OUT" 'lock OK'; then ok "fresh lock → 'lock OK'"; else fail "lock OK" "out=$(cat "$OUT")"; fi
if [[ "$(wc -c < "$OUT" | tr -d ' ')" -le 301 ]]; then ok "verdict line ≤ 300 chars"; else fail "verdict length" "$(wc -c < "$OUT")"; fi

printf 'x\n' >> "$P/docs/llm-orchestrator/LAWS.md"
RC=$(run "$P" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'lock CHANGED docs/llm-orchestrator/LAWS.md'; then
  ok "edited LAWS.md → 'lock CHANGED docs/llm-orchestrator/LAWS.md' (still exit 0)"; else fail "changed verdict" "out=$(cat "$OUT")"; fi
printf '# Laws\n\nRuling 1 — the first one.\nRuling 3 — the third one.\n' > "$P/docs/llm-orchestrator/LAWS.md"
RC=$(run "$P" --verdict); has "$OUT" 'lock OK' && ok "restoring the byte content returns to 'lock OK'" || fail "restore" "out=$(cat "$OUT")"

printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\nTAIL EDITED\n' > "$P/CLAUDE.md"
RC=$(run "$P" --verdict)
if has "$OUT" 'lock OK'; then ok "editing CLAUDE.md OUTSIDE the section is not a lock change"; else fail "outside section" "out=$(cat "$OUT")"; fi
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block EDITED\n<!-- ORCH:LAWS:END -->\nTAIL EDITED\n' > "$P/CLAUDE.md"
RC=$(run "$P" --verdict)
if has "$OUT" 'CHANGED CLAUDE.md#ORCH:LAWS'; then ok "editing INSIDE the section is 'CHANGED CLAUDE.md#ORCH:LAWS'"; else fail "inside section" "out=$(cat "$OUT")"; fi

printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\nTAIL EDITED\n<!-- ORCH:LAWS:START -->\ndecoy\n<!-- ORCH:LAWS:END -->\n' > "$P/CLAUDE.md"
RC=$(run "$P" --verdict)
if has "$OUT" 'duplicate marker'; then ok "a second START marker reads 'duplicate marker', never the last block"; else fail "duplicate marker" "out=$(cat "$OUT")"; fi
RC=$(ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$P" --lock > "$OUT" 2>"$ERR"; echo $?)
if [[ "$RC" == "1" ]] && has "$OUT" 'duplicate marker'; then ok "--lock refuses a duplicate marker pair"; else fail "--lock duplicate" "rc=$RC out=$(cat "$OUT")"; fi
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\ntail\n' > "$P/CLAUDE.md"

rm -f "$P/AGENTS.md"
RC=$(run "$P" --verdict)
if has "$OUT" 'CHANGED AGENTS.md#ORCH:LAWS'; then ok "a locked section whose file disappeared reads CHANGED"; else fail "vanished section" "out=$(cat "$OUT")"; fi
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe block\n<!-- ORCH:LAWS:END -->\ntail\n' > "$P/AGENTS.md"

NOL="$TMP/nolaws"; mkproj "$NOL"
printf '# Laws\n\nno numbered rulings yet\n' > "$NOL/docs/llm-orchestrator/LAWS.md"
RC=$(run "$NOL" --verdict)
has "$OUT" 'cadence: LAWS.md (ruling —)' && ok "no numbered ruling yet reads '(ruling —)'" || fail "ruling dash" "out=$(cat "$OUT")"
rm -f "$NOL/docs/llm-orchestrator/LAWS.md"
RC=$(run "$NOL" --verdict)
has "$OUT" 'cadence: LAWS.md absent' && ok "cadence on with no LAWS.md reads 'LAWS.md absent'" || fail "laws absent" "out=$(cat "$OUT")"

printf '\n%s== the unlock ==%s\n' "$DIM" "$RESET"
RC=$(run "$P" --lock)
if [[ "$RC" == "1" ]] && has "$OUT" 'ORCH_CADENCE_UNLOCK'; then ok "--lock over an existing lock refuses and names the unlock"; else fail "--lock refusal" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$P" --lock > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" == "0" ]] && ok "--lock under ORCH_CADENCE_UNLOCK=1 rewrites the lock" || fail "--lock unlocked" "rc=$RC out=$(cat "$OUT")"
RC=$(ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$P" --verdict > "$OUT" 2>"$ERR"; echo $?)
if has "$OUT" ' · UNLOCKED'; then ok "the verdict says UNLOCKED when the unlock is in the environment"; else fail "verdict UNLOCKED" "out=$(cat "$OUT")"; fi
for SF in "$P/.claude/settings.json" "$P/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
  BK=""; [[ -f "$SF" ]] && { BK="$SF.bk"; cp "$SF" "$BK"; }
  printf '{ "env": { "ORCH_CADENCE_UNLOCK": "1" } }\n' > "$SF"
  RC=$(ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$P" --lock > "$OUT" 2>"$ERR"; echo $?)
  if [[ "$RC" == "1" ]] && has "$OUT" "$(basename "$SF")"; then ok "--lock refuses when $(basename "$SF") persists the unlock"; else fail "persisted unlock $SF" "rc=$RC out=$(cat "$OUT")"; fi
  rm -f "$SF"; [[ -n "$BK" ]] && mv "$BK" "$SF"
done
ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$P" --lock >/dev/null 2>&1

printf '\n%s== bounded: 64 hashed, the rest named, under 2s ==%s\n' "$DIM" "$RESET"
BIG="$TMP/big"; mkproj "$BIG"
i=0; EXTRA=""
while [[ $i -lt 59 ]]; do printf 'content %s\n' "$i" > "$BIG/extra_$i.md"; EXTRA="$EXTRA\"extra_$i.md\","; i=$((i+1)); done
printf '%s\n' "{ \"schema\": 1, \"enabled\": true, \"notes_dir\": \"docs/llm-orchestrator/notes\", \"ticket_re\": \"^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:\", \"lock_extra\": [${EXTRA%,}] }" > "$BIG/docs/llm-orchestrator/cadence.json"
RC=$(run "$BIG" --lock)
N=$(wc -l < "$BIG/docs/llm-orchestrator/LOCK.sha256" | tr -d ' ')
[[ "$RC" == "0" && "$N" == "64" ]] && ok "lock_extra lands in the manifest (64 entries)" || fail "64-entry lock" "rc=$RC n=$N out=$(cat "$OUT")"
S0=$(date +%s); RC=$(run "$BIG" --verdict); S1=$(date +%s)
if [[ "$RC" == "0" ]] && has "$OUT" 'lock OK' && [[ $((S1-S0)) -le 2 ]]; then ok "--verdict over 64 entries: 'lock OK' within $((S1-S0))s (≤2s)"; else fail "verdict timing" "rc=$RC ${S1}-${S0} out=$(cat "$OUT")"; fi
# The cap bounds the config's OWN extras, and only the ones the manifest does
# not already record: 71 names added to lock_extra without a re-lock.
i=59; while [[ $i -lt 130 ]]; do printf 'content %s\n' "$i" > "$BIG/extra_$i.md"; EXTRA="$EXTRA\"extra_$i.md\","; i=$((i+1)); done
printf '%s\n' "{ \"schema\": 1, \"enabled\": true, \"notes_dir\": \"docs/llm-orchestrator/notes\", \"ticket_re\": \"^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:\", \"lock_extra\": [${EXTRA%,}] }" > "$BIG/docs/llm-orchestrator/cadence.json"
RC=$(run "$BIG" --verdict)
if has "$OUT" 'unhashed'; then ok "beyond 64 unlocked extras the verdict says how many are unhashed"; else fail "unhashed note" "out=$(cat "$OUT")"; fi

printf '\n%s== five paths then +k ==%s\n' "$DIM" "$RESET"
MANY="$TMP/many"; mkproj "$MANY"
EXTRA=""; i=0
while [[ $i -lt 8 ]]; do printf 'c %s\n' "$i" > "$MANY/m_$i.md"; EXTRA="$EXTRA\"m_$i.md\","; i=$((i+1)); done
printf '%s\n' "{ \"schema\": 1, \"enabled\": true, \"notes_dir\": \"n\", \"ticket_re\": \"^X:\", \"lock_extra\": [${EXTRA%,}] }" > "$MANY/docs/llm-orchestrator/cadence.json"
run "$MANY" --lock >/dev/null
i=0; while [[ $i -lt 8 ]]; do printf 'CHANGED %s\n' "$i" > "$MANY/m_$i.md"; i=$((i+1)); done
RC=$(run "$MANY" --verdict)
if has "$OUT" '+3' && [[ "$(grep -o ',' "$OUT" | wc -l | tr -d ' ')" == "4" ]]; then ok "at most 5 paths are named, then '+k'"; else fail "+k" "out=$(cat "$OUT")"; fi

printf '\n%s== --landing evidence ==%s\n' "$DIM" "$RESET"
LP="$TMP/land"; mkproj "$LP"
( cd "$LP" && git init -q . && git "${GIT_ID[@]}" add -A >/dev/null 2>&1 && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
BASE_TS=$(git -C "$LP" log -1 --format=%ad --date=format:'%Y-%m-%d %H:%M:%S')
ND="$LP/docs/llm-orchestrator/notes"; mkdir -p "$ND"
LATER=$(date -r $(( $(date +%s) + 3600 )) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "2099-01-01 00:00:00")
for r in BRIEFREV REV1 REV2 REFUTE GATE; do
  printf 'Started: %s\nbody\nFinished: %s\n' "$LATER" "$LATER" > "$ND/AB-1_${r}_report.md"
done
printf 'EXIT=0\n' >> "$ND/AB-1_GATE_report.md"
RC=$(run "$LP" --landing AB-1)
[[ "$RC" == "0" ]] && ok "--landing passes with five finished reports and EXIT=0" || fail "landing ok" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
mv "$ND/AB-1_REV2_report.md" "$ND/held"
RC=$(run "$LP" --landing AB-1)
if [[ "$RC" == "1" ]] && has "$OUT" 'REV2'; then ok "--landing names the missing report"; else fail "landing missing" "rc=$RC out=$(cat "$OUT")"; fi
mv "$ND/held" "$ND/AB-1_REV2_report.md"
printf 'Started: %s\nbody\nFinished: %s\n' "2001-01-01 00:00:00" "2001-01-01 00:00:01" > "$ND/AB-1_REV1_report.md"
RC=$(run "$LP" --landing AB-1)
if [[ "$RC" == "1" ]] && has "$OUT" 'REV1'; then ok "--landing rejects a stale Finished stamp"; else fail "landing stale" "rc=$RC out=$(cat "$OUT")"; fi
printf 'Started: %s\nbody\nFinished: %s\n' "$LATER" "$LATER" > "$ND/AB-1_REV1_report.md"
printf 'Started: %s\nbody\nFinished: %s\nEXIT=2\n' "$LATER" "$LATER" > "$ND/AB-1_GATE_report.md"
RC=$(run "$LP" --landing AB-1)
if [[ "$RC" == "1" ]] && has "$OUT" 'EXIT=0'; then ok "--landing rejects a gate report whose last line is not EXIT=0"; else fail "landing gate exit" "rc=$RC out=$(cat "$OUT")"; fi
printf 'Started: %s\nbody\nFinished: %s\nEXIT=0\n' "$LATER" "$LATER" > "$ND/AB-1_GATE_report.md"
printf 'Started: %s\nbody\n' "$LATER" > "$ND/AB-1_REFUTE_report.md"
RC=$(run "$LP" --landing AB-1)
if [[ "$RC" == "1" ]] && has "$OUT" 'REFUTE'; then ok "--landing rejects a report with no Finished stamp"; else fail "landing unfinished" "rc=$RC out=$(cat "$OUT")"; fi
printf 'Started: %s\nbody\nFinished: %s\n' "$LATER" "$LATER" > "$ND/AB-1_REFUTE_report.md"

printf '\n%s== --commit-msg (the git layer) ==%s\n' "$DIM" "$RESET"
G="$TMP/git"; mkproj "$G"
( cd "$G" && git init -q . ) >/dev/null 2>&1
run "$G" --lock >/dev/null
( cd "$G" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: base' ) >/dev/null 2>&1
MSG="$TMP/msg.txt"
cmsg() { printf '%s\n' "$1" > "$MSG"; ( cd "$G" && bash "$CHECK" --commit-msg "$MSG" > "$OUT" 2>"$ERR" ); echo $?; }
RC=$(cmsg 'chore: nothing locked changed')
[[ "$RC" == "0" ]] && ok "--commit-msg passes a commit that touches no lock entry" || fail "cmsg clean" "rc=$RC out=$(cat "$OUT")"
printf 'x\n' >> "$G/docs/llm-orchestrator/LAWS.md"
( cd "$G" && git "${GIT_ID[@]}" add docs/llm-orchestrator/LAWS.md ) >/dev/null 2>&1
RC=$(cmsg 'chore: sneak a law in')
if [[ "$RC" == "1" ]] && has "$OUT" 'the message carries no numbered ruling'; then ok "--commit-msg blocks a staged law change with no ruling, for that reason"; else fail "cmsg no ruling" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(cmsg 'chore: sneak a law in

Ruling 4 — amended.')
if [[ "$RC" == "1" ]] && has "$OUT" 'a stale lock cannot ride along'; then ok "--commit-msg still blocks: the staged lock is stale under a ruling"; else fail "cmsg stale lock" "rc=$RC out=$(cat "$OUT")"; fi
printf 'Ruling 4 — amended.\n' >> "$G/docs/llm-orchestrator/LAWS.md"
ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$G" --lock >/dev/null 2>&1
( cd "$G" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg 'chore: amend the laws

Ruling 4 — amended.')
[[ "$RC" == "0" ]] && ok "--commit-msg passes a fresh lock + Ruling 4 recorded in the staged laws" || fail "cmsg ruling ok" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
RC=$(cmsg 'chore: amend the laws

Ruling 2 — backwards.')
if [[ "$RC" == "1" ]] && has "$OUT" 'greater'; then ok "--commit-msg rejects a ruling number that is not greater than the laws at HEAD"; else fail "cmsg ruling order" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(cmsg 'chore: amend the laws

Ruling 9 — never written down.')
if [[ "$RC" == "1" ]] && has "$OUT" 'do not record Ruling 9'; then ok "--commit-msg rejects a ruling the staged laws do not record, for that reason"; else fail "cmsg unrecorded ruling" "rc=$RC out=$(cat "$OUT")"; fi
# Isolated: only check 1 can fail here - the ruling is well-formed and recorded,
# but --lock was never re-run, so the lock riding in the index is stale.
printf 'Ruling 5 — later.\n' >> "$G/docs/llm-orchestrator/LAWS.md"
( cd "$G" && git "${GIT_ID[@]}" add docs/llm-orchestrator/LAWS.md ) >/dev/null 2>&1
RC=$(cmsg 'chore: amend again

Ruling 5 — later.')
if [[ "$RC" == "1" ]] && has "$OUT" 'stale lock'; then ok "a well-formed ruling still cannot carry a stale lock (check 1 alone)"; else fail "cmsg check1 isolated" "rc=$RC out=$(cat "$OUT")"; fi
# Isolated: only check 2 can fail here - the lock is fresh and consistent, the
# message simply carries no ruling.
ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$G" --lock >/dev/null 2>&1
( cd "$G" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg 'chore: a fresh lock but no ruling')
if [[ "$RC" == "1" ]] && has "$OUT" 'the message carries no numbered ruling'; then ok "a fresh lock still needs a numbered ruling (check 2 alone), and says so"; else fail "cmsg check2 isolated" "rc=$RC out=$(cat "$OUT")"; fi
RC=$(cmsg 'chore: amend again

Ruling 5 — later.')
[[ "$RC" == "0" ]] && ok "a fresh lock plus Ruling 5 recorded in the staged laws passes" || fail "cmsg ruling5" "rc=$RC out=$(cat "$OUT")"
( cd "$G" && git "${GIT_ID[@]}" commit -qm 'chore: amend again

Ruling 5 — later.' ) >/dev/null 2>&1
RC=$(cmsg 'chore: amend the laws

Ruling 4 — amended.')
( cd "$G" && git "${GIT_ID[@]}" commit -qm 'chore: amend the laws

Ruling 4 — amended.' ) >/dev/null 2>&1
RC=$(cmsg 'AB-2: land the ticket')
if [[ "$RC" == "1" ]] && has "$OUT" 'AB-2'; then ok "a ticket subject triggers the landing check and it fails with no evidence"; else fail "cmsg ticket landing" "rc=$RC out=$(cat "$OUT")"; fi

printf '\n%s== --audit <rev> ==%s\n' "$DIM" "$RESET"
RC=$( ( cd "$G" && bash "$CHECK" --audit HEAD > "$OUT" 2>"$ERR" ); echo $?)
[[ "$RC" == "0" ]] && ok "--audit HEAD passes the amendment commit" || fail "audit ok" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
printf 'y\n' >> "$G/docs/llm-orchestrator/LAWS.md"
( cd "$G" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: unruled law edit' ) >/dev/null 2>&1
RC=$( ( cd "$G" && bash "$CHECK" --audit HEAD > "$OUT" 2>"$ERR" ); echo $?)
[[ "$RC" == "1" ]] && ok "--audit catches an unruled law edit in history" || fail "audit catch" "rc=$RC out=$(cat "$OUT")"

printf '\n%s== root resolution ==%s\n' "$DIM" "$RESET"
mkdir -p "$G/sub/deeper"
RC=$( ( cd "$G/sub/deeper" && bash "$CHECK" --verdict > "$OUT" 2>"$ERR" ); echo $?)
if [[ "$RC" == "0" ]] && has "$OUT" 'cadence: LAWS.md'; then ok "root resolves to the git toplevel from a subdirectory"; else fail "root git toplevel" "rc=$RC out=$(cat "$OUT")"; fi
NG="$TMP/nogit"; mkproj "$NG"
RC=$( ( cd "$TMP" && CLAUDE_PROJECT_DIR="$NG" bash "$CHECK" --verdict > "$OUT" 2>"$ERR" ); echo $?)
if has "$OUT" 'cadence: LAWS.md'; then ok "CLAUDE_PROJECT_DIR is the fallback root outside a repo"; else fail "root project dir" "out=$(cat "$OUT")"; fi

printf '\n%s== python3 is a soft dependency ==%s\n' "$DIM" "$RESET"
NOPY=(env ORCH_CADENCE_PYTHON=/nonexistent/python3)
RC=$( "${NOPY[@]}" bash "$CHECK" --root "$P" --verdict > "$OUT" 2>"$ERR"; echo $?)
if [[ "$RC" == "0" ]] && has "$OUT" 'lock OK'; then ok "--verdict is correct with no python3"; else fail "no-python verdict" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"; fi
RC=$( ( cd "$G" && "${NOPY[@]}" bash "$CHECK" --commit-msg "$MSG" > "$OUT" 2>"$ERR" ); echo $?)
[[ "$RC" == "0" || "$RC" == "1" ]] && ok "--commit-msg runs with no python3 (rc=$RC)" || fail "no-python commit-msg" "rc=$RC"
RC=$( "${NOPY[@]}" bash "$CHECK" --root "$MANY" --verdict > "$OUT" 2>"$ERR"; echo $?)
if has "$ERR" 'python3'; then ok "an array key with no python3 prints one stderr note"; else fail "no-python note" "err=$(cat "$ERR")"; fi

# ---------------------------------------------------------------------------
# Round-1 pins. Each one is written from the scene it must reproduce, and each
# one was proven red on the tree before the mechanism it names existed.
# ---------------------------------------------------------------------------
MSG2="$TMP/msg2.txt"
cmsg_at() { # cmsg_at <dir> <message>  -> stdout in $OUT, stderr in $ERR, echoes rc
  local d="$1"; printf '%s\n' "$2" > "$MSG2"
  ( cd "$d" && bash "$CHECK" --commit-msg "$MSG2" > "$OUT" 2>"$ERR" ); echo $?
}
cfgjson() { # cfgjson <file> <enabled-literal> [extra-json]
  printf '%s\n' "{ \"schema\": 1, \"enabled\": $2, \"notes_dir\": \"docs/llm-orchestrator/notes\", \"ticket_re\": \"^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:\", \"lock_extra\": [${3:-}] }" > "$1"
}

printf '\n%s== the git gate reads its mode from git, never from the working tree ==%s\n' "$DIM" "$RESET"
GG="$TMP/gitmode"; mkproj "$GG"
( cd "$GG" && git init -q . ) >/dev/null 2>&1
run "$GG" --lock >/dev/null
( cd "$GG" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: base' ) >/dev/null 2>&1
GCFG="$GG/docs/llm-orchestrator/cadence.json"
cp "$GCFG" "$TMP/gcfg.keep"
printf 'x\n' >> "$GG/docs/llm-orchestrator/LAWS.md"
( cd "$GG" && git "${GIT_ID[@]}" add docs/llm-orchestrator/LAWS.md ) >/dev/null 2>&1
cfgjson "$GCFG" false
RC=$(cmsg_at "$GG" 'chore: sneak')
if [[ "$RC" == "1" ]] && has "$OUT" 'no numbered ruling'; then ok "an UNSTAGED enabled:false does not disarm --commit-msg"; else fail "unstaged disable" "rc=$RC out=$(cat "$OUT")"; fi
printf 'not json at all\n' > "$GCFG"
RC=$(cmsg_at "$GG" 'chore: sneak')
[[ "$RC" == "1" ]] && ok "an undecodable working-tree config cannot disarm the gate (fail closed)" || fail "undecodable worktree config" "rc=$RC out=$(cat "$OUT")"
rm -f "$GCFG"
RC=$(cmsg_at "$GG" 'chore: sneak')
[[ "$RC" == "1" ]] && ok "deleting the working-tree cadence.json cannot disarm the gate" || fail "absent worktree config" "rc=$RC out=$(cat "$OUT")"
cfgjson "$GCFG" false
( cd "$GG" && git "${GIT_ID[@]}" add docs/llm-orchestrator/cadence.json ) >/dev/null 2>&1
RC=$(cmsg_at "$GG" 'chore: sneak')
[[ "$RC" == "1" ]] && ok "staging enabled:false in the same commit does not disarm it (HEAD still says true)" || fail "staged disable" "rc=$RC out=$(cat "$OUT")"
cp "$TMP/gcfg.keep" "$GCFG"
( cd "$GG" && git "${GIT_ID[@]}" add docs/llm-orchestrator/cadence.json ) >/dev/null 2>&1
RC=$( ( cd "$GG" && bash "$CHECK" --verdict > "$OUT" 2>"$ERR" ); echo $?)
if ! has "$OUT" 'config differs from HEAD'; then ok "--verdict is silent about the config while it matches HEAD"; else fail "verdict config-differs false fire" "out=$(cat "$OUT")"; fi
cfgjson "$GCFG" true '"POLICY.md"'
RC=$( ( cd "$GG" && bash "$CHECK" --verdict > "$OUT" 2>"$ERR" ); echo $?)
if [[ "$RC" == "0" ]] && has "$OUT" 'config differs from HEAD'; then ok "--verdict says ' · config differs from HEAD' when the working-tree config drifts"; else fail "verdict config differs" "rc=$RC out=$(cat "$OUT")"; fi
cp "$TMP/gcfg.keep" "$GCFG"

printf '\n%s== a python3 that runs and FAILS falls through to the sed path ==%s\n' "$DIM" "$RESET"
SHIM="$TMP/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 127\n' > "$SHIM/python3"; chmod +x "$SHIM/python3"
BROKENPY=(env "ORCH_CADENCE_PYTHON=$SHIM/python3")
RC=$( "${BROKENPY[@]}" bash "$CHECK" --root "$P" --verdict > "$OUT" 2>"$ERR"; echo $?)
if [[ "$RC" == "0" ]] && has "$OUT" 'lock OK'; then ok "a present-but-failing interpreter still reads the real lock state"; else fail "broken python verdict" "rc=$RC out=$(cat "$OUT")"; fi
RC=$( ( cd "$GG" && "${BROKENPY[@]}" bash "$CHECK" --commit-msg "$MSG2" > "$OUT" 2>"$ERR" ); echo $?)
if [[ "$RC" == "1" ]] && has "$OUT" 'no numbered ruling'; then ok "a present-but-failing interpreter cannot turn the git gate off"; else fail "broken python gate" "rc=$RC out=$(cat "$OUT")"; fi
# The guard that makes cfg_note print once is load-bearing on THIS arm: a broken
# interpreter is re-tried on every config read, and the git gate reads several.
N=$(grep -c 'python3 is unavailable' "$ERR" | tr -d ' ')
[[ "$N" == "1" ]] && ok "a broken interpreter notes once per --commit-msg invocation, not once per config read" || fail "broken-python note count" "printed $N times"

printf '\n%s== the git gate enforces the manifest even without python3 ==%s\n' "$DIM" "$RESET"
PL="$TMP/policy"; mkproj "$PL"
printf 'policy v1\n' > "$PL/POLICY.md"
cfgjson "$PL/docs/llm-orchestrator/cadence.json" true '"POLICY.md"'
( cd "$PL" && git init -q . ) >/dev/null 2>&1
run "$PL" --lock >/dev/null
( cd "$PL" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: base' ) >/dev/null 2>&1
printf 'policy v2\n' > "$PL/POLICY.md"
( cd "$PL" && git "${GIT_ID[@]}" add POLICY.md ) >/dev/null 2>&1
printf '%s\n' 'chore: policy edit' > "$MSG2"
RC=$( ( cd "$PL" && "${NOPY[@]}" bash "$CHECK" --commit-msg "$MSG2" > "$OUT" 2>"$ERR" ); echo $?)
if [[ "$RC" == "1" ]] && has "$OUT" 'POLICY.md'; then ok "a lock_extra entry recorded in the manifest is enforced with no python3"; else fail "manifest without python" "rc=$RC out=$(cat "$OUT")"; fi
N=$(grep -c 'python3 is unavailable' "$ERR" | tr -d ' ')
[[ "$N" == "1" ]] && ok "the python3-unavailable note prints exactly once per invocation" || fail "note count" "printed $N times"

printf '\n%s== --landing compares local clocks, not the author zone ==%s\n' "$DIM" "$RESET"
TZL="$TMP/tzland"; mkproj "$TZL"
( cd "$TZL" && git init -q . && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
BEP=$(( $(date +%s) - 3600 ))
( cd "$TZL" && GIT_AUTHOR_DATE="$BEP +1200" GIT_COMMITTER_DATE="$BEP +1200" git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
TND="$TZL/docs/llm-orchestrator/notes"; mkdir -p "$TND"
NOWU=$(TZ=UTC date '+%Y-%m-%d %H:%M:%S')
for r in BRIEFREV REV1 REV2 REFUTE GATE; do
  printf 'Started: %s\nbody\nFinished: %s\n' "$NOWU" "$NOWU" > "$TND/AB-4_${r}_report.md"
done
printf 'EXIT=0\n' >> "$TND/AB-4_GATE_report.md"
RC=$( TZ=UTC bash "$CHECK" --root "$TZL" --landing AB-4 > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" == "0" ]] && ok "evidence written after the base passes even when the base was authored east of here" || fail "landing zone" "rc=$RC out=$(cat "$OUT")"
printf 'Started: %s\nbody\nFinished: %s\n' "2001-01-01 00:00:00" "$NOWU" > "$TND/AB-4_REV1_report.md"
RC=$( TZ=UTC bash "$CHECK" --root "$TZL" --landing AB-4 > "$OUT" 2>"$ERR"; echo $?)
if [[ "$RC" == "1" ]] && has "$OUT" 'Started'; then ok "a Started stamp older than the base is stale evidence too"; else fail "landing started stamp" "rc=$RC out=$(cat "$OUT")"; fi

printf '\n%s== the 64 cap applies to lock_extra, never to the fixed set ==%s\n' "$DIM" "$RESET"
CAP="$TMP/cap"; mkproj "$CAP"
i=0; EXTRA=""
while [[ $i -lt 62 ]]; do
  N2=$(printf 'A%02d.md' "$i"); printf 'a %s\n' "$i" > "$CAP/$N2"; EXTRA="$EXTRA\"$N2\","; i=$((i+1))
done
cfgjson "$CAP/docs/llm-orchestrator/cadence.json" true "${EXTRA%,}"
run "$CAP" --lock >/dev/null
printf 'edited\n' >> "$CAP/docs/llm-orchestrator/LAWS.md"
RC=$(run "$CAP" --verdict)
if has "$OUT" 'CHANGED docs/llm-orchestrator/LAWS.md'; then ok "62 lock_extra names cannot push LAWS.md out of the hashed set"; else fail "cap over the fixed set" "out=$(cat "$OUT")"; fi
i=0
while [[ $i -lt 70 ]]; do
  N2=$(printf 'B%02d.md' "$i"); printf 'b %s\n' "$i" > "$CAP/$N2"; EXTRA="$EXTRA\"$N2\","; i=$((i+1))
done
cfgjson "$CAP/docs/llm-orchestrator/cadence.json" true "${EXTRA%,}"
RC=$(run "$CAP" --verdict)
if has "$OUT" 'extras unhashed'; then ok "the tail is spelled '+k extras unhashed'"; else fail "unhashed spelling" "out=$(cat "$OUT")"; fi

printf '\n%s== arming and disarming ==%s\n' "$DIM" "$RESET"
ARM="$TMP/arm"; mkproj "$ARM"
( cd "$ARM" && git init -q . ) >/dev/null 2>&1
run "$ARM" --lock >/dev/null
( cd "$ARM" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: cadence-init')
if [[ "$RC" == "0" ]] && has "$OUT" 'arming this project (first lock commit)'; then ok "the first lock commit arms the project without a ruling, and says so"; else fail "arming commit" "rc=$RC out=$(cat "$OUT")"; fi
printf 'drifted\n' >> "$ARM/docs/llm-orchestrator/LAWS.md"
( cd "$ARM" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: cadence-init')
[[ "$RC" == "1" ]] && ok "an arming commit whose staged manifest does not match the staged content is refused" || fail "arming drift" "rc=$RC out=$(cat "$OUT")"
ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$ARM" --lock >/dev/null 2>&1
( cd "$ARM" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: cadence-init' ) >/dev/null 2>&1
( cd "$ARM" && git "${GIT_ID[@]}" rm -q --cached docs/llm-orchestrator/LOCK.sha256 ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: tidy')
if [[ "$RC" == "1" ]] && has "$OUT" 'LOCK.sha256'; then ok "deleting the manifest is a lock-set change and needs a ruling"; else fail "manifest deletion" "rc=$RC out=$(cat "$OUT")"; fi
( cd "$ARM" && git "${GIT_ID[@]}" add docs/llm-orchestrator/LOCK.sha256 ) >/dev/null 2>&1
( cd "$ARM" && git "${GIT_ID[@]}" rm -q --cached docs/llm-orchestrator/cadence.json ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: tidy')
[[ "$RC" == "1" ]] && ok "deleting cadence.json from an armed commit needs a ruling too" || fail "config deletion" "rc=$RC out=$(cat "$OUT")"
( cd "$ARM" && git "${GIT_ID[@]}" add docs/llm-orchestrator/cadence.json ) >/dev/null 2>&1

printf '\n%s== the remedy names only the missing piece ==%s\n' "$DIM" "$RESET"
RC=$(cmsg_at "$ARM" 'chore: nothing to see')
printf 'Ruling 6 — later still.\n' >> "$ARM/docs/llm-orchestrator/LAWS.md"
ORCH_CADENCE_UNLOCK=1 bash "$CHECK" --root "$ARM" --lock >/dev/null 2>&1
( cd "$ARM" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: a fresh lock and no ruling')
if [[ "$RC" == "1" ]] && ! has "$OUT" 're-run --lock'; then ok "a fresh lock with no ruling is not told to re-run --lock"; else fail "remedy over-tells" "rc=$RC out=$(cat "$OUT")"; fi
printf 'Ruling 7 — unlocked.\n' >> "$ARM/docs/llm-orchestrator/LAWS.md"
( cd "$ARM" && git "${GIT_ID[@]}" add docs/llm-orchestrator/LAWS.md ) >/dev/null 2>&1
RC=$(cmsg_at "$ARM" 'chore: a stale lock

Ruling 7 — unlocked.')
if [[ "$RC" == "1" ]] && has "$OUT" 're-run --lock'; then ok "a stale lock IS told to re-run --lock"; else fail "remedy under-tells" "rc=$RC out=$(cat "$OUT")"; fi

printf '\n%s== --audit grades the revision with the revision ==%s\n' "$DIM" "$RESET"
AU="$TMP/audit"; mkproj "$AU"
( cd "$AU" && git init -q . ) >/dev/null 2>&1
run "$AU" --lock >/dev/null
( cd "$AU" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: base' ) >/dev/null 2>&1
AND="$AU/docs/llm-orchestrator/notes"; mkdir -p "$AND"
ALATER=$(date -r $(( $(date +%s) + 3600 )) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "2099-01-01 00:00:00")
for r in BRIEFREV REV1 REV2 REFUTE GATE; do
  printf 'Started: %s\nbody\nFinished: %s\n' "$ALATER" "$ALATER" > "$AND/AB-5_${r}_report.md"
done
printf 'EXIT=0\n' >> "$AND/AB-5_GATE_report.md"
( cd "$AU" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'AB-5: land the ticket' ) >/dev/null 2>&1
rm -rf "$AND"
rm -f "$AU/docs/llm-orchestrator/cadence.json"
RC=$( ( cd "$AU" && bash "$CHECK" --audit HEAD > "$OUT" 2>"$ERR" ); echo $?)
[[ "$RC" == "0" ]] && ok "--audit reads the config and the evidence at the revision, not from the working tree" || fail "audit at rev" "rc=$RC out=$(cat "$OUT") err=$(cat "$ERR")"
cfgjson "$AU/docs/llm-orchestrator/cadence.json" true

printf '\n%s== "enabled" must be the JSON boolean ==%s\n' "$DIM" "$RESET"
STR="$TMP/strbool"; mkproj "$STR"
printf '%s\n' '{ "schema": 1, "enabled": "true", "notes_dir": "docs/llm-orchestrator/notes", "ticket_re": "^X:", "lock_extra": [] }' > "$STR/docs/llm-orchestrator/cadence.json"
RC=$(run "$STR" --verdict)
has "$OUT" 'cadence: off' && ok '"enabled": "true" (a string) is off on the python path' || fail "string enabled python" "out=$(cat "$OUT")"
RC=$( "${NOPY[@]}" bash "$CHECK" --root "$STR" --verdict > "$OUT" 2>"$ERR"; echo $?)
has "$OUT" 'cadence: off' && ok '"enabled": "true" (a string) is off on the sed path' || fail "string enabled sed" "out=$(cat "$OUT")"

printf '\n%s== usage errors exit 1 (the contract is 0/1) ==%s\n' "$DIM" "$RESET"
RC=$(bash "$CHECK" --frobnicate > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" == "1" ]] && ok "an unknown option exits 1" || fail "unknown option rc" "expected 1, got $RC"
RC=$(bash "$CHECK" > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" == "1" ]] && ok "no mode exits 1" || fail "no mode rc" "expected 1, got $RC"
RC=$(bash "$CHECK" --landing > "$OUT" 2>"$ERR"; echo $?)
[[ "$RC" == "1" ]] && ok "--landing without a ticket exits 1" || fail "landing usage rc" "expected 1, got $RC"


# ---------------------------------------------------------------------------
# Round-2 pins (the gate seat's delta). Each is written from its SCENE.
# ---------------------------------------------------------------------------
printf '\n%s== a START with no END is a refusal, never a silently dropped section ==%s\n' "$DIM" "$RESET"
# SCENE: an armed project whose CLAUDE.md carries the START marker and no END.
# The section is the law; a reader that treats "started and never ended" the
# same as "this file has no section" drops the law out of the lock set, and the
# text inside it can then be rewritten under any message at all.
UT="$TMP/unterm"; mkproj "$UT"
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe project law: never rewrite history\ntail\n' > "$UT/CLAUDE.md"
RC=$(run "$UT" --lock)
if [[ "$RC" == "1" ]] && has "$OUT" 'unterminated section'; then ok "--lock refuses over a section that starts and never ends"; else fail "unterminated lock" "rc=$RC out=$(cat "$OUT")"; fi
[[ ! -f "$UT/docs/llm-orchestrator/LOCK.sha256" ]] && ok "that refusal writes no manifest at all" || fail "unterminated manifest written" "$(cat "$UT/docs/llm-orchestrator/LOCK.sha256")"

UT2="$TMP/unterm2"; mkproj "$UT2"
( cd "$UT2" && git init -q . ) >/dev/null 2>&1
run "$UT2" --lock >/dev/null
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe project law: never rewrite history\ntail\n' > "$UT2/CLAUDE.md"
RC=$(run "$UT2" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'CLAUDE.md#ORCH:LAWS (unterminated section)'; then ok "--verdict names an unterminated section for what it is"; else fail "unterminated verdict" "rc=$RC out=$(cat "$OUT")"; fi
# The harm, end to end: a manifest that never recorded the section (because it
# was written while the section was already unterminated) plus a HEAD that
# carries the same unterminated file. Both sides then read alike, nothing looks
# changed, and the law text inside the section rides in under a tidy-up subject.
grep -v 'CLAUDE.md#ORCH:LAWS' "$UT2/docs/llm-orchestrator/LOCK.sha256" > "$TMP/ut2.lock"
mv "$TMP/ut2.lock" "$UT2/docs/llm-orchestrator/LOCK.sha256"
( cd "$UT2" && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm 'chore: base' ) >/dev/null 2>&1
printf 'preamble\n<!-- ORCH:LAWS:START -->\nthe project law: REWRITE HISTORY FREELY\ntail\n' > "$UT2/CLAUDE.md"
( cd "$UT2" && git "${GIT_ID[@]}" add -A ) >/dev/null 2>&1
RC=$(cmsg_at "$UT2" 'chore: tidy the readme')
if [[ "$RC" == "1" ]] && has "$OUT" 'unterminated section'; then ok "a law rewritten inside an unterminated section cannot ride in under a tidy-up message"; else fail "unterminated commit" "rc=$RC out=$(cat "$OUT")"; fi

printf '\n%s== a CRLF manifest names each entry once ==%s\n' "$DIM" "$RESET"
# A manifest that came back through a Windows editor still reads as a manifest;
# the trailing CR must not become part of the entry name, or every path is two
# members of the union set that print identically.
CR="$TMP/crlflock"; mkproj "$CR"
run "$CR" --lock >/dev/null
awk '{ printf "%s\r\n", $0 }' "$CR/docs/llm-orchestrator/LOCK.sha256" > "$TMP/cr.lock"
mv "$TMP/cr.lock" "$CR/docs/llm-orchestrator/LOCK.sha256"
RC=$(run "$CR" --verdict)
DUPS=$(sed -n 's/.*lock CHANGED //p' "$OUT" | sed 's/ +[0-9].*//' | tr ',' '\n' | tr -d '\r' \
       | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
if [[ "$RC" == "0" ]] && [[ -z "$DUPS" ]]; then ok "a CRLF LOCK.sha256 names each entry once in the verdict"; else fail "crlf doubles the names" "rc=$RC dup=[$DUPS] out=$(cat "$OUT")"; fi

printf '\n%s== an END marker with no START is a refusal at the first lock, never "no section" ==%s\n' "$DIM" "$RESET"
# SCENE (the gate's G1, the mirror of the unterminated case): a project armed
# for the FIRST time whose CLAUDE.md carries the END marker and no START. A
# reader that counts only START markers sees "no section", writes a manifest
# without the entry, reads OK, and the law text above that marker can then be
# rewritten under any message. The only window is the first lock; it must shut.
OE="$TMP/orphanend"; mkproj "$OE"
printf 'preamble\nthe project law: never rewrite history\n<!-- ORCH:LAWS:END -->\ntail\n' > "$OE/CLAUDE.md"
RC=$(run "$OE" --lock)
if [[ "$RC" == "1" ]] && has "$OUT" 'orphan end marker'; then ok "--lock refuses over an END marker that no START opened"; else fail "orphan END lock" "rc=$RC out=$(cat "$OUT")"; fi
[[ ! -f "$OE/docs/llm-orchestrator/LOCK.sha256" ]] && ok "that refusal writes no manifest either" || fail "orphan END manifest written" "$(cat "$OE/docs/llm-orchestrator/LOCK.sha256")"
OE2="$TMP/orphanend2"; mkproj "$OE2"
( cd "$OE2" && git init -q . ) >/dev/null 2>&1
run "$OE2" --lock >/dev/null
printf 'preamble\nthe project law: never rewrite history\n<!-- ORCH:LAWS:END -->\ntail\n' > "$OE2/CLAUDE.md"
RC=$(run "$OE2" --verdict)
if [[ "$RC" == "0" ]] && has "$OUT" 'CLAUDE.md#ORCH:LAWS (orphan end marker)'; then ok "--verdict names an orphan END marker for what it is"; else fail "orphan END verdict" "rc=$RC out=$(cat "$OUT")"; fi
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-check%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-cadence-check — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
