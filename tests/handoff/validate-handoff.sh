#!/usr/bin/env bash
# Tests that both the handoff template and sample artifact have the correct
# shape: all 10 section headings, all 7 frontmatter keys, and that the sample's
# resume prompt ends with "Go." and that every resolvable repo-relative path
# cited in the sample exists on disk.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMPLATE="${ROOT}/templates/handoff.md"
SAMPLE="${ROOT}/examples/sample-handoff.md"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# ============================================================
# Section 1: Files exist
# ============================================================
printf '%s== artifact existence ==%s\n' "$DIM" "$RESET"

for f in "$TEMPLATE" "$SAMPLE"; do
  label="${f#${ROOT}/}"
  if [[ -f "$f" ]]; then
    ok "${label} exists"
  else
    fail "${label} exists" "not found: $f"
  fi
done

# ============================================================
# Section 2: 10 required section headings in both files
# ============================================================
printf '\n%s== 10 required section headings ==%s\n' "$DIM" "$RESET"

REQUIRED_SLOTS=(
  "Mission carried over"
  "Memory index"
  "Plan state"
  "Active task context"
  "Recent agent reports"
  "In-flight observations"
  "Verification baseline"
  "Known gotchas"
  "What NOT to do"
  "Resume prompt"
)

for artifact in "$TEMPLATE" "$SAMPLE"; do
  label="${artifact#${ROOT}/}"
  for slot in "${REQUIRED_SLOTS[@]}"; do
    if grep -q "^## ${slot}" "$artifact" 2>/dev/null; then
      ok "${label}: '## ${slot}' present"
    else
      fail "${label}: '## ${slot}' present" "heading not found in $artifact"
    fi
  done
done

# ============================================================
# Section 3: 7 required frontmatter keys in both files
# ============================================================
printf '\n%s== 7 frontmatter keys ==%s\n' "$DIM" "$RESET"

REQUIRED_KEYS=(
  "revision"
  "last_regenerated_at"
  "trigger"
  "context_estimate_pct"
  "slug"
  "plan"
  "spec"
)

for artifact in "$TEMPLATE" "$SAMPLE"; do
  label="${artifact#${ROOT}/}"
  for key in "${REQUIRED_KEYS[@]}"; do
    if grep -qE "^${key}:" "$artifact" 2>/dev/null; then
      ok "${label}: frontmatter key '${key}' present"
    else
      fail "${label}: frontmatter key '${key}' present" "key '${key}:' not found in $artifact"
    fi
  done
done

# ============================================================
# Section 4: Sample resume prompt ends with "Go."
# ============================================================
printf '\n%s== resume prompt ends with Go. ==%s\n' "$DIM" "$RESET"

# The resume prompt is inside a fenced code block under ## Resume prompt.
# Extract that block and check that the last non-empty line is "Go."
RESUME_BLOCK=$(awk '
  /^## Resume prompt/ { found=1; next }
  found && /^```/ { in_block = !in_block; next }
  found && in_block { print }
  found && !in_block && /^## / { exit }
' "$SAMPLE")

LAST_RESUME_LINE=$(printf '%s\n' "$RESUME_BLOCK" | sed '/^[[:space:]]*$/d' | tail -1)
if [[ "$LAST_RESUME_LINE" == "Go." ]]; then
  ok "sample resume prompt ends with 'Go.'"
else
  fail "sample resume prompt ends with 'Go.'" "last non-empty line: '${LAST_RESUME_LINE}'"
fi

# ============================================================
# Section 5: Resolvable repo-relative citation paths exist
# ============================================================
printf '\n%s== resolvable citation paths ==%s\n' "$DIM" "$RESET"

# Prefixes we consider repo-relative and thus resolvable.
PREFIXES="docs/ scripts/ skills/ templates/ tests/ examples/"

ANY_MISSING=0
# Extract all bare path tokens that start with a tracked prefix.
# We look for quoted paths (inside backticks, quotes, or parentheses) and
# also bare paths that begin with the tracked prefixes.
# Strategy: grep all word tokens that start with docs/ scripts/ etc.,
# skip ~/... and /path/to/... (illustrative) patterns.
while IFS= read -r cited; do
  # Strip surrounding backticks, quotes, parentheses, trailing punctuation.
  # Use multiple -e clauses for BSD/POSIX sed compatibility (no ERE grouping needed).
  clean=$(printf '%s' "$cited" \
    | sed -e 's/^`//' -e 's/`$//' \
          -e "s/^'//" -e "s/'$//" \
          -e 's/^(//' -e 's/)$//' \
          -e 's/[,;:]*$//')

  # Skip illustrative paths.
  case "$clean" in
    ~/*)          continue ;;
    /path/to/*)   continue ;;
    /*)           continue ;;  # absolute non-repo paths — skip
    *' '*)        continue ;;  # contains spaces — likely a sentence fragment
  esac

  # Must still start with one of the tracked prefixes after cleaning.
  matched=0
  for pfx in docs/ scripts/ skills/ templates/ tests/ examples/; do
    case "$clean" in
      ${pfx}*) matched=1; break ;;
    esac
  done
  [[ $matched -eq 0 ]] && continue

  # docs/llm-orchestrator/plans/ and docs/llm-orchestrator/specs/ contain
  # per-task generated artifacts (plan/spec files for specific projects).
  # Sample handoffs inevitably reference these with fictitious project paths;
  # treat them as illustrative and skip the existence check.
  case "$clean" in
    docs/llm-orchestrator/plans/*)  continue ;;
    docs/llm-orchestrator/specs/*)  continue ;;
  esac

  full="${ROOT}/${clean}"
  if [[ -e "$full" ]]; then
    ok "cited path exists: ${clean}"
  else
    fail "cited path exists: ${clean}" "not found: ${full}"
    ANY_MISSING=$((ANY_MISSING+1))
  fi
done < <(
  # Strip YAML frontmatter (between first and second ---) before scanning.
  awk '
    BEGIN { in_fm=0; done_fm=0; found_first=0 }
    !done_fm && !found_first && /^---[[:space:]]*$/ { in_fm=1; found_first=1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm=0; done_fm=1; next }
    in_fm { next }
    { print }
  ' "$SAMPLE" \
  | grep -oE '[a-zA-Z0-9_./-]+' \
  | grep -E '^(docs|scripts|skills|templates|tests|examples)/' \
  | sort -u
)

if [[ $ANY_MISSING -eq 0 && $FAIL -eq 0 ]]; then
  : # individual ok() calls already counted
fi

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: validate-handoff%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: validate-handoff — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
