#!/usr/bin/env bash
# LLM Orchestrator SessionStart hook.
#
# Loads the using-orchestrator meta-skill (Concise Agent Protocol) as session
# context. User-curated facts live in Claude Code's native CLAUDE.md; plugin
# state is loaded at trigger time by the gate hook, not ambient.
#
# The meta-skill bootstrap always loads. The post-compaction advisory is
# profile-aware: suppressed under ORCH_HOOK_PROFILE=minimal and when
# ORCH_DISABLED_HOOKS contains "orch-handoff-nudge". Disable this hook entirely
# via ORCH_DISABLED_HOOKS containing "orch-session-start".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-session-start,"* ]]; then
  exit 0
fi

# One loud, early notice if python3 is missing: the protocol grader and the
# subagent Status grader both no-op without it. Each also warns at grade time,
# but that stderr is easy to miss; this surfaces it once at session start.
# Informational only — never fails the hook. Silent under the minimal profile,
# where those graders are already off.
if [[ "${PROFILE}" != "minimal" ]] && ! command -v python3 >/dev/null 2>&1; then
  printf 'LLM Orchestrator: python3 not found — the protocol grader and subagent Status grader are disabled. Install python3 to enable them, or set ORCH_HOOK_PROFILE=minimal to silence this notice.\n' >&2
fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MAX_CHARS="${ORCH_SESSION_MAX_CHARS:-8000}"

# Read the hook event JSON from stdin to detect the session source. SessionStart
# fires with source in {startup, clear, compact, resume}. When source==compact,
# this is the first turn AFTER native compaction — the moment to advise the
# controller that the in-flight narrative is lossy. A PreCompact hook exists,
# but carries no additionalContext in hookSpecificOutput — it can block
# compaction, not add to it — so this is where that advisory lives.
INPUT=$(cat || true)
# Extract the source, matching only the documented enum values. Claude Code's
# SessionStart payload is flat (source is a top-level field), so the first match
# is the real value. (This takes the first enum-valued "source" in the payload;
# it does not anchor to the top level — fine because the payload does not nest
# another enum-valued source.)
SOURCE=$(printf '%s' "${INPUT}" | grep -oE '"source"[[:space:]]*:[[:space:]]*"(startup|clear|compact|resume)"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Persist the Claude Code session id so the worktree registry can key ownership
# on it (used by orch-worktree-materialize.sh --list / --release; NOT on the
# writer's anti-clobber critical path, so an absent sid degrades visibility only).
# Best-effort: never fail the hook over this.
SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
if [[ -n "${SESSION_ID}" ]] && . "${ROOT}/scripts/lib/orch-project.sh" 2>/dev/null && declare -f orch_project_hash >/dev/null 2>&1; then
  _sid_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}/sessions/$(orch_project_hash)"
  mkdir -p "${_sid_dir}" 2>/dev/null && printf '%s\n' "${SESSION_ID}" > "${_sid_dir}/sid" 2>/dev/null || true
fi

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

# Extract only the eager protocol core marked in the meta-skill, so SessionStart
# injects ~400 tokens instead of the whole ~2,000-token body. The rest of the
# file (routing table, red flags, dispatch detail) is loaded lazily when the
# agent reads the skill. Prints nothing if the markers are absent — the caller
# then falls back to the full body, so a custom meta-skill without markers keeps
# working exactly as before.
extract_eager() {
  # Buffer the block and emit it only once a matching END marker is seen. A
  # malformed START-without-END therefore prints nothing (fail closed) so the
  # caller falls back to the full body rather than grabbing the file to EOF.
  awk '
    /<!-- ORCH:EAGER:START -->/ { grab=1; buf=""; next }
    /<!-- ORCH:EAGER:END -->/   { if (grab) seen=1; grab=0; next }
    grab { buf = buf $0 "\n" }
    END  { if (seen) printf "%s", buf }
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
  # Prefer the lean eager core; fall back to the full body if unmarked.
  META_BODY=$(extract_eager "${META_FILE}")
  [[ -z "${META_BODY}" ]] && META_BODY=$(strip_frontmatter "${META_FILE}")
fi

# The post-compaction recovery note is the reactive half of the handoff feature.
# Honour the "minimal/disabled = silent" invariant.
PRESSURE_DISABLED=0
if [[ ",${DISABLED}," == *",orch-handoff-nudge,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  PRESSURE_DISABLED=1
fi

# Compact path — emit the lean recovery note plus the canonical per-turn
# protocol reminder (NOT the ~8K meta body, which would risk the 10,000-char
# additionalContext cap). The reminder is included here so protocol survival
# across compaction does not depend on the per-turn hook being enabled.
# The newest-handoff path is derived live (a pointer, never the artifact body).
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

  # Canonical protocol reminder (single source: concise-agent-protocol.md).
  CANON_FILE="${ROOT}/concise-agent-protocol.md"
  PROTOCOL_CORE=""
  [[ -f "${CANON_FILE}" ]] && PROTOCOL_CORE=$(awk '/<!-- orch-turn-reminder-start -->/{f=1;next} /<!-- orch-turn-reminder-end -->/{f=0} f' "${CANON_FILE}" 2>/dev/null)

  NOTE="

---
**Post-compaction recovery.** This session resumed immediately after native context compaction. The narrative above the boundary is a lossy summary — treat in-flight details (file:line refs, test counts, what was just edited) as unverified.

Before continuing or claiming any work done:
- Reconcile against the plan file's checkboxes and TaskList — they are authoritative over any handoff artifact. Re-run the verification baseline if it looks stale.
- Newest handoff artifact: ${NEWEST}. If its frontmatter slug does not match the active plan, discard it and rebuild from the plan file and git history.
- If all plan tasks are checked, stop and report — do not invent work.

${PROTOCOL_CORE}"

  if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
    printf 'orch-dry-run[session-start]: would inject post-compaction recovery note (%s chars)\n' "${#NOTE}" >&2
    exit 0
  fi
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

# Prepend a short preamble naming the Skill tool as the invocation surface for
# the rest of the catalog, so the agent knows where the process lives.
#
# It used to end "skipping a skill that applies is the failure mode, not
# invoking one and discarding it" — an instruction to distrust one's own
# relevance judgement, injected into every session. That is the inverse of the
# Claude 5 guidance ("Then: give Claude rules / Now: let Claude use
# judgement"), and it was the last surviving copy after the same phrasing was
# removed from the meta-skill and CLAUDE.md. The skill descriptions are already
# in context and are the real trigger surface; a mandate on top of them buys
# nothing and costs the model its own judgement about relevance.
PREAMBLE="You are running LLM Orchestrator. Below is the protocol core of your 'using-orchestrator' meta-skill. The rest of the catalog loads through the 'Skill' tool — each skill's description says when it applies.

---
"
POSTAMBLE="
---"

BODY="${PREAMBLE}${META_BODY}${POSTAMBLE}"

BODY=$(truncate_at_line "${BODY}" "${MAX_CHARS}")

if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[session-start]: would inject using-orchestrator meta-skill bootstrap (%s chars)\n' "${#BODY}" >&2
  exit 0
fi

# Keep the printf and `exit 0` on one line. With exit on a separate line, bash
# does a standalone trailing read after the printf that stalls ~570ms per
# session start once stdin has been consumed (a script-buffer artifact; the
# same-line form makes bash read the command and exit together). Regression-
# guarded by tests/test-hook-latency.sh.
ESCAPED=$(printf '%s' "${BODY}" | json_escape)

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "${ESCAPED}"; exit 0
