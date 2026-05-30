---
name: executing-plans
description: Use when you have a written plan and need to drive it task-by-task to completion. Top-level orchestrator that routes each task to sequential or parallel dispatch and tracks state.
---

# Executing plans

The controller that walks a plan from first task to last. Calls `dispatching-subagents` or `dispatching-parallel-agents` per task. Tracks state with the native Task tools (`TaskCreate` / `TaskUpdate` / `TaskList`). Persists state in the plan file's checkboxes so `/clear` can resume.

## When to use

- A plan exists at `docs/llm-orchestrator/plans/`.
- More than one task remains.
- You're the controller (top-level session), not a subagent.

## When NOT to use

- A single task → just dispatch directly.
- The plan is unclear or has TBDs → return to `writing-plans` first.

## Steps

1. **Load the plan.** Read every task. Note three lines per task:
   - `Independent:` (yes / no — depends on N)
   - `Files:` (paths the task creates/modifies)
   - Body — to scan for **semantic** dependencies (see step 2).

2. **Compute the real dependency set.** Trust but verify the plan's `Independent:` line:
   - For each task, scan the body for references to symbols, endpoints, schemas, types, or files that another later task introduces (look in those tasks' `Files:` and bodies).
   - If task A references something task B creates, A depends on B — regardless of what `Independent:` says.
   - Common semantic dependencies: API specs depend on the routes they document; tests depend on the code they exercise; migration runbooks depend on the migration they describe.
   - If a semantic dep contradicts the plan, fix the plan file in place (downgrade `Independent: yes` to `depends on B`) and continue.

3. **Group tasks for routing.** Walk the corrected plan in order:
   - Adjacent tasks with `Independent: yes` and no overlapping `Files:` → parallel group.
   - Anything else → sequential group of size 1.

4. **`TaskCreate` one task per plan task** in plan order. Mark each `in_progress` via `TaskUpdate` as you start its group.

5. **For each group:**
   - Size ≥ 3, parallel-eligible → invoke `dispatching-parallel-agents`.
   - Otherwise → invoke `dispatching-subagents`.

6. **After each group completes**, before moving on, run these post-group assertions:
   - Every completed task is marked `completed` via `TaskUpdate`.
   - Every completed task's `- [ ]` in the plan file is ticked to `- [x]`. If not, tick it now (this is the only durable state across `/clear`).
   - `DONE_WITH_CONCERNS` items routed per the policy below.

6a. **Tier-boundary handoff check.** After a tier completes with a green verify and material work remains, check context pressure. If context is past ~50%, invoke the `handing-off-to-fresh-context` skill before starting the next tier — a clean seam is the right moment to hand off. This is the primary handoff trigger; the context-pressure hook and `/llm-orchestrator:handoff` are fallbacks.

7. **DONE_WITH_CONCERNS policy.** Read each concern:
   - Touches **correctness, security, or a public contract** → address now (re-enter the inner loop with a fix prompt).
   - Touches **ergonomics, perf, style, naming** → carry forward into the final `/review` pass; record in the plan file under an `## Outstanding concerns` section.
   - Touches **future work** (e.g., "no eviction policy yet") → record in the plan and move on.

8. **Continuous execution.** Move from group to group without asking the user. Stops only on: unresolvable `BLOCKED`, all groups complete, or a verification failure that needs `systematic-debugging`.

9. **When all groups complete:**
   - Run `/verify`. If green, run `/review` (combined diff). If `Ready: yes`, hand to `/finish`.
   - If `/verify` red, invoke `systematic-debugging` and re-enter step 5 for the affected task.

## Resuming from a handoff

On resuming from a handoff artifact, the fresh controller's first action is to run the artifact's verification baseline commands and confirm green. Only after green does it pick up the next task. If verification diverges from the artifact's expected output, invoke `systematic-debugging` on the divergence before proceeding — never assume the baseline is current.

## State invariants

At any point you should be able to answer:
- "Which task is in flight?" → the task marked `in_progress` (`TaskList`).
- "What's next?" → the next `pending` item.
- "What's done?" → all `completed` items AND the plan-file ticks must agree.

If the task list and plan-file ticks disagree, re-anchor: trust the plan file (it survived `/clear`), reset the tasks (`TaskUpdate`) to match.
- The handoff artifact (under `docs/llm-orchestrator/handoffs/`) indexes plan-file checkbox state and TaskList; it never duplicates or contradicts them — the plan file remains the durable source of truth and the Task tools the in-flight source of truth.

## Output shape

Mid-execution updates (between groups):

```
Found:
- Group <N> complete: <task numbers> DONE
- Tasks: <X> completed, <Y> in flight, <Z> pending
- Plan checkboxes: <X> ticked
Next:
- Starting group <N+1>: <task numbers>
```

Final report:

```
Found:
- Plan complete: <total> tasks
- DONE: <list>
- DONE_WITH_CONCERNS (addressed): <list>
- DONE_WITH_CONCERNS (carried forward): <list>
Verify:
- <full test suite command> → <line>
Next:
- /review for combined-diff sweep
- (or) /finish if /review already happened per-task
```

## Anti-patterns

- Trusting `Independent: yes` without scanning bodies for semantic deps.
- Running the whole plan sequentially when half is independent.
- Running parallel groups without confirming file-overlap absence.
- Asking the user between groups.
- Skipping the post-group plan-checkbox tick — that loses durable state on `/clear`.
- Treating every concern as "address now"; sometimes carry-forward is correct.
