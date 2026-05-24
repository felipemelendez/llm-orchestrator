---
description: Decide what to do with the current branch — merge, PR, keep, or discard. Never destructive without explicit confirmation.
---

You are running `/finish`.

User input: $ARGUMENTS (optional — chosen option number 1-4)

Preconditions:
- `/verify` returned green.
- `/review` verdict is `yes`, or `with-fixes` is fully addressed.
- All tasks for this plan are marked `completed` (`TaskList` shows none in flight).

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
1. Merge locally into <base>
2. Push and open PR
3. Keep as-is
4. Discard (requires typing "discard")
```

4. On user choice (or `$ARGUMENTS` if provided):
   - **1**: `git checkout <base> && git merge --no-ff <branch>`. Offer worktree cleanup.
   - **2**: `git push -u origin <branch>` then `gh pr create --fill`.
   - **3**: Print where branch + worktree live.
   - **4**: Require the literal word `discard`. Then delete branch and worktree.

5. Worktree cleanup (only when user accepted):
   - Must have `.orch-worktree` marker.
   - `cd <main repo root>` first.
   - `git worktree remove <path> && git worktree prune`.

6. Report:

```
Changed:
- <merged | pushed PR #N | kept | discarded>
- <worktree cleaned up | preserved>
Next:
- <next step>
```

Constraints:
- Never force-push.
- Never delete a worktree without the `.orch-worktree` marker.
- Never auto-discard without the literal `discard` word.
