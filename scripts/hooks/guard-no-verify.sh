#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard.
# Blocks --no-verify and similar bypasses unless the user explicitly opted in.
# Reads JSON event from stdin; exits 0 to allow, exits 2 to block.

set -euo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
ALLOW="${ORCH_ALLOW_NO_VERIFY:-0}"

if [[ ",${DISABLED}," == *",orch-guard,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

INPUT=$(cat || true)

# Look for forbidden flags in the bash command field. Tolerate any JSON layout.
if grep -qE -- '--no-verify|--no-gpg-sign|-c[[:space:]]+commit\.gpgsign=false' <<< "${INPUT}"; then
  if [[ "${ALLOW}" == "1" ]]; then
    exit 0
  fi
  cat <<MSG >&2
LLM Orchestrator guard: blocked command containing --no-verify or signing bypass.
Set ORCH_ALLOW_NO_VERIFY=1 in your environment to allow.
Profile: ${PROFILE}
MSG
  exit 2
fi

exit 0
