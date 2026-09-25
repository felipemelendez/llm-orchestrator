---
name: executing-plans
description: Use when driving a written plan to completion, task by task. Routes each task to sequential or parallel dispatch.
---

# Executing plans

The controller that walks a plan from first task to last, routing each group to `dispatching-subagents` or `dispatching-parallel-agents`. The plan file's checkboxes are the only task state; they survive `/clear`.

Use when a plan exists at `docs/llm-orchestrator/plans/`, more than one task remains, and you're the top-level controller. A single task → dispatch it directly. A plan with TBDs → back to `writing-plans` first.

## Steps

1. **Verify the plan's dependency claims before trusting them.** Plans routinely mark tasks `Independent: yes` that aren't: an API spec depends on the routes it documents, tests on the code they exercise, a migration runbook on the migration it describes. If a task declares an `Interfaces:` block, treat it as authoritative — A consumes what B introduces → A depends on B. For tasks without one, scan bodies for symbols, endpoints, schemas, or files that a later task introduces (check those tasks' `Files:` and bodies). When a semantic dependency contradicts `Independent: yes`, fix the plan file in place (downgrade to `depends on B`) and continue — routing on the wrong claim dispatches a writer against ground truth that doesn't exist yet.

2. **Group for routing.** Walk the corrected plan in order: adjacent tasks with `Independent: yes` and no overlapping `Files:` form a parallel group; everything else is a sequential group of one. Groups of 3+ go to `dispatching-parallel-agents`; smaller groups to `dispatching-subagents` — below three, coordination cost beats the speedup.

3. **After each group, assert before moving on:** every finished task's plan-file `- [ ]` is ticked to `- [x]`. The tick is the only state that survives `/clear`, so a missed one is silently lost progress. Then route each `DONE_WITH_CONCERNS` by what the concern touches: correctness, security, or a public contract → address now (re-enter the inner loop with a fix prompt); ergonomics, perf, style, naming → carry into the final review pass, recorded under `## Outstanding concerns` in the plan file; future work ("no eviction policy yet") → record and move on. Treating every concern as "fix now" burns the schedule on polish; carrying a correctness concern forward ships a defect.

4. **At tier boundaries** — a tier completes with a green verify and material work remains — invoke `handing-off-to-fresh-context`: the clean seam is the right moment to write or refresh the handoff note. The handoff-nudge hook (fires once when context first crosses `ORCH_CONTEXT_HANDOFF_TOKENS`, default 950K, re-arming after each compaction) and `/llm-orchestrator:handoff` are fallbacks, not the primary trigger.

5. **Run continuously**, group to group, without asking the user. Stops: unresolvable `BLOCKED`, all groups complete, or a verification failure that needs `systematic-debugging`.

6. **When all groups complete:** run `/llm-orchestrator:verify`. Green → `/llm-orchestrator:review` on the combined diff; `Ready: yes` → `/llm-orchestrator:finish`. Red → `systematic-debugging`, then re-enter dispatch for the affected task.

## Resuming from a handoff

The fresh controller's first action is to run the handoff artifact's verification baseline and confirm green — only then pick up the next task. If verification diverges from the artifact's expected output, invoke `systematic-debugging` on the divergence before proceeding; never assume the baseline is current.

## State invariants

At any point the plan file answers what's done (ticked headings) and what's next (the first unticked heading). When your memory disagrees with it, the plan file wins — it survived `/clear`. The handoff artifact (under `docs/llm-orchestrator/handoffs/`) indexes plan-file checkbox state; it never duplicates or overrides it.

## Output shape

Between groups:

```
Found:
- Group <N> complete: <task numbers> DONE
- Plan checkboxes: <X> ticked, <Y> unticked
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
- /llm-orchestrator:review for combined-diff sweep
- (or) /llm-orchestrator:finish if review already happened per-task
```
