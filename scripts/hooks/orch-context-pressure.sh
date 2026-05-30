#!/usr/bin/env bash
# LLM Orchestrator context pressure hook — handles UserPromptSubmit and PreCompact.
#
# UserPromptSubmit (existing behaviour):
#   Estimates how full the context window is and advises a handoff when high.
#   Advisory by default: injects an additionalContext hint, never blocks.
#   Set ORCH_HOOK_PROFILE=strict and ORCH_STRICT_CONTEXT_PRESSURE=1 to enable
#   blocking once context reaches ORCH_CONTEXT_BLOCK_PCT (default 85%).
#
# PreCompact:
#   PreCompact does NOT support hookSpecificOutput.additionalContext (that field
#   is dropped and fails schema validation on manual /compact). So this hook
#   emits NOTHING on the advisory path. Only in strict mode
#   (ORCH_HOOK_PROFILE=strict AND ORCH_STRICT_CONTEXT_PRESSURE=1) AND trigger==auto
#   does it emit a top-level {"decision":"block"} so the controller can run
#   /llm-orchestrator:handoff before an automatic compaction proceeds. The
#   post-compaction advisory is injected separately by session-start.sh, which
#   fires after compaction with source==compact and DOES support additionalContext.
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

  # PreCompact only supports the top-level {"decision":"block","reason":...}
  # contract. It does NOT support hookSpecificOutput.additionalContext — that
  # field is silently dropped (and fails schema validation on manual /compact).
  # The post-compaction advisory is therefore injected from session-start.sh,
  # which fires after compaction with source=="compact" and DOES support
  # additionalContext. See docs/.../context-handoff-hook-contract.md.

  # Strict mode + auto trigger → block so the controller can run /llm-orchestrator:handoff first.
  if [[ "${PROFILE}" == "strict" ]] && [[ "${STRICT_BLOCK}" == "1" ]] && [[ "${TRIGGER}" == "auto" ]]; then
    REASON="Context compaction (trigger: ${TRIGGER}) is about to occur. Run /llm-orchestrator:handoff before compaction proceeds so state survives the boundary. The post-compaction controller should treat the in-flight narrative as lossy and re-run the verification baseline before continuing."
    ESCAPED_REASON=$(printf '%s' "${REASON}" | json_escape)
    printf '{"decision":"block","reason":%s}\n' "${ESCAPED_REASON}"
    exit 0
  fi

  # All other cases: nothing valid to emit on PreCompact. Exit silently — the
  # post-compaction nudge happens in session-start.sh (source=="compact").
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
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_LIB="${_HOOK_DIR}/../lib/orch-handoff.sh"
if [[ ! -f "${_LIB}" ]]; then
  printf 'orch-context-pressure: lib not found: %s — pressure check disabled\n' "${_LIB}" >&2
  exit 0
fi
# shellcheck source=scripts/lib/orch-handoff.sh
source "${_LIB}"

# Estimate context fill. orch_handoff_total_tokens skips synthetic all-zero
# usage lines (interrupts / "<synthetic>" turns), so this reflects the real
# fill even when the transcript ends on a synthetic line.
PCT=$(orch_handoff_estimate_pct "${TRANSCRIPT}" 2>/dev/null || true)
TOKENS=$(orch_handoff_total_tokens "${TRANSCRIPT}" 1 2>/dev/null || true)

# Nothing parseable → silent. (estimate_pct derives from the same tokens, so an
# unknown token total means an unknown percentage too.)
if [[ "${TOKENS}" == "unknown" ]]; then
  exit 0
fi

# --- Validate thresholds (fail safe to documented defaults, never fail open) --
# Under set -u, an unvalidated non-numeric value fed to (( )) aborts the script
# and silently suppresses the advisory/block. Validate every value that reaches
# arithmetic, mirroring the window validation in orch_handoff_window_tokens.
WARN_PCT="${ORCH_CONTEXT_WARN_PCT:-70}"
if ! [[ "${WARN_PCT}" =~ ^[0-9]+$ ]] || (( WARN_PCT < 1 )); then
  WARN_PCT=70
fi
BLOCK_PCT="${ORCH_CONTEXT_BLOCK_PCT:-85}"
if ! [[ "${BLOCK_PCT}" =~ ^[0-9]+$ ]] || (( BLOCK_PCT < 1 )); then
  BLOCK_PCT=85
fi
STRICT_BLOCK="${ORCH_STRICT_CONTEXT_PRESSURE:-0}"

# Absolute token floor. On a 1M-token window the percentage thresholds are
# miscalibrated: native auto-compaction fires near ~150K tokens (~15% on 1M),
# far below the 70% warn (700K). So we also trigger on an absolute token count
# sized to fire BEFORE native auto-compaction, restoring a proactive prong for
# the default profile on large windows. Default 120000.
HANDOFF_TOKENS="${ORCH_CONTEXT_HANDOFF_TOKENS:-120000}"
if ! [[ "${HANDOFF_TOKENS}" =~ ^[0-9]+$ ]]; then
  HANDOFF_TOKENS=120000
fi

WINDOW=$(orch_handoff_window_tokens)
# Effective trigger = the lower of the absolute floor and the warn-percentage
# expressed in tokens — i.e. fire when tokens >= floor OR pct >= warn.
WARN_TOKENS=$(( WARN_PCT * WINDOW / 100 ))
TRIGGER_TOKENS="${HANDOFF_TOKENS}"
if (( WARN_TOKENS < TRIGGER_TOKENS )); then
  TRIGGER_TOKENS="${WARN_TOKENS}"
fi

# Strict block path — enforcement. Fires while over the ceiling, by percentage
# OR by an absolute token ceiling (ORCH_CONTEXT_BLOCK_TOKENS, default 140000 —
# just under the ~150K native auto-compaction trigger, so strict enforcement on
# a 1M window engages before compaction rather than at an unreachable 850K).
BLOCK_TOKENS="${ORCH_CONTEXT_BLOCK_TOKENS:-140000}"
if ! [[ "${BLOCK_TOKENS}" =~ ^[0-9]+$ ]]; then
  BLOCK_TOKENS=140000
fi
if [[ "${PROFILE}" == "strict" ]] && [[ "${STRICT_BLOCK}" == "1" ]]; then
  OVER_BLOCK=0
  if [[ "${PCT}" != "unknown" ]] && (( PCT >= BLOCK_PCT )); then OVER_BLOCK=1; fi
  if (( TOKENS >= BLOCK_TOKENS )); then OVER_BLOCK=1; fi
  if (( OVER_BLOCK == 1 )); then
    REASON="Context ~${PCT}% (${TOKENS} tokens). Run /llm-orchestrator:handoff, then resume in a fresh session before continuing."
    ESCAPED_REASON=$(printf '%s' "${REASON}" | json_escape)
    printf '{"decision":"block","reason":%s}\n' "${ESCAPED_REASON}"
    exit 0
  fi
fi

# Below the trigger → silent.
if (( TOKENS < TRIGGER_TOKENS )); then
  exit 0
fi

# Advisory path. Fires each turn while above the floor — consistent with the
# per-turn protocol reminder this hook family already injects — until a handoff
# resets the session (a fresh session's token count starts below the floor).
PCT_TXT="${PCT}"
[[ "${PCT_TXT}" == "unknown" ]] && PCT_TXT="?"
MSG="Context ~${PCT_TXT}% full (${TOKENS} tokens; native auto-compaction nears ~150K). A tier boundary (after a green verify, between batches) is the right moment to hand off — run /llm-orchestrator:handoff to regenerate the handoff artifact and resume in a fresh session before an automatic compaction summarizes in-flight state."
ESCAPED_MSG=$(printf '%s' "${MSG}" | json_escape)
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "${ESCAPED_MSG}"
exit 0
