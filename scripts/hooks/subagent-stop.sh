#!/usr/bin/env bash
# LLM Orchestrator SubagentStop hook.
# Fires when a dispatched subagent finishes. Validates that the subagent's
# final response contains a `Status:` block (DONE | DONE_WITH_CONCERNS |
# BLOCKED | NEEDS_CONTEXT). If not, emits a non-blocking warning to stderr.
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

# Read the hook event JSON from stdin.
INPUT=$(cat || true)

# The transcript path is one of the standard fields. Locate it without jq.
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

if [[ -z "${TRANSCRIPT}" || ! -f "${TRANSCRIPT}" ]]; then
  # Nothing to check; pass through.
  exit 0
fi

# Transcripts are JSONL with newlines escaped inside JSON string values.
# Drop the line anchor and accept either a literal newline (some harnesses)
# or an escaped \n preceding "Status:". Tail to bound the work.
TAIL=$(tail -c 8000 "${TRANSCRIPT}" 2>/dev/null || true)

# Match Status: followed by one of the four enum values, anywhere in the tail.
# This tolerates JSONL (where actual newlines become \n) and plain markdown.
if printf '%s' "${TAIL}" | grep -qE '(\\n|^|[[:space:]])Status:[[:space:]]*(DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT)\b'; then
  exit 0
fi

WARN="orch-subagent-stop: subagent finished without a Status: block. Expected one of DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT at the start of a line."

if [[ "${STRICT}" == "1" ]]; then
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "${WARN}")"
  exit 2
fi

echo "${WARN}" >&2
exit 0
