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

# NO `set -e` HERE, DELIBERATELY. A blocking guard that aborts mid-script exits
# non-zero-but-not-2, which Claude Code treats as a non-blocking hook error — the
# command then RUNS. Measured: a single invalid-UTF-8 byte in the command made
# BSD sed exit 1 with "RE error: illegal byte sequence", `set -e` aborted before
# the block decision was computed, and a hard reset carrying that byte was
# ALLOWED. Every failure path in a guard has to fall through to the block logic,
# not out of the script. The seds also run under LC_ALL=C so bytes stay bytes.
set -uo pipefail

if [[ "${ORCH_ALLOW_DESTRUCTIVE_GIT:-0}" == "1" ]]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${HOOK_DIR}/../lib/orch-json.sh" ]] && source "${HOOK_DIR}/../lib/orch-json.sh"

# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# --- What we scan -------------------------------------------------------------
# The whole event payload, unless we can decode the command out of it exactly.
#
# Scanning the raw payload was a deliberate fail-CLOSED choice, made when the
# only available extractor was a grep that could plausibly drop part of a real
# command. With a real JSON decode that risk is gone, and the cost of the old
# choice was measurable: `grep -rn "git reset --hard" scripts/` — reading the
# guard's own source — was hard-blocked, as was any command whose model-written
# `description` mentioned a blocked verb.
#
# Quoted text is then neutralised, because a pattern inside quotes is an
# ARGUMENT, not an invocation — UNLESS the command can re-enter a shell
# (`bash -c "..."`, `$(...)`, backticks), where quoted text becomes code again.
# In that case the raw command is scanned. Both fallbacks are toward blocking.
SRC="${INPUT}"
declare -f orch_scan_source >/dev/null 2>&1 && SRC=$(orch_scan_source "${INPUT}")

# Work on a copy with `commit-graph` / `--grep=` neutralized so they can't
# false-match a subcommand below (mirrors the commit-guard approach).
SCAN=$(printf '%s' "${SRC}" | LC_ALL=C tr -c '[:print:][:space:]' ' ' \
       | LC_ALL=C sed -E 's/commit-graph/COMMITGRAPH/g')

# --- Normalize: strip git GLOBAL options that take an argument, so the
# subcommand becomes adjacent to `git`. Looped to collapse stacked globals
# (e.g. `git -C /r -c x=y reset --hard`). This is what defeats the `-C` bypass.
_i=0
while [[ ${_i} -lt 5 ]]; do
  PREV="${SCAN}"
  SCAN=$(printf '%s' "${SCAN}" | LC_ALL=C sed -E \
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
# The DECODED command when we have it. Scanning the raw payload meant a
# model-written `description` containing a backtick — routine in Claude Code —
# refused the worktree relaxation, so the relaxation almost never applied.
# Falls back to the payload, which is the conservative direction (no relax).
_RAW_SRC="${INPUT}"
declare -f orch_json_field >/dev/null 2>&1 && _DEC=$(orch_json_field "${INPUT}" tool_input.command) && [[ -n "${_DEC}" ]] && _RAW_SRC="${_DEC}"
_RAW=$(printf '%s' "${_RAW_SRC}" | tr '\n\r\t' '   ')
if ! grep -qE '(^|[^[:alnum:]_])cd[[:space:]]|(^|[^[:alnum:]_])pushd[[:space:]]|(^|[^[:alnum:]_])env[[:space:]]|[[:space:]]-C[[:space:]]|--git-dir|--work-tree|--chdir|GIT_DIR=|GIT_WORK_TREE=|(^|[^[:alnum:]_])(bash|sh|zsh|python[0-9.]*|perl|ruby|node)[[:space:]]|[$]\(|`|<\(' <<< "${_RAW}"; then
  # (2) in_our_worktree: $PWD is the command's execution dir (Claude Code runs the
  #     hook there). A linked worktree's .git is a FILE (a directory on the main
  #     checkout); the .orch-worktree marker means we created it. BOTH required, so
  #     a spoofed marker on the main checkout cannot pass (main's .git is a dir).
  # A REAL linked worktree's .git file reads `gitdir: <main>/.git/worktrees/<name>`.
  # Both file tests alone were forgeable: `mkdir /tmp/fake; printf 'gitdir:
  # <MAIN>/.git\n' > /tmp/fake/.git; touch /tmp/fake/.orch-worktree` satisfied
  # them, and `git reset --hard HEAD~2` there dropped two commits on the SHARED
  # checkout — no cd, no -C, so the deny-by-default retarget grep never fired.
  # Requiring the gitdir to point INSIDE .git/worktrees/ rejects that forgery:
  # a pointer that does resolve there resolves to a real registered worktree,
  # which is the only place the relaxation was ever meant to apply.
  if [[ -f "${PWD}/.git" && -f "${PWD}/.orch-worktree" ]] \
     && grep -qE '^gitdir:[[:space:]]*.*/\.git/worktrees/[^[:space:]/]+/?$' "${PWD}/.git" 2>/dev/null; then
    RELAX=1
  fi
fi

# The RAW decoded command, for the rules below that must see through quoting.
RAWCMD="${INPUT}"
declare -f orch_json_field >/dev/null 2>&1 && _RC=$(orch_json_field "${INPUT}" tool_input.command) && [[ -n "${_RC}" ]] && RAWCMD="${_RC}"
RAWCMD=$(printf '%s' "${RAWCMD}" | LC_ALL=C tr -c '[:print:][:space:]' ' ' | tr '\n\r\t' '   ')

reason=""

# --- PRIMARY PATH: semantic classification ------------------------------------
# The regex rules below match option SPELLINGS, and git's own parser accepts
# spellings no author enumerates: `git reset --h` really resets, `git clean
# --for` really cleans, `git --no-pager checkout -f` walked past the flag
# absorber, and a line continuation broke adjacency entirely. The classifier
# strips globals the way git does, finds the subcommand, and resolves long
# options by PREFIX against the destructive names — so it decides on meaning.
#
# Exit 3 means it could not parse with confidence (no python3, unbalanced
# quotes, a shell re-entry point, an unexpanded $). That is NOT an allow: the
# spelling rules below then run as the block-biased fallback they always were.
_CLASSIFIER="${HOOK_DIR}/../lib/orch-git-classify.py"
_DECODED_CMD=""
declare -f orch_json_field >/dev/null 2>&1 && _DECODED_CMD=$(orch_json_field "${INPUT}" tool_input.command)
if [[ -n "${_DECODED_CMD}" && -f "${_CLASSIFIER}" ]] && command -v python3 >/dev/null 2>&1; then
  _CR=0
  _CREASON=$(printf '%s' "${_DECODED_CMD}" \
    | python3 "${_CLASSIFIER}" --mode destructive --relax "${RELAX}" 2>/dev/null) || _CR=$?
  if [[ "${_CR}" != "0" && "${_CR}" != "2" ]]; then
    # Exit 3 (a `$`, a backtick, a launcher word, an interpreter). This used
    # to drop straight to the spelling regexes below, and those match only
    # full canonical spellings — so `nice git reset --h HEAD~1` and
    # `git reset --h HEAD~1 && echo $HOME` were measured ALLOWED while really
    # resetting the tree. Re-run the SAME classifier in its block-biased
    # paranoid mode instead of delegating to a weaker second rule set: one
    # source of truth for what a destructive invocation looks like. Only if
    # paranoid mode also cannot parse (exit 3 again) do the raw spelling
    # rules below get the last word.
    _CR=0
    _CREASON=$(printf '%s' "${_DECODED_CMD}" \
      | python3 "${_CLASSIFIER}" --mode destructive --relax "${RELAX}" --paranoid 1 2>/dev/null) || _CR=$?
  fi
  case "${_CR}" in
    2) reason="${_CREASON}" ;;
    0) exit 0 ;;   # parsed with confidence and found nothing destructive
    *) : ;;        # still unparseable → fall through to the spelling rules
  esac
fi

# --- git re-entering itself ----------------------------------------------
# These rules scan RAWCMD, not SCAN. They exist to catch a payload that quoting
# hides, and tokenization replaces precisely that payload with a placeholder —
# `git -c alias.zz='"'"'reset --hard'"'"' zz` scanned as `git -c __ORCH_ARG__ zz`
# and was allowed. A rule about hidden text has to read the text.
# `git -c alias.X=<anything> X` defines an alias inline and then runs it, and an
# alias body beginning with `!` is arbitrary shell. Measured: `git -c
# alias.pwn='!rm -rf .git' pwn` destroyed the repository while scanning as the
# innocuous `git -c __ORCH_ARG__ pwn` — the guard's own `-c` stripper deleted the
# payload before any rule saw it. There is no legitimate agent use for defining
# an alias inline, so the FORM is blocked, not its contents.
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:space:]]*alias\.' <<< "${RAWCMD}"; then
  reason="git -c alias.<name>=... — defines an alias inline and runs it; an alias body starting with '!' is arbitrary shell, and the option normalizer cannot see through it"
fi
# The same escape without an alias: verbs whose whole purpose is to run a command.
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(submodule[[:space:]]+foreach|bisect[[:space:]]+run|filter-branch|rebase([[:space:]]+[^[:space:]]+)*[[:space:]]+(-x|--exec)|difftool([[:space:]]+[^[:space:]]+)*[[:space:]]+--extcmd|(-c[[:space:]]*[^[:space:]]*(pager|editor|extcmd|[hH][oO][oO][kK][sS][pP][aA][tT][hH])=))' <<< "${RAWCMD}"; then
  reason="git subcommand that executes an arbitrary command (submodule foreach / bisect run / filter-branch / rebase --exec / difftool --extcmd / a -c pager|editor|extcmd|hooksPath override) — this is a shell re-entry point the guard cannot see through"
fi
# Plumbing that overwrites the working tree exactly like `reset --hard`. No rule
# covered these: measured, both reverted a tracked file with uncommitted work.
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(read-tree([[:space:]]+[^[:space:]]+)*[[:space:]]+(--reset|-u)|checkout-index([[:space:]]+[^[:space:]]+)*[[:space:]]+(-f|--force))' <<< "${SCAN}"; then
  reason="git read-tree --reset / checkout-index -f — plumbing equivalents of 'reset --hard': they overwrite tracked files, discarding uncommitted work"
fi

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

# --- git clean -f / -fd / -fdx / -df ... The absorber between `clean` and the
# force flag matters: `git clean -x -f` puts the force in the SECOND cluster,
# and inspecting only the first measured as ALLOWED while really deleting.
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+clean([[:space:]]+-[^[:space:]]+)*([[:space:]]+-[a-zA-Z]*f|[[:space:]]+--force)' <<< "${SCAN}"; then
  reason="git clean -f — deletes untracked files irrecoverably on the main checkout (allowed inside an isolated .orch-worktree)"
fi

# --- git checkout -- <path> / git checkout .  (discard worktree changes)
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+checkout[[:space:]]+(--[[:space:]]|\.([[:space:]]|"|\\|$))' <<< "${SCAN}"; then
  reason="git checkout -- / git checkout . — discards uncommitted changes to those paths (allowed inside an isolated .orch-worktree)"
fi

# --- git checkout <ref> / git switch <branch> (BRANCH SWITCH) — overwrites every
# tracked file that differs between branches, clobbering uncommitted work in the
# shared tree. Allow ONLY pure branch creation: `checkout -b/-B`, `switch -c/-C`.
# Evaluated PER SEGMENT. The creation exception describes a single invocation,
# so testing it against the whole compound command let any co-occurring `-b`
# disarm the rule: `git checkout -b tmp && git checkout main` was ALLOWED, and
# a branch switch overwrites every differing tracked file. Even `echo 'git
# checkout -b x'; git checkout main` passed, lending a flag from inside a
# quoted string to the next command. Segmentation is the fix; a command the
# splitter cannot divide falls back to being tested whole (the old behaviour).
# The flag absorber `([[:space:]]+-[^[:space:]]+)*` after `git` matches every
# sibling rule in this file; its absence here meant `nice git --no-pager
# checkout main` walked past on the fallback path. Creation exemptions are
# lowercase-only: `-B`/`-C` force-RESET an existing branch (same harm as
# `branch -M`), so on this blunt path they must block, not exempt.
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(checkout|switch)([[:space:]]|$)' <<< "${SCAN}"; then
  _segs="${SCAN}"
  declare -f orch_shell_segments >/dev/null 2>&1 && _segs=$(orch_shell_segments "${SCAN}")
  while IFS= read -r _seg; do
    [[ -n "${_seg}" ]] || continue
    grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(checkout|switch)([[:space:]]|$)' <<< "${_seg}" || continue
    if ! grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+checkout[[:space:]]+-b([[:space:]]|$)' <<< "${_seg}" \
       && ! grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+switch[[:space:]]+-c([[:space:]]|$)' <<< "${_seg}"; then
      reason="git checkout/switch <branch> — a branch switch overwrites every differing tracked file, discarding uncommitted work on the main checkout (only 'checkout -b' / 'switch -c' creation allowed; switches allowed inside an isolated .orch-worktree)"
      break
    fi
  done <<< "${_segs}"
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
# --cached is exempt even here: it removes from the INDEX ONLY — it is the
# remedy git itself prints for an accidentally-added embedded repo, and
# blocking it teaches users the guard is noise. Segment-bounded ([^&|;]) so a
# --cached in one command cannot launder a real `git rm -rf` after `&&`.
if [[ -z "${reason}" && ${RELAX} -eq 0 ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+rm([[:space:]]+-[a-zA-Z]*f|[[:space:]]+--force|[[:space:]]+-r)' <<< "${SCAN}" \
   && ! grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+rm[^&|;]*--cached' <<< "${SCAN}"; then
  reason="git rm -f/-r — force-deletes tracked files from the index and working tree on the main checkout (allowed inside an isolated .orch-worktree)"
fi

# --- degraded-path parity for the classifier's newer rules. The classifier is
# the source of truth for these (update-ref, push, the --abort family,
# checkout -B); the regexes below exist only for the no-python3 environment
# and are deliberately canonical-spelling-only.
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+update-ref([[:space:]]+[^&|;]*)?[[:space:]](-d|--stdin)([[:space:]]|$)' <<< "${SCAN}"; then
  reason="git update-ref -d / --stdin — deletes or rewrites refs directly, bypassing every porcelain protection"
fi
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]+[^&|;]*)?([[:space:]](--force[^[:space:]]*|--delete|--prune|--mirror|-[a-zA-Z]*[fd]([[:space:]]|$)|[+:][^[:space:]]+))' <<< "${SCAN}"; then
  reason="git push --force/-f/--delete/:ref — rewrites or deletes refs on the shared remote; unrecoverable from this checkout"
fi
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(merge|rebase|am|cherry-pick|revert)[^&|;]*[[:space:]]--abort([[:space:]]|$)' <<< "${SCAN}"; then
  reason="git merge/rebase/am/cherry-pick --abort — internally hard-resets to the pre-operation state, discarding conflict-resolution work"
fi
if [[ -z "${reason}" ]] && grep -qE 'git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(checkout[^&|;]*[[:space:]]-B|switch[^&|;]*[[:space:]]-C)([[:space:]]|$)' <<< "${SCAN}"; then
  reason="git checkout -B / switch -C — force-resets an existing branch to a new start point, dropping its commits"
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
