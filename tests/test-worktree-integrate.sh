#!/usr/bin/env bash
# Tests for scripts/orch-worktree-integrate.sh — the merge-back / integration
# engine. Uses the materialize engine to set up real isolated worktrees, then
# integrates them. Hermetic: throwaway git repo + ORCH_HOME under mktemp -d.
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAT="${ROOT}/scripts/orch-worktree-materialize.sh"
INTEG="${ROOT}/scripts/orch-worktree-integrate.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

for f in "$MAT" "$INTEG"; do [[ -f "$f" ]] || { printf '%sFAIL%s — not found: %s\n' "$RED" "$RESET" "$f"; exit 1; }; done

TMP="$(mktemp -d)"
trap 'cd /; rm -rf "${TMP}"' EXIT
export ORCH_HOME="${TMP}/orch"
REPO="${TMP}/repo"; mkdir -p "${REPO}"; cd "${REPO}"
git init -q; git config user.email t@t.t; git config user.name t
echo seed > seed.txt; git add seed.txt; git commit -qm seed
printf '.worktrees/\n' > .gitignore; git add .gitignore; git commit -qm ignore
SID="sess-INT"
OWNERS="${ORCH_HOME}/sessions/$(. "${ROOT}/scripts/lib/orch-project.sh"; orch_project_hash)/owners"

mat()  { bash "$MAT" "$SID" "$@" >/dev/null 2>&1; }
# commit a new file on slug's worktree branch
mk()   { echo "$3" > ".worktrees/$1/$2"; git -C ".worktrees/$1" add "$2"; git -C ".worktrees/$1" commit -qm "work $1" >/dev/null 2>&1; }
# commit a change to the shared seed.txt on slug's worktree (to force conflicts)
mkseed(){ echo "$2" > ".worktrees/$1/seed.txt"; git -C ".worktrees/$1" add seed.txt; git -C ".worktrees/$1" commit -qm "seed $1" >/dev/null 2>&1; }

printf '%s== pre-flight rejections ==%s\n' "$DIM" "$RESET"
echo dirt >> seed.txt
bash "$INTEG" --test true "$SID" nope >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "dirty base → exit 2" || fail "dirty base"
git checkout -q -- seed.txt
mat mb1; bash "$INTEG" --test true "$SID" mb1 ghost >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "missing branch → exit 2" || fail "missing branch"
mkdir -p sub; ( cd sub && bash "$INTEG" --test true "$SID" mb1 >/dev/null 2>&1 ); [[ $? -eq 2 ]] && ok "not at repo root → exit 2" || fail "not at root"

printf '\n%s== --dry-run mutates nothing ==%s\n' "$DIM" "$RESET"
mat dr; mk dr dr.txt x
before="$(git rev-parse HEAD)"
DRYOUT="$(bash "$INTEG" --dry-run --test true "$SID" dr 2>/dev/null)"
printf '%s' "$DRYOUT" | grep -q '^DRY integrate plan' && ok "--dry-run prints plan" || fail "dry-run output" "got: $DRYOUT"
[[ "$(git rev-parse HEAD)" == "$before" && -d .worktrees/dr ]] && ok "--dry-run merged nothing" || fail "dry-run mutated"

printf '\n%s== happy path: two disjoint branches integrate ==%s\n' "$DIM" "$RESET"
mat a b; mk a fa.txt alpha; mk b fb.txt beta
OUT="$(bash "$INTEG" --test true "$SID" a b 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || fail "happy exit 0" "rc=$rc out=$OUT"
[[ -f fa.txt && -f fb.txt ]] && ok "both changes landed on base" || fail "changes missing"
[[ ! -d .worktrees/a && ! -d .worktrees/b ]] && ok "worktrees removed after merge" || fail "worktrees not removed"
[[ ! -d "${OWNERS}/a" && ! -d "${OWNERS}/b" ]] && ok "claims released after merge" || fail "claims leaked"
printf '%s' "$OUT" | grep -q 'MERGED' && ok "report shows MERGED" || fail "report MERGED"

printf '\n%s== empty branch (BLOCKED writer produced nothing) → EMPTY ==%s\n' "$DIM" "$RESET"
mat empt   # worktree created, no commit → branch == base
OUT="$(bash "$INTEG" --test true "$SID" empt 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "empty branch → non-zero" || fail "empty exit"
printf '%s' "$OUT" | grep -q 'EMPTY' && ok "report flags EMPTY (no silent false-green)" || fail "EMPTY flag" "out=$OUT"

printf '\n%s== conflict: second branch conflicts, aborts clean ==%s\n' "$DIM" "$RESET"
mat c d; mkseed c C-version; mkseed d D-version
base_before="$(git rev-parse HEAD)"
OUT="$(bash "$INTEG" --test true "$SID" c d 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "conflict → non-zero" || fail "conflict exit"
printf '%s' "$OUT" | grep -q 'CONFLICT' && ok "report flags CONFLICT" || fail "CONFLICT flag" "out=$OUT"
git diff --quiet && git diff --cached --quiet && ok "base clean after abort (no conflict markers staged)" || fail "base dirty after abort"
grep -q '<<<<<<<' seed.txt 2>/dev/null && fail "conflict markers left in seed.txt" || ok "no conflict markers in tree"
grep -q 'C-version' seed.txt && [[ "$(git rev-parse HEAD)" != "$base_before" ]] && ok "prior success (c) stayed on base after d's conflict" || fail "prior success lost"
[[ ! -d "${OWNERS}/c" ]] && ok "merged slug c claim released" || fail "c claim leaked"
[[ -d "${OWNERS}/d" ]] && ok "unmerged slug d claim retained" || fail "d claim should remain"
printf '%s' "$OUT" | grep -q '^Re-run:' && ok "report emits a Re-run line" || fail "no Re-run line" "out=$OUT"
printf '%s' "$OUT" | grep -qE '^Re-run:.*[[:space:]]d([[:space:]]|$)' && ok "Re-run line contains the stopped slug d" || fail "Re-run missing slug d" "out=$OUT"

printf '\n%s== test failure: merge stays, base NOT hard-reset ==%s\n' "$DIM" "$RESET"
mat e; mk e fe.txt eee
OUT="$(bash "$INTEG" --test false "$SID" e 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "test failure → non-zero" || fail "testfail exit"
printf '%s' "$OUT" | grep -q 'TEST_FAILED' && ok "report flags TEST_FAILED" || fail "TEST_FAILED flag" "out=$OUT"
[[ -f fe.txt ]] && ok "merge commit stays on base (no auto reset --hard)" || fail "merge was undone"

printf '\n%s== no test command: refuse unless --allow-no-tests ==%s\n' "$DIM" "$RESET"
mat g; mk g fg.txt ggg
bash "$INTEG" "$SID" g >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "no test cmd, no flag → exit 2" || fail "no-test exit2"
OUT="$(bash "$INTEG" --allow-no-tests "$SID" g 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "--allow-no-tests → exit 0" || fail "allow-no-tests exit" "rc=$rc"
printf '%s' "$OUT" | grep -q 'UNVERIFIED' && ok "report warns UNVERIFIED" || fail "UNVERIFIED warn" "out=$OUT"
[[ -f fg.txt ]] && ok "--allow-no-tests: change actually landed on base" || fail "allow-no-tests change missing"

printf '\n%s== white-box: on_signal reports a committed-but-untested merge correctly ==%s\n' "$DIM" "$RESET"
# Source the engine (BASH_SOURCE guard skips main), simulate the window where a
# signal arrives after a merge committed but before its test finished: PRE is the
# pre-merge HEAD, a new commit exists (HEAD moved), no MERGE_HEAD. on_signal must
# report 'untested commit', NOT 'base clean'. Deterministic (no timing).
WB="$(cd "${REPO}" && SCRIPT="${INTEG}" bash -c '
  . "${SCRIPT}"
  CUR_SLUG=xx; CUR_IDX=0; RAW=(xx)
  PRE="$(git rev-parse HEAD)"
  git commit --allow-empty -qm "simulated committed merge"   # HEAD moves past PRE, no MERGE_HEAD
  on_signal
')"
printf '%s' "$WB" | grep -q 'untested commit' && ok "on_signal flags an untested committed merge (not 'base clean')" || fail "signal untested-commit" "got: ${WB}"
git reset -q --hard HEAD~1 2>/dev/null || true   # undo the simulated commit (test scaffolding only)

printf '\n%s== --no-remove keeps the worktree ==%s\n' "$DIM" "$RESET"
mat h; mk h fh.txt hhh
bash "$INTEG" --no-remove --test true "$SID" h >/dev/null 2>&1
[[ -d .worktrees/h ]] && ok "--no-remove kept the worktree" || fail "--no-remove removed it"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-worktree-integrate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-worktree-integrate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
