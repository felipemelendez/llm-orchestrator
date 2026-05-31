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
# ORCH_HOOK_PROFILE=minimal and when ORCH_DISABLED_HOOKS contains "orch-handoff-nudge".
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
# Extract the source, matching only the documented enum values. Claude Code's
# SessionStart payload is flat (source is a top-level field), so the first match
# is the real value. (This takes the first enum-valued "source" in the payload;
# it does not anchor to the top level — fine because the payload does not nest
# another enum-valued source.)
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

# The post-compaction recovery note is the reactive half of the Layer 9 handoff
# feature (its proactive half is the orch-handoff-nudge UserPromptSubmit hook).
# Honour the "minimal/disabled = silent" invariant: suppress under the minimal
# profile and when the handoff nudge is disabled.
PRESSURE_DISABLED=0
if [[ ",${DISABLED}," == *",orch-handoff-nudge,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  PRESSURE_DISABLED=1
fi

# ---------------------------------------------------------------------------
# Compact path — emit the lean recovery note ONLY (no meta-skill body).
#
# Why not re-inject the full meta-skill here? After native compaction the
# per-turn UserPromptSubmit hook re-asserts the Concise Agent Protocol on the
# next prompt, so the protocol is not lost. Re-injecting the ~8K meta body PLUS
# this note would risk the documented 10,000-char additionalContext cap —
# oversized hook output is spilled to a file and replaced with a preview, so
# the agent might never read the recovery directive inline. Keeping the compact
# output lean guarantees the directive is delivered.
#
# The newest-handoff path is derived live here (a pointer, never the artifact
# body), so there is no cross-hook pointer file to go stale or clobber.
# ---------------------------------------------------------------------------
if [[ "${SOURCE}" == "compact" ]] && [[ "${PRESSURE_DISABLED}" == "0" ]]; then
  PROJ="${CLAUDE_PROJECT_DIR:-${PWD}}"
  HANDOFF_DIR="${PROJ}/docs/llm-orchestrator/handoffs"
  NEWEST="none"
  if [[ -d "${HANDOFF_DIR}" ]]; then
    # Newest by modification time (robust to regeneration in place). The note
    # also tells the next turn the plan file is authoritative over the artifact,
    # so a wrong pick self-corrects, but mtime is the right primary signal.
    _newest=$(ls -1t "${HANDOFF_DIR}"/*.md 2>/dev/null | head -1)
    [[ -n "${_newest}" ]] && NEWEST="${_newest}"
  fi

  NOTE="

---
<EXTREMELY_IMPORTANT>
This session resumed immediately after native context compaction. The narrative above the boundary is a lossy summary — treat in-flight details (file:line refs, test counts, what was just edited) as unverified.

Before continuing or claiming any work done:
- Reconcile against the plan file's checkboxes and TaskList — they are authoritative over any handoff artifact. Re-run the verification baseline if it looks stale.
- Newest handoff artifact: ${NEWEST}. If its frontmatter slug does not match the active plan, discard it and rebuild from the plan file and git history.
- If all plan tasks are checked, STOP and report — do not invent work.
</EXTREMELY_IMPORTANT>"

  ESCAPED=$(printf '%s' "${NOTE}" | json_escape)
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "${ESCAPED}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal path — startup / clear / resume (and compact under minimal/disabled,
# which falls through here and emits the meta-skill with no recovery note).
# Load the using-orchestrator meta-skill as session context.
# ---------------------------------------------------------------------------
if [[ -z "${META_BODY}" ]]; then
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
