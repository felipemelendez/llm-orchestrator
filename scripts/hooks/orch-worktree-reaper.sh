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
#      (Sound because the ledger records a claim only when the COMMAND's
#      success entails the mkdir's success — "PostToolUse fires only on
#      success" alone was not enough: the polite losing form `mkdir X || echo
#      BLOCKED` exits 0 for the LOSER, and recording it had this reaper
#      releasing a mutex a live sibling held.)
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

# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

AGENT_ID=$(printf '%s' "${INPUT}" | grep -oE '"agent_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
SESSION_ID=$(printf '%s' "${INPUT}" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
CWD=$(printf '%s' "${INPUT}" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
[[ -n "${CWD}" ]] || CWD="${CLAUDE_PROJECT_DIR:-${PWD}}"

CORRUPT_SEEN=""
corrupt() { # corrupt <path> — loud report, once per path, for a non-directory at a mutex path
  # newline-delimited dedupe: a space-delimited set is poisoned by paths with spaces
  printf '%s\n' "${CORRUPT_SEEN}" | grep -qxF -- "$1" && return 0
  CORRUPT_SEEN="${CORRUPT_SEEN}${1}
"
  printf 'orch-worktree-reaper: %s is a regular file (or other non-directory), not a mutex directory — protocol corruption (a held mutex is only ever a directory created by mkdir; something improvised a hold-marker there). No writer holds that tree and mkdir will fail against it forever. Inspect and delete it by hand: rm '\''%s'\''\n' "$1" "$1" >&2
}
is_corrupt() { [[ -L "$1" || ( -e "$1" && ! -d "$1" ) ]]; } # symlinks included: mkdir never creates one

reap() { # reap <mutex-dir> <how>
  local dir="$1" how="$2"
  if is_corrupt "${dir}"; then corrupt "${dir}"; return 1; fi
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

# --- 0. corruption scan — always, before any reap-and-exit path --------------
# A regular FILE at a mutex path (repo root included — a controller once
# improvised a "hold" file there) is not a held lock and must never be listed
# as one. Report it loudly even when this invocation goes on to reap something
# else — the early exits below would otherwise swallow the report. The remedy
# is the operator's rm; corrupt() dedupes per path. Derive the checkout root
# from git so a subdirectory cwd cannot hide the repo-root path; fall back to
# the cwd, then strip any worktree suffix.
BASE="${CWD}"
TOP=$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null) && [[ -n "${TOP}" ]] && BASE="${TOP}"
case "${BASE}" in */.worktrees/*) BASE="${BASE%%/.worktrees/*}" ;; esac
for p in "${BASE}/.orch-active" "${BASE}"/.worktrees/*/.orch-active; do
  is_corrupt "${p}" && corrupt "${p}"
done

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
# trap, not just a trailing rm: killed at the hook timeout, a plain rm never runs.
trap 'rm -f "${IN_FILE}" 2>/dev/null' EXIT
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
# A path MENTIONED in a message is not a path the agent HELD. This used to reap
# every `.worktrees/<slug>` appearing anywhere in a success-shaped return, so a
# DONE that said "I left .worktrees/sibling alone, another implementer is still
# writing there" released the sibling's mutex — two writers in one tree, the
# exact corruption the mutex exists to prevent — and then bailed out via the
# first-success `exit 0` with its OWN mutex still held. The BLOCKED carve-out
# above was added for precisely this reason; success returns name siblings just
# as routinely.
#
# Ownership is now taken only from evidence, in order:
#   1. the agent's CWD is inside a worktree  → it held that one;
#   2. the message names exactly ONE worktree → no sibling to confuse it with.
# Anything ambiguous falls through to the report-and-refuse branch below.
if [[ -n "${LAM}" ]] && printf '%s' "${LAM}" | grep -qE '^Status:[[:space:]]*(DONE|DONE_WITH_CONCERNS|PARTIAL)\b'; then
  OWNED=""
  OWNED_HOW=""
  case "${CWD}" in
    */.worktrees/*)
      OWNED=$(printf '%s' "${CWD}" | sed -E 's#(.*/\.worktrees/[^/]+).*#\1#')
      OWNED_HOW="the agent's own working directory" ;;
  esac
  if [[ -z "${OWNED}" ]]; then
    MENTIONED=$(printf '%s' "${LAM}" | grep -oE '\.worktrees/[A-Za-z0-9._-]+' | sort -u)
    if [[ -n "${MENTIONED}" && $(printf '%s\n' "${MENTIONED}" | grep -c .) -eq 1 ]]; then
      OWNED=$(resolve "${MENTIONED}") || OWNED=""
      OWNED_HOW="the only worktree named in a success-shaped final message"
    elif [[ -n "${MENTIONED}" ]]; then
      printf 'orch-worktree-reaper: final message names %s worktrees — cannot tell which this agent held, so nothing was reaped (releasing a sibling a LIVE implementer is writing is the corruption the mutex prevents). Release by hand if a later dispatch returns BLOCKED after ALL implementers finished.\n' \
        "$(printf '%s\n' "${MENTIONED}" | grep -c .)" >&2
    fi
  fi
  if [[ -n "${OWNED}" && -d "${OWNED}/.orch-active" ]]; then
    reap "${OWNED}/.orch-active" "${OWNED_HOW}" && REAPED=1
  fi
  [[ ${REAPED} -eq 1 ]] && exit 0
fi

# --- Nothing provable: report, never guess ----------------------------------
# (corruption was already reported by the scan at the top)
if [[ -d "${BASE}/.worktrees" ]]; then
  LEFT=""
  for p in "${BASE}"/.worktrees/*/.orch-active; do
    [[ -d "${p}" && ! -L "${p}" ]] && LEFT="${LEFT}${p} "
  done
  if [[ -n "${LEFT}" ]]; then
    printf 'orch-worktree-reaper: mutex(es) still held (%s) — could not prove ownership by the stopped agent, so nothing was reaped (a live sibling may hold one). If a later dispatch returns BLOCKED after ALL implementers finished, release by hand: rmdir <path>\n' "${LEFT}" >&2
  fi
fi

exit 0
