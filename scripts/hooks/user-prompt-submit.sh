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

# The reminder's single source is concise-agent-protocol.md — the marked
# "Per-turn reminder" block. Extract it at runtime; the embedded copy below is
# ONLY the fallback for a broken install (canonical file unreadable), and
# tests/test-protocol-drift.sh fails if the two ever diverge.
CANON="${HOOK_DIR}/../../concise-agent-protocol.md"
REMINDER=""
if [[ -f "${CANON}" ]]; then
  REMINDER=$(awk '/<!-- orch-turn-reminder-start -->/{f=1;next} /<!-- orch-turn-reminder-end -->/{f=0} f' "${CANON}" 2>/dev/null)
fi
if [[ -z "${REMINDER}" ]]; then
  REMINDER='LLM Orchestrator — every turn:
- Open with exactly one shape header on its own line: "Changed:", "Found:", "Blocked:", "Issues:", "Plan:", or "Status:". "Changed:" blocks REQUIRE a "Verify:" line (real command + its output).
- When two skills both match, run them in this order: process (brainstorming, systematic-debugging, research-classifier) → implementation (test-driven-development, writing-plans, dispatching-*) → verification (requesting-code-review, verification-before-completion, finishing-a-branch).
- Cite file:line. Lead with the answer in one plain sentence; no preamble, no trailing summary.'
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
