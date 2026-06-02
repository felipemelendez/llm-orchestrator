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

REMINDER='LLM Orchestrator — every turn:

Common triggers (invoke the matching skill via the Skill tool before responding when the user message clearly matches): investigate/audit/bug → systematic-debugging; build/design/feature → brainstorming; library + version + design verb → research-classifier; approved spec → writing-plans; diff ready → requesting-code-review; about to claim done/fixed/passing → verification-before-completion; remember/save/forget → memory. For read-heavy work (audit, "what files handle X", grep-sweeps), dispatch the read-only explorer subagent (Haiku) via the Task tool instead of reading inline.

Response protocol:
- Open with exactly one shape header on its own line: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:". "Recommendation:" is a sub-section, never a top-level header.
- "Changed:" blocks REQUIRE a "Verify:" line with a real command and its expected output (skip only for a cosmetic edit, and say so).
- "What files / where is / find X" → "Found:". "What is the best approach / how should we" → "Plan:" with numbered steps + "Risks:".
- Cite file:line for code references.
- No preamble, no trailing summary. Lead with the answer in one plain sentence; write for the engineer, not other agents. Be brief.'

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
