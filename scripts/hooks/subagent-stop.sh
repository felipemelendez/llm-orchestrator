#!/usr/bin/env bash
# LLM Orchestrator SubagentStop hook — subagent-return validator.
#
# Fires when a dispatched subagent finishes. Three checks, scoped by agent type:
#
#   1. EMPTY RETURN (all agents): a subagent that finishes with no final text
#      terminated prematurely (MAST FM-3.1). This is a FAILURE signal — warn
#      (or block under ORCH_STRICT_STATUS=1) so the controller re-dispatches or
#      resumes instead of treating silence as success.
#   2. SHAPE (plugin agents only): the final message must match the agent's
#      output contract — a Status: block for orch-implementer (via
#      orch_grade_status_block: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT|
#      PARTIAL with the enum-implied sub-block), a protocol header
#      (Found:/Issues:/Status:...) for the read-only agents. orch-researcher is
#      skipped here — orch-researcher-validator.sh owns its contract.
#   3. EVIDENCE (orch-implementer only, warn-only): a DONE /
#      DONE_WITH_CONCERNS claim that cites an [orch-evidence] stamp is checked
#      against the ledger the PostToolUse hook wrote. A fabricated stamp or a
#      stamp from a FAILING run warns; the controller should not trust the DONE.
#
# The final text comes from the hook input's last_assistant_message field
# (transcript files lag and, on SubagentStop, transcript_path points at the
# MAIN transcript); the transcript is only a fallback for old harnesses.
#
# Non-blocking by default; ORCH_STRICT_STATUS=1 makes checks 1–2 blocking
# (exit 2 → the reason is fed back to the subagent, which keeps working).
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
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${HOOK_DIR}/../lib/orch-protocol.sh"
if [[ ! -f "${LIB}" ]]; then
  printf 'orch-subagent-stop: lib not found: %s — grading disabled\n' "${LIB}" >&2
  exit 0
fi
# shellcheck source=scripts/lib/orch-protocol.sh
source "${LIB}"
EV_LIB="${HOOK_DIR}/../lib/orch-evidence.sh"
# shellcheck source=scripts/lib/orch-evidence.sh
[[ -f "${EV_LIB}" ]] && source "${EV_LIB}"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"

# Read the hook event JSON from stdin.
# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# Extract fields without jq. last_assistant_message needs real JSON decoding
# (it contains escapes); the scalar fields are safe to grab with grep.
IN_FILE=$(mktemp) || exit 0
# trap, not just a trailing rm: killed at the hook timeout, a plain rm never runs.
trap 'rm -f "${IN_FILE}" 2>/dev/null' EXIT
printf '%s' "${INPUT}" > "${IN_FILE}"
# First output char is a sentinel: "1" = the field exists in the input (its
# emptiness is then a REAL observation), "0" = old harness without the field.
LAM_RAW=$(python3 - "${IN_FILE}" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    has = "1" if "last_assistant_message" in data else "0"
    sys.stdout.write(has + (data.get("last_assistant_message") or ""))
except Exception:
    sys.stdout.write("0")
PYEOF
)
rm -f "${IN_FILE}" 2>/dev/null
HAS_LAM="${LAM_RAW:0:1}"
ASSISTANT_TEXT="${LAM_RAW:1}"

AGENT_TYPE=$(printf '%s' "${INPUT}" | grep -oE '"agent_type"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Fallback for harnesses that predate last_assistant_message: the transcript.
# Only when the field was ABSENT — when it exists but is empty, reading the
# transcript would grade the MAIN conversation's last message, not the
# subagent's (transcript_path points at the main transcript on SubagentStop).
if [[ "${HAS_LAM}" != "1" && -z "${ASSISTANT_TEXT}" ]]; then
  TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  if [[ -n "${TRANSCRIPT}" && -f "${TRANSCRIPT}" ]]; then
    ASSISTANT_TEXT=$(orch_extract_last_assistant_text "${TRANSCRIPT}")
    [[ -n "${ASSISTANT_TEXT}" ]] || ASSISTANT_TEXT=$(cat "${TRANSCRIPT}" 2>/dev/null || true)
  fi
fi

emit() { # emit <warn-text> → warn or block per strict/dry-run, then exit
  local warn="$1"
  if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
    printf 'orch-dry-run[orch-subagent-stop]: would %s — %s\n' "$([[ "${STRICT}" == "1" ]] && echo 'block (exit 2)' || echo 'warn (stderr)')" "${warn}" >&2
    exit 0
  fi
  local esc; esc="$(printf '%s' "${warn}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"
  if [[ "${STRICT}" == "1" ]]; then
    # exit 2 feeds ONLY stderr back to the subagent — the reason goes there.
    printf '{"decision":"block","reason":%s}\n' "${esc}" | tee /dev/stderr
    exit 2
  fi
  # Warn path: stderr for the user, additionalContext for the model.
  echo "${warn}" >&2
  printf '{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":%s}}\n' "${esc}"
  exit 0
}

# --- Check 1: empty return = premature termination --------------------------
# Only when emptiness is a real observation: the harness sent the
# last_assistant_message field (empty), or a transcript existed and yielded
# nothing. An old harness with neither field nor transcript stays fail-open.
#
# Scoped to PLUGIN agents. The message tells the receiver to return a Status
# block — a contract only this plugin's agents were given. Firing it at a
# built-in Explore or Plan agent, or any third-party agent that happens to run
# in this session, hands an unexplained directive to something that has no idea
# what a Status block is and cannot comply.
_STRIPPED="$(printf '%s' "${ASSISTANT_TEXT}" | tr -d '[:space:]')"
if [[ -z "${_STRIPPED}" ]]; then
  case "${AGENT_TYPE}" in
    *orch-implementer|*orch-explorer|*orch-debugger|*orch-researcher|*orch-spec-reviewer|*orch-code-reviewer|*orch-security-reviewer)
      if [[ "${HAS_LAM}" == "1" || ( -n "${TRANSCRIPT:-}" && -f "${TRANSCRIPT:-/nonexistent}" ) ]]; then
        emit "orch-subagent-stop: subagent '${AGENT_TYPE:-unknown}' finished with NO final message — premature termination. Do not treat this as success: return an explicit Status block (DONE with Verify:, PARTIAL with Progress:/Remaining:, or BLOCKED with Need:) describing where the work stands."
      fi ;;
  esac
  exit 0
fi

# --- Check 2: shape, scoped by agent type -----------------------------------
case "${AGENT_TYPE}" in
  *orch-implementer)
    GRADE_OUTPUT=$(printf '%s\n' "${ASSISTANT_TEXT}" | orch_grade_status_block 2>&1)
    if [[ $? -ne 0 ]]; then
      emit "orch-subagent-stop: implementer finished without a valid Status block (${GRADE_OUTPUT}). Expected DONE (Summary: + Verify:) | DONE_WITH_CONCERNS (Concerns: + Verify:) | BLOCKED (Need:) | NEEDS_CONTEXT (Ask:) | PARTIAL (Progress: + Remaining:) at the start of a line. A completion claim carries the verification burden: Verify: needs a real command and its real output, not an assertion."
    fi
    # --- Check 3: evidence cross-check on completion claims (warn-only) -----
    if printf '%s' "${ASSISTANT_TEXT}" | grep -qE '^Status:[[:space:]]*(DONE|DONE_WITH_CONCERNS)\b' \
       && declare -f orch_evidence_check >/dev/null 2>&1 && [[ -n "${SESSION_ID}" ]]; then
      LEDGER=$(orch_evidence_ledger_path "${SESSION_ID}")
      EV_REASON=$(orch_evidence_check "${ASSISTANT_TEXT}" "${LEDGER}")
      EV_RC=$?
      if [[ ${EV_RC} -eq 1 ]]; then
        printf 'orch-subagent-stop: implementer DONE claim fails evidence check — %s Controller: do NOT trust this DONE; re-verify before marking the task complete.\n' "${EV_REASON}" >&2
      fi
      # A return that cites no stamp is silent by construction: citation is
      # opt-in (ORCH_EVIDENCE_MARKER=1) and the ledger is read directly by the
      # controller-side gate. Only a stamp that contradicts the ledger speaks.
    fi
    ;;
  *orch-researcher)
    : # orch-researcher-validator.sh owns the researcher's contract.
    ;;
  *orch-explorer|*orch-debugger|*orch-spec-reviewer|*orch-code-reviewer|*orch-security-reviewer)
    GRADE_OUTPUT=$(printf '%s\n' "${ASSISTANT_TEXT}" | orch_grade_reply 2>&1)
    if [[ $? -ne 0 ]]; then
      emit "orch-subagent-stop: ${AGENT_TYPE} finished without a protocol shape (${GRADE_OUTPUT}). Open the reply with the block your contract names (Found:/Issues:/Status:)."
    fi
    ;;
  *)
    : # Non-plugin agents: no shape contract — the empty-return check above is all.
    ;;
esac

exit 0
