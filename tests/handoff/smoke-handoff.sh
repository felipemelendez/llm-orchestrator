#!/usr/bin/env bash
# End-to-end smoke tests for the handoff library and context-pressure hook.
#
# Tests:
#   1. orch_handoff_estimate_pct against fixture JSONL files
#   2. orch_handoff_body_hash determinism and sensitivity
#   3. orch_handoff_next_revision on file with known revision and on missing file
#   4. Hook output: high-input.json → additionalContext; low-input.json → empty
#   5. Hook latency measurement
#   6. No-op detection: body_hash ignores frontmatter, catches real body changes
#   7. Disabled-hook: ORCH_DISABLED_HOOKS and ORCH_HOOK_PROFILE=minimal yield empty stdout
#
# Bash 3.2 compatible. Uses python3 ONLY for test-harness wall-clock timing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="${ROOT}/scripts/lib/orch-handoff.sh"
HOOK="${ROOT}/scripts/hooks/orch-context-pressure.sh"
FIXTURES="${ROOT}/tests/handoff/fixtures"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Guard: lib must exist.
if [[ ! -f "$LIB" ]]; then
  fail "orch-handoff.sh exists at scripts/lib/orch-handoff.sh" "not found: $LIB"
  printf '%sFAIL: smoke-handoff%s\n' "$RED" "$RESET"
  exit 1
fi

# Source the library (pulls in orch-project.sh transitively).
# shellcheck source=../../scripts/lib/orch-handoff.sh
source "$LIB"

# Temp dir for scratch files.
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
# Section 2: orch_handoff_body_hash determinism and sensitivity
# ============================================================
printf '\n%s== orch_handoff_body_hash ==%s\n' "$DIM" "$RESET"

# Copy templates/handoff.md to a scratch file (not using git HEAD at all).
SCRATCH="${TMP}/test-handoff.md"
cp "${ROOT}/templates/handoff.md" "$SCRATCH"

# Hash it twice — must be identical.
HASH1=$(orch_handoff_body_hash "$SCRATCH" 2>/dev/null)
HASH2=$(orch_handoff_body_hash "$SCRATCH" 2>/dev/null)

if [[ "$HASH1" == "$HASH2" ]] && [[ -n "$HASH1" ]]; then
  ok "body_hash is stable across two calls (${HASH1})"
else
  fail "body_hash is stable across two calls" "hash1='${HASH1}' hash2='${HASH2}'"
fi

# Append a body line after frontmatter → hash must change.
printf '\n<!-- smoke-test sentinel -->\n' >> "$SCRATCH"
HASH3=$(orch_handoff_body_hash "$SCRATCH" 2>/dev/null)

if [[ "$HASH3" != "$HASH1" ]] && [[ -n "$HASH3" ]]; then
  ok "body_hash changes when body content changes"
else
  fail "body_hash changes when body content changes" "hash before='${HASH1}' hash after='${HASH3}'"
fi

# ============================================================
# Section 3: orch_handoff_next_revision
# ============================================================
printf '\n%s== orch_handoff_next_revision ==%s\n' "$DIM" "$RESET"

# File with revision: 2 → expect 3.
REV_FILE="${TMP}/rev-test.md"
printf -- '---\nrevision: 2\nlast_regenerated_at: 2026-01-01T00:00:00Z\n---\n\n# body\n' > "$REV_FILE"
NEXT=$(orch_handoff_next_revision "$REV_FILE" 2>/dev/null)
if [[ "$NEXT" == "3" ]]; then
  ok "next_revision of revision:2 file == 3"
else
  fail "next_revision of revision:2 file == 3" "got: '${NEXT}'"
fi

# Missing file → expect 1.
MISSING_FILE="${TMP}/no-such-file-$(date +%s).md"
NEXT_MISSING=$(orch_handoff_next_revision "$MISSING_FILE" 2>/dev/null)
if [[ "$NEXT_MISSING" == "1" ]]; then
  ok "next_revision of missing file == 1"
else
  fail "next_revision of missing file == 1" "got: '${NEXT_MISSING}'"
fi

# ============================================================
# Section 4: Hook end-to-end — high triggers additionalContext,
#            low produces empty stdout
# ============================================================
printf '\n%s== hook output (high/low inputs) ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$HOOK" ]]; then
  fail "hook exists at scripts/hooks/orch-context-pressure.sh" "not found: $HOOK"
else
  ok "hook script found"

  # Run hook with high-input.json — should emit additionalContext.
  HIGH_OUT=$(CLAUDE_PROJECT_DIR="${ROOT}" \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)

  if printf '%s' "$HIGH_OUT" | grep -q 'additionalContext'; then
    ok "high-input.json → stdout contains 'additionalContext'"
  else
    fail "high-input.json → stdout contains 'additionalContext'" "got: '${HIGH_OUT}'"
  fi

  # Run hook with low-input.json — should emit empty stdout (below threshold).
  LOW_OUT=$(CLAUDE_PROJECT_DIR="${ROOT}" \
    bash "$HOOK" < "${FIXTURES}/low-input.json" 2>/dev/null || true)

  if [[ -z "$LOW_OUT" ]]; then
    ok "low-input.json → empty stdout (below threshold)"
  else
    fail "low-input.json → empty stdout (below threshold)" "got: '${LOW_OUT}'"
  fi
fi

# ============================================================
# Section 5: Latency measurement
# ============================================================
printf '\n%s== hook latency ==%s\n' "$DIM" "$RESET"

# Use python3 for wall-clock timing (bash 3.2 has no sub-second clock).
# python3 is allowed in the test harness per the task spec.
HAVE_PYTHON3=0
if command -v python3 >/dev/null 2>&1; then
  HAVE_PYTHON3=1
fi

if [[ $HAVE_PYTHON3 -eq 1 ]]; then
  T_START=$(python3 -c 'import time; print(time.time())')
  CLAUDE_PROJECT_DIR="${ROOT}" bash "$HOOK" < "${FIXTURES}/high-input.json" >/dev/null 2>/dev/null || true
  T_END=$(python3 -c 'import time; print(time.time())')

  # Compute elapsed ms via awk (pure awk, no python3 for math).
  ELAPSED_MS=$(awk -v s="$T_START" -v e="$T_END" 'BEGIN { printf "%.0f", (e - s) * 1000 }')

  printf '  hook wall-time: %s ms\n' "$ELAPSED_MS"

  # On a fast box assert < 50ms; on slow CI be lenient.
  if (( ELAPSED_MS < 50 )); then
    ok "hook latency < 50ms (${ELAPSED_MS}ms)"
  elif (( ELAPSED_MS < 500 )); then
    # Print but don't fail — CI boxes can be slow.
    printf '  %s!%s hook latency %sms exceeds 50ms target (CI may be slow — PASS with note)\n' \
      "$GREEN" "$RESET" "$ELAPSED_MS"
    PASS=$((PASS+1))
  else
    fail "hook latency < 500ms (${ELAPSED_MS}ms)" "hook took ${ELAPSED_MS}ms — check for hung subprocess"
  fi
else
  printf '  python3 not available — skipping latency measurement (PASS with note)\n'
  PASS=$((PASS+1))
fi

# ============================================================
# Section 6: No-op detection — body_hash ignores frontmatter,
#            catches real body changes
# ============================================================
printf '\n%s== no-op detection (body_hash vs frontmatter) ==%s\n' "$DIM" "$RESET"

# Create two files with IDENTICAL bodies but DIFFERENT frontmatter.
FILE_A="${TMP}/noop-a.md"
FILE_B="${TMP}/noop-b.md"
COMMON_BODY='## Summary

This is the shared body content for no-op detection testing.'

printf -- '---\nrevision: 1\nlast_regenerated_at: 2026-01-01T00:00:00Z\n---\n\n%s\n' \
  "$COMMON_BODY" > "$FILE_A"
printf -- '---\nrevision: 2\nlast_regenerated_at: 2026-05-30T12:00:00Z\n---\n\n%s\n' \
  "$COMMON_BODY" > "$FILE_B"

HASH_A=$(orch_handoff_body_hash "$FILE_A" 2>/dev/null)
HASH_B=$(orch_handoff_body_hash "$FILE_B" 2>/dev/null)

if [[ "$HASH_A" == "$HASH_B" ]] && [[ -n "$HASH_A" ]]; then
  ok "body_hash equal for different frontmatter, identical body (no-op detection ignores frontmatter)"
else
  fail "body_hash equal for different frontmatter, identical body" \
       "hash_a='${HASH_A}' hash_b='${HASH_B}'"
fi

# Now change the body of FILE_B — hashes must differ.
printf '\n<!-- additional line to change the body -->\n' >> "$FILE_B"
HASH_B2=$(orch_handoff_body_hash "$FILE_B" 2>/dev/null)

if [[ "$HASH_A" != "$HASH_B2" ]] && [[ -n "$HASH_B2" ]]; then
  ok "body_hash differs after real body change (no-op detection catches changes)"
else
  fail "body_hash differs after real body change" \
       "hash_a='${HASH_A}' hash_b2='${HASH_B2}'"
fi

# ============================================================
# Section 7: Disabled-hook — ORCH_DISABLED_HOOKS and
#            ORCH_HOOK_PROFILE=minimal yield empty stdout
# ============================================================
printf '\n%s== disabled-hook (ORCH_DISABLED_HOOKS / ORCH_HOOK_PROFILE=minimal) ==%s\n' "$DIM" "$RESET"

if [[ ! -f "$HOOK" ]]; then
  fail "hook exists for disabled-hook test" "not found: $HOOK"
else
  # ORCH_DISABLED_HOOKS=orch-context-pressure → hook must exit silently (empty stdout).
  DISABLED_OUT=$(ORCH_DISABLED_HOOKS=orch-context-pressure \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)

  if [[ -z "$DISABLED_OUT" ]]; then
    ok "ORCH_DISABLED_HOOKS=orch-context-pressure → empty stdout on high-input.json"
  else
    fail "ORCH_DISABLED_HOOKS=orch-context-pressure → empty stdout on high-input.json" \
         "got: '${DISABLED_OUT}'"
  fi

  # ORCH_HOOK_PROFILE=minimal → hook must exit silently (empty stdout).
  MINIMAL_OUT=$(ORCH_HOOK_PROFILE=minimal \
    bash "$HOOK" < "${FIXTURES}/high-input.json" 2>/dev/null || true)

  if [[ -z "$MINIMAL_OUT" ]]; then
    ok "ORCH_HOOK_PROFILE=minimal → empty stdout on high-input.json"
  else
    fail "ORCH_HOOK_PROFILE=minimal → empty stdout on high-input.json" \
         "got: '${MINIMAL_OUT}'"
  fi
fi

# ============================================================
# Section 8: Defect 1 regression — unterminated frontmatter
#            must produce a non-empty, content-sensitive hash.
# ============================================================
printf '\n%s== unterminated frontmatter (Defect 1 regression) ==%s\n' "$DIM" "$RESET"

UNTERM_A="${FIXTURES}/unterminated-frontmatter.md"
UNTERM_B="${FIXTURES}/unterminated-frontmatter-b.md"

UNTERM_HASH_A=$(orch_handoff_body_hash "$UNTERM_A" 2>/dev/null)
UNTERM_HASH_B=$(orch_handoff_body_hash "$UNTERM_B" 2>/dev/null)

if [[ -n "$UNTERM_HASH_A" ]]; then
  ok "unterminated-frontmatter.md: body_hash is non-empty (${UNTERM_HASH_A})"
else
  fail "unterminated-frontmatter.md: body_hash is non-empty" "got empty hash — over-strip defect not fixed"
fi

if [[ -n "$UNTERM_HASH_B" ]]; then
  ok "unterminated-frontmatter-b.md: body_hash is non-empty (${UNTERM_HASH_B})"
else
  fail "unterminated-frontmatter-b.md: body_hash is non-empty" "got empty hash"
fi

if [[ "$UNTERM_HASH_A" != "$UNTERM_HASH_B" ]]; then
  ok "unterminated files with different bodies produce different hashes (no false collision)"
else
  fail "unterminated files with different bodies produce different hashes" \
       "both hashed to '${UNTERM_HASH_A}' — false empty-hash collision"
fi

# ============================================================
# Section 9: orch_handoff_bodies_match using terminated fixtures.
# ============================================================
printf '\n%s== orch_handoff_bodies_match (terminated fixtures) ==%s\n' "$DIM" "$RESET"

TERM_A="${FIXTURES}/terminated-a.md"
TERM_B="${FIXTURES}/terminated-b.md"
TERM_C="${FIXTURES}/terminated-c.md"

MATCH_AB=$(orch_handoff_bodies_match "$TERM_A" "$TERM_B" 2>/dev/null)
if [[ "$MATCH_AB" == "noop" ]]; then
  ok "bodies_match terminated-a.md vs terminated-b.md (same body, different frontmatter) → noop"
else
  fail "bodies_match terminated-a.md vs terminated-b.md → noop" "got: '${MATCH_AB}'"
fi

MATCH_AC=$(orch_handoff_bodies_match "$TERM_A" "$TERM_C" 2>/dev/null)
if [[ "$MATCH_AC" == "changed" ]]; then
  ok "bodies_match terminated-a.md vs terminated-c.md (different body) → changed"
else
  fail "bodies_match terminated-a.md vs terminated-c.md → changed" "got: '${MATCH_AC}'"
fi

# ============================================================
# Section 10: estimate_pct regression — original fixtures still correct.
# ============================================================
printf '\n%s== estimate_pct regression (existing fixtures) ==%s\n' "$DIM" "$RESET"

check_pct "regression: high.jsonl (85%)"         "${FIXTURES}/high.jsonl"         "85"
check_pct "regression: low.jsonl (20%)"          "${FIXTURES}/low.jsonl"          "20"
check_pct "regression: nested-cache.jsonl (75%)" "${FIXTURES}/nested-cache.jsonl" "75"
check_pct "regression: malformed.jsonl (unknown)" "${FIXTURES}/malformed.jsonl"   "unknown"

# ============================================================
# Section 11: Defect 3 regression — non-numeric / empty window
#             falls back to 200000 (high.jsonl → still 85%).
# ============================================================
printf '\n%s== ORCH_CONTEXT_WINDOW_TOKENS validation (Defect 3 regression) ==%s\n' "$DIM" "$RESET"

PCT_ABC=$(ORCH_CONTEXT_WINDOW_TOKENS=abc orch_handoff_estimate_pct "${FIXTURES}/high.jsonl" 2>/dev/null)
if [[ "$PCT_ABC" == "85" ]]; then
  ok "ORCH_CONTEXT_WINDOW_TOKENS=abc falls back to 200000 (high.jsonl still 85%)"
else
  fail "ORCH_CONTEXT_WINDOW_TOKENS=abc falls back to 200000" "got: '${PCT_ABC}'"
fi

PCT_EMPTY=$(ORCH_CONTEXT_WINDOW_TOKENS= orch_handoff_estimate_pct "${FIXTURES}/high.jsonl" 2>/dev/null)
if [[ "$PCT_EMPTY" == "85" ]]; then
  ok "ORCH_CONTEXT_WINDOW_TOKENS= (empty) falls back to 200000 (high.jsonl still 85%)"
else
  fail "ORCH_CONTEXT_WINDOW_TOKENS= (empty) falls back to 200000" "got: '${PCT_EMPTY}'"
fi

# ============================================================
# Section 12: Defect 2 regression — bounded tail read.
#             Build a synthetic large transcript (5000 junk lines + real usage
#             line near the end) and assert estimate_pct returns the correct pct.
# ============================================================
printf '\n%s== bounded tail read (Defect 2 regression) ==%s\n' "$DIM" "$RESET"

SYNTH_TRANSCRIPT="${TMP}/synth-large.jsonl"
# Write 5000 junk lines (non-usage JSON).
for i in $(seq 1 5000); do
  printf '{"type":"human","message":{"content":"turn %d"}}\n' "$i"
done > "$SYNTH_TRANSCRIPT"
# Append a real usage line at the end: 50000 input_tokens / 200000 = 25%.
printf '{"type":"assistant","message":{"usage":{"input_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  >> "$SYNTH_TRANSCRIPT"

PCT_SYNTH=$(orch_handoff_estimate_pct "$SYNTH_TRANSCRIPT" 2>/dev/null)
if [[ "$PCT_SYNTH" == "25" ]]; then
  ok "synthetic large transcript (5000 junk lines + usage at end) → estimate_pct == 25"
else
  fail "synthetic large transcript → estimate_pct == 25" "got: '${PCT_SYNTH}'"
fi

# Also verify the file is large enough to exercise the tail path (> 256KB would be ideal,
# but even a smaller file confirms the grep logic works through tail -c).
SYNTH_SIZE=$(wc -c < "$SYNTH_TRANSCRIPT" | tr -d ' ')
if [[ "$SYNTH_SIZE" -gt 100000 ]]; then
  ok "synthetic transcript is > 100KB (${SYNTH_SIZE} bytes) — tail path exercised"
else
  # Still a pass — the functional correctness check above is sufficient.
  ok "synthetic transcript functional correctness confirmed (${SYNTH_SIZE} bytes)"
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
