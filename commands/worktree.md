---
description: Create an isolated git worktree for the current task, marked so cleanup is safe.
---

You are running `/llm-orchestrator:worktree`.

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
   git fetch origin   # when a remote exists
   git worktree add --no-track .worktrees/<slug> -b <branch> <start>   # <start>: origin/<main>, or origin/<dependency> for a stacked ticket (landing rule 3; a PR number resolves with gh pr view <n> --json headRefName,isCrossRepository, a fork PR or a closed one: start from origin/<main> (rule 4); push the dependency first when it is yours); the local <main> only when there is no remote. --no-track and the remote ref keep a plain push off another owner's branch
   ```

5. Drop provenance marker:
   ```bash
   touch .worktrees/<slug>/.orch-worktree
   ```
   After the first commit on the branch, when a remote exists, open its draft PR so others can
   see it and build on it (landing rule 1): `git push -u origin <branch> &&
   gh pr create --draft --base <base> --fill --head <branch>`, where `<base>` is the branch
   `<start>` named without its `origin/` prefix. Where the plan offers no drafts (a private
   repository on GitHub Free), open a normal PR titled `WIP: ...` instead.

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
- /llm-orchestrator:dispatch task 1 against this worktree
```

Constraints:
- Never nest a worktree inside another worktree.
- Refuse to create if target exists and isn't empty.
