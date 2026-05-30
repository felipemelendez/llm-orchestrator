#!/usr/bin/env bash
# LLM Orchestrator SessionStart hook.
#
# Loads the using-orchestrator meta-skill (Concise Agent Protocol) as session
# context. That's all the hook does — user-curated project facts live in
# Claude Code's native CLAUDE.md (loaded automatically by Claude Code, not
# by this hook), and plugin-internal state (research config, declined_mcp,
# cache priors) is loaded at trigger time by the gate hook, not ambient.
#
# The meta-skill bootstrap always loads (profile-independent). The post-compaction
# advisory, part of the Layer 9 handoff feature, is profile-aware: suppressed under
# ORCH_HOOK_PROFILE=minimal and when ORCH_DISABLED_HOOKS contains "orch-context-pressure".
# Disable this hook entirely via ORCH_DISABLED_HOOKS containing "orch-session-start".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-session-start,"* ]]; then
  exit 0
fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MAX_CHARS="${ORCH_SESSION_MAX_CHARS:-8000}"

# Read the hook event JSON from stdin to detect the session source. SessionStart
# fires with source in {startup, clear, compact, resume}. When source==compact,
# this is the first turn AFTER native compaction — the moment to advise the
# controller that the in-flight narrative is lossy. PreCompact cannot inject
# context (it only supports decision:block), so this is where that advisory lives.
INPUT=$(cat || true)
# Anchor to the documented SessionStart source enum so an unrelated nested
# "source" string elsewhere in the payload cannot shadow the real value.
SOURCE=$(printf '%s' "${INPUT}" | grep -oE '"source"[[:space:]]*:[[:space:]]*"(startup|clear|compact|resume)"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

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

# Post-compaction advisory — appended only when this session began from a
# native compaction. Tells the fresh controller to treat the summarised
# narrative as lossy and re-establish ground truth before continuing.
#
# This advisory is part of the Layer 9 handoff feature, whose owning hook is
# orch-context-pressure. To honour the "minimal/disabled = silent" invariant
# per-feature, suppress it under the minimal profile and when the pressure hook
# is disabled — even though the meta-skill bootstrap below always loads.
POSTCOMPACT_NOTE=""
PRESSURE_DISABLED=0
if [[ ",${DISABLED}," == *",orch-context-pressure,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  PRESSURE_DISABLED=1
fi
if [[ "${SOURCE}" == "compact" ]] && [[ "${PRESSURE_DISABLED}" == "0" ]]; then
  POSTCOMPACT_NOTE="

---
<EXTREMELY_IMPORTANT>
This session resumed immediately after native context compaction. The narrative above the compaction boundary is a lossy summary — treat in-flight details (file:line refs, test counts, what was just edited) as unverified. Before continuing or claiming any work is done: re-run the verification baseline (tests / typecheck) and reconcile against the plan file's checkboxes. If a handoff artifact under docs/llm-orchestrator/handoffs/ matches the CURRENT task (check its frontmatter slug against the active plan), read it; if none matches the current task, do NOT trust an older one — treat all in-flight state as lost and rebuild from the plan file and git history. Then, if mid-task, regenerate the handoff with /llm-orchestrator:handoff.
</EXTREMELY_IMPORTANT>"
fi

if [[ -z "${META_BODY}" ]]; then
  # Nothing to inject from the meta-skill. Still emit the post-compaction note
  # if present. Emit valid JSON with hookEventName so Claude Code accepts it.
  ESCAPED=$(printf '%s' "${POSTCOMPACT_NOTE}" | json_escape)
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "${ESCAPED}"
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
# Append the post-compaction note AFTER truncation so it is never cut off.
BODY="${BODY}${POSTCOMPACT_NOTE}"
ESCAPED=$(printf '%s' "${BODY}" | json_escape)

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "${ESCAPED}"
