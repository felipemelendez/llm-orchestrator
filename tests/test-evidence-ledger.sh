#!/usr/bin/env bash
# Tests for the evidence-ledger PostToolUse hook (orch-evidence-ledger.sh) and
# the shared stamp validator (scripts/lib/orch-evidence.sh).
#
# The input fixtures encode the REAL platform contract, verified live against
# Claude Code v2.1.220 on 2026-07-28:
#   - PostToolUse fires ONLY when the tool call succeeds (a failing Bash
#     command emits no event), so a firing event implies exit 0;
#   - tool_response = {stdout, stderr, interrupted, isImage, noOutputExpected}
#     — there is NO exit-code field.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-evidence-ledger.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

command -v python3 >/dev/null 2>&1 || { printf '%sPASS: test-evidence-ledger (skipped — python3 unavailable)%s\n' "$DIM" "$RESET"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/home"

# fire <command> [stdout] [agent_id] — pipe a REAL-shape PostToolUse event; prints hook stdout
fire() {
  local cmd="$1" out="${2:-ok}" aid="${3:-}"
  python3 -c "
import json, sys
d = {'session_id': 'ev-test', 'hook_event_name': 'PostToolUse', 'tool_name': 'Bash',
     'tool_input': {'command': sys.argv[1]},
     'tool_response': {'stdout': sys.argv[2], 'stderr': '', 'interrupted': False,
                       'isImage': False, 'noOutputExpected': False}}
if sys.argv[3]:
    d['agent_id'] = sys.argv[3]
print(json.dumps(d))" "$cmd" "$out" "$aid" | bash "$HOOK"
}
ledger() { cat "$ORCH_HOME"/state/*/evidence.ev-test.tsv 2>/dev/null; }
mutexmap() { cat "$ORCH_HOME"/state/*/mutex-map.ev-test.tsv 2>/dev/null; }

printf '%s== real-contract input (no exit field) mints an exit=0 stamp ==%s\n' "$DIM" "$RESET"
OUT=$(fire "npm test" "142 passed")
if printf '%s' "$OUT" | grep -q '"updatedToolOutput"' && printf '%s' "$OUT" | grep -qE 'orch-evidence [0-9a-f]{12} exit=0'; then
  ok "npm test → updatedToolOutput carries an exit=0 stamp"
else fail "stamp minted" "out=$OUT"; fi
if ledger | grep -qE '^[0-9a-f]{12}	0	'; then ok "ledger row recorded with exit 0"
else fail "ledger row" "$(ledger)"; fi
STAMP=$(ledger | head -1 | cut -f1)

printf '\n%s== stamp format matches the validator regex ==%s\n' "$DIM" "$RESET"
source "${ROOT}/scripts/lib/orch-evidence.sh"
CITED=$(orch_evidence_stamp_of "Verify: npm test → 142 passed [orch-evidence ${STAMP} exit=0]")
[[ "$CITED" == "$STAMP" ]] && ok "orch_evidence_stamp_of extracts the minted stamp" || fail "stamp roundtrip" "cited='$CITED' minted='$STAMP'"
L=$(ls "$ORCH_HOME"/state/*/evidence.ev-test.tsv)
orch_evidence_check "Verify: ok [orch-evidence ${STAMP} exit=0]" "$L" >/dev/null
[[ $? -eq 0 ]] && ok "validator accepts the minted stamp" || fail "validator accept" ""
orch_evidence_check "Verify: ok [orch-evidence deadbeef0123 exit=0]" "$L" >/dev/null
[[ $? -eq 1 ]] && ok "validator rejects a fabricated stamp (rc 1)" || fail "validator reject" ""

printf '\n%s== command-position anchoring: no stamps for non-verify commands ==%s\n' "$DIM" "$RESET"
anchored_ok=1
for cmd in "git add tests/smoke.sh" "echo pytest passed" "chmod +x tests/foo.sh" "shellcheck tests/x.sh" "ls -la"; do
  OUT=$(fire "$cmd" "whatever")
  [[ -z "$OUT" ]] || { anchored_ok=0; fail "anchoring" "'$cmd' minted a stamp"; }
done
[[ $anchored_ok -eq 1 ]] && ok "git add/echo/chmod/shellcheck over test paths mint NOTHING"
for cmd in "cd sub && npm test" "pytest -q" "./tests/smoke.sh" "make check"; do
  OUT=$(fire "$cmd" "green")
  printf '%s' "$OUT" | grep -q 'orch-evidence' || fail "anchoring positive" "'$cmd' minted no stamp"
done
ok "real verify invocations (incl. after &&) still mint stamps"

printf '\n%s== mutex map: success-only, plain mkdir only ==%s\n' "$DIM" "$RESET"
fire 'mkdir ".worktrees/task-a/.orch-active"' "" "agent-1" >/dev/null
mutexmap | grep -q 'claim	agent-1	.worktrees/task-a/.orch-active' && ok "successful plain mkdir records a claim" || fail "claim" "$(mutexmap)"
fire 'mkdir -p .worktrees/task-b/.orch-active' "" "agent-2" >/dev/null
mutexmap | grep -q 'agent-2' && fail "-p exclusion" "mkdir -p recorded a claim ($(mutexmap))" || ok "mkdir -p records NOTHING (exits 0 on an existing dir — proves no ownership)"
fire 'rmdir ".worktrees/task-a/.orch-active"' "" "agent-1" >/dev/null
mutexmap | grep -q 'release	agent-1' && ok "rmdir records a release" || fail "release" "$(mutexmap)"

printf '\n%s== profile / disable gates ==%s\n' "$DIM" "$RESET"
OUT=$(ORCH_HOOK_PROFILE=minimal fire "npm test" "x")
[[ -z "$OUT" ]] && ok "minimal profile → inert" || fail "minimal gate" "out=$OUT"
OUT=$(ORCH_DISABLED_HOOKS=orch-evidence-ledger fire "npm test" "x")
[[ -z "$OUT" ]] && ok "ORCH_DISABLED_HOOKS → inert" || fail "disable gate" "out=$OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-evidence-ledger%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-evidence-ledger — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
