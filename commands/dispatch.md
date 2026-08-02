---
description: Execute one or more tasks from the current plan. Routes to sequential per-task-review or parallel fan-out based on task independence.
---

You are running `/llm-orchestrator:dispatch`.

User input: $ARGUMENTS — task selector. Forms accepted:
- empty → all remaining unchecked tasks in the latest plan
- `1` → just task 1
- `1,2,4` → tasks 1, 2, and 4
- `1-3` → tasks 1 through 3

Steps:

1. Load the latest plan from `docs/llm-orchestrator/plans/` (or accept `--plan <path>` if passed).

2. Resolve `$ARGUMENTS` into a task set.

3. Use `TaskCreate` (native Claude Code task tool) to create one task per resolved plan task, in plan order. This is your state board for the rest of the run.

4. Decide routing per task by reading its `Independent:` line:
   - All selected tasks `Independent: yes` and no shared files → invoke `dispatching-parallel-agents` (one batch; review happens **after** the batch, not per task — that skill's step 7 does per-task review for high-risk surface and a combined-diff review otherwise).
   - One task, or tasks with dependencies → invoke `dispatching-subagents` (sequential, with per-task two-stage review).
   - Mixed → run the independent set first in parallel, then sequential for the rest.

   Before any parallel batch, satisfy that skill's hard precondition: **every
   writer envelope declares its isolation mode.** Default: run
   `scripts/orch-worktree-materialize.sh` first and give each agent its own
   worktree. Only when the project rules out worktrees, use the declared
   shared-checkout mode ("Steps — shared-checkout writers" in
   `dispatching-parallel-agents`): the exact line
   `shared checkout; controller-partitioned file ownership` plus that writer's
   exclusive files, pairwise-disjoint lists across writers, a stated writer
   cap, and no locks or hold-markers from anyone. "Never dispatch two implementers against the same
   file" alone is weaker than either mode and does not substitute for one —
   undeclared writers in one checkout race on every file, not just the ones
   they both edit. An envelope declaring neither mode dispatches a writer that
   fails closed (BLOCKED).

   For a multi-tier plan, drive it through `executing-plans` rather than calling
   the dispatch skills directly: it owns the post-group assertions and the
   tier-boundary handoff that routing straight to a dispatch skill skips.

5. Follow the invoked skill exactly. After each task completes, mark its task `completed` via `TaskUpdate` and tick the plan checkbox in the plan file.

6. Continuous execution: do not ask the user between tasks. Stop only on unresolvable `BLOCKED`, genuine ambiguity, or all-done.

7. When the task set is empty, report:

```
Found:
- Dispatched <N> subagents
- DONE: <list of task numbers>
- DONE_WITH_CONCERNS: <list>
- BLOCKED: <list, if any>
Next:
- /llm-orchestrator:review on the combined diff (if not already done per-task)
- (or) /llm-orchestrator:verify then /llm-orchestrator:finish
```

Constraints:
- Never dispatch two implementers against the same file.
- Never trust a `DONE` without a `Verify:` line that actually ran.
- Do not pass file paths as "context" — paste the content.
