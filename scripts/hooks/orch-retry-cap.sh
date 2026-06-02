#!/usr/bin/env bash
# LLM Orchestrator Stop hook — retry-storm circuit breaker (EXPERIMENTAL).
#
# Detects the controller repeating essentially the same final reply across
# consecutive Stop events — a stuck loop that burns time and tokens — and, once
# it has happened ORCH_RETRY_CAP_N times in a row, tells the user to stop and
# reassess (re-read the plan, change approach, escalate the model, or /clear).
#
# DEFAULT: DISABLED. The threshold is a conservative placeholder until skill
# telemetry (ORCH_TELEMETRY) yields real retry-shape data — design the cap on
# observed shapes, not a guess. Controls:
#   ORCH_RETRY_CAP=1     enable, warn-only (stderr).
#   ORCH_STRICT_RETRY=1  enable and block (exit 2) at the threshold.
#   ORCH_RETRY_CAP_N     consecutive-identical threshold (default 3 — warn on the
#                        3rd repeat, matching Anthropic's "/clear after 2 failed
#                        corrections" guidance).
#
# Off under the minimal profile / ORCH_DISABLED_HOOKS=orch-retry-cap. Honours
# ORCH_HOOK_DRY_RUN=1. Needs python3 (shared transcript extractor); skips if absent.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
ENABLED="${ORCH_RETRY_CAP:-0}"
STRICT="${ORCH_STRICT_RETRY:-0}"
N="${ORCH_RETRY_CAP_N:-3}"

# Strict implies enabled.
[[ "${STRICT}" == "1" ]] && ENABLED=1

if [[ "${ENABLED}" != "1" ]] \
   || [[ ",${DISABLED}," == *",orch-retry-cap,"* ]] \
   || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi
[[ "${N}" =~ ^[0-9]+$ ]] && (( N >= 1 )) || N=3
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${HOOK_DIR}/../lib/orch-protocol.sh"
[[ -f "${LIB}" ]] || exit 0
# shellcheck source=scripts/lib/orch-protocol.sh
source "${LIB}"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"

INPUT=$(cat || true)
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ -n "${TRANSCRIPT}" && -f "${TRANSCRIPT}" ]] || exit 0
REPLY=$(orch_extract_last_assistant_text "${TRANSCRIPT}")
[[ -n "${REPLY}" ]] || exit 0

# Fingerprint: lowercase + collapse whitespace, then hash. Near-identical
# repeated replies (a stuck loop) collapse to the same fingerprint; normal
# varied progress does not.
NORM=$(printf '%s' "${REPLY}" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
if declare -f orch_sha1_of >/dev/null 2>&1; then
  FP=$(orch_sha1_of "${NORM}")
else
  FP=$(printf '%s' "${NORM}" | cksum | awk '{print $1}')
fi

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
HASH="default"
declare -f orch_project_hash >/dev/null 2>&1 && HASH=$(orch_project_hash 2>/dev/null || echo default)
STATE_DIR="${HOME_DIR}/state/${HASH}"
STATE="${STATE_DIR}/retry-cap"
mkdir -p "${STATE_DIR}" 2>/dev/null || exit 0

PREV_FP=""; COUNT=0
if [[ -f "${STATE}" ]]; then
  PREV_FP=$(awk 'NR==1{print; exit}' "${STATE}" 2>/dev/null)
  COUNT=$(awk 'NR==2{print; exit}' "${STATE}" 2>/dev/null)
  [[ "${COUNT}" =~ ^[0-9]+$ ]] || COUNT=0
fi

if [[ "${FP}" == "${PREV_FP}" ]]; then
  COUNT=$((COUNT + 1))
else
  COUNT=1
fi

if (( COUNT < N )); then
  printf '%s\n%s\n' "${FP}" "${COUNT}" > "${STATE}" 2>/dev/null || true
  exit 0
fi

# Threshold reached — reset the counter so we nag once per storm, not every turn.
printf '%s\n%s\n' "${FP}" "0" > "${STATE}" 2>/dev/null || true

WARN="orch-retry-cap: the last ${COUNT} replies were essentially identical — this looks like a stuck loop. Stop and reassess: re-read the plan file, try a different approach, escalate to a stronger model, or run /clear and resume from the plan. (Experimental; threshold ORCH_RETRY_CAP_N=${N} — tune once telemetry has data.)"

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-retry-cap]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${WARN}" >&2
  exit 0
fi

if [[ "${STRICT}" == "1" ]]; then
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "${WARN}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  exit 2
fi

echo "${WARN}" >&2
exit 0
