#!/usr/bin/env bash
# Tests for the PreCompact + post-compaction handoff contract.
#
# Contract under test (corrected 2026-05-30):
#   - PreCompact does NOT support hookSpecificOutput.additionalContext; that field
#     is dropped and fails schema validation on manual /compact. So the advisory
#     path on PreCompact emits NOTHING.
#   - The only valid PreCompact output is the top-level {"decision":"block",...},
#     emitted only in strict mode on an auto trigger.
#   - The post-compaction advisory is injected by session-start.sh when the
#     session begins with source=="compact" (SessionStart DOES support
#     additionalContext and fires after compaction).
#
# Checks:
#   1. PreCompact auto, non-strict   → empty stdout (no additionalContext)
#   2. PreCompact manual, non-strict → empty stdout
#   3. PreCompact strict + auto      → top-level decision:block
#   4. Disabled hook                 → empty stdout
#   5. UserPromptSubmit regression   → additionalContext (unchanged contract)
#   6. session-start source=compact  → additionalContext w/ post-compaction note
#   7. session-start source=startup  → no post-compaction note
#   8. Valid JSON on every non-empty output
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-context-pressure.sh"
SESSION_HOOK="${ROOT}/scripts/hooks/session-start.sh"
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
    return 0  # empty stdout is fine (disabled / advisory-suppressed paths)
  fi
  if printf '%s' "$output" | python3 -c "import json,sys;json.load(sys.stdin)" 2>/dev/null; then
    ok "${label}: valid JSON"
  else
    fail "${label}: valid JSON" "output was not valid JSON: $(printf '%s' "$output" | head -c 200)"
  fi
}

# Guard: hooks must exist.
for h in "$HOOK" "$SESSION_HOOK"; do
  if [[ ! -f "$h" ]]; then
    printf '%sFAIL: test-precompact%s — hook not found: %s\n' "$RED" "$RESET" "$h"
    exit 1
  fi
done

printf '%s== PreCompact advisory path emits nothing (additionalContext unsupported) ==%s\n' "$DIM" "$RESET"

AUTO_INPUT='{"hook_event_name":"PreCompact","trigger":"auto","transcript_path":"tests/handoff/fixtures/high.jsonl"}'
AUTO_OUT=$(printf '%s' "$AUTO_INPUT" | CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" 2>/dev/null || true)

if [[ -z "$AUTO_OUT" ]]; then
  ok "PreCompact auto (non-strict): empty stdout"
else
  fail "PreCompact auto (non-strict): empty stdout" "got: '${AUTO_OUT}'"
fi

if printf '%s' "$AUTO_OUT" | grep -q 'additionalContext'; then
  fail "PreCompact auto: must NOT emit additionalContext" "got: '${AUTO_OUT}'"
else
  ok "PreCompact auto: no additionalContext (correct — PreCompact does not support it)"
fi

MANUAL_INPUT='{"hook_event_name":"PreCompact","trigger":"manual","transcript_path":"tests/handoff/fixtures/high.jsonl"}'
MANUAL_OUT=$(printf '%s' "$MANUAL_INPUT" | CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" 2>/dev/null || true)

if [[ -z "$MANUAL_OUT" ]]; then
  ok "PreCompact manual (non-strict): empty stdout"
else
  fail "PreCompact manual (non-strict): empty stdout" "got: '${MANUAL_OUT}'"
fi

printf '\n%s== PreCompact strict auto → block ==%s\n' "$DIM" "$RESET"

STRICT_OUT=$(printf '%s' "$AUTO_INPUT" | \
  CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOOK_PROFILE=strict ORCH_STRICT_CONTEXT_PRESSURE=1 \
  bash "$HOOK" 2>/dev/null || true)

if printf '%s' "$STRICT_OUT" | grep -q '"decision":"block"'; then
  ok "PreCompact strict+auto: emits top-level decision:block"
else
  fail "PreCompact strict+auto: emits top-level decision:block" "got: '${STRICT_OUT}'"
fi

# The block payload must NOT carry hookSpecificOutput/additionalContext.
if printf '%s' "$STRICT_OUT" | grep -q 'additionalContext'; then
  fail "PreCompact strict block: must not carry additionalContext" "got: '${STRICT_OUT}'"
else
  ok "PreCompact strict block: clean decision/reason payload only"
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

printf '\n%s== Post-compaction injection via SessionStart ==%s\n' "$DIM" "$RESET"

COMPACT_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"compact"}' | bash "$SESSION_HOOK" 2>/dev/null || true)

if printf '%s' "$COMPACT_OUT" | grep -q '"hookEventName":"SessionStart"'; then
  ok "SessionStart compact: hookEventName is SessionStart"
else
  fail "SessionStart compact: hookEventName is SessionStart" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi

if printf '%s' "$COMPACT_OUT" | grep -q 'resumed immediately after native context compaction'; then
  ok "SessionStart compact: injects post-compaction advisory"
else
  fail "SessionStart compact: injects post-compaction advisory" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi

if printf '%s' "$COMPACT_OUT" | grep -q 'verification baseline'; then
  ok "SessionStart compact: advisory tells controller to re-run verification baseline"
else
  fail "SessionStart compact: advisory tells controller to re-run verification baseline" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi

assert_valid_json "SessionStart compact" "$COMPACT_OUT"

STARTUP_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$SESSION_HOOK" 2>/dev/null || true)

if printf '%s' "$STARTUP_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "SessionStart startup: must NOT inject post-compaction advisory" "got post-compaction note on a normal startup"
else
  ok "SessionStart startup: no post-compaction advisory (correct)"
fi

assert_valid_json "SessionStart startup" "$STARTUP_OUT"

printf '\n%s== Post-compaction advisory is profile/disable-aware (minimal=silent) ==%s\n' "$DIM" "$RESET"

COMPACT_INPUT='{"hook_event_name":"SessionStart","source":"compact"}'

MIN_OUT=$(printf '%s' "$COMPACT_INPUT" | ORCH_HOOK_PROFILE=minimal bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$MIN_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "minimal profile + compact: must suppress post-compaction advisory" "advisory leaked under minimal"
else
  ok "minimal profile + compact: post-compaction advisory suppressed"
fi
# But the meta-skill bootstrap must still load under minimal.
if printf '%s' "$MIN_OUT" | grep -q 'EXTREMELY_IMPORTANT'; then
  ok "minimal profile: meta-skill bootstrap still loads (not suppressed)"
else
  fail "minimal profile: meta-skill bootstrap still loads" "bootstrap missing under minimal"
fi
assert_valid_json "minimal compact" "$MIN_OUT"

DIS_OUT=$(printf '%s' "$COMPACT_INPUT" | ORCH_DISABLED_HOOKS=orch-context-pressure bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$DIS_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "disabled pressure hook + compact: must suppress post-compaction advisory" "advisory leaked when pressure hook disabled"
else
  ok "disabled pressure hook + compact: post-compaction advisory suppressed"
fi
assert_valid_json "disabled-pressure compact" "$DIS_OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-precompact%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-precompact — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
