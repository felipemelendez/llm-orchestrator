#!/usr/bin/env bash
# Tests for the absolute token floor in the context-pressure advisory
# (orch-context-pressure.sh UserPromptSubmit branch) and the supporting lib
# helpers (orch_handoff_total_tokens, orch_handoff_window_tokens).
#
# Design (post-review): percentage thresholds are miscalibrated on a 1M window
# (native auto-compaction fires near ~150K tokens, ~15% fill, far below a 70%
# warn at 700K). An absolute floor (ORCH_CONTEXT_HANDOFF_TOKENS, default 120000)
# restores a proactive prong. The advisory fires each turn while above the floor
# (consistent with the per-turn protocol reminder), not via a fragile edge-trigger
# that real-transcript shapes (synthetic zero-usage lines, multi-usage turns,
# cache dips) would defeat. The extractor SKIPS synthetic all-zero usage lines.
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-context-pressure.sh"
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

run() { CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" < "${FIXTURES}/$1" 2>/dev/null || true; }
has_advisory() { printf '%s' "$1" | grep -q 'additionalContext'; }
valid_json() { printf '%s' "$1" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null; }

printf '%s== lib: token extraction, synthetic-skip, window ==%s\n' "$DIM" "$RESET"

T1=$(orch_handoff_total_tokens "${FIXTURES}/high.jsonl" 1)
[[ "$T1" == "850000" ]] && ok "total_tokens(high,1) == 850000" || fail "total_tokens(high,1)" "got $T1"

# Only one usage line → 2nd-from-last is unknown (not a duplicate of the last).
T2=$(orch_handoff_total_tokens "${FIXTURES}/high.jsonl" 2)
[[ "$T2" == "unknown" ]] && ok "total_tokens(high,2) == unknown (single usage line)" || fail "total_tokens(high,2)" "got $T2"

# CRITICAL: a synthetic trailing line (ALL usage fields zero) must be skipped, so
# the estimate reflects the real prior turn (580K), not 0.
ST=$(orch_handoff_total_tokens "${FIXTURES}/synthetic-trailing.jsonl" 1)
[[ "$ST" == "580000" ]] && ok "all-zero synthetic trailing line skipped → 580000 (not 0)" || fail "synthetic-trailing total" "got $ST"
STP=$(orch_handoff_estimate_pct "${FIXTURES}/synthetic-trailing.jsonl")
[[ "$STP" =~ ^5[78]$ ]] && ok "synthetic-trailing estimate_pct ~58% (not 0%)" || fail "synthetic-trailing pct" "got $STP"

# CRITICAL (regression guard): a GENUINE trailing turn that was a full cache hit
# reports input_tokens:0 but a large cache_read — it carries the real fill and
# MUST be counted, not mistaken for synthetic. Keying skip on input_tokens==0
# alone (the earlier wrong fix) returned an undercount/unknown here.
CH=$(orch_handoff_total_tokens "${FIXTURES}/cachehit-trailing.jsonl" 1)
[[ "$CH" == "661000" ]] && ok "genuine cache-hit trailing turn (input 0, cache_read 660K) → 661000 (counted, not dropped)" || fail "cachehit-trailing total" "got $CH (must be 661000)"
CHP=$(orch_handoff_estimate_pct "${FIXTURES}/cachehit-trailing.jsonl")
[[ "$CHP" == "66" ]] && ok "cachehit-trailing estimate_pct == 66% (real fill, not undercount/unknown)" || fail "cachehit-trailing pct" "got $CHP"

# A transcript whose only usage line is truly synthetic (all zero) → unknown.
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "${FIXTURES}/all-synthetic.jsonl"
AS=$(orch_handoff_total_tokens "${FIXTURES}/all-synthetic.jsonl" 1)
[[ "$AS" == "unknown" ]] && ok "all-synthetic transcript → unknown" || fail "all-synthetic" "got $AS"
rm -f "${FIXTURES}/all-synthetic.jsonl"

W=$(orch_handoff_window_tokens)
[[ "$W" == "1000000" ]] && ok "window_tokens default == 1000000" || fail "window_tokens default" "got $W"
W=$(ORCH_CONTEXT_WINDOW_TOKENS=abc orch_handoff_window_tokens)
[[ "$W" == "1000000" ]] && ok "window_tokens falls back on non-numeric" || fail "window_tokens fallback" "got $W"

printf '\n%s== hook: advisory fires while above the floor ==%s\n' "$DIM" "$RESET"

OUT=$(run synthetic-trailing-input.json)
has_advisory "$OUT" && ok "synthetic trailing line, real fill 580K → fires (not silently 0)" || fail "synthetic-trailing fires" "got: '$OUT'"
valid_json "$OUT" && ok "advisory is valid JSON" || fail "advisory valid JSON" "got: '$OUT'"

OUT=$(run cachehit-trailing-input.json)
has_advisory "$OUT" && ok "genuine cache-hit trailing turn (661K) → fires (not silenced by input_tokens:0)" || fail "cachehit-trailing fires" "got: '$OUT'"

OUT=$(run floor-cross-input.json)
has_advisory "$OUT" && ok "130K (above 120K floor) → fires" || fail "130K fires" "got: '$OUT'"

# Fires every turn while above floor (no edge-trigger; matches per-turn reminder).
OUT=$(run floor-already-input.json)
has_advisory "$OUT" && ok "140K, sustained above floor → still fires (per-turn, no missed nudge)" || fail "140K fires" "got: '$OUT'"

OUT=$(run floor-below-input.json)
has_advisory "$OUT" && fail "50K below floor must be silent" "got: '$OUT'" || ok "50K below floor → silent"

OUT=$(run high-input.json)
has_advisory "$OUT" && ok "850K single line → fires" || fail "850K fires" "got: '$OUT'"

printf '\n%s== hook: floor vs percentage interplay ==%s\n' "$DIM" "$RESET"

# Disable the floor (above window) → 850K = 85% ≥ 70% warn → fires via pct.
OUT=$(ORCH_CONTEXT_HANDOFF_TOKENS=2000000 run high-input.json)
has_advisory "$OUT" && ok "floor disabled + 85% fill → fires via warn percentage" || fail "warn pct path" "got: '$OUT'"

# Disable floor + low fill (5%) → silent.
OUT=$(ORCH_CONTEXT_HANDOFF_TOKENS=2000000 run floor-below-input.json)
has_advisory "$OUT" && fail "floor disabled + 5% must be silent" "got: '$OUT'" || ok "floor disabled + 5% → silent"

# Non-numeric floor falls back to default (120000) → 130K still fires.
OUT=$(ORCH_CONTEXT_HANDOFF_TOKENS=oops run floor-cross-input.json)
has_advisory "$OUT" && ok "non-numeric floor → default 120000 → 130K fires" || fail "non-numeric floor fallback" "got: '$OUT'"

printf '\n%s== hook: malformed thresholds fail SAFE, not open-to-silence ==%s\n' "$DIM" "$RESET"

# A non-numeric WARN_PCT must not abort the script and silently suppress the
# floor advisory (set -u + (( )) would otherwise kill it). 130K > floor → fires.
OUT=$(ORCH_CONTEXT_WARN_PCT=abc run floor-cross-input.json)
has_advisory "$OUT" && ok "WARN_PCT=abc → defaults to 70, advisory still fires" || fail "WARN_PCT=abc no fail-open" "got: '$OUT'"
OUT=$(ORCH_CONTEXT_WARN_PCT='1 2' run floor-cross-input.json)
has_advisory "$OUT" && ok "WARN_PCT='1 2' (spaces) → defaults to 70, still fires" || fail "WARN_PCT spaces no fail-open" "got: '$OUT'"

# Non-numeric BLOCK_PCT in strict must not disable enforcement.
OUT=$(ORCH_HOOK_PROFILE=strict ORCH_STRICT_CONTEXT_PRESSURE=1 ORCH_CONTEXT_BLOCK_PCT=abc run high-input.json)
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "BLOCK_PCT=abc strict → defaults to 85, still blocks" || fail "BLOCK_PCT=abc no fail-open" "got: '$OUT'"

printf '\n%s== hook: strict block token ceiling (1M-window reachability) ==%s\n' "$DIM" "$RESET"

# On a 1M window, 140K tokens = 14% (< 85% block pct) but >= the 140K token
# ceiling → strict must still block (otherwise strict enforcement is unreachable
# before native compaction).
OUT=$(ORCH_HOOK_PROFILE=strict ORCH_STRICT_CONTEXT_PRESSURE=1 run floor-already-input.json)
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "strict + 140K tokens (14%) → blocks via token ceiling" || fail "strict token ceiling" "got: '$OUT'"
valid_json "$OUT" && ok "strict block is valid JSON" || fail "strict block valid JSON" "got: '$OUT'"

# Non-strict at 140K → advisory, never a block.
OUT=$(run floor-already-input.json)
printf '%s' "$OUT" | grep -q '"decision":"block"' && fail "non-strict must not block" "got: '$OUT'" || ok "non-strict at 140K → advisory only, no block"

printf '\n%s== hook: disabled / minimal still silent ==%s\n' "$DIM" "$RESET"

OUT=$(ORCH_DISABLED_HOOKS=orch-context-pressure run floor-cross-input.json)
[[ -z "$OUT" ]] && ok "disabled hook → empty stdout above floor" || fail "disabled hook silent" "got: '$OUT'"
OUT=$(ORCH_HOOK_PROFILE=minimal run floor-cross-input.json)
[[ -z "$OUT" ]] && ok "minimal profile → empty stdout above floor" || fail "minimal profile silent" "got: '$OUT'"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-token-floor%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-token-floor — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
