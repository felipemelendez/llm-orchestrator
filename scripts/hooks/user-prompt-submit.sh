#!/usr/bin/env bash
# LLM Orchestrator UserPromptSubmit hook.
# Fires before Claude processes each user message. Injects a one-line nudge
# toward the Concise Agent Protocol so the agent's reply lands in a named shape.
# One line is the whole budget: this is the only surface billed on every turn.
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
    _EV_LIB="${HOOK_DIR}/../lib/orch-evidence.sh"
    _PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
    # shellcheck source=scripts/lib/orch-project.sh
    [[ -f "${_PROJ_LIB}" ]] && source "${_PROJ_LIB}"
    # shellcheck source=scripts/lib/orch-evidence.sh
    if [[ -f "${_EV_LIB}" ]]; then
      source "${_EV_LIB}"
      _TS=$(orch_turn_start_path "${_SID}")
      mkdir -p "$(dirname "${_TS}")" 2>/dev/null && date +%s > "${_TS}" 2>/dev/null
    fi
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
if [[ -f "${CANON}" ]]; then
  REMINDER=$(awk '/<!-- orch-turn-nudge-start -->/{f=1;next} /<!-- orch-turn-nudge-end -->/{f=0} f' "${CANON}" 2>/dev/null)
fi
if [[ -z "${REMINDER}" ]]; then
  REMINDER='LLM Orchestrator — open this reply with exactly one shape header: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:". A "Changed:" block REQUIRES a "Verify:" line (real command + its output). Lead with the outcome.'
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
