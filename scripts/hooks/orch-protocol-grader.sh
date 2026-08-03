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
# ORCH_HOOK_PROFILE=strict IMPLIES this flag. ARCHITECTURE.md has always
# documented `strict` as "all hooks active and blocking", but nothing branched
# on it — blocking came only from the explicit knob, so setting the profile
# bought the word and none of the behaviour. An explicit ORCH_STRICT_PROTOCOL=0
# still wins, so a per-check opt-out survives.
STRICT="${ORCH_STRICT_PROTOCOL:-0}"
if [[ -z "${ORCH_STRICT_PROTOCOL:-}" && "${ORCH_HOOK_PROFILE:-standard}" == "strict" ]]; then
  STRICT=1
fi

if [[ ",${DISABLED}," == *",orch-protocol-grader,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

# Full opt-out for the grader — but strict mode always wins, so the enforcement
# path can never be silently disabled by this flag.
if [[ "${ORCH_DISABLE_PROTOCOL_GRADER:-0}" == "1" && "${STRICT}" != "1" ]]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'orch-protocol-grader: python3 not found — protocol grading disabled\n' >&2
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
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
  if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
    printf 'orch-dry-run[orch-protocol-grader]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARN}" >&2
    exit 0
  fi
  if [[ "${STRICT}" == "1" ]]; then
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" | tee /dev/stderr
    exit 2
  fi
  echo "${WARN}" >&2
fi

exit 0
