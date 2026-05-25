---
name: finishing-a-branch
description: Use when implementation is complete and tests pass. Decides between merge, PR, keep, or discard — without destructive actions unless the user confirms.
---

# Finishing a branch

The branch is green. Now what?

## Preconditions

Before this skill runs:
- `/verify` has been run; tests pass.
- `/review` has been run; verdict is yes or with-fixes already addressed.
- **Regression check passes.** Run:
  ```
  orch_regression_check <project-dir>
  ```
  If it returns nonzero (a previously-green suite now fails), **refuse to merge or open a PR** and report what regressed. Fix the regression first. This check is never destructive — it only reads and runs tests.

If any precondition is false, stop and do that first.

## Detect environment

```
git rev-parse --abbrev-ref HEAD          # current branch
git rev-parse --git-dir                  # detect worktree
git rev-parse --git-common-dir
git status --porcelain                    # clean tree?
```

If HEAD is detached, you only get options 3 and 4 below.

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
- `git checkout <base> && git merge --no-ff <branch>`
- If the branch lived in a worktree marked `.orch-worktree`, offer cleanup after merge.

### 2. PR
- `git push -u origin <branch>`
- `gh pr create` — title from branch name, body from latest commit + plan link.
- Do not cleanup the worktree (the user may need to push more commits).

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

## Anti-patterns

- Auto-discarding without explicit confirmation.
- Removing a worktree without a provenance file.
- Force-pushing to main.
- Merging without confirming the base branch.
