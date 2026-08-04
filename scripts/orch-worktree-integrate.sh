#!/usr/bin/env bash
# LLM Orchestrator — worktree merge-back / integration engine.
#
# The symmetric JOIN half of the materialize engine. After parallel writers
# finish in their isolated worktrees, this reassembles their branches into the
# base test-gated. Two modes:
#
# SPECULATIVE (default) — the merge-queue discipline Zuul and GitHub merge
#   queues use: all N branches are merged sequentially onto a throwaway
#   integration branch in an ISOLATED worktree (the base is never touched),
#   and the suite runs ONCE against the combined tip.
#     - Green tip → the base fast-forwards to it atomically. N branches land
#       for one suite run instead of N.
#     - Red tip → bisect the merge points for the longest explicitly-tested
#       green prefix, fast-forward the base to THAT, eject the first failing
#       branch (kept on the integration branch for inspection), report the
#       rest Pending with a Re-run line. Only states that actually ran green
#       ever reach the base.
#   Safety is strictly stronger than serial: the base never holds an untested
#   or half-merged commit at any instant — its only mutation is a --ff-only
#   move to a suite-green SHA.
#
# SERIAL (--serial) — the original engine: merge each branch into the base one
#   at a time, run the suite after each, stop at the first conflict / test
#   failure / empty branch keeping prior successes. A test failure leaves the
#   failed merge committed on the base (never auto-reset) for inspection.
#
# Both modes: conflicts abort cleanly; empty branches (a BLOCKED writer that
# produced nothing) stop the queue rather than silently "passing"; merged
# slugs release their registry claim and (unless --no-remove) drop their
# worktree; the report always says exactly what landed, what didn't, and how
# to re-run the remainder.
#
# NOTE: sourcing this file sets -uo pipefail in the caller's shell (intentional).
#
# Usage:
#   orch-worktree-integrate.sh [--test "<cmd>"] [--allow-no-tests] [--no-remove] \
#                              [--serial] [--dry-run] <session_id> <slug> [slug ...]
#
# Bash 3.2 compatible.

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MAT="${_SCRIPT_DIR}/orch-worktree-materialize.sh"   # for --release

# tr flattens newlines BEFORE line-based sed sees them — an embedded newline
# used to survive sanitization and corrupt every branch/claim name built from
# the slug (same defect class as the materialize engine's sanitize; both fixed).
sanitize() { printf '%s' "$1" | tr '\n' '_' | sed 's/[^A-Za-z0-9._-]/_/g'; }

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
INT_BR=""        # speculative: integration branch (kept when it holds a failure)
INT_WT=""        # speculative: integration worktree path (always cleaned)
INT_LOCK=""      # exclusive integration lock path (empty when not held)
OWN_LANDED=""    # newline-separated shas of merge commits THIS run created

# --- integration lock ------------------------------------------------------
# Two integrates interleaving on one base is how a landed merge got hard-reset
# away: run B landed its merge, printed MERGED at exit 0, released its claim
# and removed its worktree — and run A's restore_base then `reset --hard`ed
# the base back past B's commit, because B's fresh merge is a DESCENDANT of
# A's recorded pre-sha. B reported success for a commit that is not on the
# base. The engines mutate one shared checkout; they get one exclusive lock.
#
# `mkdir` is the atomic primitive; the pid inside lets a later run distinguish
# a SIGKILLed integrate (reclaim, or every future integrate deadlocks) from a
# LIVE one (refuse — never steal). Released by report_and_exit, which every
# engine path funnels through, plus an EXIT trap for the pre-flight exits.
acquire_int_lock() {
  local gd pid
  gd="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  local lock="${gd}/orch-integrate.lockdir"
  if ! mkdir "${lock}" 2>/dev/null; then
    pid="$(cat "${lock}/pid" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" != *[!0-9]* ]] \
       && ! kill -0 "${pid}" 2>/dev/null && ! ps -p "${pid}" >/dev/null 2>&1; then
      # Recorded holder is provably dead (ps sees any uid, so EPERM ≠ death).
      rm -rf "${lock}" 2>/dev/null
      if ! mkdir "${lock}" 2>/dev/null; then
        echo "orch-integrate: another integration grabbed the lock while a dead one was being reclaimed — refusing to run two integrations against one base (lock: ${lock})" >&2
        return 1
      fi
      echo "orch-integrate: reclaimed integration lock from dead pid ${pid}" >&2
    else
      echo "orch-integrate: another integration is in progress (holder pid ${pid:-unknown}, lock ${lock}) — two integrates interleaving on one base is how landed merges get reset away. Re-run when it finishes; if the holder is truly gone, remove the lock by hand." >&2
      return 1
    fi
  fi
  printf '%s\n' "$$" > "${lock}/pid" 2>/dev/null || true
  INT_LOCK="${lock}"
}

release_int_lock() {
  [[ -n "${INT_LOCK}" ]] || return 0
  rm -f "${INT_LOCK}/pid" 2>/dev/null
  rmdir "${INT_LOCK}" 2>/dev/null
  INT_LOCK=""
}

report_and_exit() {
  local code="$1" s
  trap - EXIT INT TERM HUP    # clear first so no path double-reports
  release_int_lock
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

# --- serial mode (original engine) -----------------------------------------

# restore_base <pre_sha> — undo a staged merge on the base and PROVE it worked.
# Prints nothing on success; prints a diagnostic and returns 1 if the base is
# still mid-merge or has moved.
#
# `git merge --abort || git reset --merge || true` was not enough, and `|| true`
# hid it. When the suite rewrites a file THE MERGE TOUCHED — a formatter, a
# codegen step, a snapshot updater, all routine — both refuse:
#
#   error: Entry 'f.txt' not uptodate. Cannot merge.
#   fatal: Could not reset index file to revision 'HEAD'.     (rc=128, both)
#
# and MERGE_HEAD survives, so the run reported "the merge was discarded and the
# base is unchanged" with the base sitting mid-merge. The next run then read
# that state and advised committing the red merge.
#
# The escalation is `reset --hard <pre>`, which is safe HERE specifically: the
# pre-flight rejects a dirty base, so the only content that can be lost is the
# staged merge and whatever the suite just wrote — both disposable by
# definition. A caller that cannot restore must say so rather than claim clean.
restore_base() {
  local pre="$1"
  # A hard reset needs a target we have PROVEN exists. An empty or bogus `pre`
  # made `git reset --hard ""` fail into `|| true`, and the second check was
  # skipped because it is guarded on `-n "${pre}"` — so the function returned 0
  # and the caller announced "the base is unchanged" having verified nothing.
  if [[ -z "${pre}" ]] || ! git rev-parse -q --verify "${pre}^{commit}" >/dev/null 2>&1; then
    git merge --abort >/dev/null 2>&1 || git reset -q --merge >/dev/null 2>&1 || true
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      printf 'the base is STILL MID-MERGE at %s and no valid pre-merge sha was recorded — resolve by hand (git merge --abort) before re-running' \
             "$(git rev-parse --short HEAD 2>/dev/null)"
      return 1
    fi
    return 0
  fi
  git merge --abort >/dev/null 2>&1 || git reset -q --merge >/dev/null 2>&1 || true
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || \
     [[ "$(git rev-parse HEAD 2>/dev/null)" != "${pre}" ]]; then
    # Only ever rewind to `pre` when every commit being discarded is one THIS
    # RUN committed. "HEAD is a descendant of pre" is NOT that proof: a
    # parallel integrate's freshly landed merge commit is a descendant too,
    # and hard-resetting past it destroys a merge whose run already reported
    # MERGED at exit 0 — the corruption the integration lock exists to
    # prevent, closed here independently so restore_base is safe even if some
    # future path reaches it unlocked. OWN_LANDED holds the shas this run's
    # own `git commit`s created; anything else in pre..HEAD is foreign.
    if [[ "$(git rev-parse HEAD 2>/dev/null)" == "${pre}" ]]; then
      git reset -q --hard "${pre}" >/dev/null 2>&1 || true
    else
      local _extra _sha _foreign=""
      _extra="$(git rev-list "${pre}..HEAD" 2>/dev/null)"
      [[ -n "${_extra}" ]] || _foreign=1   # empty = not even a descendant (base rewound/unrelated)
      for _sha in ${_extra}; do
        case "${OWN_LANDED}" in *"${_sha}"*) ;; *) _foreign=1 ;; esac
      done
      if [[ -z "${_foreign}" ]]; then
        git reset -q --hard "${pre}" >/dev/null 2>&1 || true
      else
        printf 'the base moved to %s and the commits past the pre-merge sha %s are NOT this run'\''s own merges — a parallel run may have landed them; refusing to reset, resolve by hand' \
               "$(git rev-parse --short HEAD 2>/dev/null)" "$(git rev-parse --short "${pre}" 2>/dev/null)"
        return 1
      fi
    fi
  fi
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    printf 'the base is STILL MID-MERGE at %s — abort and hard reset both failed; resolve by hand (git merge --abort; git reset --hard %s) before re-running' \
           "$(git rev-parse --short HEAD 2>/dev/null)" "${pre}"
    return 1
  fi
  if [[ -n "${pre}" && "$(git rev-parse HEAD 2>/dev/null)" != "${pre}" ]]; then
    printf 'the base moved to %s and could not be restored to %s — resolve by hand before re-running' \
           "$(git rev-parse --short HEAD 2>/dev/null)" "${pre}"
    return 1
  fi
  return 0
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
      STOPPED="${CUR_SLUG} — ABORTED (signal) — base moved to $(git rev-parse --short HEAD 2>/dev/null) before the interrupt; that commit passed its suite, later slugs did not run"
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

do_serial() {
  trap 'on_signal' EXIT INT TERM HUP
  local raw slug branch i n="${#RAW[@]}" mergesha testline extra
  for (( i=0; i<n; i++ )); do
    raw="${RAW[$i]}"; slug="$(sanitize "${raw}")"; branch="orch/${SID}/${slug}"
    CUR_SLUG="${slug}"; CUR_IDX=${i}; PRE=""

    # empty-branch (e.g. a BLOCKED writer produced nothing) → real failure, stop.
    if [[ "$(git rev-list --count "HEAD..${branch}" 2>/dev/null || echo 0)" == "0" ]]; then
      STOPPED="${slug} — EMPTY — branch has no commits ahead of base (the task produced nothing, or was already integrated)"
      PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
    fi

    PRE="$(git rev-parse HEAD)"   # record pre-merge HEAD so on_signal can tell committed-vs-clean
    # --no-commit: stage the merge, run the suite against it, and only then let
    # it become part of the branch. Committing first and testing afterwards left
    # a RED merge on the base every time a branch broke the suite — the exact
    # thing the "base only ever moves to a suite-green SHA" invariant forbids.
    if ! git merge --no-ff --no-commit "${branch}" >/dev/null 2>&1; then
      if restore_err="$(restore_base "${PRE}")"; then
        STOPPED="${slug} — CONFLICT — overlapping changes; merge aborted, base clean"
      else
        STOPPED="${slug} — CONFLICT_DIRTY — overlapping changes, and ${restore_err}"
      fi
      PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
    fi

    if [[ ${UNVERIFIED} -eq 1 ]]; then
      testline="UNVERIFIED"
      git commit -q --no-edit -m "integrate ${slug}" >/dev/null 2>&1 || true
      mergesha="$(git rev-parse --short HEAD)"
      OWN_LANDED="${OWN_LANDED}$(git rev-parse HEAD 2>/dev/null)
"
    else
      TESTOUT="$(mktemp)"
      if eval "${TESTCMD}" >"${TESTOUT}" 2>&1; then
        testline="$(grep -v '^[[:space:]]*$' "${TESTOUT}" | tail -1 | cut -c1-80)"; [[ -n "${testline}" ]] || testline="passed"
        rm -f "${TESTOUT}"; TESTOUT=""
        # Green: only now does the merge join the branch.
        if ! git commit -q --no-edit -m "integrate ${slug}" >/dev/null 2>&1; then
          if restore_err="$(restore_base "${PRE}")"; then
            STOPPED="${slug} — COMMIT_FAILED — the suite passed but the merge commit could not be created; base clean"
          else
            STOPPED="${slug} — COMMIT_FAILED_DIRTY — the merge commit could not be created, and ${restore_err}"
          fi
          PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
        fi
        mergesha="$(git rev-parse --short HEAD)"
        OWN_LANDED="${OWN_LANDED}$(git rev-parse HEAD 2>/dev/null)
"
      else
        rm -f "${TESTOUT}"; TESTOUT=""
        # Red: discard the staged merge — and VERIFY the discard, because the
        # suite that just failed may also have rewritten a merged file, which
        # makes both abort forms refuse. Only claim "base is unchanged" when
        # the base is provably unchanged.
        if restore_err="$(restore_base "${PRE}")"; then
          STOPPED="${slug} — TEST_FAILED — '${TESTCMD}' failed against the merged tree; the merge was discarded and the base is unchanged at $(git rev-parse --short HEAD)"
        else
          STOPPED="${slug} — TEST_FAILED_DIRTY — '${TESTCMD}' failed against the merged tree AND ${restore_err}"
        fi
        PENDING=("${RAW[@]:$((i+1))}"); RERUN=("${RAW[@]:$i}"); report_and_exit 1
      fi
    fi

    # Test passed (or unverified): the merge is committed and verified. The outcome
    # is now CERTAIN, so clear the in-flight markers BEFORE cleanup/record — a signal
    # during cleanup then drops this slug from Integrated (it's already on the base —
    # lesser harm) instead of double-reporting it as both MERGED and ABORTED. CUR_IDX
    # stays at this slug so a between-slugs signal lists the correct remaining work.
    CUR_SLUG=""; PRE=""
    release_and_remove "${slug}"
    I_LINE+=("${slug} → MERGED (tests: ${testline})${extra_note}")
  done

  CUR_IDX=-1
  report_and_exit 0
}

# --- shared cleanup helper -------------------------------------------------
extra_note=""
release_and_remove() { # <slug> — release registry claim + drop worktree; sets extra_note
  local slug="$1"
  extra_note=""
  bash "${MAT}" --release "${SID}" "${slug}" >/dev/null 2>&1 || extra_note=" [claim not released: ${slug}]"
  if [[ ${NOREMOVE} -eq 0 ]]; then
    git worktree remove ".worktrees/${slug}" >/dev/null 2>&1 || extra_note="${extra_note} [worktree not removed: .worktrees/${slug}]"
    git worktree prune >/dev/null 2>&1 || true
  fi
}

# --- speculative mode ------------------------------------------------------

spec_cleanup_int() { # remove the integration worktree; drop the branch unless $1=keep
  if [[ -n "${INT_WT}" ]]; then
    git worktree remove --force "${INT_WT}" >/dev/null 2>&1 || true
    git worktree prune >/dev/null 2>&1 || true
    INT_WT=""
  fi
  if [[ -n "${INT_BR}" && "${1:-}" != "keep" ]]; then
    git branch -D "${INT_BR}" >/dev/null 2>&1 || true
    INT_BR=""
  fi
}

SPEC_LANDED=0    # set the moment the base fast-forwards; the signal report depends on it
spec_on_signal() {
  [[ -n "${INT_WT}" ]] && git -C "${INT_WT}" merge --abort >/dev/null 2>&1 || true
  spec_cleanup_int
  if [[ ${SPEC_LANDED} -eq 1 ]]; then
    # The ff-only move already happened; only cleanup was interrupted.
    STOPPED="ABORTED (signal during cleanup) — the verified batch ALREADY LANDED (base at $(git rev-parse --short HEAD 2>/dev/null)); some claims/worktrees may need manual release"
    PENDING=(); RERUN=()
  else
    # The base is untouched until the single --ff-only move.
    STOPPED="ABORTED (signal) — speculative batch discarded, base untouched"
    PENDING=(); RERUN=("${RAW[@]}")
  fi
  report_and_exit 1
}

spec_test() { # run the suite inside the integration worktree; prints last line, rc = suite rc
  TESTOUT="$(mktemp)"
  if ( cd "${INT_WT}" && eval "${TESTCMD}" ) >"${TESTOUT}" 2>&1; then
    local line; line="$(grep -v '^[[:space:]]*$' "${TESTOUT}" | tail -1 | cut -c1-80)"; [[ -n "${line}" ]] || line="passed"
    rm -f "${TESTOUT}"; TESTOUT=""
    printf '%s' "${line}"; return 0
  fi
  rm -f "${TESTOUT}"; TESTOUT=""
  return 1
}

spec_land() { # <sha> — fast-forward the base to an explicitly-verified SHA
  git merge --ff-only "$1" >/dev/null 2>&1
}

do_speculative() {
  trap 'spec_on_signal' EXIT INT TERM HUP
  local n="${#RAW[@]}" i raw slug branch testline
  local SLUGS=() MSHA=()   # MSHA[i] = integration tip after slug i merged (1-based via i+1)
  local base_sha; base_sha="$(git rev-parse HEAD)"

  INT_BR="orch/${SID}/_integration.$$"
  INT_WT="$(git rev-parse --show-toplevel)/.worktrees/_integration.$$"
  mkdir -p "$(git rev-parse --show-toplevel)/.worktrees" 2>/dev/null || true
  if ! git worktree add -b "${INT_BR}" "${INT_WT}" HEAD >/dev/null 2>&1; then
    # Cannot build the speculation scratch space — fall back to serial.
    INT_BR=""; INT_WT=""
    trap - EXIT INT TERM HUP
    do_serial
    return
  fi

  # Phase 1: merge every branch onto the integration tip (no tests yet).
  local queue_stop_idx=-1 queue_stop_line=""
  for (( i=0; i<n; i++ )); do
    raw="${RAW[$i]}"; slug="$(sanitize "${raw}")"; branch="orch/${SID}/${slug}"
    SLUGS[$i]="${slug}"
    if [[ "$(git -C "${INT_WT}" rev-list --count "HEAD..${branch}" 2>/dev/null || echo 0)" == "0" ]]; then
      queue_stop_idx=${i}; queue_stop_line="${slug} — EMPTY — branch has no commits ahead of base (the task produced nothing, or was already integrated)"
      break
    fi
    if ! git -C "${INT_WT}" merge --no-ff -m "integrate ${slug}" "${branch}" >/dev/null 2>&1; then
      git -C "${INT_WT}" merge --abort >/dev/null 2>&1 || true
      queue_stop_idx=${i}; queue_stop_line="${slug} — CONFLICT — overlapping changes; merge aborted, base clean"
      break
    fi
    MSHA[$i]="$(git -C "${INT_WT}" rev-parse HEAD)"
  done

  local merged_count=${#MSHA[@]}   # branches that merged cleanly onto the tip

  # Phase 2: one suite run at the deepest clean tip; on red, bisect for the
  # longest explicitly-tested-green prefix. lo is always a TESTED-green index
  # (0 = base, assumed green per the regression baseline); hi a tested-red one.
  local land_idx=${merged_count}   # 1-based count of slugs to land
  local fail_line=""

# checkout_or_abort <ref> <what> — move HEAD, or stop speculating.
#
# `git checkout` fails whenever the working tree is dirty in a way the move
# would clobber, and a test suite that rewrites a tracked file (snapshots,
# lockfiles, format-on-test, any generated artifact) makes that the NORMAL
# case rather than an exotic one. Discarding the status here does not lose a
# little accuracy — it makes every subsequent measurement describe a tree the
# engine is no longer standing in, while the diagnostics keep naming the tree
# it meant to be in. The observed result was a confident "red at the BASE,
# not attributable to any branch" for a green base with one clearly guilty
# branch, followed by a serial fallback that put a red commit on the base.
#
# Speculation is an optimisation. When it cannot be performed honestly the
# right move is to stop speculating, not to guess.
checkout_or_abort() {
  local ref="$1" what="$2" err
  if err=$(git -C "${INT_WT}" checkout -q "${ref}" 2>&1); then
    return 0
  fi
  printf 'orch-integrate: could not check out %s (%s) inside the integration worktree: %s\n' \
    "${what}" "${ref}" "${err}" >&2
  printf 'orch-integrate: the suite likely modifies a tracked file, so every further measurement here would describe the wrong tree. Abandoning speculation and falling back to --serial, which tests on the real base checkout.\n' >&2
  return 1
}

  if [[ ${merged_count} -gt 0 && ${UNVERIFIED} -eq 0 ]]; then
    if testline="$(spec_test <"/dev/null")"; then
      : # tip green → land everything that merged
    else
      # Red tip. Before blaming a branch, check the BASE state inside this
      # same worktree: a fresh worktree misses untracked build state (deps,
      # generated files), and a suite red for environmental reasons must not
      # eject an innocent branch. Environmental/pre-existing red → serial
      # fallback, which tests on the real base checkout.
      if ! checkout_or_abort "${base_sha}" "the base state"; then
        trap - EXIT INT TERM HUP
        spec_cleanup_int
        do_serial
        return
      fi
      if ! spec_test >/dev/null </dev/null; then
        printf 'orch-integrate: suite is red at the BASE state inside the integration worktree — environmental (untracked deps?) or pre-existing failure, not attributable to any branch. Falling back to --serial (tests run on the base checkout).\n' >&2
        trap - EXIT INT TERM HUP
        spec_cleanup_int
        do_serial
        return
      fi
      if ! checkout_or_abort "${INT_BR}" "the integration tip"; then
        trap - EXIT INT TERM HUP
        spec_cleanup_int
        do_serial
        return
      fi
      # lo can only advance via an explicitly GREEN test at MSHA[lo-1], so the
      # salvage point needs no re-test; capture the green suite line as we go.
      local lo=0 hi=${merged_count} mid green_line="" green_out=""
      while (( hi - lo > 1 )); do
        mid=$(( (lo + hi) / 2 ))
        # A failed checkout mid-bisect would re-measure the previous tree and
        # attribute its result to `mid` — the bisect would converge on an
        # innocent branch. Stop instead.
        if ! checkout_or_abort "${MSHA[$((mid-1))]}" "bisect step ${mid}"; then
          trap - EXIT INT TERM HUP
          spec_cleanup_int
          do_serial
          return
        fi
        if green_out="$(spec_test </dev/null)"; then lo=${mid}; green_line="${green_out}"; else hi=${mid}; fi
      done
      land_idx=${lo}
      testline="${green_line:-passed}"
      local cul_slug="${SLUGS[$((hi-1))]}" cul_sha; cul_sha="$(git rev-parse --short "${MSHA[$((hi-1))]}")"
      if (( land_idx > 0 )); then
        fail_line="${cul_slug} — TEST_FAILED — ejected from the queue; '${TESTCMD}' fails at the first prefix containing it (failing state kept at ${cul_sha} on branch ${INT_BR}; base untouched by it)"
      else
        fail_line="${cul_slug} — TEST_FAILED — no green prefix found ('${TESTCMD}' red at the first merge); nothing landed, base untouched (failing state kept at ${cul_sha} on branch ${INT_BR})"
      fi
    fi
  elif [[ ${UNVERIFIED} -eq 1 ]]; then
    testline="UNVERIFIED"
  fi

  # Phase 3: land the verified prefix with a single fast-forward.
  if (( land_idx > 0 )); then
    if ! spec_land "${MSHA[$((land_idx-1))]}"; then
      spec_cleanup_int keep
      STOPPED="LAND_FAILED — fast-forward refused (the base moved since the batch started, or untracked files collide with merged content); verified result kept on branch ${INT_BR}, base untouched"
      PENDING=(); RERUN=("${RAW[@]}")
      report_and_exit 1
    fi
    SPEC_LANDED=1
    for (( i=0; i<land_idx; i++ )); do
      release_and_remove "${SLUGS[$i]}"
      I_LINE+=("${SLUGS[$i]} → MERGED (tests: ${testline}; speculative batch — 1 suite run for ${land_idx} branch(es))${extra_note}")
    done
  fi

  # Phase 4: report the stop line + pending set.
  if [[ -n "${fail_line}" ]]; then
    local cul_idx=${land_idx}   # 0-based index of the culprit
    STOPPED="${fail_line}"
    PENDING=("${RAW[@]:$((cul_idx+1))}"); RERUN=("${RAW[@]:${cul_idx}}")
    spec_cleanup_int keep       # keep the branch holding the failing state
    report_and_exit 1
  fi
  if (( queue_stop_idx >= 0 )); then
    STOPPED="${queue_stop_line}"
    PENDING=("${RAW[@]:$((queue_stop_idx+1))}"); RERUN=("${RAW[@]:${queue_stop_idx}}")
    spec_cleanup_int
    report_and_exit 1
  fi

  spec_cleanup_int
  report_and_exit 0
}

do_integrate() {
  OWN_LANDED=""   # reset for sourced re-runs; only THIS run's commits count
  local dry=0 allow_no_tests=0 serial=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) TESTCMD="$2"; shift 2 ;;
      --allow-no-tests) allow_no_tests=1; shift ;;
      --no-remove) NOREMOVE=1; shift ;;
      --serial) serial=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) break ;;
    esac
  done
  SID="${1:-}"; shift || true
  [[ -n "${SID}" ]] || { echo "orch-integrate: empty session id (try materialize --sid)" >&2; exit 2; }
  [[ "${SID}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "orch-integrate: invalid session id — got '${SID}'" >&2; exit 2; }
  [[ $# -gt 0 ]] || { echo "usage: orch-worktree-integrate.sh [--test \"<cmd>\"] [--allow-no-tests] [--no-remove] [--serial] [--dry-run] <session_id> <slug> [slug ...]" >&2; exit 2; }

  RAW=("$@"); local raw slug branch

  # pre-flight (no mutation)
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "orch-integrate: not inside a git repository" >&2; exit 2; }
  [[ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]] || { echo "orch-integrate: must be run from the repo root" >&2; exit 2; }

  # Exclusive from here on: even the dirty-base check below can be looking at
  # a CONCURRENT integrate's staged merge, and reporting that as "your base is
  # dirty" sends the operator chasing the wrong problem. The EXIT trap covers
  # the pre-flight exits; the engines' own traps hand release duty to
  # report_and_exit, which every engine path funnels through.
  acquire_int_lock || exit 1
  trap 'release_int_lock' EXIT
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
    printf 'DRY integrate plan (%s; test: %s):\n' "$([[ ${serial} -eq 1 ]] && echo serial || echo 'speculative — 1 suite run at the combined tip')" "${TESTCMD:-UNVERIFIED}"
    for raw in "${RAW[@]}"; do slug="$(sanitize "${raw}")"; printf -- '- %s → HEAD via orch/%s/%s\n' "${slug}" "${SID}" "${slug}"; done
    return 0
  fi

  if [[ ${serial} -eq 1 ]]; then
    do_serial
  else
    do_speculative
  fi
}

main() {
  case "${1:-}" in
    -h|--help|"") echo "usage: orch-worktree-integrate.sh [--test \"<cmd>\"] [--allow-no-tests] [--no-remove] [--serial] [--dry-run] <session_id> <slug> [slug ...]" ;;
    *) do_integrate "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
