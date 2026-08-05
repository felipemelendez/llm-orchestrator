---
name: finishing-a-branch
description: Use when implementation is complete and tests pass. Decides between merge, PR, keep, or discard — without destructive actions unless the user confirms.
---

# Finishing a branch

The branch is green. Now what?

## Preconditions

Before this skill runs:
- `/llm-orchestrator:verify` has been run; tests pass.
- `/llm-orchestrator:review` has been run; verdict is yes or with-fixes already addressed.
- **Regression check passes.** Run:
  ```bash
  orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
  L=$(orch_lib orch-detect.sh) && . "$L" && orch_regression_check <project-dir>
  ```
  Exit codes: `0` — suite passes now (or the baseline was never green, so no guard applies). `1` — a previously-green suite now fails: **refuse to merge or open a PR**, report what regressed, fix that first. `2` — unknown: either no baseline was ever recorded (the branch didn't go through `using-git-worktrees` step 7), or a green baseline exists but **no test command is detected anymore** — the stderr line says which. For a missing baseline, say so and continue on the strength of `/llm-orchestrator:verify` — do not report a regression that was never measured. For a vanished test command, treat it as a blocker: a project that lost the ability to run the suite its baseline was built from must not be certified clean — find out what removed it before finishing. This check is never destructive — it only reads and runs tests.

If any precondition is false, stop and do that first.

## Detect environment

```
git rev-parse --abbrev-ref HEAD          # current branch
git rev-parse --git-dir                  # detect worktree
git rev-parse --git-common-dir
git status --porcelain                    # clean tree?
```

If HEAD is detached, drop options 1 and 4 — there is no branch to merge and none to delete.
Options 2 and 3 still apply — push with `git push origin HEAD:refs/heads/<new-branch>` and open
the PR from there. Removing the PR route from a detached HEAD strands the work in a state only
the reflog can recover.

Also confirm this is a worktree and not a submodule before treating it as one:
`git rev-parse --show-superproject-working-tree` returns a path inside a submodule, where
`GIT_DIR != GIT_COMMON_DIR` is true for a different reason.

## Options (always present this menu)

```
1. Merge locally into <base>
2. Push and open PR
3. Keep as-is (no action; come back later)
4. Discard
```

## Behaviors

### 1. Merge
- Confirm base branch with user.
- `git checkout <base> && git pull --ff-only` — the point of this step is that base moved,
  so merge into the current base, not a stale local copy.
- `git merge --no-ff <branch>`
- **Run the suite on the merged tree.** The branch was green in isolation; base has moved
  since. A merge that conflicts textually is loud, and one that conflicts semantically is
  silent — this is the only step that catches the second kind.
- If it fails: stop. Leave the branch and the worktree exactly where they are and report what
  broke. Nothing has been pushed, so the merge is local and recoverable (`git merge --abort`,
  or reset the base branch to its pre-merge commit).
- Only once green: offer cleanup if the branch lived in a worktree marked `.orch-worktree`,
  then `git branch -d <branch>`.

### 2. PR
- `git push -u origin <branch>` (detached HEAD: `git push origin HEAD:refs/heads/<new-branch>`)
- A rejected push means the remote moved while you worked. Investigate before doing anything
  else; force-push only if the user asks for it in those words.
- `gh pr create` — title from branch name, body from latest commit + plan link.
- Do not clean up the worktree (the user may need to push more commits).

### 3. Keep
- No-op. Print where the branch + worktree live so they're easy to find later.

### 4. Discard
- Require the user to type the word `discard` literally.
- Only then: `git checkout <base> && git branch -D <branch>`
- Cleanup worktree only if marked `.orch-worktree`.

## Output shape

Before:

```
Found:
- Branch: feat/x
- Worktree: .worktrees/feat-x (LLM Orchestrator-created)
- Tests: 142 passed
- Review: yes
Options:
- 1. Merge into main
- 2. Push and open PR
- 3. Keep
- 4. Discard (requires "discard" confirmation)
Recommendation:
- 2 — change touches public API; PR review is cheap insurance
```

After the user picks:

```
Changed:
- Pushed feat/x to origin
- Opened PR #142: <title> — <url>
Next:
- Watch CI; merge when green.
```
