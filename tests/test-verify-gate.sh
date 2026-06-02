#!/usr/bin/env bash
# Tests for the verification gate Stop hook (orch-verify-gate.sh).
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-verify-gate.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

if ! command -v python3 >/dev/null 2>&1; then
  printf '%sPASS: test-verify-gate (skipped — python3 unavailable)%s\n' "$DIM" "$RESET"; exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  printf '%sPASS: test-verify-gate (skipped — git unavailable)%s\n' "$DIM" "$RESET"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A clean committed git repo to act as CLAUDE_PROJECT_DIR (so the WIP escape
# does not fire on the warn cases).
CLEAN="$TMP/clean"; mkdir -p "$CLEAN"
( cd "$CLEAN" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "initial" )

# Build a transcript whose last assistant message is $1.
mk_transcript() {
  local text="$1" f="$TMP/t.$RANDOM.jsonl"
  printf '{"role":"user","content":"go"}\n' > "$f"
  printf '{"role":"assistant","content":%s}\n' "$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" >> "$f"
  printf '%s' "$f"
}
run() { # run <transcript> [env assignments...]: prints "rc|stderr"
  local tr="$1"; shift
  local err rc
  err=$(printf '{"transcript_path":"%s"}' "$tr" | env "$@" CLAUDE_PROJECT_DIR="$CLEAN" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}

printf '%s== Completion claim without Verify: → warns (default, non-blocking) ==%s\n' "$DIM" "$RESET"
tr=$(mk_transcript "Changed: fixed the parser. All tests passing now.")
out=$(run "$tr"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-verify-gate'; then
  ok "claim + no Verify + clean tree → warn, exit 0"
else fail "warn case" "rc=$rc err=$err"; fi

printf '\n%s== Same, ORCH_STRICT_VERIFY=1 → blocks (exit 2) ==%s\n' "$DIM" "$RESET"
out=$(run "$tr" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
if [[ "$rc" == "2" ]]; then ok "strict mode → exit 2"; else fail "strict block" "rc=$rc"; fi

printf '\n%s== Completion claim WITH Verify: line → silent ==%s\n' "$DIM" "$RESET"
tr2=$(mk_transcript "Changed: fixed the parser.
Verify: pytest -q → 5 passed")
out=$(run "$tr2"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "evidence present → no warning"; else fail "evidence case" "rc=$rc err=$err"; fi

printf '\n%s== No Changed: block → silent ==%s\n' "$DIM" "$RESET"
tr3=$(mk_transcript "Found: the parser lives in src/parse.ts:42.")
out=$(run "$tr3"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "no Changed: → no warning"; else fail "no-claim case" "rc=$rc err=$err"; fi

printf '\n%s== False-positive prose in non-Changed: replies → silent (strict too) ==%s\n' "$DIM" "$RESET"
fp_ok=1
for prose in \
  "Found: the bug is in the parser. I have not fixed it yet." \
  "Plan: 1. add the test 2. once that is done, refactor the loop" \
  "Status: blocked. The login flow is still passing the wrong token." \
  "Issues: the migration has not been verified against staging."; do
  trx=$(mk_transcript "$prose")
  out=$(run "$trx" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
  if [[ "$rc" != "0" || -n "$err" ]]; then fp_ok=0; fail "false-positive guard" "prose nagged/blocked: '$prose' (rc=$rc)"; fi
done
[[ "$fp_ok" == "1" ]] && ok "negated/descriptive prose in Found:/Plan:/Status:/Issues: never fires (even strict)"

printf '\n%s== WIP escape: dirty tree → silent even with claim ==%s\n' "$DIM" "$RESET"
DIRTY="$TMP/dirty"; mkdir -p "$DIRTY"
( cd "$DIRTY" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm initial && echo change >> f )
err=$(printf '{"transcript_path":"%s"}' "$tr" | CLAUDE_PROJECT_DIR="$DIRTY" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "dirty tree → WIP escape, no warning"; else fail "dirty escape" "rc=$rc err=$err"; fi

printf '\n%s== WIP escape: last commit subject contains wip → silent ==%s\n' "$DIM" "$RESET"
WIP="$TMP/wip"; mkdir -p "$WIP"
( cd "$WIP" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "wip: halfway" )
err=$(printf '{"transcript_path":"%s"}' "$tr" | CLAUDE_PROJECT_DIR="$WIP" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "wip commit subject → no warning"; else fail "wip escape" "rc=$rc err=$err"; fi

printf '\n%s== Dry-run logs intent, never blocks ==%s\n' "$DIM" "$RESET"
out=$(run "$tr" ORCH_STRICT_VERIFY=1 ORCH_HOOK_DRY_RUN=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-dry-run\[orch-verify-gate\]'; then
  ok "dry-run: logs intent, exit 0 even with strict"
else fail "dry-run" "rc=$rc err=$err"; fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-verify-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-verify-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
