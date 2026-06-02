#!/usr/bin/env bash
# Tests for opt-in skill telemetry (skill-telemetry.sh) and the
# ORCH_HOOK_DRY_RUN behavior across injecting/grading hooks.
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/skill-telemetry.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP"
JSONL="$TMP/telemetry/skills.jsonl"
SKILL_EVENT='{"tool_name":"Skill","tool_input":{"skill":"llm-orchestrator:brainstorming"}}'

lines() { [[ -f "$JSONL" ]] && wc -l < "$JSONL" | tr -d ' ' || echo 0; }

printf '%s== Telemetry is opt-in (default off) ==%s\n' "$DIM" "$RESET"
printf '%s' "$SKILL_EVENT" | bash "$HOOK"
if [[ ! -f "$JSONL" ]]; then ok "default (ORCH_TELEMETRY unset): nothing written"
else fail "default off" "file unexpectedly created"; fi

printf '\n%s== ORCH_TELEMETRY=1 appends one event line per invocation ==%s\n' "$DIM" "$RESET"
printf '%s' "$SKILL_EVENT" | ORCH_TELEMETRY=1 bash "$HOOK"
printf '%s' "$SKILL_EVENT" | ORCH_TELEMETRY=1 bash "$HOOK"
if [[ "$(lines)" == "2" ]]; then ok "two invocations → two lines"
else fail "append count" "expected 2 lines, got $(lines)"; fi

# Anchored full-shape match — proves skill + ts + project AND no extra fields.
if grep -qE '^\{"skill":"[^"]*","ts":[0-9]+,"project":"[^"]*"\}$' "$JSONL"; then
  ok "line is exactly {skill, ts, project} — no extra fields"
else
  fail "line shape" "got: $(cat "$JSONL")"
fi

# Never logs arguments/prompt/output.
if grep -qiE 'prompt|argument|output|tool_input' "$JSONL"; then
  fail "no content leakage" "telemetry line contains content fields: $(cat "$JSONL")"
else
  ok "no arguments/prompt/output ever logged"
fi

printf '\n%s== Only the Skill tool is recorded ==%s\n' "$DIM" "$RESET"
before=$(lines)
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | ORCH_TELEMETRY=1 bash "$HOOK"
if [[ "$(lines)" == "$before" ]]; then ok "non-Skill tool ignored"
else fail "Skill-only" "Bash event was recorded"; fi

printf '\n%s== Dry-run logs intent, writes nothing ==%s\n' "$DIM" "$RESET"
before=$(lines)
dr=$(printf '%s' "$SKILL_EVENT" | ORCH_TELEMETRY=1 ORCH_HOOK_DRY_RUN=1 bash "$HOOK" 2>&1 1>/dev/null)
if [[ "$(lines)" == "$before" ]] && printf '%s' "$dr" | grep -q 'orch-dry-run\[orch-skill-telemetry\]'; then
  ok "dry-run: stderr logs intent, no append"
else
  fail "dry-run" "lines changed or no stderr log (stderr: $dr)"
fi

printf '\n%s== .orchrc project-local opt-in ==%s\n' "$DIM" "$RESET"
proj="$TMP/proj"; mkdir -p "$proj"; echo 'ORCH_TELEMETRY=1' > "$proj/.orchrc"
before=$(lines)
printf '%s' "$SKILL_EVENT" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK"
if [[ "$(lines)" -gt "$before" ]]; then ok ".orchrc ORCH_TELEMETRY=1 enables logging"
else fail ".orchrc opt-in" "no line appended via .orchrc"; fi

printf '\n%s== Dry-run never bypasses the destructive-git guard ==%s\n' "$DIM" "$RESET"
GUARD="${ROOT}/scripts/hooks/guard-destructive-git.sh"
if [[ -f "$GUARD" ]]; then
  rc=$(printf '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}' \
        | ORCH_HOOK_DRY_RUN=1 bash "$GUARD" >/dev/null 2>&1; echo $?)
  if [[ "$rc" == "2" ]]; then ok "guard still blocks under ORCH_HOOK_DRY_RUN (exit 2)"
  else fail "guard not bypassable" "expected exit 2, got $rc"; fi
fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-telemetry%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-telemetry — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
