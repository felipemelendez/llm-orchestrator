---
name: writing-plans
description: Use when a spec is approved and implementation has not started. Produces a dated, checklist-shaped plan file that another agent (or you) can execute task-by-task. Not for work already covered by an existing plan, and not before brainstorming has produced the spec.
---

# Writing plans

Plans are short, dated, and checkable. One file per feature. Lives in `docs/llm-orchestrator/plans/`.

## When to use

After `brainstorming` writes a spec and the user approves it. Or when the user hands you requirements directly.

Skip for trivial work (under ~15 minutes of editing). Just do it.

## Steps

0.5. **Research gate (Trigger B).** Before re-reading the spec, scan its `## Approach` section. If the approach names libraries or version-specific APIs that the spec's `## Research` section doesn't already cover (i.e. brainstorming's Trigger A didn't catch them, or the user wrote the spec directly), invoke `research-classifier` against the approach text. If `RESEARCH_NEEDED` fires, dispatch `orch-researcher` with the eight-field envelope in `templates/researcher-prompt.md` (it returns `BLOCKED` on a missing field) and act on its outcome BEFORE writing any plan tasks. `CONTRADICTED` halts the plan write — revise the spec's approach first.

1. **Read the spec.** Re-read every section. Note any "TBD". Confirm `## Research` section is populated (verdict + brief path) or explicitly "none".
2. **Map files.** List every file you will create or modify, with line ranges if obvious. If you can't list them, the spec isn't ready.
3. **Order tasks.** Each task is independent enough to dispatch, or explicitly marked sequential. Where independence matters, declare an `Interfaces:` block per task — `introduces:` (symbols/endpoints/files the task creates) and `consumes:` (what it needs from other tasks). The executor treats declared interfaces as authoritative and falls back to body-scanning only when the block is absent.
4. **For each task, write checkable steps.** 2–5 minutes of work each. Steps include: write test, run test (expect fail), implement, run test (expect pass), commit. Every step must be literal and executable (see the no-placeholder rule below) — the exact command with its expected output line, and the specific change, not a description of it.
4.5. **For each task, write the termination contract** — a `Done when:` line (the observable end state; the verify command's green output is the usual one) and a `Stop if:` line (the abort conditions: N failed fix attempts on the same test, an edit needed outside the task's Files, a budget). An agent with an acceptance criterion but no stop rule knows how to prove success but not when to stop failing — "unaware of termination conditions" is 12.4% of multi-agent failures in the MAST taxonomy (arXiv:2503.13657, N=1642). The dispatcher pastes both lines into the implementer envelope; a fired `Stop if:` returns `PARTIAL` or `BLOCKED`, never more attempts.
5. **Add risks.** One line per risk. Mitigation if obvious.
6. **Self-review.** Run the no-placeholder rule below over the whole plan, and check cross-task consistency: a symbol introduced in one task is referenced by the exact same name in later tasks (no `clearLayers()` in task 2 then `clearFullLayers()` in task 5). Confirm `## References` section pulls citations from the brief (if any).
7. **Save to** `docs/llm-orchestrator/plans/YYYY-MM-DD-<slug>-plan.md`.
7.5. **Plan review — the step-6 self-review is the primary check.** Run it honestly; it catches most real gaps at a fraction of a subagent round-trip's cost. **Escalate to a fresh reviewer subagent only for high-stakes plans** — security-sensitive work, an irreversible migration, 5+ tasks, or a plan whose line-number/command claims you couldn't verify yourself: dispatch a general-purpose subagent with `skills/writing-plans/plan-document-reviewer-prompt.md`, passing the plan and spec paths. Advisory verdict; if `Issues Found`, fix and re-dispatch, cap 3 iterations, then surface what remains to the user rather than blocking.

## How big is a task

A task is the smallest unit that carries its own test cycle and is worth a fresh
reviewer's gate.

Fold setup, configuration, scaffolding and documentation into the task whose
deliverable needs them. Split only where a reviewer could meaningfully reject
one task while approving its neighbour. Every task ends with something that can
be tested on its own.

This is a different question from step size. Steps are minutes of work; a task
is a unit of review. Getting it wrong in either direction is expensive — tasks
too small means a review round per trivial edit, too large means a reviewer
judging four unrelated things behind one verdict.

Write for an engineer with no context for this codebase and no particular
instinct for good test design. That assumption is why the no-placeholder rule
below exists — anything you leave implicit gets filled in with a guess.

## No placeholders (hard rule)

A plan another agent can execute task-by-task has no gaps for them to invent. Forbidden in any step:

- Vague stand-ins: `TODO`, `etc.`, `and so on`, `handle edge cases`, `add validation`, `add error handling`, `wire it up` — name the exact validation, the exact error, the exact wiring.
- Back-references instead of content: `similar to task 3`, `same as above`, `repeat for the others` — spell it out per task.
- A step with no command, or a `run:` step with no expected-output line.

Required in each step instead: the literal change (the actual function/test to write, or the exact edit), the exact command to run, and the exact output line to expect. If you can't write the literal step, the spec isn't ready — go back to brainstorming, don't paper over it with a placeholder.

## Plan format

Use the template at `templates/plan.md`.

```
# <Title> — Plan

Date: YYYY-MM-DD
Spec: docs/llm-orchestrator/specs/YYYY-MM-DD-<slug>-spec.md

## Global constraints

Project-wide requirements every task inherits — version floors, dependency
limits, naming and copy rules, platform targets. One line each, values copied
verbatim from the spec.

A task-scoped implementer never sees the spec preamble. If a constraint lives
only there, it does not reach the agent doing the work, and the reviewer marks
the omission as a defect that was never communicated. Every task's requirements
implicitly include this section, and it gets pasted into every dispatch.

## Goal
- one line

## Files

Map every file to be created or modified **and what each one is responsible
for**. The responsibility annotation is what makes this drive decomposition
rather than being a checklist — files that change together belong in the same
task, and the split follows responsibility, not technical layer.


- create: path/to/new.ts
- modify: path/to/existing.ts:120–180
- test: path/to/new.test.ts

## Tasks

### 1. <task name>
Independent: yes | no (depends on N)
Done when: <observable end state>
Stop if: <abort conditions → PARTIAL or BLOCKED>

Steps:
- [ ] write failing test in <file>
- [ ] run: `<cmd>` — expect: <line>
- [ ] implement <thing> in <file>
- [ ] run: `<cmd>` — expect: <line>
- [ ] commit: `<message>`

### 2. <task name>
...

## Risks
- <risk> — <one-line mitigation or "accept">

## Verify done
- <command> — <expected output>
```

## Output

When done, return:

```
Plan:
- Saved to docs/llm-orchestrator/plans/2026-05-23-<slug>-plan.md
- N tasks, M marked independent
Next:
- /llm-orchestrator:worktree to isolate, then /llm-orchestrator:dispatch task 1
```

## Anti-patterns

- Plans without commands to run.
- "Add validation" as a step (specify what validation).
- Plans where every task depends on the previous one (then it isn't a plan, it's prose — keep it short).
- Plans that re-describe the spec. Reference the spec, don't duplicate it.
