#!/usr/bin/env bash
# Static portability scan of every shell script and command body in the repo.
#
# Flags constructs that work on Linux+GNU but break on macOS+bash 3.2:
#   - mapfile / readarray (bash 4+ only)
#   - associative arrays (declare -A; bash 4+ only)
#   - <<< herestring with $'\n' (works but worth flagging)
#   - sed -i without empty-string arg (GNU style; breaks on BSD)
#   - grep -P (PCRE; GNU-only)
#   - date -d (GNU-only)
#   - readlink -f (GNU-only)
#   - shasum-only or sha1sum-only references without portable fallback
#   - ${VAR:+$'\n'...} (the bash 3.2 quote-expansion trap)
#
# Usage: ./tests/test-portability.sh
# Exit codes: 0 = all portable, 1 = at least one finding.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; RESET=$'\033[0m'
else GREEN=""; RED=""; YEL=""; RESET=""; fi

FAIL=0
PASS=0

# scan PATTERN DESCRIPTION  — fail if any *.sh under ROOT (excluding tests/) matches
scan() {
  local pattern="$1" desc="$2"
  local hits
  hits=$(grep -rEn "$pattern" \
          "$ROOT/scripts" "$ROOT/hooks" 2>/dev/null \
        | grep -v '\.git/' \
        | grep -v 'tests/smoke.sh' \
        | grep -v 'tests/test-portability.sh' \
        | grep -v '# portable-ok' \
        || true)
  if [[ -n "$hits" ]]; then
    printf '  %s✗%s %s\n' "$RED" "$RESET" "$desc"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$hits"
    FAIL=$((FAIL+1))
  else
    printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$desc"
    PASS=$((PASS+1))
  fi
}

# warn PATTERN DESC — informational, doesn't fail
warn() {
  local pattern="$1" desc="$2"
  local hits
  hits=$(grep -rEn "$pattern" "$ROOT/scripts" "$ROOT/hooks" 2>/dev/null \
        | grep -v '\.git/' \
        | grep -v 'tests/test-portability.sh' \
        || true)
  if [[ -n "$hits" ]]; then
    printf '  %s!%s %s\n' "$YEL" "$RESET" "$desc"
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$hits"
  fi
}

printf '== Shell portability scan ==\n'

scan 'mapfile|readarray' "No mapfile/readarray (bash 4+; macOS default is 3.2)"
scan 'declare -A' "No associative arrays (bash 4+)"
scan 'grep[[:space:]]+-[A-Za-z]*P' "No grep -P (PCRE; GNU-only)"
scan 'date[[:space:]]+-d[[:space:]]' "No 'date -d' (GNU-only; use ISO format)"
scan 'readlink[[:space:]]+-f' "No 'readlink -f' (GNU-only; not portable to BSD/macOS)"
scan '\$\{[A-Za-z_]+:\+\\\$' "No \${VAR:+\$'\\n'} pattern (bash 3.2 quote-expansion bug)"

# sed -i must always be either GNU-detected first OR include '' arg
warn "sed[[:space:]]+-i[[:space:]]+[^'\\\"]" "Check sed -i usage — BSD requires sed -i '' (empty arg)"

# Check for hardcoded ~/.llm-orchestrator (should be ${ORCH_HOME:-...})
warn "~/.llm-orchestrator" "Hardcoded ~/.llm-orchestrator (consider \${ORCH_HOME:-...})"

# Check for shasum without fallback in any *.md command body
printf '\n== Command body portability ==\n'
HASH_HITS=$(grep -rln 'shasum' "$ROOT/commands" 2>/dev/null || true)
ANY_FAIL=0
if [[ -n "$HASH_HITS" ]]; then
  while IFS= read -r f; do
    if ! grep -q 'sha1sum\|cksum' "$f"; then
      printf '  %s✗%s %s references shasum without sha1sum/cksum fallback\n' "$RED" "$RESET" "$f"
      ANY_FAIL=1; FAIL=$((FAIL+1))
    fi
  done <<< "$HASH_HITS"
fi
if [[ $ANY_FAIL -eq 0 ]]; then
  printf '  %s✓%s All commands using shasum have a portable fallback\n' "$GREEN" "$RESET"
  PASS=$((PASS+1))
fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%s%d portability checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s See lines above.\n' "$RED" "$PASS" "$FAIL" "$RESET"
  exit 1
fi
