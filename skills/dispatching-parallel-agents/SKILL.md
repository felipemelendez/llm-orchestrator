---
name: dispatching-parallel-agents
description: Use when 3+ tasks are independent (no shared files, no order dependency) and can be done concurrently. Fan-out only — per-task review happens after all return, not inside this skill.
---

# Dispatching parallel agents (fan-out)

Send N implementers in one batch. Collect N returns. Then review.

## When this applies

- 3+ tasks all marked `Independent: yes` in the plan.
- No two selected tasks touch the same files.
- You understand each task well enough to write a complete envelope.

## When this does NOT apply

- Tasks have dependencies → use `dispatching-subagents`.
- Two tasks share files → conflicts will corrupt the work; use sequential.
- You haven't understood the problem → don't parallelize confusion.
- Fewer than 3 independent tasks → just go sequential; the coordination cost wins.

## Steps

1. **Confirm independence.** For each pair of tasks, ask: "if I do these in opposite order, does the result change?" Yes → not independent → sequential.

2. **Confirm no file overlap.** Read each task's `Files:` list. If any file appears in two tasks, sequential.

3. **`TaskCreate` the set.** One task per plan task. Mark all `in_progress` via `TaskUpdate`.

4. **Build N envelopes** using `templates/implementer-prompt.md` (or `templates/dispatch-prompt.md` for non-implementer roles). Each envelope is self-contained — paste context, never reference paths.

5. **Send in parallel.** In a single message, dispatch all N agents.

6. **Wait for all returns.** Don't dispatch follow-ups before all N return.

7. **Triage each Status:**
   - `DONE` → mark the task `completed` via `TaskUpdate`, tick plan checkbox.
   - `DONE_WITH_CONCERNS` → record, mark completed.
   - `BLOCKED` → satisfy `Need:`, re-dispatch just that one.
   - `NEEDS_CONTEXT` → answer `Ask:`, re-dispatch just that one.

8. **Check for conflicts.** Parallel implementers usually leave changes in the working tree (not yet committed). To detect overlap:
   ```bash
   # Files touched in the working tree across all parallel implementers
   git status --porcelain | awk '{ print $2 }' | sort | uniq -d
   # If implementers DID commit (each commit-per-task), also check:
   git log --since="<start of group>" --name-only --pretty=format: | sort | uniq -d
   ```
   Any duplicate file means two implementers edited the same path. If non-empty:
   - Read each touched line range with `git diff <file>`.
   - You (the controller) reconcile by hand. Never let implementers merge each other.
   - Re-run the relevant tests after merge.

9. **Then review.** After all N are `DONE`, run a per-task spec-review and code-review pass (the inner loop from `dispatching-subagents` steps 3–6), or invoke `/review` once on the combined diff. Choose based on:
   - High-risk surface (public APIs, security paths): per-task review.
   - Low-risk surface (independent UI tweaks, parallel test additions): combined review.

## Sizing

- Sweet spot: 3–5 parallel agents.
- More than 8: re-think the decomposition.
- Don't mix parallel implementers with parallel reviewers — review is sequential to implementation.

## Continuous execution

Same rule as `dispatching-subagents`: don't pause between fan-out and review unless the user is genuinely needed.

## Output shape

After all return:

```
Found:
- Dispatched <N> agents in parallel
- DONE: <list>
- DONE_WITH_CONCERNS: <list>
- BLOCKED: <list>
- NEEDS_CONTEXT: <list>
Conflicts:
- <file> edited by agent A and B — merged into <commit>  (or "none")
Verify:
- <combined test command> → <line>
Next:
- /review the combined diff  (or per-task review pass if high-risk)
```

## Anti-patterns

- Parallel agents on the same file.
- Dispatching parallel before understanding the failure mode.
- Trusting a `DONE` without `Verify:` matching.
- Dispatching 10 agents because you can; coordination cost dominates.
- Forgetting to mark tasks `completed` via `TaskUpdate` → state drifts.
