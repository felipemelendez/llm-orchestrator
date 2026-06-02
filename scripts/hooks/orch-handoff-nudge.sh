#!/usr/bin/env bash
# LLM Orchestrator handoff nudge — UserPromptSubmit hook.
#
# ONE job: when the conversation's token usage first crosses an absolute floor
# (ORCH_CONTEXT_HANDOFF_TOKENS, default 950000), tell the agent ONCE to write
# the durable handoff note, so the note exists before native auto-compaction
# summarizes in-flight state. The matching half is session-start.sh, which
# fires on source=compact and reminds the next turn to READ that note.
#
# Fire-once-per-fill-cycle: a per-session marker suppresses repeat nudges (no
# every-turn nagging). When usage drops back below the floor — e.g. after a
# compaction reset the context — the marker is cleared so the next fill cycle
# nudges again. Marker lives at ${ORCH_HOME:-~/.llm-orchestrator}/handoff/.
#
# Profile-aware: silent under ORCH_HOOK_PROFILE=minimal and when
# ORCH_DISABLED_HOOKS contains "orch-handoff-nudge".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-handoff-nudge,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

INPUT=$(cat || true)

# session_id keys the fire-once marker; degrade to "unknown" if absent.
SID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
SID="${SID:-unknown}"
SID=$(printf '%s' "${SID}" | tr -c 'A-Za-z0-9._-' '_')

TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
if [[ -n "${TRANSCRIPT}" && "${TRANSCRIPT}" != /* ]]; then
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then TRANSCRIPT="${CLAUDE_PROJECT_DIR}/${TRANSCRIPT}"; else TRANSCRIPT="${PWD}/${TRANSCRIPT}"; fi
fi
if [[ -z "${TRANSCRIPT}" ]] || [[ ! -f "${TRANSCRIPT}" ]]; then
  exit 0
fi

# Source the handoff lib for token estimation.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_LIB="${_HOOK_DIR}/../lib/orch-handoff.sh"
[[ -f "${_LIB}" ]] || exit 0
# shellcheck source=scripts/lib/orch-handoff.sh
source "${_LIB}"

TOKENS=$(orch_handoff_total_tokens "${TRANSCRIPT}" 1 2>/dev/null || true)
[[ "${TOKENS}" == "unknown" || -z "${TOKENS}" ]] && exit 0

FLOOR="${ORCH_CONTEXT_HANDOFF_TOKENS:-950000}"
[[ "${FLOOR}" =~ ^[0-9]+$ ]] || FLOOR=950000
# Force base-10 so a leading-zero value (e.g. 0700000) is not read as octal in
# the arithmetic comparison / message below.
FLOOR=$((10#${FLOOR}))

MARKER_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}/handoff"
MARKER="${MARKER_DIR}/nudged.${SID}"

# Below the floor → re-arm (clear any prior marker) and stay silent.
if (( TOKENS < FLOOR )); then
  rm -f "${MARKER}" 2>/dev/null || true
  exit 0
fi

# At/above the floor → nudge once per fill cycle.
if [[ -f "${MARKER}" ]]; then
  exit 0
fi
# Record the nudge BEFORE emitting. If the marker can't be written (read-only
# home, full disk, non-writable ORCH_HOME), exit silently rather than nudge
# every turn — missing one nudge is better than an unbounded nag loop.
mkdir -p "${MARKER_DIR}" 2>/dev/null || true
: > "${MARKER}" 2>/dev/null || true
[[ -f "${MARKER}" ]] || exit 0

json_escape() {
  local s; s=$(cat)
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '"%s"' "${s}"
}

MSG="Context has passed ~${FLOOR} tokens. At the next clean stopping point (a finished step with a green verify, nothing in flight), write or refresh the handoff note with /llm-orchestrator:handoff so it survives the upcoming automatic compaction. You will not be reminded again until after the next compaction."

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-handoff-nudge]: would inject handoff nudge (~%s token floor crossed)\n' "${FLOOR}" >&2
  exit 0
fi

ESCAPED=$(printf '%s' "${MSG}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED}"
exit 0
