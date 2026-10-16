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
     prefix, or ask). A ticket stacked on an open branch (its `Requires landed:` dependency is
     not landed by landing rule 4's test; a PR number: its `headRefName`; `CLOSED` unmerged or
     `isCrossRepository`: build on the default branch, rule 4) uses that branch as `<base>`; the
     skill's option 1 says the rest.

3. If `$ARGUMENTS` is empty, present the options menu with a one-line recommendation:

```
1. Push and open PR (default)
2. Merge locally into <base> (only when the user picks it)
3. Keep as-is
4. Discard (requires typing "discard")
```

4. On user choice (or `$ARGUMENTS` if provided):
   - **1**: follow `finishing-a-branch` option 1 exactly (push, PR reuse or create, retarget,
     merge, post-merge steps). Offer worktree cleanup only after the merge.
   - **2**: follow the skill's option 2 exactly. Offer worktree cleanup.
   - **3**: Print where branch + worktree live.
   - **4**: require the literal word `discard`, then follow the skill's option 4 exactly.

5. Worktree cleanup (only when user accepted):
   - Must have `.orch-worktree` marker.
   - `cd <main repo root>` first.
   - `git worktree remove <path> && git worktree prune`.

6. Report:

```
Changed:
- <pushed and opened PR #N | merged PR #N; suite on <main>: <line> | merged locally | kept | discarded>
- <worktree cleaned up | preserved>
Next:
- <next step>
```

Constraints:
- Never force-push, and never rewrite pushed history. Investigate a rejected push.
- Never delete a worktree without the `.orch-worktree` marker.
- Never auto-discard without the literal `discard` word.
