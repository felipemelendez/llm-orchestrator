#!/usr/bin/env bash
# Tests for scripts/hooks/guard-destructive-git.sh — blocks working-tree-
# destroying git (stash save, reset --hard, clean -f, checkout --, restore,
# branch -D, worktree remove --force) and allows the safe/read-only forms.
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${ROOT}/scripts/hooks/guard-destructive-git.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$GUARD" ]] || { printf '%sFAIL%s — not found: %s\n' "$RED" "$RESET" "$GUARD"; exit 1; }

# Two real contexts: a MAIN checkout (.git is a directory) and one of OUR linked
# worktrees (.git is a file + an .orch-worktree marker). The guard keys its
# context-scoped relaxation on $PWD, so we run it FROM each directory.
TMP="$(mktemp -d)"; trap 'cd /; rm -rf "$TMP"' EXIT
MAINDIR="$TMP/main"; mkdir -p "$MAINDIR"
( cd "$MAINDIR" && git init -q && git config user.email t@t.t && git config user.name t \
    && echo s > s.txt && git add s.txt && git commit -qm s \
    && git worktree add -q "$TMP/wt" -b wtb >/dev/null 2>&1 && touch "$TMP/wt/.orch-worktree" )
WT="$TMP/wt"

# rc of the guard for a command string, run from the MAIN checkout (RELAX off).
rc_for()    { printf '{"tool_input":{"command":"%s"}}' "$1" | ( cd "$MAINDIR" && bash "$GUARD" ) >/dev/null 2>&1; echo $?; }
# ...and run from inside one of our marked worktrees (RELAX eligible).
rc_for_wt() { printf '{"tool_input":{"command":"%s"}}' "$1" | ( cd "$WT" && bash "$GUARD" ) >/dev/null 2>&1; echo $?; }

blocks()    { local cmd="$1"; [[ "$(rc_for "$cmd")" == "2" ]] && ok "BLOCK: $cmd" || fail "BLOCK: $cmd" "expected exit 2"; }
allows()    { local cmd="$1"; [[ "$(rc_for "$cmd")" == "0" ]] && ok "ALLOW: $cmd" || fail "ALLOW: $cmd" "expected exit 0"; }
blocks_wt() { local cmd="$1"; [[ "$(rc_for_wt "$cmd")" == "2" ]] && ok "WT-BLOCK: $cmd" || fail "WT-BLOCK: $cmd" "expected exit 2"; }
allows_wt() { local cmd="$1"; [[ "$(rc_for_wt "$cmd")" == "0" ]] && ok "WT-ALLOW: $cmd" || fail "WT-ALLOW: $cmd" "expected exit 0"; }

printf '%s== blocks working-tree-destroying git ==%s\n' "$DIM" "$RESET"
blocks "git stash"
blocks "git stash push -m wip"
blocks "git stash push --include-untracked -m x"
blocks "git stash -u"
blocks "git stash save wip"
blocks "git stash drop"
blocks "git stash clear"
blocks "git stash pop"
blocks "git stash apply stash@{0}"
blocks "git stash branch feat"
blocks "git reset --hard"
blocks "git reset --hard HEAD"
blocks "echo done && git reset --hard"
blocks "git clean -fd"
blocks "git clean -f"
blocks "git clean -fdx"
blocks "git checkout -- src/file.ts"
blocks "git checkout ."
blocks "git restore src/file.ts"
blocks "git restore --worktree src/file.ts"
blocks "git branch -D feat/x"
blocks "git worktree remove --force .worktrees/x"
blocks "git stash && bash tests/smoke.sh && git stash pop"

printf '\n%s== blocks branch-switch (overwrites the working tree) ==%s\n' "$DIM" "$RESET"
blocks "git checkout main"
blocks "git checkout feat/other"
blocks "git checkout HEAD~1"
blocks "git switch main"
blocks "git switch -"

printf '\n%s== blocks global-option bypasses (git -C / --git-dir) ==%s\n' "$DIM" "$RESET"
blocks "git -C /repo stash"
blocks "git -C /repo reset --hard"
blocks "git -C /repo clean -fd"
blocks "git -C /repo checkout main"
blocks "git -c core.pager=cat reset --hard"
blocks "git --git-dir=/repo/.git reset --hard"
blocks "git -C /repo -c x=y reset --hard"

printf '\n%s== blocks newly-covered destructive forms ==%s\n' "$DIM" "$RESET"
blocks "git reset --keep HEAD~1"
blocks "git reset --merge HEAD"
blocks "git rm -f src/file.ts"
blocks "git rm -rf src/"
blocks "git restore -W --staged src/file.ts"
blocks "git restore -W src/file.ts"
blocks "rm -rf .git"
blocks "rm -rf .worktrees/feat-x"
blocks "rm -fr .git/"

printf '\n%s== allows safe / read-only git ==%s\n' "$DIM" "$RESET"
allows "git stash list"
allows "git stash show"
allows "git restore --staged src/file.ts"
allows "git restore --staged ."
allows "git reset --soft HEAD~1"
allows "git reset HEAD~1"
allows "git status --short"
allows "git diff --stat"
allows "git add -A"
allows "git commit -m message"
allows "git checkout -b feat/x"
allows "git switch -c feat/x"
allows "git -C /repo status"
allows "git -C /repo log --oneline"
allows "git log --oneline"
allows "git commit-graph write"

printf '\n%s== context-scope: worktree-LOCAL destructive git allowed inside our worktree ==%s\n' "$DIM" "$RESET"
allows_wt "git stash"
allows_wt "git stash pop"
allows_wt "git stash apply"
allows_wt "git reset --hard"
allows_wt "git reset --hard HEAD"
allows_wt "git clean -fd"
allows_wt "git checkout main"
allows_wt "git switch other"
allows_wt "git restore src/file.ts"
allows_wt "git rm -f src/file.ts"
allows_wt "git stash && npm test && git stash pop"
allows_wt "git stash && pytest -q && git stash pop"

printf '\n%s== context-scope: reach-beyond / shared-state still blocked in a worktree ==%s\n' "$DIM" "$RESET"
blocks_wt "git branch -D feat/x"
blocks_wt "git worktree remove --force ."
blocks_wt "rm -rf .git"
blocks_wt "rm -rf .worktrees/x"
blocks_wt "git stash drop"
blocks_wt "git stash clear"
blocks_wt "git stash branch feat"
blocks_wt "git stash pop stash@{1}"
blocks_wt "git stash apply stash@{0}"

printf '\n%s== context-scope: directory-retarget refused even inside a worktree ==%s\n' "$DIM" "$RESET"
blocks_wt "git -C /main stash"
blocks_wt "git -C /main reset --hard"
blocks_wt "cd /main && git reset --hard"
blocks_wt "env -C /main git reset --hard"
blocks_wt "env --chdir=/main git reset --hard"
blocks_wt "GIT_DIR=/main/.git git stash"
# word-boundary: a command merely containing 'env' (printenv) still relaxes
allows_wt "printenv PATH && git stash"
blocks_wt "git --git-dir=/main/.git reset --hard"
blocks_wt "bash -c 'cd /main && git reset --hard'"
blocks_wt "python3 -c 'import os;os.chdir(\"/m\");os.system(\"git reset --hard\")'"
# an interpreter anywhere in the chain refuses relaxation (can't prove it won't chdir) — safe over-block
blocks_wt "git stash && bash tests/run.sh && git stash pop"

printf '\n%s== context-scope: precedence + unmarked worktree ==%s\n' "$DIM" "$RESET"
blocks_wt "git stash pop && git branch -D feat"
# strip the marker → no longer one of ours → relaxation must NOT apply
rm -f "$WT/.orch-worktree"
[[ "$(rc_for_wt 'git stash')" == "2" ]] && ok "unmarked linked worktree → git stash BLOCKED" || fail "unmarked worktree should block"
touch "$WT/.orch-worktree"
# the main checkout still blocks the same worktree-local commands
blocks "git stash"
blocks "git reset --hard"

printf '\n%s== ORCH_ALLOW_DESTRUCTIVE_GIT=1 overrides (lets it through) ==%s\n' "$DIM" "$RESET"
OVR=$(printf '{"tool_input":{"command":"git reset --hard"}}' | ORCH_ALLOW_DESTRUCTIVE_GIT=1 bash "$GUARD" >/dev/null 2>&1; echo $?)
[[ "$OVR" == "0" ]] && ok "ORCH_ALLOW_DESTRUCTIVE_GIT=1 → git reset --hard allowed" || fail "override" "expected exit 0, got $OVR"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-destructive-git-guard%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-destructive-git-guard — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
