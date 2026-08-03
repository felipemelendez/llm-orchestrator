#!/usr/bin/env bash
# LLM Orchestrator retry-storm circuit breaker (Stop + SubagentStop).
#
# MAST FM-1.3 (step repetition, 15.7% of failures in the N=1642 set) is the
# taxonomy's single largest unaddressed failure mode. Two detectors:
#
#   Stop (controller): the same final reply repeated ORCH_RETRY_CAP_N times in
#     a row — a stuck controller loop. Stateful (fingerprint file per project).
#
#   SubagentStop (per agent, keyed on agent_id): the subagent's own transcript
#     shows the SAME tool action (name + arguments) executed ORCH_RETRY_CAP_N
#     or more times consecutively — the step-repetition shape itself, not a
#     proxy for it. Stateless: the transcript is scanned on stop.
#
# DEFAULT: ON, warn-only. Controls:
#   ORCH_RETRY_CAP=0     disable entirely.
#   ORCH_STRICT_RETRY=1  block (exit 2) at the threshold instead of warning.
#   ORCH_RETRY_CAP_N     threshold (default 3 — warn at the 3rd repeat,
#                        matching Anthropic's "/clear after 2 failed
#                        corrections" guidance).
#
# Off under the minimal profile / ORCH_DISABLED_HOOKS=orch-retry-cap. Honours
# ORCH_HOOK_DRY_RUN=1. Needs python3 (transcript parsing); skips if absent.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
ENABLED="${ORCH_RETRY_CAP:-1}"
# ORCH_HOOK_PROFILE=strict IMPLIES this flag. ARCHITECTURE.md has always
# documented `strict` as "all hooks active and blocking", but nothing branched
# on it — blocking came only from the explicit knob, so setting the profile
# bought the word and none of the behaviour. An explicit ORCH_STRICT_RETRY=0
# still wins, so a per-check opt-out survives.
STRICT="${ORCH_STRICT_RETRY:-0}"
if [[ -z "${ORCH_STRICT_RETRY:-}" && "${ORCH_HOOK_PROFILE:-standard}" == "strict" ]]; then
  STRICT=1
fi
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
EVENT=$(printf '%s' "${INPUT}" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

report() { # report <warn-text>
  local warn="$1"
  if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
    printf 'orch-dry-run[orch-retry-cap]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${warn}" >&2
    exit 0
  fi
  local esc; esc="$(printf '%s' "${warn}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  if [[ "${STRICT}" == "1" ]]; then
    # exit 2 feeds ONLY stderr back to the model — put the reason there
    # (stdout JSON is ignored on a non-zero exit).
    printf '{"decision":"block","reason":%s}\n' "${esc}" | tee /dev/stderr
    exit 2
  fi
  # Warn path: stderr for the user, additionalContext for the model.
  echo "${warn}" >&2
  printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s}}\n' \
    "\"${EVENT:-Stop}\"" "${esc}"
  exit 0
}

# --- SubagentStop: consecutive identical tool actions in the agent's own
# transcript. On SubagentStop, transcript_path names the MAIN transcript
# (<dir>/<session>.jsonl); the subagent's own file lives at
# <dir>/<session>/subagents/agent-<agent_id>.jsonl (verified on disk).
if [[ "${EVENT}" == "SubagentStop" ]]; then
  AGENT_ID=$(printf '%s' "${INPUT}" | grep -oE '"agent_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  [[ -n "${AGENT_ID}" && -n "${TRANSCRIPT}" ]] || exit 0
  SUB_DIR="${TRANSCRIPT%.jsonl}/subagents"
  SUB_T=""
  for cand in "${SUB_DIR}/agent-${AGENT_ID}.jsonl" "${SUB_DIR}/${AGENT_ID}.jsonl"; do
    [[ -f "${cand}" ]] && { SUB_T="${cand}"; break; }
  done
  if [[ -z "${SUB_T}" && -d "${SUB_DIR}" ]]; then
    SUB_T=$(ls "${SUB_DIR}" 2>/dev/null | grep -F "${AGENT_ID}" | head -1)
    [[ -n "${SUB_T}" ]] && SUB_T="${SUB_DIR}/${SUB_T}"
  fi
  [[ -n "${SUB_T}" && -f "${SUB_T}" ]] || exit 0

  RESULT=$(python3 - "${SUB_T}" "${N}" <<'PYEOF' 2>/dev/null || true
import json, sys

path, n = sys.argv[1], int(sys.argv[2])
fps = []
try:
    with open(path, errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = obj.get("message")
            if obj.get("type") != "assistant" or not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    fps.append("%s|%s" % (b.get("name", ""),
                                          json.dumps(b.get("input", {}), sort_keys=True)))
except Exception:
    sys.exit(0)

best_run, best_fp, run, prev = 0, "", 0, None
for fp in fps:
    run = run + 1 if fp == prev else 1
    prev = fp
    if run > best_run:
        best_run, best_fp = run, fp
if best_run >= n:
    name = best_fp.split("|", 1)[0]
    print("%d\t%s" % (best_run, name))
PYEOF
)
  [[ -n "${RESULT}" ]] || exit 0
  RUN_LEN="${RESULT%%	*}"; TOOL_NAME="${RESULT#*	}"
  report "orch-retry-cap: this subagent executed the SAME ${TOOL_NAME} action ${RUN_LEN} times in a row — step repetition, not progress. Controller: do not re-dispatch the identical prompt; change the approach (add the missing context, decompose the task, or escalate per the BLOCKED recovery tree)."
fi

# --- Stop: whole-reply repetition by the controller (stateful) --------------
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
# Session-keyed: two concurrent sessions in one repo must not interleave
# counters, and yesterday's identical "all green" reply must not accrue.
SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
STATE="${STATE_DIR}/retry-cap.${SESSION_ID:-default}"
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

report "orch-retry-cap: the last ${COUNT} replies were essentially identical — this looks like a stuck loop. Stop and reassess: re-read the plan file, try a different approach, escalate the model, or run /clear and resume from the plan. (Threshold ORCH_RETRY_CAP_N=${N}.)"
