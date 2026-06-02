#!/usr/bin/env bash
# Tests for the retry-storm circuit breaker Stop hook (orch-retry-cap.sh).
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-retry-cap.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

if ! command -v python3 >/dev/null 2>&1; then
  printf '%sPASS: test-retry-cap (skipped — python3 unavailable)%s\n' "$DIM" "$RESET"; exit 0
fi

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

mk_transcript() { # mk_transcript <text> -> path
  local text="$1" f="$BASE/t.$RANDOM.jsonl"
  printf '{"role":"assistant","content":%s}\n' "$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" > "$f"
  printf '%s' "$f"
}
# fire <fresh-home> <transcript> [env...] -> "rc|stderr"
fire() {
  local home="$1" tr="$2"; shift 2
  local err rc
  err=$(printf '{"transcript_path":"%s"}' "$tr" | env ORCH_HOME="$home" "$@" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}

SAME=$(mk_transcript "Status: trying the same fix again. It still fails the same way.")
DIFF=$(mk_transcript "Status: a different approach this time, exploring the parser.")

printf '%s== Default OFF: identical replies never warn ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d); off_ok=1
for i in 1 2 3 4 5; do
  out=$(fire "$H" "$SAME"); [[ "${out#*|}" == "" ]] || off_ok=0
done
[[ "$off_ok" == "1" ]] && ok "ORCH_RETRY_CAP unset → silent across 5 identical replies" || fail "default off" "warned while disabled"

printf '\n%s== Enabled, N=3: warns on the 3rd identical reply, not before ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
o1=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3); o2=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)
o3=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)
if [[ "${o1#*|}" == "" && "${o2#*|}" == "" ]]; then ok "1st and 2nd identical replies are silent"
else fail "pre-threshold silent" "o1='$o1' o2='$o2'"; fi
if [[ "${o3%%|*}" == "0" ]] && printf '%s' "${o3#*|}" | grep -q 'orch-retry-cap'; then ok "3rd identical reply warns (exit 0)"
else fail "threshold warn" "o3='$o3'"; fi

printf '\n%s== A different reply resets the counter ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3 >/dev/null
fire "$H" "$DIFF" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3 >/dev/null   # reset
r2=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)         # count=1 again
r3=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)         # count=2, still silent
if [[ "${r2#*|}" == "" && "${r3#*|}" == "" ]]; then ok "varied reply between repeats prevents a false trip"
else fail "reset" "r2='$r2' r3='$r3'"; fi

printf '\n%s== Strict mode blocks (exit 2) at the threshold ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 >/dev/null
s2=$(fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2)
if [[ "${s2%%|*}" == "2" ]]; then ok "ORCH_STRICT_RETRY=1 → exit 2 at threshold"; else fail "strict block" "s2='$s2'"; fi

printf '\n%s== Dry-run logs intent, never blocks ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 ORCH_HOOK_DRY_RUN=1 >/dev/null
d2=$(fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 ORCH_HOOK_DRY_RUN=1)
if [[ "${d2%%|*}" == "0" ]] && printf '%s' "${d2#*|}" | grep -q 'orch-dry-run\[orch-retry-cap\]'; then
  ok "dry-run: logs intent, exit 0 even under strict"
else fail "dry-run" "d2='$d2'"; fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-retry-cap%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-retry-cap — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
