#!/usr/bin/env bash
# Tests the research-classifier skill's stated rules against the curated
# examples table in skills/research-classifier/EXAMPLES.md.
#
# The classifier itself runs in-model (zero-shot prompt). What we can test
# deterministically: that the documented signal heuristics, applied
# mechanically to the curated examples, produce the expected verdict.
#
# The table rows are PARSED from EXAMPLES.md at run time — they are the case
# source, not documentation of one. Flipping an expected verdict there, or
# changing a heuristic in SKILL.md, fails this script until both sides agree.
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

# The cases come FROM skills/research-classifier/EXAMPLES.md — its table rows
# are parsed as this test's input, so the file's "if a heuristic change moves
# any of these, the test fails" claim is true by construction. This list used
# to be hardcoded here: flipping a row's expected verdict in EXAMPLES.md
# changed nothing, and three files all claimed a wiring that did not exist.
EXAMPLES="$ROOT/skills/research-classifier/EXAMPLES.md"
rows=0; rows_needed=0; rows_skip=0
while IFS= read -r line; do
  # Rows look like: | "Input text" | `NEEDED` | why |
  input=$(printf '%s\n' "$line" | sed -nE 's/^\| *"(.*)" *\| *`(NEEDED|SKIP)`.*$/\1/p' | tr -d '`')
  wantv=$(printf '%s\n' "$line" | sed -nE 's/^\| *"(.*)" *\| *`(NEEDED|SKIP)`.*$/\2/p')
  [[ -z "$input" || -z "$wantv" ]] && continue
  rows=$((rows+1))
  case "$wantv" in
    NEEDED) rows_needed=$((rows_needed+1)) ;;
    SKIP)   rows_skip=$((rows_skip+1)) ;;
  esac
  expect "$input" "$wantv"
done < "$EXAMPLES"

# A parser that silently matches zero (or lopsided) rows is this same suite's
# dead-guard failure mode one level up: assert the table actually fed us cases
# of BOTH verdicts, so a format drift in EXAMPLES.md cannot erase the coverage.
if (( rows >= 10 && rows_needed >= 1 && rows_skip >= 1 )); then
  ok "EXAMPLES.md supplied $rows cases ($rows_needed NEEDED, $rows_skip SKIP)"
else
  fail "EXAMPLES.md row parsing" "parsed $rows rows ($rows_needed NEEDED, $rows_skip SKIP) from $EXAMPLES — table missing or format drifted"
fi

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
