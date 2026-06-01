#!/usr/bin/env bash
# LLM Orchestrator — worktree merge-back / integration engine.
#
# The symmetric JOIN half of the materialize engine. After parallel writers
# finish in their isolated worktrees, this merges each branch back into the base
# branch — sequentially, with a test gate after EACH merge, stopping at the first
# failure while keeping prior successes. Orchestration is only complete when the
# pieces reassemble reliably; this enforces that instead of trusting the
# controller to merge by hand.
#
# Safety: conflicts get a clean `git merge --abort`. A signal/error mid-merge
# aborts the in-progress merge so the base is never left half-merged. We NEVER
# auto-`reset --hard` the base; a test failure after a clean merge stops and
# reports the base SHA for the human/controller to resolve. Destructive git here
# runs inside this trusted script, out of the PreToolUse guard's scope.
#
# NOTE: sourcing this file sets -uo pipefail in the caller's shell (intentional).
#
# Usage:
#   orch-worktree-integrate.sh [--test "<cmd>"] [--allow-no-tests] [--no-remove] \
#                              [--dry-run] <session_id> <slug> [slug ...]
#
# Bash 3.2 compatible.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MAT="${_SCRIPT_DIR}/orch-worktree-materialize.sh"   # for --release

sanitize() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# --- report state ----------------------------------------------------------
I_LINE=()        # completed "Integrated:" lines
STOPPED=""       # single "Stopped:" line (empty if none)
PENDING=()       # slugs not attempted (original order)
RERUN=()         # stopped + pending slugs (original order) for the Re-run line
UNVERIFIED=0     # 1 when running without a test gate
TESTCMD=""
CUR_SLUG=""      # in-flight slug; non-empty ONLY while its outcome is uncertain
CUR_IDX=-1       # in-flight loop index, for Pending/Re-run on the signal path
PRE=""           # base HEAD captured just before the in-flight slug's merge
TESTOUT=""       # temp file holding current test output (cleaned on every exit)
NOREMOVE=0       # --no-remove, reproduced in the Re-run line
RAW=()           # original slug args (global so on_signal can slice them)

report_and_exit() {
  local code="$1" s
  trap - EXIT INT TERM HUP    # clear first so no path double-reports
  [[ -n "${TESTOUT:-}" ]] && rm -f "${TESTOUT}" >/dev/null 2>&1; true
  [[ ${UNVERIFIED} -eq 1 ]] && printf 'WARNING: no test command — this run is UNVERIFIED.\n'
  printf 'Integrated:\n'
  if [[ ${#I_LINE[@]} -gt 0 ]]; then for s in "${I_LINE[@]}"; do printf -- '- %s\n' "${s}"; done; else printf -- '- (none)\n'; fi
  if [[ -n "${STOPPED}" ]]; then printf 'Stopped:\n- %s\n' "${STOPPED}"; fi
  if [[ ${#PENDING[@]} -gt 0 ]]; then local pj; pj="$(printf '%s, ' "${PENDING[@]}")"; printf 'Pending (not attempted, original order):\n- %s\n' "${pj%, }"; fi
  if [[ ${#RERUN[@]} -gt 0 ]]; then
    local t="--test $(printf '%q' "${TESTCMD}")"; [[ ${UNVERIFIED} -eq 1 ]] && t="--allow-no-tests"; [[ ${NOREMOVE} -eq 1 ]] && t="${t} --no-remove"
    printf 'Re-run: bash %s %s %s %s\n' "${_SCRIPT_DIR}/orch-worktree-integrate.sh" "${t}" "${SID:-<sid>}" "${RERUN[*]}"
  fi
  exit "${code}"
}

on_signal() {
  # Decide from git's REAL state, not a shadow flag (which lags commits by a line).
  local in_merge=""; git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && in_merge=1
  git merge --abort >/dev/null 2>&1 || true   # cleans an in-progress merge; no-op otherwise
  if [[ -n "${CUR_SLUG}" ]]; then
    # interrupted mid-slug
    if [[ -n "${in_merge}" ]]; then
      STOPPED="${CUR_SLUG} — ABORTED (signal) — in-progress merge aborted, base clean"
    elif [[ -n "${PRE}" && "$(git rev-parse HEAD 2>/dev/null)" != "${PRE}" ]]; then
      STOPPED="${CUR_SLUG} — ABORTED (signal; untested commit at $(git rev-parse --short HEAD 2>/dev/null)) — base holds a merge whose tests did not finish; treat as TEST_FAILED (inspect/revert)"
    else
      STOPPED="${CUR_SLUG} — ABORTED (signal) — no merge in progress, base clean"
    fi
    PENDING=("${RAW[@]:$((CUR_IDX+1))}"); RERUN=("${RAW[@]:$CUR_IDX}")
  else
    # signal before the loop (CUR_IDX=-1 → all) or between slugs (after the last
    # completed CUR_IDX → the rest). Nothing was interrupted, so no Stopped line.
    PENDING=("${RAW[@]:$((CUR_IDX+1))}"); RERUN=("${RAW[@]:$((CUR_IDX+1))}")
  fi
  report_and_exit 1
}

do_integrate() {
  local dry=0 allow_no_tests=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) TESTCMD="$2"; shift 2 ;;
      --allow-no-tests) allow_no_tests=1; shift ;;
      --no-remove) NOREMOVE=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) break ;;
    esac
  done
  SID="${1:-}"; shift || true
  [[ -n "${SID}" ]] || { echo "orch-integrate: empty session id (try materialize --sid)" >&2; exit 2; }
  [[ "${SID}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "orch-integrate: invalid session id — got '${SID}'" >&2; exit 2; }
  [[ $# -gt 0 ]] || { echo "usage: orch-worktree-integrate.sh [--test \"<cmd>\"] [--allow-no-tests] [--no-remove] [--dry-run] <session_id> <slug> [slug ...]" >&2; exit 2; }

  RAW=("$@"); local raw slug branch i n="$#"

  # pre-flight (no mutation)
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "orch-integrate: not inside a git repository" >&2; exit 2; }
  [[ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]] || { echo "orch-integrate: must be run from the repo root" >&2; exit 2; }
  git diff --quiet >/dev/null 2>&1 && git diff --cached --quiet >/dev/null 2>&1 || { echo "orch-integrate: base branch is dirty — commit or stash your own changes first" >&2; exit 2; }
  for raw in "${RAW[@]}"; do
    slug="$(sanitize "${raw}")"; branch="orch/${SID}/${slug}"
    git show-ref --verify --quiet "refs/heads/${branch}" || { echo "orch-integrate: branch missing: ${branch}" >&2; exit 2; }
  done

  # resolve the test command
  if [[ -z "${TESTCMD}" ]]; then
    TESTCMD="$(. "${_SCRIPT_DIR}/lib/orch-detect.sh" >/dev/null 2>&1; orch_detect_cached "${PWD}" 2>/dev/null | sed -n 's/^test=//p' | head -1)"
  fi
  if [[ -z "${TESTCMD}" ]]; then
    [[ ${allow_no_tests} -eq 1 ]] || { echo "orch-integrate: no test command found — pass --test \"<cmd>\" or --allow-no-tests" >&2; exit 2; }
    UNVERIFIED=1
  fi

  if [[ ${dry} -eq 1 ]]; then
    printf 'DRY integrate plan (test: %s):\n' "${TESTCMD:-UNVERIFIED}"
    for raw in "${RAW[@]}"; do slug="$(sanitize "${raw}")"; printf -- '- %s → HEAD via orch/%s/%s\n' "${slug}" "${SID}" "${slug}"; done
    return 0
  fi

  trap 'on_signal' EXIT INT TERM HUP
  local mergesha testline extra
  for (( i=0; i<n; i++ )); do
    raw="${RAW[$i]}"; slug="$(sanitize "${raw}")"; branch="orch/${SID}/${slug}"
    CUR_SLUG="${slug}"; CUR_IDX=${i}; PRE=""

    # empty-branch (e.g. a BLOCKED writer produced nothing) → real failure, stop.
    if [[ "$(git rev-list --count "HEAD..${branch}" 2>/dev/null || echo 0)" == "0" ]]; then
      STOPPED="${slug} — EMPTY — branch has no commits ahead of base (the task produced nothing, or was already integrated)"
      PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
    fi

    PRE="$(git rev-parse HEAD)"   # record pre-merge HEAD so on_signal can tell committed-vs-clean
    if ! git merge --no-ff -m "integrate ${slug}" "${branch}" >/dev/null 2>&1; then
      git merge --abort >/dev/null 2>&1 || true
      STOPPED="${slug} — CONFLICT — overlapping changes; merge aborted, base clean"
      PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
    fi
    mergesha="$(git rev-parse --short HEAD)"

    if [[ ${UNVERIFIED} -eq 1 ]]; then
      testline="UNVERIFIED"
    else
      TESTOUT="$(mktemp)"
      if eval "${TESTCMD}" >"${TESTOUT}" 2>&1; then
        testline="$(grep -v '^[[:space:]]*$' "${TESTOUT}" | tail -1 | cut -c1-80)"; [[ -n "${testline}" ]] || testline="passed"
        rm -f "${TESTOUT}"; TESTOUT=""
      else
        rm -f "${TESTOUT}"; TESTOUT=""
        STOPPED="${slug} — TEST_FAILED — base at ${mergesha}; '${TESTCMD}' failed (base NOT reset — inspect or revert)"
        PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
      fi
    fi

    # Test passed (or unverified): the merge is committed and verified. The outcome
    # is now CERTAIN, so clear the in-flight markers BEFORE cleanup/record — a signal
    # during cleanup then drops this slug from Integrated (it's already on the base —
    # lesser harm) instead of double-reporting it as both MERGED and ABORTED. CUR_IDX
    # stays at this slug so a between-slugs signal lists the correct remaining work.
    CUR_SLUG=""; PRE=""
    extra=""
    bash "${MAT}" --release "${SID}" "${slug}" >/dev/null 2>&1 || extra=" [claim not released: ${slug}]"
    if [[ ${NOREMOVE} -eq 0 ]]; then
      git worktree remove ".worktrees/${slug}" >/dev/null 2>&1 || extra="${extra} [worktree not removed: .worktrees/${slug}]"
      git worktree prune >/dev/null 2>&1 || true
    fi
    I_LINE+=("${slug} → MERGED (tests: ${testline})${extra}")
  done

  CUR_IDX=-1
  report_and_exit 0
}

main() {
  case "${1:-}" in
    -h|--help|"") echo "usage: orch-worktree-integrate.sh [--test \"<cmd>\"] [--allow-no-tests] [--no-remove] [--dry-run] <session_id> <slug> [slug ...]" ;;
    *) do_integrate "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
