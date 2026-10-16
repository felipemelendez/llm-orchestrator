#!/usr/bin/env bash
# LLM Orchestrator — the landing board.
#
# Prints the unmerged ticket branches of a repository against its base branch
# and the oldest one's age in days, so a session opens knowing what is waiting
# to land (skills/finishing-a-branch/references/landing-rules.md, rule 1).
# A report. Read-only git, no network, bash 3.2.
#
# Usage:
#   orch-landing-board.sh [--root <dir>]          # print the board line (or nothing)
#
# The base is origin's HEAD when the remote has one (the remote's view of it,
# so a branch merged on the forge stops counting even before the local base is
# pulled), else a local main or master. Branches named orch/<sid>/<slug> are
# the materialize engine's task worktrees for one ticket and are not listed.
# A branch merged by squash or rebase stays unmerged by commit, so it stays
# listed until its local branch is deleted. A branch's age is the age of its
# first commit off the base, not of its tip, so
# a merge of the base does not make a stale branch look fresh, and a branch
# stacked on an unlanded branch counts that branch's commits too, since that
# work has waited as long. One git call per branch. Outside a git
# repository, or with no base, it prints nothing and exits 0. `--limit <n>`
# and `--check` are accepted and ignored (older callers).

set -uo pipefail

ROOT="${PWD}"
while (( $# )); do
  case "$1" in
    --root) [[ $# -ge 2 && ( "$2" != -* || -d "$2" ) ]] || { printf 'orch-landing-board: --root needs a value\n' >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --limit) shift; (( $# )) && [[ "$1" != -* ]] && shift ;;
    --check) shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'orch-landing-board: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1 || exit 0

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
  # Age of the first commit off the base (a stacked branch counts its base's
  # unlanded commits too: that work has waited that long). Every listed branch
  # has one, since the list is --no-merged. The trailing -- keeps a branch
  # named like a path a branch.
  first=$(git -C "${ROOT}" log --reverse --format=%ct "${BASE}..${name}" -- 2>/dev/null | head -1)
  case "${first}" in (''|*[!0-9]*) first="${NOW}" ;; esac
  age=$(( (NOW - first) / 86400 ))
  (( age > OLDEST )) && OLDEST=${age}
  (( COUNT <= 6 )) && NAMES="${NAMES:+${NAMES}, }${name}"
done < <(git -C "${ROOT}" for-each-ref --format='%(refname:short)' --no-merged "${BASE}" refs/heads 2>/dev/null)

(( COUNT > 0 )) || exit 0
(( COUNT > 6 )) && NAMES="${NAMES}, …"
printf 'landing board: %s unmerged branch(es) against %s, oldest %sd: %s\n' "${COUNT}" "${SHOWN}" "${OLDEST}" "${NAMES}"
exit 0
