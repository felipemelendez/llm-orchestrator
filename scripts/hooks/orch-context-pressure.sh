#!/usr/bin/env bash
# LLM Orchestrator context pressure hook — handles UserPromptSubmit and PreCompact.
#
# UserPromptSubmit (existing behaviour):
#   Estimates how full the context window is and advises a handoff when high.
#   Advisory by default: injects an additionalContext hint, never blocks.
#   Set ORCH_HOOK_PROFILE=strict and ORCH_STRICT_CONTEXT_PRESSURE=1 to enable
#   blocking once context reaches ORCH_CONTEXT_BLOCK_PCT (default 85%).
#
# PreCompact (new):
#   Emits an advisory via additionalContext on every compaction event.
#   In strict mode (ORCH_HOOK_PROFILE=strict AND ORCH_STRICT_CONTEXT_PRESSURE=1)
#   AND trigger==auto, emits a top-level block decision instead so the controller
#   can run /llm-orchestrator:handoff before compaction proceeds.
#
# Gated by ORCH_HOOK_PROFILE: skipped under minimal.
# Disabled if ORCH_DISABLED_HOOKS contains "orch-context-pressure".

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-context-pressure,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

# Read the hook event JSON from stdin.
INPUT=$(cat || true)

# Extract hook_event_name — grep-extract idiom.
HOOK_EVENT=$(printf '%s' "${INPUT}" | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Default to UserPromptSubmit for backwards compatibility (pre-existing inputs
# that do not carry hook_event_name, e.g. the existing test fixtures).
HOOK_EVENT="${HOOK_EVENT:-UserPromptSubmit}"

# Native shell JSON escape — no python3 dependency.
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

# ============================================================
# PreCompact branch
# ============================================================
if [[ "${HOOK_EVENT}" == "PreCompact" ]]; then
  # Extract trigger ("auto" | "manual").
  TRIGGER=$(printf '%s' "${INPUT}" | grep -oE '"trigger"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  TRIGGER="${TRIGGER:-unknown}"

  STRICT_BLOCK="${ORCH_STRICT_CONTEXT_PRESSURE:-0}"

  # Strict mode + auto trigger → block so the controller can run /llm-orchestrator:handoff first.
  if [[ "${PROFILE}" == "strict" ]] && [[ "${STRICT_BLOCK}" == "1" ]] && [[ "${TRIGGER}" == "auto" ]]; then
    REASON="Context compaction (trigger: ${TRIGGER}) is about to occur. Run /llm-orchestrator:handoff before compaction proceeds so state survives the boundary. The post-compaction controller should treat the in-flight narrative as lossy and re-run the verification baseline before continuing."
    ESCAPED_REASON=$(printf '%s' "${REASON}" | json_escape)
    printf '{"decision":"block","reason":%s}\n' "${ESCAPED_REASON}"
    exit 0
  fi

  # Advisory path (all other cases).
  MSG="Context compaction is about to occur (trigger: ${TRIGGER}). Regenerate the handoff artifact with /llm-orchestrator:handoff so state survives the compaction boundary. The post-compaction controller should treat the in-flight narrative as lossy and re-run the verification baseline before continuing."
  ESCAPED_MSG=$(printf '%s' "${MSG}" | json_escape)
  printf '{"hookSpecificOutput":{"hookEventName":"PreCompact","additionalContext":%s}}\n' "${ESCAPED_MSG}"
  exit 0
fi

# ============================================================
# UserPromptSubmit branch (existing behaviour — kept exactly as-is)
# ============================================================

# Extract transcript_path — same idiom as orch-protocol-grader.sh.
TRANSCRIPT=$(printf '%s' "${INPUT}" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)

# Resolve relative paths against CLAUDE_PROJECT_DIR or cwd.
if [[ -n "${TRANSCRIPT}" && "${TRANSCRIPT}" != /* ]]; then
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    TRANSCRIPT="${CLAUDE_PROJECT_DIR}/${TRANSCRIPT}"
  else
    TRANSCRIPT="${PWD}/${TRANSCRIPT}"
  fi
fi

# Defense-in-depth: if TRANSCRIPT is empty or is not a regular file (e.g. a
# FIFO, device node, or a path that does not exist), degrade silently — same
# behaviour as the "unknown" advisory path.
if [[ -z "${TRANSCRIPT}" ]] || [[ ! -f "${TRANSCRIPT}" ]]; then
  exit 0
fi

# Source the handoff lib.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="${_HOOK_DIR}/../lib/orch-handoff.sh"
if [[ ! -f "${_LIB}" ]]; then
  printf 'orch-context-pressure: lib not found: %s — pressure check disabled\n' "${_LIB}" >&2
  exit 0
fi
# shellcheck source=scripts/lib/orch-handoff.sh
source "${_LIB}"

# Estimate context fill percentage.
PCT=$(orch_handoff_estimate_pct "${TRANSCRIPT}" 2>/dev/null || true)

# If unknown or below the warn threshold, exit silently.
WARN_PCT="${ORCH_CONTEXT_WARN_PCT:-70}"
if [[ "${PCT}" == "unknown" ]]; then
  exit 0
fi
if (( PCT < WARN_PCT )); then
  exit 0
fi

BLOCK_PCT="${ORCH_CONTEXT_BLOCK_PCT:-85}"
STRICT_BLOCK="${ORCH_STRICT_CONTEXT_PRESSURE:-0}"

# Strict block path.
if [[ "${PROFILE}" == "strict" ]] && [[ "${STRICT_BLOCK}" == "1" ]] && (( PCT >= BLOCK_PCT )); then
  REASON="Context ~${PCT}%. Run /llm-orchestrator:handoff, then resume in a fresh session before continuing."
  ESCAPED_REASON=$(printf '%s' "${REASON}" | json_escape)
  printf '{"decision":"block","reason":%s}\n' "${ESCAPED_REASON}"
  exit 0
fi

# Advisory path.
MSG="Context ~${PCT}% full. A tier boundary (after a green verify, between batches) is the right moment to hand off — run /llm-orchestrator:handoff to regenerate the handoff artifact and resume in a fresh session."
ESCAPED_MSG=$(printf '%s' "${MSG}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED_MSG}"
exit 0
