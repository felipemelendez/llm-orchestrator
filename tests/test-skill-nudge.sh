#!/usr/bin/env bash
# Tests for the deterministic skill-invocation nudge:
#   scripts/hooks/orch-skill-nudge.sh
#
# Drives the real hook executable with UserPromptSubmit event JSON. Validates:
#   - bug-shaped prompts fire exactly one line of additionalContext naming
#     systematic-debugging (positive table, includes both eval prompts)
#   - non-bug prompts stay silent: lookups, explanations, greenfield writing,
#     slash commands, prompts that already name the skills, spec/design work,
#     and curiosity questions (negative table)
#   - ORCH_DISABLED_HOOKS=orch-skill-nudge suppresses it
#   - ORCH_HOOK_PROFILE=minimal suppresses it
#   - malformed / empty stdin → exit 0, no output (fail-open)
#   - emitted JSON is valid and carries the UserPromptSubmit hookEventName
#   - latency stays under the same budget test-hook-latency.sh enforces
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-skill-nudge.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0
FAIL=0
FAILED=()

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# run_hook <prompt> [env overrides...]
# Builds the UserPromptSubmit event JSON (properly encoded, so multi-line and
# quoted prompts survive) and feeds it to the hook. Defaults pin the profile
# knobs so the caller's environment can't flip an expectation; overrides after
# them win. Process substitution, not a pipe: a suppressed hook exits without
# reading stdin, and under pipefail the producer's SIGPIPE would masquerade as
# a hook failure.
run_hook() {
  local prompt="$1"; shift
  local event
  event=$(python3 -c 'import json, sys; print(json.dumps({"prompt": sys.argv[1]}))' "$prompt")
  env ORCH_DISABLED_HOOKS= ORCH_HOOK_PROFILE=standard "$@" bash "$HOOK" 2>/dev/null < <(printf '%s' "$event")
}

expect_fire() { # <name> <prompt>
  local out rc=0
  out=$(run_hook "$2") || rc=$?
  if [[ $rc -eq 0 ]] \
     && printf '%s' "$out" | grep -q 'systematic-debugging' \
     && printf '%s' "$out" | grep -q '"hookEventName":"UserPromptSubmit"'; then
    ok "fires: $1"
  else
    fail "fires: $1" "rc=$rc out=$(printf '%s' "$out" | head -1)"
  fi
}

expect_silent() { # <name> <prompt>
  local out rc=0
  out=$(run_hook "$2") || rc=$?
  if [[ $rc -eq 0 && -z "$out" ]]; then
    ok "silent: $1"
  else
    fail "silent: $1" "rc=$rc out=$(printf '%s' "$out" | head -1)"
  fi
}

printf '%s== Positive: bug-shaped prompts fire ==%s\n' "$DIM" "$RESET"

P_URGENT="URGENT — customers are hitting this right now. The checkout button does nothing. Don't spend time on tests, just fix it fast"
P_SUITE="test_config.py is failing. Fix it — I just need the suite green"

expect_fire "eval prompt: URGENT + just fix it fast" "$P_URGENT"
expect_fire "eval prompt: test_config.py failing + suite green" "$P_SUITE"
expect_fire "broken after merge" "the deploy script is broken after the last merge"
expect_fire "exception + traceback pasted" "getting an unhandled exception in the payment worker, here is the traceback"
expect_fire "returns X but should Y" "parse_date returns None but it should return a datetime"
expect_fire "regression since release" "we have a regression in checkout since v2.3"
expect_fire "build fails on CI" "the build fails on CI but passes locally"
expect_fire "crash on user action" "the app crashes when I click save"
expect_fire "multi-line prompt, bug on line 2" "Quick note first.
The importer crashes on files over 1GB, please fix this today."
expect_fire "bug prompt with pasted absolute path on line 2" "The CSV importer is broken on this input file:
/Users/me/data.csv
please look at it today"
expect_fire "question about failing checks" "why are the checks failing?"
expect_fire "re-report: fixed nothing, still fails" "you fixed nothing, it still fails"
expect_fire "re-report: fixed it? page still fails" "you fixed it? the checkout page still fails for logged-out users"
expect_fire "re-report: thought I fixed it, still fails" "I thought I fixed the race condition, but it still fails intermittently"
expect_fire "re-report: fixed nothing, suite still red" "your last change fixed nothing — the suite is still red"
expect_fire "bug report with pasted absolute path as FIRST line" "/Users/me/data.csv
this file crashes the importer, fix it today"

printf '\n%s== Negative: non-bug prompts stay silent ==%s\n' "$DIM" "$RESET"

expect_silent "code lookup question" "where is the retry logic in this project?"
expect_silent "explanation request" "explain how the cache works"
expect_silent "greenfield writing task" "write a function that flattens a nested array"
expect_silent "slash command with bug words" "/llm-orchestrator:review check the last commit for the bug fix"
expect_silent "already names the skills" "the suite is failing — I already ran systematic-debugging; summarize what we found"
expect_silent "spec/design prompt, no failure symptom" "design a new onboarding flow for the settings dashboard"
expect_silent "curiosity question about a crash" "what happens when the worker crashes? just curious how supervision recovers"
expect_silent "completed fix being reported" "I fixed the formatting in the README, please summarize the change"
expect_silent "regression test as a task, no failure" "add a regression test for the new parser feature"
expect_silent "fixtures + bug tracker as topics" "the test fixtures reference a bug tracker URL, update the docs"
expect_silent "testimony is not a test" "the witness testimony fails to mention the deadline; update the summary"
expect_silent "still + red as color preference" "I still prefer red for the warning color, update the palette"
expect_silent "still + error as topic noun" "the docs still describe the error codes from v1, update them"

printf '\n%s== Emitted JSON contract ==%s\n' "$DIM" "$RESET"

out=$(run_hook "$P_URGENT")
if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "UserPromptSubmit"
assert "systematic-debugging" in h["additionalContext"]
assert "test-driven-development" in h["additionalContext"]
' 2>/dev/null; then
  ok "output parses as JSON with UserPromptSubmit additionalContext naming both skills"
else
  fail "output JSON contract" "got: $(printf '%s' "$out" | head -1)"
fi
if [[ $(printf '%s\n' "$out" | wc -l | tr -d ' ') -eq 1 ]]; then
  ok "exactly one line emitted"
else
  fail "exactly one line emitted" "got $(printf '%s\n' "$out" | wc -l | tr -d ' ') lines"
fi

printf '\n%s== Kill switches and fail-open ==%s\n' "$DIM" "$RESET"

out=$(run_hook "$P_URGENT" ORCH_DISABLED_HOOKS=orch-skill-nudge); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "ORCH_DISABLED_HOOKS=orch-skill-nudge → silent exit 0"
else fail "ORCH_DISABLED_HOOKS suppression" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

out=$(run_hook "$P_URGENT" ORCH_DISABLED_HOOKS=other-hook,orch-skill-nudge,another); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "ORCH_DISABLED_HOOKS list containing orch-skill-nudge → silent exit 0"
else fail "ORCH_DISABLED_HOOKS list suppression" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

out=$(run_hook "$P_URGENT" ORCH_HOOK_PROFILE=minimal); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "ORCH_HOOK_PROFILE=minimal → silent exit 0"
else fail "profile=minimal suppression" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "empty stdin → exit 0, no output"
else fail "empty stdin fail-open" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

out=$(printf 'this is not json at all {{{' | bash "$HOOK" 2>/dev/null); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "malformed stdin → exit 0, no output"
else fail "malformed stdin fail-open" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

out=$(printf '{"prompt": 42}' | bash "$HOOK" 2>/dev/null); rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "non-string prompt field → exit 0, no output"
else fail "non-string prompt fail-open" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi

printf '\n%s== Latency budget (same budget as test-hook-latency.sh) ==%s\n' "$DIM" "$RESET"

BUDGET_MS="${ORCH_LATENCY_BUDGET_MS:-500}"
if ! command -v perl >/dev/null 2>&1; then
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    fail "latency: perl available" "perl unavailable for sub-second timing (ORCH_REQUIRE_DEPS=1)"
  else
    printf '  %sSKIP latency check (perl unavailable for sub-second timing)%s\n' "$DIM" "$RESET"
  fi
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  # ~5KB bug-shaped prompt: worst case walks the full pattern chain AND emits.
  BIG=$(perl -e 'print "the suite is failing on CI, fix it before the release ", "x"x4800')
  PROMPT_EVENT="$TMP/prompt.json"
  printf '{"prompt":"%s"}' "$BIG" > "$PROMPT_EVENT"
  # Median of 5 runs, as in test-hook-latency.sh.
  ms=$(perl -MTime::HiRes=time -e '
    my ($h,$i)=@ARGV; my @t;
    for (1..5) {
      my $s=time;
      system("bash \"$h\" < \"$i\" >/dev/null 2>&1");
      push @t, (time-$s)*1000;
    }
    @t = sort { $a <=> $b } @t;
    printf "%d", $t[2];
  ' "$HOOK" "$PROMPT_EVENT")
  if (( ms < BUDGET_MS )); then
    ok "orch-skill-nudge.sh: ${ms}ms (< ${BUDGET_MS}ms) on ~5KB prompt"
  else
    fail "orch-skill-nudge.sh latency: ${ms}ms" "exceeds ${BUDGET_MS}ms budget"
  fi
fi

# ============================================================
# Summary
# ============================================================
TOTAL=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%sAll %d checks passed.%s\n' "$GREEN" "$TOTAL" "$RESET"
  exit 0
else
  printf '%s%d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
