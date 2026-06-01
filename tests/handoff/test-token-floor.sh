#!/usr/bin/env bash
# Tests for (a) the lib token-estimation helpers and (b) the handoff-nudge hook
# (scripts/hooks/orch-handoff-nudge.sh), which fires ONCE per fill cycle when
# conversation token usage first crosses ORCH_CONTEXT_HANDOFF_TOKENS (default
# 950000), telling the agent to write the handoff note. It re-arms when usage
# drops back below the floor (e.g. after a compaction), so a long session gets
# one nudge per cycle, never per-turn nagging.
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-handoff-nudge.sh"
LIB="${ROOT}/scripts/lib/orch-handoff.sh"
FIXTURES="${ROOT}/tests/handoff/fixtures"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

for f in "$HOOK" "$LIB"; do
  [[ -f "$f" ]] || { printf '%sFAIL%s — not found: %s\n' "$RED" "$RESET" "$f"; exit 1; }
done
# shellcheck source=scripts/lib/orch-handoff.sh
source "$LIB"

valid_json() { printf '%s' "$1" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; }
has_ctx()    { printf '%s' "$1" | grep -q 'additionalContext'; }

# Hermetic state dir so the fire-once marker never pre-exists / leaks across runs.
TMPHOME="$(mktemp -d)"
export ORCH_HOME="${TMPHOME}/orch"
trap 'rm -rf "${TMPHOME}"' EXIT

# Run the nudge hook with a given transcript fixture + session id.
# Pin the floor to 800K here so the crossing assertions (850K fires / 200K
# silent) are independent of the production default (950000).
nudge() {
  local jsonl="$1" sid="$2"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"tests/handoff/fixtures/%s"}' "$sid" "$jsonl" \
    | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_CONTEXT_HANDOFF_TOKENS=800000 bash "$HOOK" 2>/dev/null || true
}

printf '%s== lib: token extraction, synthetic-skip, window ==%s\n' "$DIM" "$RESET"

T1=$(orch_handoff_total_tokens "${FIXTURES}/high.jsonl" 1)
[[ "$T1" == "850000" ]] && ok "total_tokens(high,1) == 850000" || fail "total_tokens(high,1)" "got $T1"

ST=$(orch_handoff_total_tokens "${FIXTURES}/synthetic-trailing.jsonl" 1)
[[ "$ST" == "580000" ]] && ok "all-zero synthetic trailing line skipped → 580000 (not 0)" || fail "synthetic-trailing total" "got $ST"

CH=$(orch_handoff_total_tokens "${FIXTURES}/cachehit-trailing.jsonl" 1)
[[ "$CH" == "661000" ]] && ok "genuine cache-hit trailing turn (input 0, cache_read 660K) → 661000 (counted)" || fail "cachehit-trailing total" "got $CH"

W=$(orch_handoff_window_tokens)
[[ "$W" == "1000000" ]] && ok "window_tokens default == 1000000" || fail "window_tokens default" "got $W"
W=$(ORCH_CONTEXT_WINDOW_TOKENS=abc orch_handoff_window_tokens)
[[ "$W" == "1000000" ]] && ok "window_tokens falls back on non-numeric" || fail "window_tokens fallback" "got $W"

printf '\n%s== hook: fires once when usage first crosses the 800K floor ==%s\n' "$DIM" "$RESET"

OUT=$(nudge high.jsonl s1)   # 850K ≥ 800K → fire
has_ctx "$OUT" && ok "850K (above 800K floor), first crossing → nudge fires" || fail "first crossing fires" "got: '$OUT'"
valid_json "$OUT" && ok "nudge output is valid JSON" || fail "nudge valid JSON" "got: '$OUT'"
printf '%s' "$OUT" | grep -q '/llm-orchestrator:handoff' && ok "nudge tells the agent to run /llm-orchestrator:handoff" || fail "nudge mentions handoff command" "got: '$OUT'"

printf '\n%s== hook: does NOT re-fire on the next turn (fire-once, no nagging) ==%s\n' "$DIM" "$RESET"
OUT=$(nudge high.jsonl s1)   # same session, marker exists → silent
[[ -z "$OUT" ]] && ok "second turn still above floor → silent (marker suppresses repeat)" || fail "fire-once" "got: '$OUT'"

printf '\n%s== hook: re-arms after usage drops (compaction), then nudges again ==%s\n' "$DIM" "$RESET"
OUT=$(nudge low.jsonl s1)    # 200K < floor → re-arm (clear marker), silent
[[ -z "$OUT" ]] && ok "dropped below floor (200K) → silent and re-armed" || fail "re-arm silent" "got: '$OUT'"
OUT=$(nudge high.jsonl s1)   # back above floor → fires again
has_ctx "$OUT" && ok "crosses floor again after re-arm → nudge fires again" || fail "re-arm re-fires" "got: '$OUT'"

printf '\n%s== hook: below floor with no prior marker → silent ==%s\n' "$DIM" "$RESET"
OUT=$(nudge low.jsonl s2)    # fresh session, 200K < floor → silent
[[ -z "$OUT" ]] && ok "200K, fresh session → silent" || fail "below floor silent" "got: '$OUT'"

printf '\n%s== hook: floor is configurable ==%s\n' "$DIM" "$RESET"
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s3","transcript_path":"tests/handoff/fixtures/low.jsonl"}' \
  | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_CONTEXT_HANDOFF_TOKENS=150000 bash "$HOOK" 2>/dev/null || true)
has_ctx "$OUT" && ok "200K with floor lowered to 150K → fires" || fail "configurable floor" "got: '$OUT'"
# Non-numeric floor falls back to 950000 → 200K silent.
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s4","transcript_path":"tests/handoff/fixtures/low.jsonl"}' \
  | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_CONTEXT_HANDOFF_TOKENS=oops bash "$HOOK" 2>/dev/null || true)
[[ -z "$OUT" ]] && ok "non-numeric floor → defaults to 950000 → 200K silent" || fail "floor fallback" "got: '$OUT'"

printf '\n%s== hook: disabled / minimal → silent even above floor ==%s\n' "$DIM" "$RESET"
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s5","transcript_path":"tests/handoff/fixtures/high.jsonl"}' \
  | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_DISABLED_HOOKS=orch-handoff-nudge bash "$HOOK" 2>/dev/null || true)
[[ -z "$OUT" ]] && ok "ORCH_DISABLED_HOOKS=orch-handoff-nudge → silent" || fail "disabled silent" "got: '$OUT'"
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s6","transcript_path":"tests/handoff/fixtures/high.jsonl"}' \
  | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOOK_PROFILE=minimal bash "$HOOK" 2>/dev/null || true)
[[ -z "$OUT" ]] && ok "ORCH_HOOK_PROFILE=minimal → silent" || fail "minimal silent" "got: '$OUT'"

printf '\n%s== hook: missing/empty transcript → silent (no crash) ==%s\n' "$DIM" "$RESET"
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s7"}' | CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" 2>/dev/null || true)
[[ -z "$OUT" ]] && ok "no transcript_path → silent" || fail "missing transcript silent" "got: '$OUT'"

printf '\n%s== hook: leading-zero floor is base-10, not octal ==%s\n' "$DIM" "$RESET"
# 0900000 must mean 900000 (decimal). low.jsonl is 200K, which is below it → silent.
# Without base-10 normalization, bash reads 0900000 as octal, errors on the
# invalid digit 9, and the hook would fire (and garble the message) instead.
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s8","transcript_path":"tests/handoff/fixtures/low.jsonl"}' \
  | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_CONTEXT_HANDOFF_TOKENS=0900000 bash "$HOOK" 2>/dev/null || true)
[[ -z "$OUT" ]] && ok "floor 0900000 (base-10 = 900000) + 200K → silent (no octal misparse)" || fail "octal floor" "got: '$OUT'"

printf '\n%s== hook: non-writable marker location → no nag loop (fires at most once) ==%s\n' "$DIM" "$RESET"
# ORCH_HOME under a non-directory path makes the marker un-writable. The hook
# must NOT nudge every turn — it exits silently when it cannot record the marker.
NAG=0
for _i in 1 2 3; do
  out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"s9","transcript_path":"tests/handoff/fixtures/high.jsonl"}' \
    | CLAUDE_PROJECT_DIR="${ROOT}" ORCH_HOME=/dev/null/nope bash "$HOOK" 2>/dev/null || true)
  printf '%s' "$out" | grep -q 'additionalContext' && NAG=$((NAG+1))
done
(( NAG <= 1 )) && ok "non-writable marker dir → fired ${NAG} times across 3 turns (≤1, no nag loop)" || fail "nag loop on non-writable marker" "fired ${NAG}/3"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-token-floor%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-token-floor — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
