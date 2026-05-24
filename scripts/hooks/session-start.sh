#!/usr/bin/env bash
# LLM Orchestrator SessionStart hook.
#
# Loads the using-orchestrator meta-skill (Concise Agent Protocol) as session
# context. That's all the hook does — user-curated project facts live in
# Claude Code's native CLAUDE.md (loaded automatically by Claude Code, not
# by this hook), and plugin-internal state (research config, declined_mcp,
# cache priors) is loaded at trigger time by the gate hook, not ambient.
#
# Profile gating via ORCH_HOOK_PROFILE (default: standard).
# Disable via ORCH_DISABLED_HOOKS containing "orch-session-start".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-session-start,"* ]]; then
  exit 0
fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MAX_CHARS="${ORCH_SESSION_MAX_CHARS:-8000}"

strip_frontmatter() {
  awk '
    BEGIN { in_fm=0; passed=0 }
    /^---$/ {
      if (passed==0 && in_fm==0) { in_fm=1; next }
      else if (in_fm==1) { in_fm=0; passed=1; next }
    }
    passed==1 || (passed==0 && in_fm==0) { print }
  ' "$1"
}

json_escape() {
  local s
  s=$(cat)
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  printf '"%s"' "${s}"
}

truncate_at_line() {
  local input="$1"
  local cap="$2"
  if (( ${#input} <= cap )); then
    printf '%s' "${input}"
    return
  fi
  local head="${input:0:cap}"
  head="${head%$'\n'*}"
  printf '%s\n\n[truncated — raise ORCH_SESSION_MAX_CHARS to see more]' "${head}"
}

META_BODY=""
META_FILE="${ROOT}/skills/using-orchestrator/SKILL.md"
if [[ -f "${META_FILE}" ]]; then
  META_BODY=$(strip_frontmatter "${META_FILE}")
fi

if [[ -z "${META_BODY}" ]]; then
  # Nothing to inject. Emit valid JSON with hookEventName so Claude Code accepts it.
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}\n'
  exit 0
fi

# Wrap the meta-skill in an EXTREMELY_IMPORTANT block so Claude Code treats it
# as system-level directive context rather than ordinary documentation. The
# preamble explicitly names the Skill tool as the invocation surface for every
# other skill in the catalog — this is what gets the agent to auto-invoke
# brainstorming / systematic-debugging / writing-plans / etc. on plain English,
# instead of doing the work inline.
PREAMBLE="<EXTREMELY_IMPORTANT>
You are running LLM Orchestrator.

Below is the full content of your 'using-orchestrator' meta-skill — your introduction to the response protocol and the skill catalog. For every other skill referenced below, use the 'Skill' tool to invoke it. Skipping a skill that applies is the failure mode, not invoking one and discarding the result.

---
"
POSTAMBLE="
---
</EXTREMELY_IMPORTANT>"

BODY="${PREAMBLE}${META_BODY}${POSTAMBLE}"

BODY=$(truncate_at_line "${BODY}" "${MAX_CHARS}")
ESCAPED=$(printf '%s' "${BODY}" | json_escape)

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "${ESCAPED}"
