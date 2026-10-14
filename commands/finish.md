---
description: Land the current branch through a pull request (the default), or merge locally, keep or discard. Nothing destructive without confirmation.
---

You are running `/llm-orchestrator:finish`.

User input: $ARGUMENTS (optional — chosen option number 1-4)

Preconditions:
- `/llm-orchestrator:verify` returned green.
- `/llm-orchestrator:review` verdict is `READY`; or `READY-WITH-FIXES` with the mild findings handled; or `NOT-READY` with every blocking finding recorded `refuted`, `settled` or `follow-up` and the mild ones handled (a mild fix that changed behaviour goes back for review first).
- Every task heading checkbox in the plan file is ticked.

If preconditions are not met, stop and report which one. If they are met, this
runs now: a landing verdict is landed in the session it arrives, never held
for a sibling (`finishing-a-branch`'s `references/landing-rules.md`).

Steps:

1. Invoke `finishing-a-branch`.

2. Detect environment:
   - Current branch (`git rev-parse --abbrev-ref HEAD`).
   - Detached HEAD?
   - In a worktree (`git rev-parse --git-dir` vs `--git-common-dir`)?
   - Worktree marked (`.orch-worktree` present)?
   - Base branch (`git symbolic-ref --short refs/remotes/origin/HEAD` without its `origin/`
     prefix, or ask).

3. If `$ARGUMENTS` is empty, present the options menu with a one-line recommendation:

```
1. Push and open PR (default)
2. Merge locally into <base> (only when the user picks it)
3. Keep as-is
4. Discard (requires typing "discard")
```

4. On user choice (or `$ARGUMENTS` if provided):
   - **1**: `git push -u origin <branch>`, then `gh pr create --base <base> --head <branch>`
     with a short, plain-words body of Summary / Decisions / Review / Verification / Manual
     checklist for the owner / Open items, written by `finishing-a-branch`'s
     `references/pr-body.md` for a person who was not in the conversation. When merging is
     authorized and the PR's checks are green: `gh pr merge <n> --merge`, then, in the checkout that
     holds `<base>` (`git worktree list`), `git pull --ff-only` and run the full suite there;
     if none holds it, `git fetch origin <base>:<base>` and run the suite in a new detached
     worktree of `<base>`, removed afterwards. Then merge `<base>` into every still-open ticket
     branch and run its checks (landing rule 5). Offer worktree cleanup only after the merge.
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
