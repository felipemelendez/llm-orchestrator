#!/usr/bin/env bash
# Regression guard for the tier-boundary handoff rule (constraint #12).
#
# Asserts that:
#   1. skills/handing-off-to-fresh-context/SKILL.md documents the
#      tier-boundary-beats-threshold rule:
#        a. context > 50% fires at a clean seam below the 70% threshold
#        b. The worked-example contrast between "55% after tier 2 green-verify"
#           (great handoff) and "70% mid-batch" (bad handoff) is present.
#   2. skills/executing-plans/SKILL.md references handing-off-to-fresh-context
#      at a tier boundary.
#
# This prevents a future maintainer from collapsing the rule to a pure
# percentage threshold, losing the tier-boundary-dominance constraint.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HANDOFF_SKILL="${ROOT}/skills/handing-off-to-fresh-context/SKILL.md"
EXEC_SKILL="${ROOT}/skills/executing-plans/SKILL.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Guard: skills must exist.
printf '%s== skill file existence ==%s\n' "$DIM" "$RESET"

for f in "$HANDOFF_SKILL" "$EXEC_SKILL"; do
  label="${f#${ROOT}/}"
  if [[ -f "$f" ]]; then
    ok "${label} exists"
  else
    fail "${label} exists" "not found: $f"
  fi
done

# ============================================================
# Section 1: handing-off-to-fresh-context documents the rule
# ============================================================
printf '\n%s== handing-off-to-fresh-context: tier-boundary rule ==%s\n' "$DIM" "$RESET"

# 1a. The skill must say to fire when context > 50% at a tier boundary,
#     even though that is below the 70% threshold.
# We look for the "50%" percentage threshold mention combined with the idea
# that the seam fires below the 70% hook threshold.

if grep -q '50%' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill mentions 50% context threshold for tier-boundary firing"
else
  fail "handoff skill mentions 50% context threshold for tier-boundary firing" \
       "grep '50%' found no match in ${HANDOFF_SKILL}"
fi

if grep -q '70%' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill mentions the 70% warn threshold (for contrast)"
else
  fail "handoff skill mentions the 70% warn threshold (for contrast)" \
       "grep '70%' found no match in ${HANDOFF_SKILL}"
fi

# The rule must explicitly say to fire BELOW (or despite) the threshold,
# i.e., the tier-boundary fires before the pressure hook.
if grep -qE 'below the (70%|threshold)|even though that is below' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill explicitly states firing below the 70% threshold"
else
  fail "handoff skill explicitly states firing below the 70% threshold" \
       "no match for 'below the (70%|threshold)|even though that is below' in ${HANDOFF_SKILL}"
fi

# 1b. Worked-example contrast: "55%" good case vs "70%" bad case.
# The skill must contain the worked example showing 55% after a tier green-verify
# is a great handoff and 70% mid-batch is a bad handoff.

if grep -q '55%' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill has the 55% worked-example (great handoff scenario)"
else
  fail "handoff skill has the 55% worked-example (great handoff scenario)" \
       "grep '55%' found no match in ${HANDOFF_SKILL}"
fi

# The worked example should contrast a good (tier-seam) vs bad (mid-batch) handoff.
if grep -qE 'great handoff|good handoff|clean.*seam' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill documents the 'great handoff at tier seam' contrast"
else
  fail "handoff skill documents the 'great handoff at tier seam' contrast" \
       "no 'great handoff|good handoff|clean.*seam' in ${HANDOFF_SKILL}"
fi

if grep -qE 'bad handoff|tangled|mid-batch' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill documents the 'bad handoff mid-batch' contrast"
else
  fail "handoff skill documents the 'bad handoff mid-batch' contrast" \
       "no 'bad handoff|tangled|mid-batch' in ${HANDOFF_SKILL}"
fi

# Anti-patterns section must contain both the 55% and 70% case to make the
# contrast explicit (this is constraint #12 — the "worked-example" lines).
if grep -qE '55%.*tier|tier.*55%' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill ties the 55% example to a tier seam"
else
  fail "handoff skill ties the 55% example to a tier seam" \
       "no '55%.*tier' or 'tier.*55%' match in ${HANDOFF_SKILL}"
fi

if grep -qE '70%.*mid-batch|mid-batch.*70%' "$HANDOFF_SKILL" 2>/dev/null; then
  ok "handoff skill ties the 70% example to mid-batch (bad)"
else
  fail "handoff skill ties the 70% example to mid-batch (bad)" \
       "no '70%.*mid-batch' or 'mid-batch.*70%' match in ${HANDOFF_SKILL}"
fi

# ============================================================
# Section 2: executing-plans references handing-off-to-fresh-context
#            at a tier boundary
# ============================================================
printf '\n%s== executing-plans: tier-boundary handoff reference ==%s\n' "$DIM" "$RESET"

if grep -q 'handing-off-to-fresh-context' "$EXEC_SKILL" 2>/dev/null; then
  ok "executing-plans skill references handing-off-to-fresh-context"
else
  fail "executing-plans skill references handing-off-to-fresh-context" \
       "grep found no match in ${EXEC_SKILL}"
fi

if grep -iE 'tier.boundar|tier boundary' "$EXEC_SKILL" 2>/dev/null | grep -q .; then
  ok "executing-plans skill mentions tier boundary as the handoff trigger"
else
  fail "executing-plans skill mentions tier boundary as the handoff trigger" \
       "no case-insensitive 'tier.boundar' or 'tier boundary' match in ${EXEC_SKILL}"
fi

# The two references must co-occur near each other (i.e. the tier-boundary step
# invokes the handoff skill, not just mentions it elsewhere).
# Check that the same section/paragraph that mentions tier boundary also mentions
# handing-off-to-fresh-context.
TIER_CTX=$(grep -in 'tier.boundar\|tier boundary\|Tier-boundary' "$EXEC_SKILL" 2>/dev/null | head -5)
HANDOFF_CTX=$(grep -n 'handing-off-to-fresh-context' "$EXEC_SKILL" 2>/dev/null | head -5)

if [[ -n "$TIER_CTX" ]] && [[ -n "$HANDOFF_CTX" ]]; then
  # Extract the line numbers and ensure they're within 10 lines of each other.
  TIER_LINE=$(printf '%s' "$TIER_CTX" | head -1 | cut -d: -f1)
  HANDOFF_LINE=$(printf '%s' "$HANDOFF_CTX" | head -1 | cut -d: -f1)
  DIFF=$((HANDOFF_LINE - TIER_LINE))
  if [[ $DIFF -lt 0 ]]; then DIFF=$((-DIFF)); fi
  if (( DIFF <= 15 )); then
    ok "tier-boundary and handing-off-to-fresh-context are co-located in executing-plans (within 15 lines)"
  else
    fail "tier-boundary and handing-off-to-fresh-context are co-located in executing-plans (within 15 lines)" \
         "tier_boundary at line ${TIER_LINE}, handoff-skill at line ${HANDOFF_LINE} — ${DIFF} lines apart"
  fi
else
  fail "tier-boundary step invokes handing-off-to-fresh-context in executing-plans" \
       "one or both references missing"
fi

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: tier-boundary%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: tier-boundary — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
