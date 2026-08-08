#!/usr/bin/env bash
# Tests for the post-compaction recovery note — the REACTIVE half of Layer 9.
#
# Contract (reactive-only; re-verified 2026-08-08):
#   - Claude Code DOES ship PreCompact and PostCompact hooks (the 2026-05-31
#     version of this note claimed it shipped neither — that was wrong, and it
#     was load-bearing for keeping Layer 9 reactive). This suite stays scoped to
#     the reactive half regardless: PreCompact carries no additionalContext in
#     hookSpecificOutput, so it cannot inject the recovery note, and adopting it
#     for anything else is an unmeasured behaviour bet — see docs/MEASUREMENTS.md.
#   - When native compaction fires, session-start.sh runs with source=="compact" and injects
#     ONLY a lean recovery note via hookSpecificOutput.additionalContext (no
#     meta-skill body, to stay under the 10,000-char cap), deriving the newest
#     handoff artifact path inline (by mtime).
#   - The note tells the next turn: treat the summary as lossy, reconcile against
#     the plan-file checkboxes (authoritative), re-verify if the baseline looks
#     stale, discard a slug-mismatched handoff, stop if all tasks are checked.
#   - Suppressed under ORCH_HOOK_PROFILE=minimal and when ORCH_DISABLED_HOOKS
#     contains "orch-handoff-nudge"; on a normal startup it loads the full
#     meta-skill instead and emits no recovery note.
#
# (The proactive write-nudge floor is covered by test-token-floor.sh.)
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SESSION_HOOK="${ROOT}/scripts/hooks/session-start.sh"

TMPHOME="$(mktemp -d)"
trap 'rm -rf "${TMPHOME}"' EXIT

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

assert_valid_json() {
  local label="$1" output="$2"
  [[ -z "$output" ]] && return 0
  if printf '%s' "$output" | python3 -c "import json,sys;json.load(sys.stdin)" 2>/dev/null; then
    ok "${label}: valid JSON"
  else
    fail "${label}: valid JSON" "output was not valid JSON: $(printf '%s' "$output" | head -c 200)"
  fi
}

[[ -f "$SESSION_HOOK" ]] || { printf '%sFAIL: test-precompact%s — not found: %s\n' "$RED" "$RESET" "$SESSION_HOOK"; exit 1; }

printf '%s== Post-compaction lean injection via SessionStart ==%s\n' "$DIM" "$RESET"

PROJ1="${TMPHOME}/proj1"
mkdir -p "${PROJ1}/docs/llm-orchestrator/handoffs"
printf -- '---\nslug: demo\n---\n' > "${PROJ1}/docs/llm-orchestrator/handoffs/2026-05-31-demo.md"

COMPACT_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"compact","session_id":"c1"}' | CLAUDE_PROJECT_DIR="${PROJ1}" bash "$SESSION_HOOK" 2>/dev/null || true)

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
  ok "SessionStart compact: tells controller to re-check the verification baseline"
else
  fail "SessionStart compact: verification baseline" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi
if printf '%s' "$COMPACT_OUT" | grep -q 'checkboxes'; then
  ok "SessionStart compact: points at the plan checkboxes as authoritative"
else
  fail "SessionStart compact: plan checkboxes authoritative" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi
if printf '%s' "$COMPACT_OUT" | grep -q '2026-05-31-demo.md'; then
  ok "SessionStart compact: derives the newest handoff path inline"
else
  fail "SessionStart compact: derives newest handoff path" "got: '$(printf '%s' "$COMPACT_OUT" | head -c 200)'"
fi
if printf '%s' "$COMPACT_OUT" | grep -q 'You are running LLM Orchestrator'; then
  fail "SessionStart compact: must NOT re-inject the full meta-skill (10K cap risk)" "meta preamble leaked"
else
  ok "SessionStart compact: lean — no meta-skill preamble"
fi
if (( ${#COMPACT_OUT} < 10000 )); then
  ok "SessionStart compact: output ${#COMPACT_OUT} chars (< 10000 additionalContext cap)"
else
  fail "SessionStart compact: under 10000-char cap" "was ${#COMPACT_OUT} chars"
fi
assert_valid_json "SessionStart compact" "$COMPACT_OUT"

printf '\n%s== Post-compaction "none" fallback (no handoff yet) ==%s\n' "$DIM" "$RESET"
PROJ2="${TMPHOME}/proj2"
mkdir -p "${PROJ2}/docs/llm-orchestrator/handoffs"   # empty
NONE_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"compact","session_id":"c2"}' | CLAUDE_PROJECT_DIR="${PROJ2}" bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$NONE_OUT" | grep -q 'Newest handoff artifact: none' && printf '%s' "$NONE_OUT" | grep -q 'rebuild from the plan file and git history'; then
  ok "SessionStart compact (no artifact): emits 'none' + rebuild-from-plan instruction"
else
  fail "SessionStart compact (no artifact): 'none' + rebuild instruction" "got: '$(printf '%s' "$NONE_OUT" | head -c 200)'"
fi
assert_valid_json "SessionStart compact none" "$NONE_OUT"

printf '\n%s== SessionStart startup unaffected ==%s\n' "$DIM" "$RESET"
STARTUP_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$STARTUP_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "SessionStart startup: must NOT inject post-compaction advisory" "got post-compaction note on a normal startup"
else
  ok "SessionStart startup: no post-compaction advisory (correct)"
fi
if printf '%s' "$STARTUP_OUT" | grep -q 'You are running LLM Orchestrator'; then
  ok "SessionStart startup: still loads the full meta-skill bootstrap"
else
  fail "SessionStart startup: loads meta-skill bootstrap" "bootstrap missing on startup"
fi
assert_valid_json "SessionStart startup" "$STARTUP_OUT"

printf '\n%s== Recovery note is profile/disable-aware (minimal=silent) ==%s\n' "$DIM" "$RESET"
COMPACT_INPUT='{"hook_event_name":"SessionStart","source":"compact"}'

MIN_OUT=$(printf '%s' "$COMPACT_INPUT" | ORCH_HOOK_PROFILE=minimal bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$MIN_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "minimal profile + compact: must suppress recovery note" "advisory leaked under minimal"
else
  ok "minimal profile + compact: recovery note suppressed"
fi
if printf '%s' "$MIN_OUT" | grep -q 'You are running LLM Orchestrator'; then
  ok "minimal profile: meta-skill bootstrap still loads (not suppressed)"
else
  fail "minimal profile: meta-skill bootstrap still loads" "bootstrap missing under minimal"
fi
assert_valid_json "minimal compact" "$MIN_OUT"

DIS_OUT=$(printf '%s' "$COMPACT_INPUT" | ORCH_DISABLED_HOOKS=orch-handoff-nudge bash "$SESSION_HOOK" 2>/dev/null || true)
if printf '%s' "$DIS_OUT" | grep -q 'resumed immediately after native context compaction'; then
  fail "disabled handoff-nudge + compact: must suppress recovery note" "advisory leaked when disabled"
else
  ok "ORCH_DISABLED_HOOKS=orch-handoff-nudge + compact: recovery note suppressed"
fi
assert_valid_json "disabled compact" "$DIS_OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-precompact%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-precompact — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
