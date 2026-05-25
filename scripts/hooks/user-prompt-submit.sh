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

BEFORE responding, scan the user message against the skill catalog. If a skill applies (even a 1% chance), invoke it via the Skill tool FIRST. Common triggers: "investigate" / "audit" / bug-shaped → systematic-debugging. "build" / "design" / "add a feature" → brainstorming. Library + version + design verb → research-classifier. Approved spec → writing-plans. Diff ready → requesting-code-review. About to claim "done" / "fixed" / "passing" → verification-before-completion. "Remember" / "save this" / "forget" → memory. Skipping a check that should have happened is the failure mode — invoking and discarding is not.

For read-heavy work (audit, "what files handle X", grep-sweeps), dispatch orch-explorer (Haiku) via the Task tool instead of doing reads inline. Multi-step features go through brainstorming → spec → /llm-orchestrator:plan → /llm-orchestrator:dispatch, not inline implementation.

Then respond following these protocol rules:
1. Open with one of these six headers on its own line, before any other text: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:".
2. "Recommendation:" is a sub-section of "Found:" or "Plan:", never a top-level header.
3. "Changed:" blocks REQUIRE a "Verify:" line at the end with a real command and its expected output. Skip "Verify:" only if the change is purely cosmetic (e.g. a typo in a comment) — and say so.
4. "What is the best approach", "how should we", "what is the way to" questions take "Plan:" shape with numbered steps + "Risks:" + "Verify after each step:".
5. "What files", "where is", "find X" questions take "Found:" shape.
6. Cite file:line for code references.
7. No preamble ("Sure!", "Of course", "I will go ahead and..."). No trailing summary that restates the bullets above.
8. Write for the engineer, not for other agents: lead with the answer in one plain sentence, expand or avoid internal jargon and tool-names (say "the research step", not "orch-researcher Trigger A"), and cut filler.
9. Be brief: the fewest lines that fully answer, then stop. Default to a few bullets, not three screens. Expand only when asked.'

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

ESCAPED=$(printf '%s' "${REMINDER}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
