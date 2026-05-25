#!/usr/bin/env bash
# Tests the protocol shape grader (scripts/lib/orch-protocol.sh and
# scripts/protocol-lint.sh).
#
# Fixtures are heredoc strings piped to the lint CLI. Checks:
#   (a) valid Changed:+Verify: → PASS (exit 0)
#   (b) Changed: with NO Verify: → FAIL (exit nonzero)
#   (c) reply whose first line is prose with no header → FAIL
#   (d) valid Found: reply → PASS
#   (e) Changed: + "no verification needed (cosmetic)" → PASS
#
# Status block validation (orch_grade_status_block):
#   (f) Status: BLOCKED without Need: → FAIL
#   (g) Status: DONE_WITH_CONCERNS without Concerns: → FAIL
#   (h) Status: DONE with Summary: → PASS
#   (i) inline Status: DONE (not line-leading) → FAIL
#   (j) Status: NEEDS_CONTEXT without Ask: → FAIL
#   (k) Status: BLOCKED with Need: → PASS
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$ROOT/scripts/protocol-lint.sh"
LIB="$ROOT/scripts/lib/orch-protocol.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Helper: pipe a heredoc string to lint, assert expected exit code.
# Usage: check_lint <label> <want_exit> <reply_text>
check_lint() {
  local label="$1" want_exit="$2" reply="$3"
  local got_exit output
  output=$(printf '%s' "$reply" | bash "$LINT" 2>&1)
  got_exit=$?
  if [[ "$got_exit" -eq "$want_exit" ]]; then
    ok "$label (exit=$want_exit)"
  else
    fail "$label" "wanted exit $want_exit, got $got_exit. output: $output"
  fi
}

printf '%s== Protocol grader fixture tests ==%s\n' "$DIM" "$RESET"

# (a) Valid Changed: with Verify: line — expect PASS (exit 0)
check_lint "valid Changed:+Verify:" 0 "$(cat <<'REPLY'
Changed:
- scripts/foo.sh:12 — fixed null check

Why:
- Prevents crash on empty input

Verify:
- bash tests/smoke.sh → all pass
REPLY
)"

# (b) Changed: with NO Verify: line — expect FAIL (exit nonzero)
check_lint "Changed: missing Verify:" 1 "$(cat <<'REPLY'
Changed:
- scripts/foo.sh:12 — fixed null check

Why:
- Prevents crash on empty input
REPLY
)"

# (c) Reply whose first non-blank line is prose, no valid header — expect FAIL
check_lint "prose first line no header" 1 "$(cat <<'REPLY'
Sure, I went ahead and fixed the null check in foo.sh. Here is what I did:
- scripts/foo.sh:12 — fixed null check
REPLY
)"

# (d) Valid Found: reply — expect PASS (exit 0)
check_lint "valid Found: reply" 0 "$(cat <<'REPLY'
Found:
- Key fact one
- Key fact two

Recommendation:
- Use option A because it is simpler

Next:
- Run the linter
REPLY
)"

# (e) Changed: with cosmetic exemption text — expect PASS (exit 0)
check_lint "Changed: with cosmetic exemption" 0 "$(cat <<'REPLY'
Changed:
- README.md — fix typo in title

no verification needed (cosmetic)
REPLY
)"

# Helper: call orch_grade_status_block in a subshell, assert expected exit code.
# Usage: check_status_block <label> <want_exit> <reply_text>
check_status_block() {
  local label="$1" want_exit="$2" reply="$3"
  local got_exit output
  output=$(printf '%s' "$reply" | bash -c "source '$LIB'; orch_grade_status_block" 2>&1)
  got_exit=$?
  if [[ "$got_exit" -eq "$want_exit" ]]; then
    ok "$label (exit=$want_exit)"
  else
    fail "$label" "wanted exit $want_exit, got $got_exit. output: $output"
  fi
}

printf '\n%s== Status block validation tests ==%s\n' "$DIM" "$RESET"

# (f) Status: BLOCKED without Need: → FAIL (exit 1)
check_status_block "BLOCKED without Need:" 1 "$(cat <<'REPLY'
Status: BLOCKED
Summary: could not proceed
REPLY
)"

# (g) Status: DONE_WITH_CONCERNS without Concerns: → FAIL (exit 1)
check_status_block "DONE_WITH_CONCERNS without Concerns:" 1 "$(cat <<'REPLY'
Status: DONE_WITH_CONCERNS
Summary: done but something is off
REPLY
)"

# (h) Status: DONE with Summary: → PASS (exit 0)
check_status_block "DONE with Summary:" 0 "$(cat <<'REPLY'
Status: DONE
Summary: implemented the feature
Changed:
- scripts/foo.sh:12 — added null check
Verify:
- bash tests/smoke.sh → all pass
REPLY
)"

# (i) Inline Status: DONE (not line-leading) → FAIL (exit 1)
check_status_block "inline Status: DONE not line-leading" 1 "$(cat <<'REPLY'
The Status: DONE check passes when the line starts properly.
But this line has Status: DONE inline which should not count.
REPLY
)"

# (j) Status: NEEDS_CONTEXT without Ask: → FAIL (exit 1)
check_status_block "NEEDS_CONTEXT without Ask:" 1 "$(cat <<'REPLY'
Status: NEEDS_CONTEXT
Summary: missing information
REPLY
)"

# (k) Status: BLOCKED with Need: → PASS (exit 0)
check_status_block "BLOCKED with Need:" 0 "$(cat <<'REPLY'
Status: BLOCKED
Summary: cannot proceed without auth token
Need:
- Provide the API key for the external service
REPLY
)"

# ============================================================
# Code-fence Verify: tests
# ============================================================
printf '\n%s== Code-fence Verify: tests ==%s\n' "$DIM" "$RESET"

# (l) Changed: with Verify: INSIDE a fenced code block → FAIL (exit 1)
# Note: use printf with literal backticks (can't embed ``` in single-quoted heredoc)
_FENCE_ONLY=$(printf 'Changed:\n- scripts/foo.sh:1 -- fix\n\n```\nVerify: this is inside a fence and must NOT count\n```\n')
check_lint "Changed:+Verify: inside code fence → FAIL" 1 "$_FENCE_ONLY"

# (m) Changed: with Verify: OUTSIDE a code fence → PASS (exit 0)
_FENCE_OUTSIDE=$(printf 'Changed:\n- scripts/foo.sh:1 -- fix\n\n```\nsome code block\n```\n\nVerify:\n- bash tests/smoke.sh -> all pass\n')
check_lint "Changed:+Verify: outside any fence → PASS" 0 "$_FENCE_OUTSIDE"

# (n) Changed: with Verify: inside AND outside fence → PASS (the outside one counts)
_FENCE_BOTH=$(printf 'Changed:\n- scripts/foo.sh:1 -- fix\n\n```\nVerify: inside fence, ignored\n```\n\nVerify:\n- bash tests/smoke.sh -> all pass\n')
check_lint "Changed:+Verify: inside fence and outside fence → PASS" 0 "$_FENCE_BOTH"

# ============================================================
# Summary
# ============================================================
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d checks passed.%s\n' "$GREEN" "$PASS" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
