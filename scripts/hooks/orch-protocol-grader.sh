#!/usr/bin/env bash
# LLM Orchestrator Stop hook — Concise Agent Protocol grader.
# Fires on every Stop event (after the controller's last reply).
# Validates that the reply conforms to the Concise Agent Protocol shape.
#
# Non-blocking by default: emits a one-line warning to stderr, exit 0.
# Set ORCH_STRICT_PROTOCOL=1 to escalate to blocking (exit 2).
#
# Gated by ORCH_HOOK_PROFILE: skipped when profile is "minimal".
# Disabled if ORCH_DISABLED_HOOKS contains "orch-protocol-grader".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
STRICT="${ORCH_STRICT_PROTOCOL:-0}"

if [[ ",${DISABLED}," == *",orch-protocol-grader,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'orch-protocol-grader: python3 not found — protocol grading disabled\n' >&2
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/lib/orch-protocol.sh"
if [[ ! -f "${LIB}" ]]; then
  printf 'orch-protocol-grader: lib not found: %s — grading disabled\n' "${LIB}" >&2
  exit 0
fi
# shellcheck source=scripts/lib/orch-protocol.sh
source "${LIB}"

# Read the hook event JSON from stdin.
INPUT=$(cat || true)

# Locate transcript path — same extraction as subagent-stop.sh.
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

if [[ -z "${TRANSCRIPT}" || ! -f "${TRANSCRIPT}" ]]; then
  # No transcript available; nothing to grade.
  exit 0
fi

# Extract the last assistant message text using the shared helper.
# Handles both string-content and array-of-blocks schemas.
REPLY=$(orch_extract_last_assistant_text "${TRANSCRIPT}")

if [[ -z "${REPLY}" ]]; then
  # No assistant message found; nothing to grade.
  exit 0
fi

# Grade the clean extracted text. Capture output and exit code separately —
# never use || true on the same line as the grader call.
GRADE_OUT=$(printf '%s\n' "${REPLY}" | orch_grade_reply 2>&1)
GRADE_RC=$?

if [[ ${GRADE_RC} -ne 0 ]]; then
  WARN="orch-protocol-grader: controller reply does not conform to Concise Agent Protocol. ${GRADE_OUT}"
  if [[ "${STRICT}" == "1" ]]; then
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
    exit 2
  fi
  echo "${WARN}" >&2
fi

exit 0
