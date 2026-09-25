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

# --- turn boundary --------------------------------------------------------
# Record when this user turn began. The Stop-hook verify gate asks the evidence
# ledger "did a verify command run green since this epoch?" — which is how a
# completion claim gets checked without the model citing anything, and what
# stops a stale green from an earlier turn counting as evidence for this one.
# Best-effort: absence just means the gate treats the window as unknown (soft).
#
# Guarded on a non-tty stdin. This hook did not read stdin at all before; under
# the harness it is always piped, but a bare `bash user-prompt-submit.sh` in a
# terminal (or a test that forgets to redirect) would block in `cat` forever.
# A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
if [[ -n "${INPUT}" && "${ORCH_HOOK_DRY_RUN:-0}" != "1" ]]; then
  _SID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  if [[ -n "${_SID}" ]]; then
    # The per-turn stamp this used to write belonged to the evidence ledger,
    # which is gone; nothing reads it any more.
    _PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
    # shellcheck source=scripts/lib/orch-project.sh
    [[ -f "${_PROJ_LIB}" ]] && source "${_PROJ_LIB}"
  fi
fi

# The nudge's single source is concise-agent-protocol.md — the marked
# "Turn nudge" block. Extract it at runtime; the embedded copy below is ONLY the
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
# (tests/evals/cases/shape-header-no-turn-hook.json) measured the hook's turn-one
# contribution at zero. What survives is the output-format contract the Stop-hook
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
# No enabled cadence (or no way to tell): no reply-format rule and no reminder.
[[ -n "${WORKFLOW}" ]] || exit 0
MARKER="orch-turn-nudge"
[[ "${WORKFLOW}" == "proportional" ]] && MARKER="orch-proportional-nudge"
if [[ -f "${CANON}" ]]; then
  REMINDER=$(awk -v s="<!-- $MARKER-start -->" -v e="<!-- $MARKER-end -->" '$0==s{f=1;next} $0==e{f=0} f' "${CANON}" 2>/dev/null)
fi
if [[ -z "${REMINDER}" ]]; then
  if [[ "$MARKER" == "orch-proportional-nudge" ]]; then
    REMINDER='LLM Orchestrator — open with "Changed:", "Found:", "Blocked:", "Issues:", "Plan:" or "Status:" unless project instructions set a reply format. Completion uses "Verification: PASS|PENDING|BLOCKED|NOT APPLICABLE — explanation". Only observed checks support PASS.'
  else
    REMINDER='LLM Orchestrator — open with one header: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:", unless project instructions set a reply format. A "Changed:" block REQUIRES a "Verify:" line (real command + its output).'
  fi
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
