---
description: Land the current branch through a pull request (the default), or merge locally, keep or discard. Nothing destructive without confirmation.
---

You are running `/llm-orchestrator:finish`.

User input: $ARGUMENTS (optional — chosen option number 1-4)

Preconditions:
- `/llm-orchestrator:verify` returned green.
- `/llm-orchestrator:review` verdict is `READY`, or `READY-WITH-FIXES` with the mild findings handled.
- Every task heading checkbox in the plan file is ticked.

If preconditions are not met, stop and report which one.

Steps:

1. Invoke `finishing-a-branch`.

2. Detect environment:
   - Current branch (`git rev-parse --abbrev-ref HEAD`).
   - Detached HEAD?
   - In a worktree (`git rev-parse --git-dir` vs `--git-common-dir`)?
   - Worktree marked (`.orch-worktree` present)?
   - Base branch (`git symbolic-ref refs/remotes/origin/HEAD` or ask).

3. If `$ARGUMENTS` is empty, present the options menu with a one-line recommendation:

```
1. Push and open PR (default)
2. Merge locally into <base> (only when the user picks it)
3. Keep as-is
4. Discard (requires typing "discard")
```

4. On user choice (or `$ARGUMENTS` if provided):
   - **1**: `git push -u origin <branch>`, then `gh pr create --base <base> --head <branch>`
     with a body of Summary / Decisions / Review / Verification / Manual checklist for the
     owner / Open items (the shape is in `finishing-a-branch`). When merging is authorized
     and the PR's checks are green: `gh pr merge <n> --merge`, then
     `git checkout <base> && git pull --ff-only` and run the full suite on the base. Offer
     worktree cleanup only after the merge.
   - **2**: `git checkout <base> && git pull --ff-only && git merge --no-ff <branch>`, then run
     the suite on the merged tree. Offer worktree cleanup.
   - **3**: Print where branch + worktree live.
   - **4**: Require the literal word `discard`. Then delete branch and worktree.

5. Worktree cleanup (only when user accepted):
   - Must have `.orch-worktree` marker.
   - `cd <main repo root>` first.
   - `git worktree remove <path> && git worktree prune`.

6. Report:

```
Changed:
- <pushed and opened PR #N | merged PR #N; suite on <base>: <line> | merged locally | kept | discarded>
- <worktree cleaned up | preserved>
Next:
- <next step>
```

Constraints:
- Never force-push, and never rewrite pushed history. Investigate a rejected push.
- Never delete a worktree without the `.orch-worktree` marker.
- Never auto-discard without the literal `discard` word.
