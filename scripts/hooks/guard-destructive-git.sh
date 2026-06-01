#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard — blocks working-tree-destroying git.
#
# Why this exists: agents (especially review/verification/parallel subagents
# sharing one checkout) reach for `git stash` / `git reset --hard` / `git clean`
# / a branch switch to "get a clean tree" for tests — and those silently discard
# the user's uncommitted work. `git stash` is the worst offender: it runs an
# internal `git reset --hard HEAD`, and with --include-untracked it also deletes
# untracked files. Concurrent agents doing this on one tree race and lose work.
#
# Design: NORMALIZE then MATCH. Git's global options (`-C <dir>`, `--git-dir=`,
# `--work-tree=`, `-c k=v`, `--namespace`) are stripped first so the real
# subcommand sits adjacent to `git`. Without this, `git -C /repo reset --hard`
# slips past a naive `git ... reset` matcher — the flag-absorber eats `-C` but
# not its path argument. Normalizing once closes that whole bypass class for
# every rule at the same time, instead of patching each command separately.
#
# This hook blocks the destructive forms on every Bash tool call (controller AND
# subagents). Read-only / non-destructive git is allowed. The ONLY opt-out is an
# explicit ORCH_ALLOW_DESTRUCTIVE_GIT=1 in the hook's OWN process environment
# (set deliberately by a human). An inline `ORCH_ALLOW_DESTRUCTIVE_GIT=1 git …`
# prefix in the scanned command does NOT disarm the guard — that prefix lands in
# the child shell's env, not this hook's, so the destructive command is still
# scanned and blocked.
#
# Reads the JSON event from stdin; exit 0 to allow, exit 2 to block.

set -euo pipefail

if [[ "${ORCH_ALLOW_DESTRUCTIVE_GIT:-0}" == "1" ]]; then
  exit 0
fi

INPUT=$(cat || true)

# We scan the whole event payload, not just the extracted command value. This is
# deliberate and fail-CLOSED: a buggy command-extractor could drop part of a real
# destructive command and let it through (fail-open) — far worse than the rare
# false positive where a non-command JSON field happens to contain a blocked
# pattern. Blocking a benign command is recoverable; missing `git reset --hard`
# is not. In Claude Code's payload the non-command fields are not user-controlled,
# so the false-positive surface is small in practice.

# Work on a copy with `commit-graph` / `--grep=` neutralized so they can't
# false-match a subcommand below (mirrors the commit-guard approach).
SCAN=$(printf '%s' "${INPUT}" | sed -E 's/commit-graph/COMMITGRAPH/g')

# --- Normalize: strip git GLOBAL options that take an argument, so the
# subcommand becomes adjacent to `git`. Looped to collapse stacked globals
# (e.g. `git -C /r -c x=y reset --hard`). This is what defeats the `-C` bypass.
_i=0
while [[ ${_i} -lt 5 ]]; do
  PREV="${SCAN}"
  SCAN=$(printf '%s' "${SCAN}" | sed -E \
    -e 's/(git)[[:space:]]+-C[[:space:]]+[^[:space:]]+/\1/g' \
    -e 's/(git)[[:space:]]+-c[[:space:]]+[^[:space:]]+/\1/g' \
    -e 's/(git)[[:space:]]+--git-dir[=[:space:]][^[:space:]]+/\1/g' \
    -e 's/(git)[[:space:]]+--work-tree[=[:space:]][^[:space:]]+/\1/g' \
    -e 's/(git)[[:space:]]+--namespace[=[:space:]][^[:space:]]+/\1/g')
  [[ "${SCAN}" == "${PREV}" ]] && break
  _i=$((_i + 1))
done

# --- Context-scoped relaxation -------------------------------------------------
# Inside one of OUR isolated worktrees, destructive git can only touch that
# agent's own disposable work, so the worktree-LOCAL commands are allowed there
# while still blocked on the shared main checkout. Computed FAIL-CLOSED: relax
# only on positive confirmation, using pure file tests + a raw-command scan — NO
# git subprocess, so `set -euo pipefail` can never turn a detection error into a
# fail-OPEN (a git exit 128 would otherwise abort the hook = "allow").
RELAX=0
# (1) simple_direct: refuse relaxation if the RAW command (INPUT, pre-normalization
#     — SCAN has already had -C/--git-dir stripped) carries ANY directory-retarget
#     or interpreter/subshell construct that could move the git off this worktree
#     (git -C, --git-dir, --work-tree, GIT_DIR=, cd/pushd, env -C/--chdir, a shell
#     interpreter, or command/process substitution). Deny-by-default.
# Flatten newlines/tabs first so a multi-line command can't hide a retarget token
# from the line-oriented grep (e.g. `git -C\n/main reset --hard`).
_RAW=$(printf '%s' "${INPUT}" | tr '\n\r\t' '   ')
if ! grep -qE '(^|[^[:alnum:]_])cd[[:space:]]|(^|[^[:alnum:]_])pushd[[:space:]]|(^|[^[:alnum:]_])env[[:space:]]|[[:space:]]-C[[:space:]]|--git-dir|--work-tree|--chdir|GIT_DIR=|GIT_WORK_TREE=|(^|[^[:alnum:]_])(bash|sh|zsh|python[0-9.]*|perl|ruby|node)[[:space:]]|[$]\(|`|<\(' <<< "${_RAW}"; then
  # (2) in_our_worktree: $PWD is the command's execution dir (Claude Code runs the
  #     hook there). A linked worktree's .git is a FILE (a directory on the main
  #     checkout); the .orch-worktree marker means we created it. BOTH required, so
  #     a spoofed marker on the main checkout cannot pass (main's .git is a dir).
  if [[ -f "${PWD}/.git" && -f "${PWD}/.orch-worktree" ]]; then
    RELAX=1
  fi
fi

reason=""

# --- ALWAYS-BLOCKED stash sub-forms (even inside a worktree): drop/clear/branch
# destroy entries on the repo-global stash stack (shared by the main checkout AND
# every worktree); an explicit-ref pop/apply (stash@{N}) consumes a specific
# shared entry. Checked before the relaxable stash rule so it always wins.
if grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+stash[[:space:]]+(drop|clear|branch|(pop|apply)[[:space:]]+stash@)' <<< "${SCAN}"; then
  reason="git stash drop/clear/branch or explicit-ref pop/apply — destroys or consumes entries on the repo-global stash stack shared with the main checkout and sibling worktrees"
fi

# --- git stash, all tree-touching forms: bare `git stash`, push/save/drop/clear,
# AND pop/apply/branch, or stash with a flag (-u/--include-untracked/-m/...).
# save runs an internal `git reset --hard`; pop/apply overwrite whatever files
# the stash touches (a pre-existing stash applied onto a shared tree clobbers a
# concurrent agent's in-flight edits); `stash branch` smuggles a `checkout -b`
# past the branch-switch rule. Only the read-only forms `git stash list/show`
# are allowed (they are not in the alternation and have a word after `stash`, so
# the bare-form anchor does not catch them).
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+stash([[:space:]]+(push|save|pop|apply)|[[:space:]]+-|[[:space:]]*("|\\|;|&|\||$))' <<< "${SCAN}"; then
  reason="git stash (save/pop/apply) — save runs an internal 'git reset --hard'; on the main checkout it can clobber the user's work. Allowed inside an isolated .orch-worktree; 'git stash list/show' are always read-only"
fi

# --- git reset --hard / --keep / --merge (all can discard uncommitted changes)
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+reset[^&|;]*(--hard|--keep|--merge)' <<< "${SCAN}"; then
  reason="git reset --hard/--keep/--merge — discards uncommitted changes on the main checkout (use 'git reset --soft' to keep work staged; allowed inside an isolated .orch-worktree)"
fi

# --- git clean -f / -fd / -fdx / -df ...
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+clean([[:space:]]+-[a-zA-Z]*f|[[:space:]]+--force)' <<< "${SCAN}"; then
  reason="git clean -f — deletes untracked files irrecoverably on the main checkout (allowed inside an isolated .orch-worktree)"
fi

# --- git checkout -- <path> / git checkout .  (discard worktree changes)
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+checkout[[:space:]]+(--[[:space:]]|\.([[:space:]]|"|\\|$))' <<< "${SCAN}"; then
  reason="git checkout -- / git checkout . — discards uncommitted changes to those paths (allowed inside an isolated .orch-worktree)"
fi

# --- git checkout <ref> / git switch <branch> (BRANCH SWITCH) — overwrites every
# tracked file that differs between branches, clobbering uncommitted work in the
# shared tree. Allow ONLY pure branch creation: `checkout -b/-B`, `switch -c/-C`.
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git[[:space:]]+(checkout|switch)([[:space:]]|$)' <<< "${SCAN}"; then
  if ! grep -qE 'git[[:space:]]+checkout[[:space:]]+-[bB]([[:space:]]|$)' <<< "${SCAN}" \
     && ! grep -qE 'git[[:space:]]+switch[[:space:]]+-[cC]([[:space:]]|$)' <<< "${SCAN}"; then
    reason="git checkout/switch <branch> — a branch switch overwrites every differing tracked file, discarding uncommitted work on the main checkout (only 'checkout -b' / 'switch -c' creation allowed; switches allowed inside an isolated .orch-worktree)"
  fi
fi

# --- git restore — allow ONLY a pure --staged (unstage) restore; block anything
# that touches the worktree (no flags, or --worktree/-W, even alongside --staged).
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+restore' <<< "${SCAN}"; then
  has_staged=no; has_wt=no
  grep -qE 'restore[^&|;]*--staged' <<< "${SCAN}" && has_staged=yes
  grep -qE 'restore[^&|;]*(--worktree|-W)([[:space:]]|$)' <<< "${SCAN}" && has_wt=yes
  if [[ "${has_wt}" == "yes" || "${has_staged}" == "no" ]]; then
    reason="git restore (worktree) — discards uncommitted changes (use 'git restore --staged' alone to only unstage)"
  fi
fi

# --- git rm -f / --force / -r (force-deletes tracked files from index + worktree)
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+rm([[:space:]]+-[a-zA-Z]*f|[[:space:]]+--force|[[:space:]]+-r)' <<< "${SCAN}"; then
  reason="git rm -f/-r — force-deletes tracked files from the index and working tree on the main checkout (allowed inside an isolated .orch-worktree)"
fi

# --- git branch -D / --delete --force
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+branch[^&|;]*(-D|--delete[[:space:]]+--force|-[a-zA-Z]*D)' <<< "${SCAN}"; then
  reason="git branch -D — force-deletes a branch, dropping unmerged commits"
fi

# --- git worktree remove --force
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+worktree[[:space:]]+remove[^&|;]*(--force|-f)' <<< "${SCAN}"; then
  reason="git worktree remove --force — discards a worktree's uncommitted changes"
fi

# --- raw filesystem destruction of the work containers themselves: `rm -rf .git`
# or `rm -rf .worktrees/...`. Not a git command, so it bypasses every rule above.
# Scoped narrowly to those two containers — rm elsewhere is a legitimate tool.
if [[ -z "${reason}" ]] && grep -qE 'rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+[^&|;]*(\.git|\.worktrees)([[:space:]/"]|$)' <<< "${SCAN}"; then
  reason="rm -rf of .git/.worktrees — irrecoverably destroys a repository or an isolated worktree (and any uncommitted work inside it)"
fi

if [[ -n "${reason}" ]]; then
  cat <<MSG >&2
LLM Orchestrator guard: blocked a working-tree-destroying command.
  ${reason}.
Uncommitted work must not be discarded automatically — especially by a
subagent, and never on a shared checkout where parallel agents race.
Worktree-local destructive git (stash/reset --hard/clean/checkout/restore) is
permitted inside one of our isolated worktrees; this command ran on the shared
main checkout (or carried a directory-retargeting form like 'git -C' / 'cd').
If you really mean to discard it here, set ORCH_ALLOW_DESTRUCTIVE_GIT=1.
MSG
  exit 2
fi

exit 0
