---
name: writing-plans
description: Use when a spec is approved and implementation has not started. Produces a dated, checklist-shaped plan file that another agent (or you) can execute task-by-task. Not for work already covered by an existing plan, and not before brainstorming has produced the spec.
---

# Writing plans

A plan lets another agent — or you after `/clear` — execute task-by-task without re-deriving the design. One dated file per feature: `docs/llm-orchestrator/plans/YYYY-MM-DD-<slug>-plan.md`, copied from `templates/plan.md`. The template is the single source for structure because the executor depends on it mechanically:

- Each `### N. <task name>  - [ ]` heading carries the task-level checkbox — the durable state `dispatching-subagents` ticks and `executing-plans` greps across `/clear`. A heading without it makes progress untrackable.
- Each task's `Files:`, `Done when:`, `Stop if:`, `Owner:`, and optional `Interfaces:` blocks are pasted into the dispatch envelope; `## Global constraints` goes into every dispatch; `## References` carries the verified sources.

Skip planning for trivial work (under ~15 minutes of editing) — just do it.

## Before writing (Trigger B)

Scan the spec's `## Approach` for libraries or version-specific APIs its `## Research` section doesn't already cover, and run `research-classifier` on that text if any appear. Act on the outcome before writing tasks — a `CONTRADICTED` brief halts the plan and sends the spec back for revision, because every task written against a contradicted approach is a task an implementer will execute faithfully and wrongly. Then re-read the whole spec; note any TBD, and confirm `## Research` is populated or explicitly "none".

## Tasks

A task is the smallest unit worth a fresh reviewer's gate; a step is 2–5 minutes of work inside one. Split only where a reviewer could meaningfully reject one task while approving its neighbour; fold setup, config, and docs into the task whose deliverable needs them. Every task ends with something testable on its own, and its steps carry the full cycle: write test, run it (expect fail), implement, run it (expect pass), commit. Where files change together, they belong to the same task — split by responsibility, not technical layer.

Every task carries a termination contract:

- `Done when:` — the observable end state, usually the verify command's green output.
- `Stop if:` — the abort conditions: N failed fix attempts on the same test, an edit needed outside the task's `Files:`, a budget. An agent with an acceptance criterion but no stop rule knows how to prove success but not when to stop failing — unawareness of termination conditions is one of the most common multi-agent failure modes (MAST, arXiv:2503.13657). A fired `Stop if:` returns `PARTIAL` or `BLOCKED`, never more attempts.
- `Interfaces:` where independence matters — `introduces:` (symbols/endpoints/files the task creates) and `consumes:` (what it needs from other tasks). The executor treats declared interfaces as authoritative and body-scans only when the block is absent.

Add a `## Risks` line per risk, with the mitigation when it's obvious.

## No placeholders

Write for an engineer with no context for this codebase and no instinct for good test design — whatever the plan leaves implicit gets filled in with a guess. So every step states the literal change (the actual test or edit), the exact command, and the expected output line. `add validation`, `handle edge cases`, `wire it up`, `similar to task 3` are gaps wearing a costume: name the exact validation, the exact error, and spell it out per task. If you can't write the literal step, the spec isn't ready — go back to brainstorming rather than papering over the hole.

## Self-review

Re-read the whole plan against the no-placeholder rule, plus cross-task consistency: a symbol introduced in one task is referenced by the exact same name in later tasks (no `clearLayers()` in task 2 becoming `clearFullLayers()` in task 5 — the executor won't reconcile them). Confirm `## References` pulls citations from the brief. This honest pass is the primary check. Escalate to a fresh reviewer subagent (prompt: `skills/writing-plans/plan-document-reviewer-prompt.md`, with the plan and spec paths; advisory verdict, cap 3 iterations, then surface what remains) only for high-stakes plans: security-sensitive work, an irreversible migration, 5+ tasks, or line-number/command claims you couldn't verify yourself.

## Output

```
Plan:
- Saved to docs/llm-orchestrator/plans/YYYY-MM-DD-<slug>-plan.md
- N tasks, M marked independent
Next:
- /llm-orchestrator:worktree to isolate, then /llm-orchestrator:dispatch task 1
```
