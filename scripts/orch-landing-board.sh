#!/usr/bin/env bash
# LLM Orchestrator — the landing board.
#
# Prints the unmerged ticket branches of a repository against its base branch,
# the oldest one's age in days, and a warning when their number fills the
# work-in-progress limit (skills/finishing-a-branch/references/landing-rules.md,
# rules 1 and 9). Read-only git, no network, bash 3.2.
#
# Usage:
#   orch-landing-board.sh [--root <dir>] [--limit <n>]          # print the board line (or nothing)
#   orch-landing-board.sh [--root <dir>] [--limit <n>] --check  # same; exit 3 when there is no room for one more
#
# The limit is --limit, else ORCH_WIP_LIMIT, else "wip_limit" in the project's
# docs/llm-orchestrator/cadence.json, else 2. The base is origin's HEAD when
# the remote has one (the remote's view of it, so a branch merged on the forge
# stops counting even before the local base is pulled), else a local main or
# master. Branches named orch/<sid>/<slug> are the materialize engine's task
# worktrees for one ticket and are not counted. A branch's age is the age of its
# first commit off the base, not of its tip, so a merge of the base does not
# make a stale branch look fresh. Outside a git repository, or with no base, it
# prints nothing and exits 0. `--check` is what /llm-orchestrator:dispatch runs
# before cutting a new ticket branch: exit 3 means the open branches already
# fill the limit, land one first. The session-start hook prints the same line.

set -uo pipefail

ROOT="${PWD}"
LIMIT=""
CHECK=0
while (( $# )); do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'orch-landing-board: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1 || exit 0
TOP=$(git -C "${ROOT}" rev-parse --show-toplevel 2>/dev/null)

# The limit, in order of precedence. The cadence.json key is read with one
# grep so a project without python3 still gets its number.
[[ -n "${LIMIT}" ]] || LIMIT="${ORCH_WIP_LIMIT:-}"
if [[ -z "${LIMIT}" && -n "${TOP}" && -f "${TOP}/docs/llm-orchestrator/cadence.json" ]]; then
  LIMIT=$(grep -oE '"wip_limit"[[:space:]]*:[[:space:]]*[0-9]+' "${TOP}/docs/llm-orchestrator/cadence.json" 2>/dev/null \
          | head -1 | grep -oE '[0-9]+$')
fi
case "${LIMIT}" in (''|*[!0-9]*) LIMIT=2 ;; esac

# The base: the remote's view of origin's HEAD when it exists, else local main/master.
BASE=""; SHOWN=""
REMOTE_HEAD=$(git -C "${ROOT}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
if [[ -n "${REMOTE_HEAD}" ]] && git -C "${ROOT}" show-ref --verify --quiet "refs/remotes/${REMOTE_HEAD}"; then
  BASE="${REMOTE_HEAD}"; SHOWN="${REMOTE_HEAD#origin/}"
fi
if [[ -z "${BASE}" ]]; then
  for b in main master; do
    if git -C "${ROOT}" show-ref --verify --quiet "refs/heads/${b}"; then BASE="${b}"; SHOWN="${b}"; break; fi
  done
fi
[[ -n "${BASE}" ]] || exit 0

NOW=$(date +%s)
COUNT=0; OLDEST=0; NAMES=""
while IFS= read -r name; do
  [[ -z "${name}" || "${name}" == "${SHOWN}" ]] && continue
  case "${name}" in orch/*) continue ;; esac
  COUNT=$((COUNT + 1))
  # Age of the first commit off the base; the tip's date when none is found.
  first=$(git -C "${ROOT}" log --reverse --format=%ct "${BASE}..${name}" 2>/dev/null | head -1)
  [[ -n "${first}" ]] || first=$(git -C "${ROOT}" log -1 --format=%ct "${name}" 2>/dev/null)
  case "${first}" in (''|*[!0-9]*) first="${NOW}" ;; esac
  age=$(( (NOW - first) / 86400 ))
  (( age > OLDEST )) && OLDEST=${age}
  (( COUNT <= 6 )) && NAMES="${NAMES:+${NAMES}, }${name}"
done < <(git -C "${ROOT}" for-each-ref --format='%(refname:short)' --no-merged "${BASE}" refs/heads 2>/dev/null)

(( COUNT > 0 )) || exit 0
(( COUNT > 6 )) && NAMES="${NAMES}, …"
LINE="landing board: ${COUNT} unmerged branch(es) against ${SHOWN}, oldest ${OLDEST}d: ${NAMES}"
if (( COUNT > LIMIT )); then
  LINE="${LINE} · over the limit of ${LIMIT} in progress: land before dispatching more (finishing-a-branch, landing-rules.md)"
elif (( COUNT == LIMIT )); then
  LINE="${LINE} · at the limit of ${LIMIT} in progress: land one before cutting another (finishing-a-branch, landing-rules.md)"
fi
printf '%s\n' "${LINE}"
if (( CHECK == 1 && COUNT >= LIMIT )); then exit 3; fi
exit 0
