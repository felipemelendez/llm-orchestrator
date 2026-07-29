#!/usr/bin/env bash
# LLM Orchestrator SubagentStop hook (matcher: orch-implementer) — mutex reaper.
#
# The implementer's writer mutex (`mkdir <worktree>/.orch-active`) is released
# by a VOLUNTARY final-turn rmdir. An implementer that dies or terminates
# prematurely strands the mutex — and every later dispatch into that worktree
# returns BLOCKED forever. This reaper releases a mutex ONLY when the evidence
# ties it to the implementer that just stopped:
#
#   1. The mutex map written by orch-evidence-ledger.sh: claims recorded with
#      THIS agent_id and no matching release → reap those paths exactly.
#      (Sound because PostToolUse fires only on success: a lost mkdir race
#      records no claim, so a claim really means this agent held the mutex.)
#   2. A `.worktrees/<slug>` path named in the agent's final message, ONLY
#      when that message is a success-shaped Status (DONE / DONE_WITH_CONCERNS
#      / PARTIAL) — i.e. the agent reports having worked there and stopped
#      without releasing. Never on BLOCKED/NEEDS_CONTEXT: a BLOCKED return
#      routinely NAMES a sibling's held worktree ("Need: a worktree not
#      already being written…"), and reaping it would unlock a tree a LIVE
#      sibling is writing — the exact corruption the mutex exists to prevent.
#
# There is deliberately NO "single leftover" heuristic: with parallel writers,
# the one remaining mutex is usually a live sibling's. When neither evidence
# path matches, the reaper reaps NOTHING and prints what is still held; the
# controller releases by hand once all implementers have finished
# (`rmdir <worktree>/.orch-active` — see dispatching-subagents, stale-mutex
# corner).
#
# Reaping is `rmdir` on purpose: it only removes an EMPTY marker dir; anything
# unexpected inside makes it a no-op with a warning. Never blocks (exit 0).
# Gated by ORCH_HOOK_PROFILE (off under minimal) and
# ORCH_DISABLED_HOOKS=orch-worktree-reaper.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-worktree-reaper,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"

INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

AGENT_ID=$(printf '%s' "${INPUT}" | grep -oE '"agent_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
CWD=$(printf '%s' "${INPUT}" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ -n "${CWD}" ]] || CWD="${CLAUDE_PROJECT_DIR:-${PWD}}"

reap() { # reap <mutex-dir> <how>
  local dir="$1" how="$2"
  [[ -d "${dir}" ]] || return 1
  if rmdir "${dir}" 2>/dev/null; then
    printf 'orch-worktree-reaper: released abandoned writer mutex %s (matched via %s) — the implementer stopped without releasing it; the worktree is dispatchable again.\n' "${dir}" "${how}" >&2
    return 0
  fi
  printf 'orch-worktree-reaper: mutex %s is NOT empty — refusing to remove it; inspect by hand.\n' "${dir}" >&2
  return 1
}

resolve() { # resolve <path> → absolute (against CWD when relative); refuses $-vars
  case "$1" in
    *'$'*) return 1 ;;   # unexpanded variable recorded verbatim — unusable
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "${CWD}" "$1" ;;
  esac
}

REAPED=0

# --- 1. mutex map (exact, per agent_id) -------------------------------------
if [[ -n "${AGENT_ID}" && -n "${SESSION_ID}" ]]; then
  HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  HASH="default"
  declare -f orch_project_hash >/dev/null 2>&1 && HASH=$(orch_project_hash 2>/dev/null || echo default)
  MAP="${HOME_DIR}/state/${HASH}/mutex-map.${SESSION_ID}.tsv"
  if [[ -f "${MAP}" ]]; then
    # Paths this agent claimed and never released.
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      abs=$(resolve "${path}") || continue
      reap "${abs}" "mutex map (agent ${AGENT_ID})" && REAPED=1
    done < <(awk -F'\t' -v a="${AGENT_ID}" '
      $2==a && $1=="claim"   { c[$3]=1 }
      $2==a && $1=="release" { delete c[$3] }
      END { for (p in c) print p }' "${MAP}" 2>/dev/null)
    [[ ${REAPED} -eq 1 ]] && exit 0
  fi
fi

# --- 2. worktree named in a SUCCESS-shaped final message --------------------
IN_FILE=$(mktemp) || exit 0
printf '%s' "${INPUT}" > "${IN_FILE}"
LAM=$(python3 - "${IN_FILE}" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("last_assistant_message") or "", end="")
except Exception:
    pass
PYEOF
)
rm -f "${IN_FILE}" 2>/dev/null
if [[ -n "${LAM}" ]] && printf '%s' "${LAM}" | grep -qE '^Status:[[:space:]]*(DONE|DONE_WITH_CONCERNS|PARTIAL)\b'; then
  for slugpath in $(printf '%s' "${LAM}" | grep -oE '\.worktrees/[A-Za-z0-9._-]+' | sort -u); do
    abs=$(resolve "${slugpath}") || continue
    [[ -d "${abs}/.orch-active" ]] && reap "${abs}/.orch-active" "final-message path (success status)" && REAPED=1
  done
  [[ ${REAPED} -eq 1 ]] && exit 0
fi

# --- Nothing provable: report, never guess ----------------------------------
if [[ -d "${CWD}/.worktrees" ]]; then
  LEFT=$(ls -d "${CWD}"/.worktrees/*/.orch-active 2>/dev/null || true)
  if [[ -n "${LEFT}" ]]; then
    printf 'orch-worktree-reaper: mutex(es) still held (%s) — could not prove ownership by the stopped agent, so nothing was reaped (a live sibling may hold one). If a later dispatch returns BLOCKED after ALL implementers finished, release by hand: rmdir <path>\n' "$(printf '%s' "${LEFT}" | tr '\n' ' ')" >&2
  fi
fi

exit 0
