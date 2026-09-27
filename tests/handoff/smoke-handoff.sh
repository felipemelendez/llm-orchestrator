#!/usr/bin/env bash
# End-to-end smoke tests for the handoff token-estimation lib and the
# handoff-nudge hook.
#
# Tests:
#   1. orch_handoff_estimate_pct against fixture JSONL files
#   2. Hook output: high-input.json → additionalContext; below-floor → empty
#   3. Disabled-hook: ORCH_DISABLED_HOOKS / ORCH_HOOK_PROFILE=minimal → empty stdout
#   4. ORCH_CONTEXT_WINDOW_TOKENS validation (non-numeric / empty → 1000000)
#   5. Bounded tail read on a large synthetic transcript
#
# The hook's speed is not timed here: one wall-clock run failed whenever the
# machine was busy. tests/test-hook-latency.sh times it (median of five runs).
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${ROOT}/scripts/lib/orch-handoff.sh"
HOOK="${ROOT}/scripts/hooks/orch-handoff-nudge.sh"
FIXTURES="${ROOT}/tests/handoff/fixtures"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

if [[ ! -f "$LIB" ]]; then
  fail "orch-handoff.sh exists at scripts/lib/orch-handoff.sh" "not found: $LIB"
  printf '%sFAIL: smoke-handoff%s\n' "$RED" "$RESET"
  exit 1
fi
# shellcheck source=../../scripts/lib/orch-handoff.sh
source "$LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ============================================================
# Section 1: orch_handoff_estimate_pct fixture assertions
# ============================================================
printf '%s== orch_handoff_estimate_pct ==%s\n' "$DIM" "$RESET"

check_pct() {
  local label="$1" file="$2" expected="$3"
  local got
  got=$(orch_handoff_estimate_pct "$file" 2>/dev/null)
  if [[ "$got" == "$expected" ]]; then
    ok "${label}: estimate_pct == ${expected}"
  else
    fail "${label}: estimate_pct == ${expected}" "got: '${got}'"
  fi
}

check_pct "high.jsonl (85%)"       "${FIXTURES}/high.jsonl"       "85"
check_pct "low.jsonl (20%)"        "${FIXTURES}/low.jsonl"        "20"
check_pct "nested-cache.jsonl (75%)" "${FIXTURES}/nested-cache.jsonl" "75"
check_pct "malformed.jsonl (unknown)" "${FIXTURES}/malformed.jsonl" "unknown"

# ============================================================
# Section 2: Hook end-to-end — above floor fires, below floor silent
# ============================================================
printf '\n%s== hook output (high/low inputs) ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$HOOK" ]]; then
  fail "hook exists at scripts/hooks/orch-handoff-nudge.sh" "not found: $HOOK"
else
  ok "hook script found"

  # Hermetic state dir so the fire-once marker never pre-exists / leaks.
  _SMOKE_HOME="$(mktemp -d)"

  # high-input.json (850K) with the floor pinned to 800K (independent of the
  # 950000 production default) → nudge fires (additionalContext).
  HIGH_OUT=$(CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOME="${_SMOKE_HOME}" ORCH_CONTEXT_HANDOFF_TOKENS=800000 \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)

  if printf '%s' "$HIGH_OUT" | grep -q 'additionalContext'; then
    ok "high-input.json (850K) → nudge fires (additionalContext)"
  else
    fail "high-input.json (850K) → nudge fires" "got: '${HIGH_OUT}'"
  fi

  # floor-below-input.json (50K, under the floor) → silent.
  LOW_OUT=$(CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOME="${_SMOKE_HOME}" ORCH_CONTEXT_HANDOFF_TOKENS=800000 \
    bash "$HOOK" < "${FIXTURES}/floor-below-input.json" 2>/dev/null || true)

  if [[ -z "$LOW_OUT" ]]; then
    ok "below-floor input (50K) → empty stdout"
  else
    fail "below-floor input (50K) → empty stdout" "got: '${LOW_OUT}'"
  fi
  rm -rf "${_SMOKE_HOME}"
fi

# ============================================================
# Section 3: Disabled-hook — ORCH_DISABLED_HOOKS / minimal → empty stdout
# ============================================================
printf '\n%s== disabled-hook (ORCH_DISABLED_HOOKS / ORCH_HOOK_PROFILE=minimal) ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$HOOK" ]]; then
  fail "hook exists for disabled-hook test" "not found: $HOOK"
else
  DISABLED_OUT=$(ORCH_DISABLED_HOOKS=orch-handoff-nudge ORCH_HOME="$(mktemp -d)" \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)
  if [[ -z "$DISABLED_OUT" ]]; then
    ok "ORCH_DISABLED_HOOKS=orch-handoff-nudge → empty stdout on high-input.json"
  else
    fail "ORCH_DISABLED_HOOKS=orch-handoff-nudge → empty stdout on high-input.json" "got: '${DISABLED_OUT}'"
  fi

  MINIMAL_OUT=$(ORCH_HOOK_PROFILE=minimal ORCH_HOME="$(mktemp -d)" \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)
  if [[ -z "$MINIMAL_OUT" ]]; then
    ok "ORCH_HOOK_PROFILE=minimal → empty stdout on high-input.json"
  else
    fail "ORCH_HOOK_PROFILE=minimal → empty stdout on high-input.json" "got: '${MINIMAL_OUT}'"
  fi
fi

# ============================================================
# Section 4: ORCH_CONTEXT_WINDOW_TOKENS validation (fallback to 1000000)
# ============================================================
printf '\n%s== ORCH_CONTEXT_WINDOW_TOKENS validation ==%s\n' "$DIM" "$RESET"

PCT_ABC=$(ORCH_CONTEXT_WINDOW_TOKENS=abc orch_handoff_estimate_pct "${FIXTURES}/high.jsonl" 2>/dev/null)
if [[ "$PCT_ABC" == "85" ]]; then
  ok "ORCH_CONTEXT_WINDOW_TOKENS=abc falls back to 1000000 (high.jsonl still 85%)"
else
  fail "ORCH_CONTEXT_WINDOW_TOKENS=abc falls back to 1000000" "got: '${PCT_ABC}'"
fi

PCT_EMPTY=$(ORCH_CONTEXT_WINDOW_TOKENS= orch_handoff_estimate_pct "${FIXTURES}/high.jsonl" 2>/dev/null)
if [[ "$PCT_EMPTY" == "85" ]]; then
  ok "ORCH_CONTEXT_WINDOW_TOKENS= (empty) falls back to 1000000 (high.jsonl still 85%)"
else
  fail "ORCH_CONTEXT_WINDOW_TOKENS= (empty) falls back to 1000000" "got: '${PCT_EMPTY}'"
fi

# ============================================================
# Section 5: bounded tail read on a large synthetic transcript
# ============================================================
printf '\n%s== bounded tail read ==%s\n' "$DIM" "$RESET"

SYNTH_TRANSCRIPT="${TMP}/synth-large.jsonl"
for i in $(seq 1 5000); do
  printf '{"type":"human","message":{"content":"turn %d"}}\n' "$i"
done > "$SYNTH_TRANSCRIPT"
printf '{"type":"assistant","message":{"usage":{"input_tokens":250000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  >> "$SYNTH_TRANSCRIPT"

PCT_SYNTH=$(orch_handoff_estimate_pct "$SYNTH_TRANSCRIPT" 2>/dev/null)
if [[ "$PCT_SYNTH" == "25" ]]; then
  ok "synthetic large transcript (5000 junk lines + usage at end) → estimate_pct == 25"
else
  fail "synthetic large transcript → estimate_pct == 25" "got: '${PCT_SYNTH}'"
fi

SYNTH_SIZE=$(wc -c < "$SYNTH_TRANSCRIPT" | tr -d ' ')
if [[ "$SYNTH_SIZE" -gt 100000 ]]; then
  ok "synthetic transcript is > 100KB (${SYNTH_SIZE} bytes) — tail path exercised"
else
  # NOT a pass: a fixture too small to reach the tail path proves nothing
  # about it. Both branches of this if/else used to print ok, so the check
  # could not fail in any world and inflated the pass count by one either way.
  printf '  %snote%s synthetic transcript is only %s bytes — tail path NOT exercised this run\n' \
    "$DIM" "$RESET" "$SYNTH_SIZE"
fi

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: smoke-handoff%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: smoke-handoff — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
