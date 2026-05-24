---
description: Execute one or more tasks from the current plan. Routes to sequential per-task-review or parallel fan-out based on task independence.
---

You are running `/dispatch`.

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
   - All selected tasks `Independent: yes` and no shared files → invoke `dispatching-parallel-agents` (one batch, no per-task review).
   - One task, or tasks with dependencies → invoke `dispatching-subagents` (sequential, with per-task two-stage review).
   - Mixed → run the independent set first in parallel, then sequential for the rest.

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
- /review on the combined diff (if not already done per-task)
- (or) /verify then /finish
```

Constraints:
- Never dispatch two implementers against the same file.
- Never trust a `DONE` without a `Verify:` line that actually ran.
- Do not pass file paths as "context" — paste the content.
