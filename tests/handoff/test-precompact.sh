#!/usr/bin/env bash
# Tests for PreCompact awareness in orch-context-pressure.sh.
#
# Checks:
#   1. PreCompact advisory (auto trigger): stdout contains hookEventName, additionalContext, "compaction"
#   2. Manual trigger advisory (not strict): still advisory, not block
#   3. Strict auto block: ORCH_HOOK_PROFILE=strict + ORCH_STRICT_CONTEXT_PRESSURE=1 + auto → block
#   4. Disabled: ORCH_DISABLED_HOOKS=orch-context-pressure + PreCompact → empty stdout
#   5. UserPromptSubmit regression: high-input.json still yields additionalContext
#   6. Valid JSON: each non-empty output parses with python3
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-context-pressure.sh"
FIXTURES="${ROOT}/tests/handoff/fixtures"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

assert_valid_json() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    return 0  # empty stdout is fine (disabled/below-threshold paths)
  fi
  if printf '%s' "$output" | python3 -c "import json,sys;json.load(sys.stdin)" 2>/dev/null; then
    ok "${label}: valid JSON"
  else
    fail "${label}: valid JSON" "output was not valid JSON: $(printf '%s' "$output" | head -c 200)"
  fi
}

# Guard: hook must exist.
if [[ ! -f "$HOOK" ]]; then
  printf '%sFAIL: test-precompact%s — hook not found: %s\n' "$RED" "$RESET" "$HOOK"
  exit 1
fi

printf '%s== PreCompact advisory (auto trigger) ==%s\n' "$DIM" "$RESET"

AUTO_INPUT='{"hook_event_name":"PreCompact","trigger":"auto","transcript_path":"tests/handoff/fixtures/high.jsonl"}'
AUTO_OUT=$(printf '%s' "$AUTO_INPUT" | CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" 2>/dev/null || true)

if printf '%s' "$AUTO_OUT" | grep -q '"hookEventName":"PreCompact"'; then
  ok "PreCompact auto: stdout contains hookEventName:PreCompact"
else
  fail "PreCompact auto: stdout contains hookEventName:PreCompact" "got: '${AUTO_OUT}'"
fi

if printf '%s' "$AUTO_OUT" | grep -q 'additionalContext'; then
  ok "PreCompact auto: stdout contains additionalContext"
else
  fail "PreCompact auto: stdout contains additionalContext" "got: '${AUTO_OUT}'"
fi

if printf '%s' "$AUTO_OUT" | grep -q 'compaction'; then
  ok "PreCompact auto: stdout contains 'compaction'"
else
  fail "PreCompact auto: stdout contains 'compaction'" "got: '${AUTO_OUT}'"
fi

assert_valid_json "PreCompact auto" "$AUTO_OUT"

printf '\n%s== PreCompact advisory (manual trigger, non-strict) ==%s\n' "$DIM" "$RESET"

MANUAL_INPUT='{"hook_event_name":"PreCompact","trigger":"manual","transcript_path":"tests/handoff/fixtures/high.jsonl"}'
MANUAL_OUT=$(printf '%s' "$MANUAL_INPUT" | CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" 2>/dev/null || true)

if printf '%s' "$MANUAL_OUT" | grep -q 'additionalContext'; then
  ok "PreCompact manual: advisory (additionalContext present)"
else
  fail "PreCompact manual: advisory (additionalContext present)" "got: '${MANUAL_OUT}'"
fi

if printf '%s' "$MANUAL_OUT" | grep -qv '"decision":"block"' 2>/dev/null || ! printf '%s' "$MANUAL_OUT" | grep -q '"decision"'; then
  ok "PreCompact manual: no block decision emitted"
else
  fail "PreCompact manual: no block decision emitted" "got: '${MANUAL_OUT}'"
fi

assert_valid_json "PreCompact manual" "$MANUAL_OUT"

printf '\n%s== PreCompact strict auto → block ==%s\n' "$DIM" "$RESET"

STRICT_OUT=$(printf '%s' "$AUTO_INPUT" | \
  CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOOK_PROFILE=strict ORCH_STRICT_CONTEXT_PRESSURE=1 \
  bash "$HOOK" 2>/dev/null || true)

if printf '%s' "$STRICT_OUT" | grep -q '"decision":"block"'; then
  ok "PreCompact strict+auto: emits top-level decision:block"
else
  fail "PreCompact strict+auto: emits top-level decision:block" "got: '${STRICT_OUT}'"
fi

assert_valid_json "PreCompact strict auto block" "$STRICT_OUT"

printf '\n%s== Disabled hook ==%s\n' "$DIM" "$RESET"

DISABLED_OUT=$(printf '%s' "$AUTO_INPUT" | \
  ORCH_DISABLED_HOOKS=orch-context-pressure bash "$HOOK" 2>/dev/null || true)

if [[ -z "$DISABLED_OUT" ]]; then
  ok "ORCH_DISABLED_HOOKS=orch-context-pressure + PreCompact → empty stdout"
else
  fail "ORCH_DISABLED_HOOKS=orch-context-pressure + PreCompact → empty stdout" "got: '${DISABLED_OUT}'"
fi

printf '\n%s== UserPromptSubmit regression ==%s\n' "$DIM" "$RESET"

UPS_OUT=$(CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)

if printf '%s' "$UPS_OUT" | grep -q 'additionalContext'; then
  ok "UserPromptSubmit regression: high-input.json → additionalContext"
else
  fail "UserPromptSubmit regression: high-input.json → additionalContext" "got: '${UPS_OUT}'"
fi

if printf '%s' "$UPS_OUT" | grep -q '"hookEventName":"UserPromptSubmit"'; then
  ok "UserPromptSubmit regression: hookEventName is UserPromptSubmit"
else
  fail "UserPromptSubmit regression: hookEventName is UserPromptSubmit" "got: '${UPS_OUT}'"
fi

assert_valid_json "UserPromptSubmit regression" "$UPS_OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-precompact%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-precompact — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
