---
description: Create an isolated git worktree for the current task. Marks provenance so cleanup is safe.
---

You are running `/worktree`.

User input: $ARGUMENTS (optional — branch name)

Steps:

1. Invoke `using-git-worktrees`.

2. Determine the branch name:
   - If `$ARGUMENTS` is non-empty, use it.
   - Otherwise derive from the most recent plan filename: `feat/<slug>` or `fix/<slug>`.

3. Determine the directory:
   - Default `.worktrees/<slug>` inside the repo root.
   - If `.worktrees/` is not ignored, add it to `.gitignore` first.

4. Create:
   ```bash
   git worktree add .worktrees/<slug> -b <branch>
   ```

5. Drop provenance marker:
   ```bash
   touch .worktrees/<slug>/.orch-worktree
   ```

6. Detect manifests and install deps (only if a lockfile exists). Skip if user passed `--no-install`.

7. Run baseline test command if obvious. If unclear, skip and ask.

8. Report:

```
Changed:
- worktree at .worktrees/<slug> on branch <branch>
- baseline: <N> passed (or "skipped — unknown test command")
Verify:
- (cd .worktrees/<slug> && <test-cmd>)
Next:
- /dispatch task 1 against this worktree
```

Constraints:
- Never nest a worktree inside another worktree.
- Refuse to create if target exists and isn't empty.
