#!/usr/bin/env bash
# LLM Orchestrator PostToolUse telemetry hook — event-only, opt-in.
#
# When enabled, appends ONE line per Skill invocation to
#   ${ORCH_HOME:-~/.llm-orchestrator}/telemetry/skills.jsonl
# Logged: skill name + epoch timestamp + project hash. NEVER: arguments,
# prompt text, tool output, or any other content. This is deliberately not a
# surveillance hook — it records that a skill ran, nothing about what it did.
#
# Default: DISABLED. Enable via ORCH_TELEMETRY=1 in the environment, or a
# project-local .orchrc line `ORCH_TELEMETRY=1`. Matches only the Skill tool.
# Never blocks; always exits 0.
#
# Honours ORCH_HOOK_DRY_RUN=1 (logs intent to stderr, writes nothing).
# Disabled via ORCH_DISABLED_HOOKS containing "orch-skill-telemetry".

set -uo pipefail

DISABLED="${ORCH_DISABLED_HOOKS:-}"
if [[ ",${DISABLED}," == *",orch-skill-telemetry,"* ]]; then
  exit 0
fi

# Opt-in gate: env var wins; otherwise a project-local .orchrc may enable it.
TELEMETRY="${ORCH_TELEMETRY:-0}"
if [[ "${TELEMETRY}" != "1" ]]; then
  ORCHRC="${CLAUDE_PROJECT_DIR:-${PWD}}/.orchrc"
  if [[ -f "${ORCHRC}" ]] \
     && grep -qE '^[[:space:]]*ORCH_TELEMETRY[[:space:]]*=[[:space:]]*1[[:space:]]*$' "${ORCHRC}" 2>/dev/null; then
    TELEMETRY=1
  fi
fi
[[ "${TELEMETRY}" == "1" ]] || exit 0

INPUT=$(cat || true)

# Only the Skill tool. Confirm tool_name before recording anything.
TOOL_NAME=$(printf '%s' "${INPUT}" \
  | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ "${TOOL_NAME}" == "Skill" ]] || exit 0

# Skill name from tool_input — carried as "skill":"<name>" (may be namespaced,
# e.g. "llm-orchestrator:brainstorming"). Fall back to "name" defensively in
# case the harness keys it differently. Nothing else is read from the input.
SKILL=$(printf '%s' "${INPUT}" \
  | grep -oE '"skill"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
if [[ -z "${SKILL}" ]]; then
  SKILL=$(printf '%s' "${INPUT}" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
fi
[[ -n "${SKILL}" ]] || exit 0

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-skill-telemetry]: would append skill="%s" to telemetry/skills.jsonl\n' "${SKILL}" >&2
  exit 0
fi

# Project hash — best-effort; never fail the hook over it.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_HASH="unknown"
if . "${HOOK_DIR}/../lib/orch-project.sh" 2>/dev/null \
   && declare -f orch_project_hash >/dev/null 2>&1; then
  PROJECT_HASH=$(orch_project_hash 2>/dev/null || echo unknown)
fi

TS=$(date +%s 2>/dev/null || echo 0)

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
TEL_DIR="${HOME_DIR}/telemetry"
mkdir -p "${TEL_DIR}" 2>/dev/null || exit 0

# JSON-escape the skill token (controlled, but be safe).
SKILL_ESC=${SKILL//\\/\\\\}; SKILL_ESC=${SKILL_ESC//\"/\\\"}

# A single short JSONL line; O_APPEND keeps concurrent writes from interleaving.
printf '{"skill":"%s","ts":%s,"project":"%s"}\n' "${SKILL_ESC}" "${TS}" "${PROJECT_HASH}" \
  >> "${TEL_DIR}/skills.jsonl" 2>/dev/null || true
exit 0
