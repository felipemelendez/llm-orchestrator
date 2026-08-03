#!/usr/bin/env bash
# Tests for scripts/orch-worktree-materialize.sh — the worktree materialize/
# rollback engine + active-owner registry. Hermetic: a throwaway git repo and
# ORCH_HOME under mktemp -d. Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/scripts/orch-worktree-materialize.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$SCRIPT" ]] || { printf '%sFAIL%s — not found: %s\n' "$RED" "$RESET" "$SCRIPT"; exit 1; }

# Hermetic sandbox: a real git repo + isolated ORCH_HOME.
TMP="$(mktemp -d)"
trap 'cd /; rm -rf "${TMP}"' EXIT
export ORCH_HOME="${TMP}/orch"
REPO="${TMP}/repo"
mkdir -p "${REPO}"
cd "${REPO}"
git init -q
git config user.email t@t.t; git config user.name t
echo seed > seed.txt; git add seed.txt; git commit -qm seed
printf '.worktrees/\n' > .gitignore; git add .gitignore; git commit -qm ignore

SID="sess-AAA"
run() { bash "$SCRIPT" "$@"; }   # returns the script's exit code
OWNERS="${ORCH_HOME}/sessions/$(cd "${REPO}" && bash -c '. '"${ROOT}"'/scripts/lib/orch-project.sh; orch_project_hash')/owners"

printf '%s== materialize: happy path ==%s\n' "$DIM" "$RESET"
OUT="$(run "$SID" a b 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || fail "happy exit 0" "rc=$rc"
[[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" == "2" ]] && ok "prints 2 worktree lines" || fail "2 lines" "got: $OUT"
[[ -d .worktrees/a && -d .worktrees/b ]] && ok "both worktree dirs exist" || fail "worktree dirs"
git show-ref --verify --quiet "refs/heads/orch/${SID}/a" && ok "branch orch/SID/a exists" || fail "branch a"
[[ -f .worktrees/a/.orch-worktree && -f .worktrees/a/.orch-worktree-lock ]] && ok "provenance + lock files written" || fail "provenance files"
[[ "$(cat .worktrees/a/.orch-worktree-lock)" == "$SID" ]] && ok "lock contains session id" || fail "lock content"
[[ -d "${OWNERS}/a" && -d "${OWNERS}/b" ]] && ok "registry claims exist for a,b" || fail "claims exist"
excl="$(git -C .worktrees/a rev-parse --git-path info/exclude)"
grep -qx '\.orch-\*' "$excl" && ok ".orch-* added to worktree exclude" || fail "exclude entry"

printf '\n%s== registry: second claim on a taken slug is refused ==%s\n' "$DIM" "$RESET"
run "$SID" a >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "re-materialize claimed slug 'a' → non-zero" || fail "second claim should fail"

printf '\n%s== --list shows owners ==%s\n' "$DIM" "$RESET"
run --list 2>/dev/null | cut -f1 | grep -qx a && ok "--list includes a" || fail "--list a"

printf '\n%s== --release: owner vs non-owner vs idempotent ==%s\n' "$DIM" "$RESET"
run --release other-sid a >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "release by non-owner → refused" || fail "non-owner release"
[[ -d "${OWNERS}/a" ]] && ok "claim a survived non-owner release" || fail "claim a still there"
run --release "$SID" a >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "release by owner → ok" || fail "owner release"
[[ ! -d "${OWNERS}/a" ]] && ok "claim a removed after owner release" || fail "claim a gone"
run --release "$SID" a >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "release of already-gone claim → idempotent 0" || fail "idempotent release"

printf '\n%s== --prune: age-gated reclamation ==%s\n' "$DIM" "$RESET"
# b is claimed and its worktree exists → kept on worktree-existence, not age.
# Force STALE_SECS=0 so the age gate cannot be the reason it survives.
ORCH_REGISTRY_STALE_SECS=0 bash "$SCRIPT" --prune >/dev/null 2>&1
[[ -d "${OWNERS}/b" ]] && ok "prune keeps live claim (worktree exists, even past TTL)" || fail "prune kept live"
# worktree gone: young claim is left alone at the default TTL...
rm -rf .worktrees/b
run --prune >/dev/null 2>&1
[[ -d "${OWNERS}/b" ]] && ok "prune leaves a recent dead claim (under TTL)" || fail "prune too eager"
# ...but is reclaimed once past the TTL (forced via STALE_SECS=0).
ORCH_REGISTRY_STALE_SECS=0 bash "$SCRIPT" --prune >/dev/null 2>&1
[[ ! -d "${OWNERS}/b" ]] && ok "prune drops dead claim (worktree gone, past TTL)" || fail "prune dead"
# a recent meta-less dir = live in-progress claim → skipped at default TTL.
mkdir -p "${OWNERS}/inflight"
run --prune >/dev/null 2>&1
[[ -d "${OWNERS}/inflight" ]] && ok "prune skips recent meta-less (in-progress) claim" || fail "prune ate in-progress"
# an OLD meta-less dir = abandoned orphan from a kill-in-window → reclaimed.
ORCH_REGISTRY_STALE_SECS=0 bash "$SCRIPT" --prune >/dev/null 2>&1
[[ ! -d "${OWNERS}/inflight" ]] && ok "prune reclaims old meta-less orphan (kill-in-window recovery)" || fail "orphan not reclaimed"

printf '\n%s== --dry-run mutates nothing ==%s\n' "$DIM" "$RESET"
before="$(ls .worktrees 2>/dev/null)"
run --dry-run "$SID" dryslug 2>/dev/null | grep -q '^DRY dryslug' && ok "--dry-run prints plan" || fail "dry-run output"
[[ ! -d .worktrees/dryslug && ! -d "${OWNERS}/dryslug" ]] && ok "--dry-run created no worktree or claim" || fail "dry-run mutated"

printf '\n%s== duplicate slug rejected, nothing created ==%s\n' "$DIM" "$RESET"
run "$SID" dup dup >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "duplicate slugs → non-zero" || fail "dup exit"
[[ ! -d .worktrees/dup && ! -d "${OWNERS}/dup" ]] && ok "duplicate run created nothing" || fail "dup leaked"

printf '\n%s== pre-flight: existing path rejected ==%s\n' "$DIM" "$RESET"
mkdir -p .worktrees/exists
run "$SID" exists >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "existing path → non-zero" || fail "path exists exit"
rm -rf .worktrees/exists

printf '\n%s== rollback: failed worktree add releases the claim (no leak) ==%s\n' "$DIM" "$RESET"
# A bad --base passes pre-flight but makes `git worktree add` fail; the claim is
# made then must be rolled back by the EXIT trap.
run --base does-not-exist-ref "$SID" rb >/dev/null 2>&1; [[ $? -ne 0 ]] && ok "bad base → non-zero" || fail "rollback exit"
[[ ! -d "${OWNERS}/rb" ]] && ok "rollback released the claim (no leaked owner)" || fail "claim leaked: ${OWNERS}/rb"
[[ ! -d .worktrees/rb ]] && ok "rollback left no worktree" || fail "worktree leaked"
# (real branch-rollback is asserted non-vacuously in the white-box test below,
#  where a valid base actually creates the branch before rollback removes it.)

printf '\n%s== writer mutex: mkdir .orch-active is exclusive (sequential + concurrent) ==%s\n' "$DIM" "$RESET"
run "$SID" mtx >/dev/null 2>&1
mkdir .worktrees/mtx/.orch-active 2>/dev/null && ok "first .orch-active claim succeeds" || fail "first mutex"
mkdir .worktrees/mtx/.orch-active 2>/dev/null && fail "second mutex should fail" || ok "second .orch-active claim refused (exclusive)"
rmdir .worktrees/mtx/.orch-active
# concurrent: two racing processes, exactly one wins the mutex.
MRES="${TMP}/mtxrace"; : > "$MRES"
for i in 1 2 3 4; do ( mkdir .worktrees/mtx/.orch-active 2>/dev/null && echo win >> "$MRES" ) & done
wait
mwins="$(grep -c '^win$' "$MRES")"
[[ "$mwins" == "1" ]] && ok "4 concurrent writers race → exactly 1 takes the mutex" || fail "mutex race" "got ${mwins}"

printf '\n%s== concurrent claim race: exactly one winner ==%s\n' "$DIM" "$RESET"
RES="${TMP}/race"; : > "$RES"
for i in 1 2 3; do ( run "$SID" racer >/dev/null 2>&1; echo $? >> "$RES" ) & done
wait
wins="$(grep -c '^0$' "$RES")"
[[ "$wins" == "1" ]] && ok "3 concurrent claims on one slug → exactly 1 winner" || fail "race winners" "got ${wins}"

printf '\n%s== signal: SIGTERM mid-batch leaves no orphaned claim ==%s\n' "$DIM" "$RESET"
# Start a large batch, SIGTERM it mid-flight, and assert the registry is never
# left inconsistent: every surviving sig* claim must have its worktree (whether
# the batch finished or the trap rolled it all back, counts must match — a
# broken trap would leave claims without worktrees).
bash "$SCRIPT" "$SID" sg0 sg1 sg2 sg3 sg4 sg5 sg6 sg7 sg8 sg9 sg10 sg11 >/dev/null 2>&1 &
sgpid=$!
# Readiness: wait until the FIRST claim appears so we KILL mid-batch (not after
# completion). With the kill landing while ~11 worktree-adds remain, the trap
# must roll back everything created → exactly 0 claims and 0 worktrees.
ready=0
for _ in $(seq 1 100); do ls -d "${OWNERS}"/sg* >/dev/null 2>&1 && { ready=1; break; }; sleep 0.05; done
kill -TERM "$sgpid" 2>/dev/null
wait "$sgpid" 2>/dev/null
# Model what production does — the Stop hook prunes every turn — so an in-window
# orphan (a claim made but not yet recorded for rollback when the signal landed,
# the documented mkdir→record window) is reclaimed by the age gate, not immediate
# rollback. After that, the registry must hold no ORPHANED claim: every surviving
# claim has its worktree (claims == worktrees). That's the real no-leak invariant
# and it is timing-stable (strict 0/0 isn't — the batch may finish before the kill,
# or the orphan may persist until prune). The deterministic proof that rollback_all
# fully tears down is the white-box test below.
ORCH_REGISTRY_STALE_SECS=0 bash "$SCRIPT" --prune >/dev/null 2>&1
nc=$(ls -d "${OWNERS}"/sg* 2>/dev/null | wc -l | tr -d ' ')
nw=$(ls -d .worktrees/sg* 2>/dev/null | wc -l | tr -d ' ')
[[ "$ready" == "1" ]] || fail "signal readiness" "no claim ever appeared"
[[ "$nc" == "$nw" ]] && ok "after SIGTERM + prune: no orphaned claim (claims ${nc} == worktrees ${nw})" || fail "signal rollback" "claims=${nc} worktrees=${nw}"

printf '\n%s== --sid reads the persisted session id ==%s\n' "$DIM" "$RESET"
mkdir -p "$(dirname "${OWNERS}")"; printf 'sess-FROM-FILE\n' > "$(dirname "${OWNERS}")/sid"
[[ "$(run --sid 2>/dev/null)" == "sess-FROM-FILE" ]] && ok "--sid prints the stored id" || fail "--sid"
rm -f "$(dirname "${OWNERS}")/sid"
[[ -z "$(run --sid 2>/dev/null)" ]] && ok "--sid prints nothing when no sid stored" || fail "--sid empty"

printf '\n%s== white-box: registry_claim cleans its dir on meta-write failure ==%s\n' "$DIM" "$RESET"
CL="$(cd "${REPO}" && ORCH_HOME="${ORCH_HOME}" SCRIPT="${SCRIPT}" bash -c '
  . "${SCRIPT}"; init_paths
  mv() { command false; }                 # force the meta mv -f to fail
  registry_claim wfail br /tmp/none SID && echo CLAIM_OK || true
  declare -f mv >/dev/null && unset -f mv
  [[ -d "${OWNERS}/wfail" ]] && echo LEFT || echo CLEANED
')"
[[ "$CL" == "CLEANED" ]] && ok "registry_claim removes its claim dir when the meta write fails" || fail "claim cleanup" "got: ${CL}"

printf '\n%s== white-box: rollback_all reverse-order, incl. meta-less claim ==%s\n' "$DIM" "$RESET"
# Source the script (BASH_SOURCE guard skips main), build a 2-worktree batch plus
# a simulated in-progress (meta-less) claim, then verify rollback_all removes all
# claims, worktrees, and branches.
WB="$(cd "${REPO}" && ORCH_HOME="${ORCH_HOME}" SID="${SID}" SCRIPT="${SCRIPT}" bash -c '
  . "${SCRIPT}"; init_paths
  do_materialize "${SID}" wa wb >/dev/null 2>&1 || { echo SETUP_FAIL; exit 0; }
  [[ -d .worktrees/wa && -d .worktrees/wb && -d "${OWNERS}/wa" && -d "${OWNERS}/wb" ]] || { echo SETUP2; exit 0; }
  mkdir "${OWNERS}/wc"                          # meta-less in-progress claim
  # rollback_all uses rm -rf directly (no ownership check) — there is no R_SID array.
  R_SLUG+=(wc); R_PATH+=("${PWD}/.worktrees/wc"); R_BRANCH+=("orch/${SID}/wc")
  rollback_all
  [[ ! -d .worktrees/wa && ! -d .worktrees/wb ]] || { echo WT_LEFT; exit 0; }
  [[ ! -d "${OWNERS}/wa" && ! -d "${OWNERS}/wb" && ! -d "${OWNERS}/wc" ]] || { echo CLAIM_LEFT; exit 0; }
  git show-ref --verify --quiet "refs/heads/orch/${SID}/wa" && { echo BRANCH_WA_LEFT; exit 0; }
  git show-ref --verify --quiet "refs/heads/orch/${SID}/wb" && { echo BRANCH_WB_LEFT; exit 0; }
  echo OK
')"
[[ "$WB" == "OK" ]] && ok "rollback_all clears worktrees+claims+branches (and a meta-less claim)" || fail "rollback_all" "got: ${WB}"

printf '\n%s== white-box: rollback_all refuses to destroy ANOTHER session'"'"'s worktree ==%s\n' "$DIM" "$RESET"
# The one place this engine can lose uncommitted work with no second command.
# Window: our claim is pruned while a slow `worktree add` still holds the path,
# another session re-claims the slug and populates the SAME path, and then our
# failure path force-removes it. Simulated directly: record a path in the
# rollback list, hand both ownership proofs (registry meta + the worktree's own
# .orch-worktree-lock stamp) to a different session, then roll back.
XS="$(cd "${REPO}" && ORCH_HOME="${ORCH_HOME}" SID="${SID}" SCRIPT="${SCRIPT}" bash -c '
  . "${SCRIPT}"; init_paths
  do_materialize other-session xown >/dev/null 2>&1 || { echo SETUP_FAIL; exit 0; }
  echo "precious uncommitted work" > .worktrees/xown/WORK.txt
  # Our run recorded the same path, believing it was ours.
  R_SID="${SID}"
  R_SLUG=(xown); R_PATH=("${PWD}/.worktrees/xown"); R_BRANCH=("orch/${SID}/xown")
  rollback_all 2>/dev/null
  [[ -d .worktrees/xown ]] || { echo WORKTREE_DESTROYED; exit 0; }
  [[ -f .worktrees/xown/WORK.txt ]] || { echo WORK_LOST; exit 0; }
  [[ -d "${OWNERS}/xown" ]] || { echo CLAIM_DESTROYED; exit 0; }
  echo OK
')"
[[ "$XS" == "OK" ]] && ok "rollback_all skips a path owned by another session (work preserved)" \
  || fail "cross-session rollback" "got: ${XS} — rollback destroyed another session's worktree"

printf '\n%s== duplicate-slug guard is live (not dead code) ==%s\n' "$DIM" "$RESET"
# `sanitize` printed with no trailing newline, so `... | sort | uniq -d` saw one
# concatenated line and the guard could never fire. The suite named for it
# passed anyway, because the claim mkdir rejected the second slug — a test
# green for a different reason than the one it names. Assert the GUARD.
DUPOUT="$(cd "${REPO}" && run "$SID" 'dup slug' 'dup_slug' 2>&1)"; duprc=$?
if [[ $duprc -ne 0 ]] && printf '%s' "$DUPOUT" | grep -q 'duplicate slug'; then
  ok "two raw slugs that sanitize alike are rejected BY the duplicate guard"
else
  fail "duplicate-slug guard" "rc=$duprc out=$(printf '%s' "$DUPOUT" | head -1)"
fi
[[ ! -d "${REPO}/.worktrees/dup_slug" ]] && ok "duplicate-slug rejection created nothing" || fail "dup leaked"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-worktree-materialize%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-worktree-materialize — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
