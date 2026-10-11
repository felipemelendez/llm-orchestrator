---
name: finishing-a-branch
description: Use when a branch's work is done and tests pass, to land it through a pull request (the default), or merge locally, keep or discard. Nothing destructive without confirmation.
---

# Finishing a branch

## Proportional cadence

For enabled `workflow: proportional`, finish the cadence's selected path.
Reuse valid checks; validate changed inputs. Land through option 1 below (push,
PR, merge, base checks) without another menu when the laws' Landing rule or the
user authorizes it. Commit/push/merge/discard need authorization. After consumers stop
and work is preserved, finish resources through the task helper: clean disposable
copies; retain unique/dirty/active work and report its path. Stop here; the
preconditions below are for projects without an enabled cadence.

## Preconditions

Before this skill runs:
- `/llm-orchestrator:verify` has been run; tests pass.
- `/llm-orchestrator:review` has been run; the verdict is `READY`, or `READY-WITH-FIXES` with the mild findings already handled.
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

If HEAD is detached, drop options 2 and 4 — there is no branch to merge and none to delete.
Options 1 and 3 still apply; push with `git push origin HEAD:refs/heads/<new-branch>`.

Also confirm this is a worktree and not a submodule before treating it as one:
`git rev-parse --show-superproject-working-tree` returns a path inside a submodule, where
`GIT_DIR != GIT_COMMON_DIR` is true for a different reason.

## Options (always present this menu)

```
1. Push and open PR (default)
2. Merge locally into <base> (only when the user picks it)
3. Keep as-is (no action; come back later)
4. Discard
```

## Behaviors

### 1. Push and open PR (default)
- Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` without its `origin/`
  prefix (`main`, not `origin/main`), or ask.
- `git push -u origin <branch>` (detached HEAD: `git push origin HEAD:refs/heads/<new-branch>`).
  Never rewrite pushed history. Investigate a rejected push; force-push only with explicit
  user authorization.
- One PR per ticket, keeping the project's naming:
  `gh pr create --base <base> --head <branch> --title "<title>" --body-file <file>`. Body:
  ```
  ## Summary — what changed and why
  ## Decisions — choices made, alternatives not taken
  ## Review — verdict, findings and how each was handled
  ## Verification — commands run and their result lines
  ## Manual checklist for the owner — what only a person can check
  ## Open items — what is left, or "None"
  ```
- Merge only when the laws' Landing rule or the user authorizes it and the PR's checks are
  green: `gh pr merge <n> --merge` (a merge commit). Then, in the checkout that holds `<base>`
  (`git worktree list`; from a ticket worktree it is usually the main checkout), `git pull
  --ff-only` and run the full suite there, one suite at a time. Red: stop and report.
- Many tickets: one PR at a time, in merge order, base checks green between them.
- Keep the worktree until the PR is merged, then offer cleanup if marked `.orch-worktree` and
  `git branch -d <branch>`. Not authorized to merge: stop after opening and report the URL.

### 2. Merge locally (opt-out)
- Only when the user chose it. Confirm base branch with user.
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
- Review: READY
Options:
- 1. Push and open PR (default)
- 2. Merge locally into main
- 3. Keep
- 4. Discard (requires "discard" confirmation)
Recommendation:
- 1 — the default; the PR carries the summary and the review record
```

After landing:

```
Changed:
- Pushed feat/x to origin
- Opened PR #142: <title> — <url>
- Merged PR #142 with a merge commit; pulled main
Verify:
- <full suite command on main> → <result line>
Next:
- PR for the next ticket, or none.
```
