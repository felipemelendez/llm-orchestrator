#!/usr/bin/env bash
# LLM Orchestrator UserPromptSubmit hook.
# Fires before Claude processes each user message. Injects a one-line reminder
# of the Concise Agent Protocol so the agent's reply lands in a named shape.
#
# Gated by ORCH_HOOK_PROFILE: skipped under minimal.
# Disabled if ORCH_DISABLED_HOOKS contains "orch-user-prompt-submit".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-user-prompt-submit,"* ]]; then
  exit 0
fi
if [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

# The reminder's single source is concise-agent-protocol.md — the marked
# "Per-turn reminder" block. Extract it at runtime; the embedded copy below is
# ONLY the fallback for a broken install (canonical file unreadable), and
# tests/test-protocol-drift.sh fails if the two ever diverge.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CANON="${HOOK_DIR}/../../concise-agent-protocol.md"
REMINDER=""
if [[ -f "${CANON}" ]]; then
  REMINDER=$(awk '/<!-- orch-turn-reminder-start -->/{f=1;next} /<!-- orch-turn-reminder-end -->/{f=0} f' "${CANON}" 2>/dev/null)
fi
if [[ -z "${REMINDER}" ]]; then
  REMINDER='LLM Orchestrator — every turn:
- Invoke the matching skill first: bug/investigate → systematic-debugging; build/design → brainstorming; library+version → research-classifier; approved spec → writing-plans; diff ready → requesting-code-review; claiming done/fixed/passing → verification-before-completion; remember/forget → managing-memory. Read-heavy sweeps → dispatch the explorer subagent.
- Open with exactly one shape header on its own line: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:".
- "Changed:" blocks REQUIRE a "Verify:" line (real command + its output). "Where is / what files / find X" → "Found:". "Best approach / how should we" → "Plan:" with "Risks:".
- Cite file:line. No preamble, no trailing summary; lead with the answer in one plain sentence.'
fi

# Native shell JSON escape — no python3 dependency.
json_escape() {
  local s
  s=$(cat)
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  printf '"%s"' "${s}"
}

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[user-prompt-submit]: would inject protocol reminder (%s chars) as UserPromptSubmit additionalContext\n' "${#REMINDER}" >&2
  exit 0
fi

ESCAPED=$(printf '%s' "${REMINDER}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
