#!/usr/bin/env bash
# LLM Orchestrator SubagentStop hook.
# Fires when a dispatched subagent finishes. Validates that the subagent's
# final response contains a `Status:` block (DONE | DONE_WITH_CONCERNS |
# BLOCKED | NEEDS_CONTEXT) with the required sub-block implied by the enum.
# If not, emits a non-blocking warning to stderr.
#
# Validation rules (via orch_grade_status_block):
#   - Status: must appear at line start (not inline in prose)
#   - DONE         requires Summary:
#   - DONE_WITH_CONCERNS requires Concerns:
#   - BLOCKED      requires Need:
#   - NEEDS_CONTEXT requires Ask:
#
# Non-blocking by default; set ORCH_STRICT_STATUS=1 to make it blocking
# (exit 2 with a decision block, telling Claude to re-run the subagent).
#
# Gated by ORCH_HOOK_PROFILE: only active under standard or strict.
# Disabled if ORCH_DISABLED_HOOKS contains "orch-subagent-stop".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
STRICT="${ORCH_STRICT_STATUS:-0}"

if [[ ",${DISABLED}," == *",orch-subagent-stop,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'orch-subagent-stop: python3 not found — protocol grading disabled\n' >&2
  exit 0
fi

# Source the protocol grader library.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HOOK_DIR}/../lib/orch-protocol.sh"
if [[ ! -f "${LIB}" ]]; then
  printf 'orch-subagent-stop: lib not found: %s — grading disabled\n' "${LIB}" >&2
  exit 0
fi
# shellcheck source=scripts/lib/orch-protocol.sh
source "${LIB}"

# Read the hook event JSON from stdin.
INPUT=$(cat || true)

# The transcript path is one of the standard fields. Locate it without jq.
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

if [[ -z "${TRANSCRIPT}" || ! -f "${TRANSCRIPT}" ]]; then
  # Nothing to check; pass through.
  exit 0
fi

# Extract the last assistant message text using the shared helper.
# Handles both string-content and array-of-blocks schemas; returns decoded text.
ASSISTANT_TEXT=$(orch_extract_last_assistant_text "${TRANSCRIPT}")

if [[ -z "${ASSISTANT_TEXT}" ]]; then
  # No role-keyed JSONL found; fall back to treating the whole file as the text.
  # This handles plain markdown / mixed transcripts that are not JSONL.
  ASSISTANT_TEXT=$(cat "${TRANSCRIPT}" 2>/dev/null || true)
fi

if [[ -z "${ASSISTANT_TEXT}" ]]; then
  # Nothing to validate.
  exit 0
fi

# Use orch_grade_status_block to validate line-leading Status: + sub-blocks.
GRADE_OUTPUT=$(printf '%s\n' "${ASSISTANT_TEXT}" | orch_grade_status_block 2>&1)
GRADE_RC=$?

if [[ "${GRADE_RC}" -eq 0 ]]; then
  exit 0
fi

WARN="orch-subagent-stop: subagent finished without a Status: block (${GRADE_OUTPUT}). Expected one of DONE (with Summary:) | DONE_WITH_CONCERNS (with Concerns:) | BLOCKED (with Need:) | NEEDS_CONTEXT (with Ask:) at the start of a line."

if [[ "${STRICT}" == "1" ]]; then
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 2
fi

echo "${WARN}" >&2
exit 0
