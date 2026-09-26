#!/usr/bin/env bash
# LLM Orchestrator UserPromptSubmit hook.
# Fires before Claude processes each user message. In a project whose
# cadence.json is enabled, injects a one-line nudge toward the Concise Agent
# Protocol so the agent's reply lands in a named shape. Everywhere else it
# injects nothing. One line is the whole budget: this is billed on every turn.
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

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The hook input carries the project's cwd, which decides whether the cadence
# is enabled. Read it only from a non-tty stdin: a bare `bash
# user-prompt-submit.sh` in a terminal would otherwise block in `cat` forever.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# The nudge's single source is concise-agent-protocol.md — the marked
# orch-proportional-nudge block. Extract it at runtime; the embedded copy below is ONLY the
# fallback for a broken install (canonical file unreadable), and
# tests/test-protocol-drift.sh fails if the two ever diverge.
#
# This block is a DISTILLATION of the protocol, not a copy of it. Everything the
# agent needs once — the skill-precedence ordering, the working rules, the
# routing table — is injected once by SessionStart (the using-orchestrator eager
# block) or read from the skill on demand. Restating it here bought a second copy
# of text already in the window: the behaviour that made per-turn repetition pay
# off ("Earlier Claude models could sometimes need repeated instructions or be
# more likely to listen to instructions at the end of their context window than
# at the start") is named as an EARLIER-model trait in Anthropic's Claude 5
# context-engineering guidance, and this repo's own ablation
# (the shape-header-no-turn-hook case, removed when the evals moved to
# claude plugin eval) measured the hook's turn-one contribution at zero. What survives is the output-format contract the Stop-hook
# grader enforces, kept short per the Opus 5 guidance to "pair the instruction
# with a short reminder near the end of the prompt".
CANON="${HOOK_DIR}/../../concise-agent-protocol.md"
REMINDER=""
WORKFLOW=""
PROTOCOL_LIB="${HOOK_DIR}/../lib/orch-protocol.sh"
if [[ -f "$PROTOCOL_LIB" ]]; then
  source "$PROTOCOL_LIB"
  WORKFLOW=$(orch_protocol_workflow "$INPUT")
fi
# A broken cadence.json: the one-line error instead of a reply-format rule.
# No enabled cadence, or no way to tell: nothing at all.
CONFIG_ERROR=""
[[ "${WORKFLOW}" == "error" || "${WORKFLOW}" == "undecodable" ]] && CONFIG_ERROR=$(orch_protocol_config_error "${WORKFLOW}")
[[ "${WORKFLOW}" == "proportional" || -n "${CONFIG_ERROR}" ]] || exit 0
MARKER="orch-proportional-nudge"
if [[ -n "${CONFIG_ERROR}" ]]; then
  REMINDER="${CONFIG_ERROR}"
elif [[ -f "${CANON}" ]]; then
  REMINDER=$(awk -v s="<!-- $MARKER-start -->" -v e="<!-- $MARKER-end -->" '$0==s{f=1;next} $0==e{f=0} f' "${CANON}" 2>/dev/null)
fi
if [[ -z "${REMINDER}" ]]; then
  REMINDER='Open with "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", "Status:" unless project instructions set a reply format. End with "Verification: PASS|PENDING|BLOCKED|NOT APPLICABLE — why". PASS needs checks you ran; applicability never clears failed or required checks.'
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
  printf 'orch-dry-run[user-prompt-submit]: would inject protocol turn nudge (%s chars) as UserPromptSubmit additionalContext\n' "${#REMINDER}" >&2
  exit 0
fi

ESCAPED=$(printf '%s' "${REMINDER}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
