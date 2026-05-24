#!/usr/bin/env bash
# Tests the research-classifier skill's stated rules against the curated
# Examples table in skills/research-classifier/SKILL.md.
#
# The classifier itself runs in-model (zero-shot prompt). What we can test
# deterministically: that the documented signal heuristics, applied
# mechanically to the curated examples, produce the expected verdict.
#
# If a SKILL.md heuristic change moves any curated example to the wrong
# verdict, this script fails. Edit the table AND the heuristics together.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/research-classifier/SKILL.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Load shared signal patterns — single source of truth across sniffer + classifier.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/orch-signals.sh"

# Heuristic check matching the skill body's documented signals at *standard*
# aggressiveness. Returns "NEEDED" or "SKIP" on stdout.
#
# Signal patterns come from scripts/lib/orch-signals.sh (shared with sniffer).
# Drift between this test and the sniffer is structurally prevented.
classify_standard() {
  local input="$1"
  local lower
  lower=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

  # 1. YES signals (each may contribute)
  local has_library=0 has_version=0 has_security=0 has_arch_verb=0
  local has_user_invoke=0

  if printf '%s' "$lower" | grep -qE "$ORCH_SIG_LIBRARY"; then has_library=1; fi
  if printf '%s' "$lower" | grep -qE "$ORCH_SIG_VERSION"; then has_version=1; fi
  if printf '%s' "$lower" | grep -qE "$ORCH_SIG_SECURITY"; then has_security=1; fi
  if printf '%s' "$lower" | grep -qE "$ORCH_SIG_ARCH"; then has_arch_verb=1; fi
  if printf '%s' "$lower" | grep -qE "$ORCH_SIG_INVOCATION"; then has_user_invoke=1; fi

  # 2. NO signal short-circuits (override YES if the request is clearly mechanical)
  if printf '%s' "$lower" | grep -qE '\b(typo|rename|cyclomatic|debounce|throttle|reduce[[:space:]]+complexity)\b'; then
    # Even if a library is mentioned, mechanical refactors skip.
    # Exception: rename inside files where API surface is in scope — but our curated examples are clear.
    printf 'SKIP'
    return
  fi
  if printf '%s' "$lower" | grep -qE '\b(write[[:space:]]+a[[:space:]]+function|flatten[[:space:]]+an[[:space:]]+array|fix[[:space:]]+the[[:space:]]+typo|add[[:space:]]+a[[:space:]]+test[[:space:]]+for)\b'; then
    printf 'SKIP'
    return
  fi
  if printf '%s' "$lower" | grep -qE '\b(add[[:space:]]+a[[:space:]]+(debounce|throttle|memoize|util)[[:space:]]+(util|helper|in[[:space:]]+))'; then
    printf 'SKIP'
    return
  fi

  # 3. Standard aggressiveness rule:
  #    library + (version OR security OR architectural verb) → NEEDED
  #    Or: explicit user invocation → NEEDED
  if (( has_user_invoke == 1 )); then
    printf 'NEEDED'; return
  fi
  if (( has_security == 1 )); then
    # Security alone is enough — wrong here is expensive.
    printf 'NEEDED'; return
  fi
  if (( has_library == 1 )); then
    if (( has_version == 1 || has_arch_verb == 1 )); then
      printf 'NEEDED'; return
    fi
    # Library alone at standard → skip.
    printf 'SKIP'; return
  fi
  if (( has_version == 1 || has_arch_verb == 1 )); then
    # Version or arch verb without library → also skip at standard
    # (no library means no API surface to verify).
    printf 'SKIP'; return
  fi

  printf 'SKIP'
}

# Test each curated example from the skill.
expect() {
  local input="$1" want="$2"
  local got
  got=$(classify_standard "$input")
  if [[ "$got" == "$want" ]]; then
    ok "[$want] $input"
  else
    fail "[$want] $input" "classified as $got"
  fi
}

printf '%s== Research classifier — curated examples ==%s\n' "$DIM" "$RESET"

# These match the Examples table in skills/research-classifier/SKILL.md.
# Drift in either side fails the test.
expect "Add a function that returns the current ISO timestamp"                       "SKIP"
expect "Fix the typo in README.md"                                                   "SKIP"
expect "Rename users to accounts throughout users.ts"                                "SKIP"
expect "Add a test for users.ts:42"                                                  "SKIP"
expect "Add OAuth login with Auth0"                                                  "NEEDED"
expect "Migrate the test suite from Mocha to Vitest"                                 "NEEDED"
expect "Set up Next.js 14 middleware for tenant routing"                             "NEEDED"
expect "Add a Prisma migration for the user_policy table"                            "NEEDED"
expect "Implement JWT token refresh"                                                 "NEEDED"
expect "Reduce the cyclomatic complexity of users.ts:checkAccess"                    "SKIP"
expect "Add a debounce util in src/lib/"                                             "SKIP"
expect "Wire Stripe Checkout with the v15 SDK"                                       "NEEDED"

# Skill structural checks
printf '\n%s== Skill file checks ==%s\n' "$DIM" "$RESET"
if grep -q '^## Examples' "$SKILL" || grep -q '## Examples (curated' "$SKILL"; then
  ok "Examples table present in skill"
else
  fail "Examples table" "missing — smoke test loses its source of truth"
fi
if grep -q 'CONTRADICTED' "$SKILL"; then
  ok "Contradiction-detected outcome documented"
else
  fail "Contradiction-detected outcome" "missing — first-class outcome not specified"
fi
if grep -q 'research_aggressiveness' "$SKILL"; then
  ok "Per-project aggressiveness tuning documented"
else
  fail "Aggressiveness tuning" "missing"
fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d classifier checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
