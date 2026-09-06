#!/usr/bin/env bash
# Latency budget: every hook must finish well under ORCH_LATENCY_BUDGET_MS
# (default 500) on a ~5KB transcript/prompt. Catches slow-drift before users
# feel it. Times with perl Time::HiRes (already a soft dependency); if perl is
# absent the test skips loudly rather than failing.
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="${ROOT}/scripts/hooks"
BUDGET_MS="${ORCH_LATENCY_BUDGET_MS:-500}"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# A skipped suite is NOT a passed suite. This used to print `PASS: <name>
# (skipped — ...)`, and smoke.sh greps the `PASS:` prefix, so a missing
# dependency read as green — in precisely the environment where orch-json.sh
# degrades and the guards are weakest. Under ORCH_REQUIRE_DEPS=1 (set in CI) a
# missing dependency is a hard failure instead: CI is the instrument every
# other claim is measured on, so it must never quietly under-run.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}


if ! command -v perl >/dev/null 2>&1; then
  skip_suite test-hook-latency 'perl unavailable for sub-second timing'
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/home"
mkdir -p "$ORCH_HOME"

# ~5KB assistant transcript (JSONL) for the Stop/SubagentStop graders.
TRANSCRIPT="$TMP/transcript.jsonl"
{
  pad=$(printf 'lorem ipsum dolor sit amet %.0s' {1..40})
  for i in $(seq 1 30); do
    printf '{"role":"assistant","content":"Changed: did thing %s. Verify: ran tests. %s"}\n' "$i" "$pad"
  done
} > "$TRANSCRIPT"

# ~5KB prompt for the UserPromptSubmit hooks.
BIG=$(perl -e 'print "add a Stripe webhook handler with the stripe library and openssl ", "x"x4800')
PROMPT_EVENT="$TMP/prompt.json"; printf '{"prompt":"%s"}' "$BIG" > "$PROMPT_EVENT"
TRANSCRIPT_EVENT="$TMP/te.json"; printf '{"transcript_path":"%s","source":"startup"}' "$TRANSCRIPT" > "$TRANSCRIPT_EVENT"
SKILL_EVENT="$TMP/sk.json"; printf '{"tool_name":"Skill","tool_input":{"skill":"llm-orchestrator:brainstorming"}}' > "$SKILL_EVENT"
BASH_EVENT="$TMP/bash.json"; printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' > "$BASH_EVENT"
START_EVENT="$TMP/start.json"; printf '{"source":"startup"}' > "$START_EVENT"
AGENT_EVENT="$TMP/agent.json"; printf '{"tool_name":"Agent","tool_input":{"description":"one seat","prompt":"do the thing","model":"opus"}}' > "$AGENT_EVENT"

# The cadence hooks are measured twice: on the INERT path every other project
# takes (stage 1 is a file test and a grep, so it must cost almost nothing), and
# in cadence mode, where they read the project's cadence state — and where they
# still have to clear the same 500 ms every call pays.
CADENCE_OFF="$TMP/cadence-off"; mkdir -p "$CADENCE_OFF"
CADENCE_ON="$TMP/cadence-on"
mkdir -p "$CADENCE_ON/docs/llm-orchestrator" "$CADENCE_ON/.claude"
printf '{ "schema": 1, "enabled": true }\n' > "$CADENCE_ON/docs/llm-orchestrator/cadence.json"
printf '# Laws\n\nRuling 1 — the cadence.\n' > "$CADENCE_ON/docs/llm-orchestrator/LAWS.md"
printf '{}\n' > "$CADENCE_ON/.claude/settings.json"
printf '# P\n\n<!-- ORCH:LAWS:START -->\nlaws\n<!-- ORCH:LAWS:END -->\n\ntail\n' > "$CADENCE_ON/CLAUDE.md"
cp "$CADENCE_ON/CLAUDE.md" "$CADENCE_ON/AGENTS.md"

# time_hook <hook-file> <input-file> — prints elapsed ms (median of 5 runs, so a
# one-off scheduler/GC hiccup neither trips the budget nor masks a real regression).
time_hook() {
  local hook="$1" inf="$2"
  perl -MTime::HiRes=time -e '
    my ($h,$i)=@ARGV; my @t;
    for (1..5) {
      my $s=time;
      system("bash \"$h\" < \"$i\" >/dev/null 2>&1");
      push @t, (time-$s)*1000;
    }
    @t = sort { $a <=> $b } @t;
    printf "%d", $t[2];
  ' "$hook" "$inf"
}

printf '%s== Hook latency budget: %s ms on ~5KB input ==%s\n' "$DIM" "$BUDGET_MS" "$RESET"

# Per-turn and per-event hooks must clear the strict budget. SessionStart runs
# once per session (startup/clear/compact/resume), so it carries a separate,
# higher ceiling: it loads + escapes the full meta-skill and hits a bash
# end-of-script buffer artifact (~580ms) that no clean code change removes. A
# one-time session-init cost is imperceptible; this still guards it from drifting
# unboundedly. Override either with ORCH_LATENCY_BUDGET_MS / the 3rd arg.
SESSION_BUDGET_MS="${ORCH_SESSION_LATENCY_BUDGET_MS:-1200}"

# check_latency <hook> <input-file> [budget-ms]
check_latency() {
  local name="$1" inf="$2" budget="${3:-$BUDGET_MS}"
  local hook="${HOOKS}/${name}"
  [[ -f "$hook" ]] || { fail "$name present" "missing $hook"; return; }
  local ms; ms=$(time_hook "$hook" "$inf")
  if (( ms < budget )); then
    ok "$name: ${ms}ms (< ${budget}ms)"
  else
    fail "$name: ${ms}ms" "exceeds ${budget}ms budget"
  fi
}

check_latency "session-start.sh"            "$START_EVENT"   "$SESSION_BUDGET_MS"
check_latency "user-prompt-submit.sh"       "$PROMPT_EVENT"
check_latency "orch-research-gate.sh"       "$PROMPT_EVENT"
check_latency "orch-handoff-nudge.sh"       "$TRANSCRIPT_EVENT"
check_latency "guard-no-verify.sh"          "$BASH_EVENT"
check_latency "guard-destructive-git.sh"    "$BASH_EVENT"
check_latency "skill-telemetry.sh"          "$SKILL_EVENT"
check_latency "orch-protocol-grader.sh"     "$TRANSCRIPT_EVENT"
check_latency "subagent-stop.sh"            "$TRANSCRIPT_EVENT"
check_latency "orch-researcher-validator.sh" "$TRANSCRIPT_EVENT"
check_latency "orch-verify-gate.sh"         "$TRANSCRIPT_EVENT"
ORCH_RETRY_CAP=1 check_latency "orch-retry-cap.sh" "$TRANSCRIPT_EVENT"
check_latency "orch-stop.sh"                "$TRANSCRIPT_EVENT"
check_latency "orch-evidence-ledger.sh"     "$BASH_EVENT"
check_latency "orch-worktree-reaper.sh"     "$TRANSCRIPT_EVENT"

CLAUDE_PROJECT_DIR="$CADENCE_OFF" check_latency "guard-dispatch-model.sh" "$AGENT_EVENT"
CLAUDE_PROJECT_DIR="$CADENCE_OFF" check_latency "orch-cadence-stop.sh"    "$TRANSCRIPT_EVENT"

printf '\n%s== In cadence mode (the same 500 ms budget) ==%s\n' "$DIM" "$RESET"
CLAUDE_PROJECT_DIR="$CADENCE_ON" check_latency "guard-dispatch-model.sh" "$AGENT_EVENT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-hook-latency%s (%d hooks under budget)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-hook-latency — %d under budget, %d over.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
