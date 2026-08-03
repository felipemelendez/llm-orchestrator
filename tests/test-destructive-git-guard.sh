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
# The payload is built with a real JSON encoder: hand-interpolating a command
# that contains quotes produced INVALID JSON, which the guard correctly treats
# as undecodable and falls back to a raw scan — so quote-related cases were
# testing the fallback, not the rule. Written to a file rather than piped, so
# `pipefail` cannot turn a hook's early exit (SIGPIPE on the writer) into a
# fake non-zero result.
_PAYLOAD="$(mktemp)"
trap 'rm -f "$_PAYLOAD"' EXIT
_mkpayload() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$1" > "$_PAYLOAD"
  else
    printf '{"tool_input":{"command":"%s"}}' "$1" > "$_PAYLOAD"
  fi
}
rc_for()    { _mkpayload "$1"; ( cd "$MAINDIR" && bash "$GUARD" < "$_PAYLOAD" ) >/dev/null 2>&1; echo $?; }
# ...and run from inside one of our marked worktrees (RELAX eligible).
rc_for_wt() { _mkpayload "$1"; ( cd "$WT" && bash "$GUARD" < "$_PAYLOAD" ) >/dev/null 2>&1; echo $?; }

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

printf '\n%s== spellings git accepts that a regex guard missed ==%s\n' "$DIM" "$RESET"
# Every case here was measured ALLOWED by the spelling-matching guard, and
# every one was measured to really run against git 2.54. Three mechanisms:
# long-option abbreviation (git takes any unambiguous prefix), VALUELESS global
# options (the old absorber stripped only the five value-taking ones), and a
# line continuation (the newline rewrite tracked quotes but not a backslash).
blocks "git reset --h HEAD~1"
blocks "git reset --ha HEAD~1"
blocks "git reset --har HEAD~1"
blocks "git reset --k HEAD~1"
blocks "git reset --mer HEAD~1"
blocks "git clean --for -d"
blocks "git clean --forc"
blocks "git restore --workt src/file.ts"
blocks "git worktree remove --fo .worktrees/x"
blocks "git branch --delete --forc feat/x"
blocks "git --no-pager checkout -f main"
blocks "git -P checkout -f main"
blocks "git --no-pager switch main"
blocks "git --no-pager stash"
blocks "git --paginate reset --hard"
blocks "git --no-optional-locks checkout main"
blocks "$(printf 'git reset \\\n--hard HEAD~1')"
blocks "$(printf 'git \\\n--no-pager \\\ncheckout -f main')"

printf '\n%s== false positives: a guard that blocks these gets switched off ==%s\n' "$DIM" "$RESET"
# `--help` touches nothing, and branch CREATION is the documented exception —
# blocking them while allowing `--h` on a destructive reset is the profile of a
# guard users disable. Note git resolves `--h` to `--hard`, NOT `--help`
# (verified: it printed "HEAD is now at" and moved the tree), so the help
# exemption must not cover a prefix that could name a destructive option.
allows "git checkout --help"
allows "git switch --help"
allows "git reset --help"
allows "git clean --help"
allows "git checkout -q -b newbranch"
allows "git switch --create newbranch"
# ...but --force revokes the creation exemption. Measured against git 2.54:
# `git checkout -b safe` carried an uncommitted edit over intact, while
# `git checkout -f -b forced` silently discarded it. Plain creation is safe
# only because git refuses to clobber; -f removes exactly that protection, so
# it must not ride along inside the exemption.
blocks "git checkout -f -b newbranch main"
blocks "git checkout --force -b newbranch"
blocks "git switch -f -c newbranch"
blocks "git switch --force --create newbranch"
blocks "git switch --discard-changes main"
allows "git checkout -b feat/x main"
allows "git branch -d merged-topic"
allows "git branch --list"
allows "git branch --format=%(refname)"

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

printf '\n%s== REGRESSION: the creation exception is per-segment, not per-payload ==%s\n' "$DIM" "$RESET"
# The `checkout -b` / `switch -c` exception describes ONE invocation. Tested
# against the whole compound command, any co-occurring `-b` disarmed the rule
# and a real branch switch — which overwrites every differing tracked file —
# was allowed through.
blocks 'git checkout -b tmp && git checkout main'
blocks 'git switch -c tmp; git switch main'
blocks "echo 'git checkout -b x' ; git checkout main"
allows 'git checkout -b feature/x'
allows 'git switch -c feature/y'

printf '\n%s== REGRESSION: quoted patterns are arguments, not invocations ==%s\n' "$DIM" "$RESET"
# Scanning the raw payload blocked read-only searches for the guard's own
# patterns — the most likely benign hit there is. A shell re-entry point
# (bash -c, $(), backticks) turns quoted text back into code, so those still block.
allows 'grep -rn "git reset --hard" scripts/'
allows "git log --grep='git reset --hard'"
allows 'rg "git clean -fd" docs/'
blocks 'bash -c "git reset --hard"'
blocks 'sh -c "git clean -fd"'
blocks 'eval "git reset --hard"'

printf '\n%s== REGRESSION: a model-written description never blocks a clean command ==%s\n' "$DIM" "$RESET"
DESC_RC=$(python3 -c "
import json
print(json.dumps({'tool_name':'Bash','tool_input':{
  'command':'git commit -m fix',
  'description':'commit the fix without git reset --hard'}}))" \
  | bash "$GUARD" >/dev/null 2>&1; echo $?)
[[ "$DESC_RC" == "0" ]] && ok "pattern only in the description → allowed" || fail "description-only block" "expected 0, got $DESC_RC"

printf '\n%s== REGRESSION: git re-entering itself ==%s\n' "$DIM" "$RESET"
# `git -c alias.X=<body> X` defines an alias inline and runs it; a body starting
# with `!` is arbitrary shell. Measured: one such command destroyed a repository
# while scanning as `git -c __ORCH_ARG__ pwn` — the guard's own -c stripper
# deleted the payload before any rule saw it. These rules read the RAW command,
# because a rule about text that quoting hides has to read the text.
blocks "git -c alias.zz=reset zz --hard"
blocks "git -c alias.zz='reset --hard' zz"
blocks "git -c alias.pwn='!rm -rf .git' pwn"
blocks "git -c alias.bd='branch -D' bd other"
blocks "git submodule foreach 'touch /tmp/x'"
blocks "git bisect run ./script.sh"
blocks "git rebase --exec 'touch /tmp/x' main"
blocks "git difftool -y --extcmd='touch /tmp/x' HEAD -- f"
blocks "git filter-branch --tree-filter 'touch /tmp/x' HEAD"
# Plumbing equivalents of a hard reset, previously covered by no rule at all.
blocks "git read-tree --reset -u HEAD"
blocks "git checkout-index -f -a"

printf '\n%s== REGRESSION: brace expansion is real word-splitting ==%s\n' "$DIM" "$RESET"
# `{a,b}` is one opaque token to shlex and two words to bash.
blocks "git {reset,--hard}"
blocks "git {clean,-fdx}"
blocks "git {checkout,-f,other}"
blocks "git {branch,-D,other}"
blocks "git {restore,.}"
blocks "rm {-rf,.git}"

printf '\n%s== REGRESSION: a newline separates commands ==%s\n' "$DIM" "$RESET"
# shlex treats a newline as ordinary whitespace, so two commands collapsed into
# one segment and the `checkout -b` creation exemption from the first covered
# the real branch switch in the second — the hole the per-segment fix closed for
# `&&` and `;`, reopened for the way a model most naturally writes two commands.
blocks "$(printf 'git checkout -b tmp\ngit checkout main')"
blocks "$(printf 'git switch -c tmp\ngit switch main')"
blocks "$(printf 'git checkout -b a\ngit checkout -b b\ngit checkout main')"
allows "$(printf 'cd sub\nnpm test')"

printf '\n%s== malformed payloads must never fail OPEN ==%s\n' "$DIM" "$RESET"
# Mutation-found gap: adding a JSON-parse fail-open to this guard left all 130
# checks green — there was no malformed-payload case at all. A guard that can
# be argued out of firing by a broken event is not a guard. Each payload below
# is undecodable in a different way and must still reach the block decision by
# falling back to a raw scan.
raw_rc() { printf '%s' "$1" > "$_PAYLOAD"; ( cd "$MAINDIR" && bash "$GUARD" < "$_PAYLOAD" ) >/dev/null 2>&1; echo $?; }
# Undecodable AND carrying destructive text → must still block via the raw scan.
for _bad in \
  'not json at all git reset --hard' \
  '{"tool_input":{"command":"git reset --hard"' \
  '{"tool_input":{"command":"git clean -fd"' \
  '{"tool_input":{"command":"git reset --hard"},,,}' \
  '{"tool_input" "command" "git stash"}' ; do
  RC=$(raw_rc "$_bad")
  if [[ "$RC" == "2" ]]; then ok "undecodable + destructive still blocks: ${_bad:0:34}"
  else fail "undecodable + destructive blocks: ${_bad:0:34}" "expected 2, got $RC — FAIL-OPEN"; fi
done
# Malformed but carrying NO destructive text: there is nothing to block, so
# allowing is correct — but the guard must exit cleanly rather than crash.
# (A non-0/non-2 exit is a hook ERROR, which Claude Code treats as allow, so a
# crash on a weird payload is itself a fail-open.)
for _empty in '{"tool_input":' '{}' '{"tool_input":{"command":' '' 'null'; do
  RC=$(raw_rc "$_empty")
  if [[ "$RC" == "0" || "$RC" == "2" ]]; then ok "malformed-but-harmless payload exits cleanly (rc=$RC): ${_empty:0:24}"
  else fail "malformed payload crashed: ${_empty:0:24}" "got $RC — a crash code reads as ALLOW"; fi
done

printf '\n%s== forged worktree markers must not unlock the relaxation ==%s\n' "$DIM" "$RESET"
# Mutation-found gap: dropping the `gitdir:` CONTENT check left every check
# green. Both file tests alone are forgeable — mkdir a dir, write a .git FILE
# pointing anywhere, touch .orch-worktree — and `git reset --hard HEAD~2` then
# ran against the SHARED checkout with no cd and no -C for the retarget grep
# to catch. A real linked worktree's .git resolves into .git/worktrees/<name>.
FORGE="$TMP/forged"; mkdir -p "$FORGE"
printf 'gitdir: %s/.git\n' "$MAINDIR" > "$FORGE/.git"
touch "$FORGE/.orch-worktree"
forged_rc() { _mkpayload "$1"; ( cd "$FORGE" && bash "$GUARD" < "$_PAYLOAD" ) >/dev/null 2>&1; echo $?; }
for _cmd in "git reset --hard HEAD~2" "git clean -fd" "git stash" "git checkout main"; do
  RC=$(forged_rc "$_cmd")
  if [[ "$RC" == "2" ]]; then ok "forged .git marker does NOT relax: $_cmd"
  else fail "forged marker relaxed: $_cmd" "expected 2, got $RC — a spoofed worktree got worktree privileges"; fi
done
# A .git file pointing at a plausible-looking but non-worktrees path is also a forgery.
printf 'gitdir: %s/.git/modules/x\n' "$MAINDIR" > "$FORGE/.git"
RC=$(forged_rc "git reset --hard HEAD~2")
[[ "$RC" == "2" ]] && ok "gitdir pointing outside .git/worktrees/ does not relax" \
  || fail "non-worktrees gitdir relaxed" "expected 2, got $RC"

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
