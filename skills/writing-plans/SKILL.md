---
name: writing-plans
description: You MUST use this after a spec is approved and before any implementation work begins. Produces a dated, checklist-shaped plan file that another agent (or you) can execute task-by-task.
---

# Writing plans

Plans are short, dated, and checkable. One file per feature. Lives in `docs/llm-orchestrator/plans/`.

## When to use

After `brainstorming` writes a spec and the user approves it. Or when the user hands you requirements directly.

Skip for trivial work (under ~15 minutes of editing). Just do it.

## Steps

0.5. **Research gate (Trigger B).** Before re-reading the spec, scan its `## Approach` section. If the approach names libraries or version-specific APIs that the spec's `## Research` section doesn't already cover (i.e. brainstorming's Trigger A didn't catch them, or the user wrote the spec directly), invoke `research-classifier` against the approach text. If `RESEARCH_NEEDED` fires, dispatch `orch-researcher` and act on its outcome BEFORE writing any plan tasks. `CONTRADICTED` halts the plan write — revise the spec's approach first.

1. **Read the spec.** Re-read every section. Note any "TBD". Confirm `## Research` section is populated (verdict + brief path) or explicitly "none".
2. **Map files.** List every file you will create or modify, with line ranges if obvious. If you can't list them, the spec isn't ready.
3. **Order tasks.** Each task is independent enough to dispatch, or explicitly marked sequential. Where independence matters, declare an `Interfaces:` block per task — `introduces:` (symbols/endpoints/files the task creates) and `consumes:` (what it needs from other tasks). The executor treats declared interfaces as authoritative and falls back to body-scanning only when the block is absent.
4. **For each task, write checkable steps.** 2–5 minutes of work each. Steps include: write test, run test (expect fail), implement, run test (expect pass), commit. Every step must be literal and executable (see the no-placeholder rule below) — the exact command with its expected output line, and the specific change, not a description of it.
5. **Add risks.** One line per risk. Mitigation if obvious.
6. **Self-review.** Run the no-placeholder rule below over the whole plan, and check cross-task consistency: a symbol introduced in one task is referenced by the exact same name in later tasks (no `clearLayers()` in task 2 then `clearFullLayers()` in task 5). Confirm `## References` section pulls citations from the brief (if any).
7. **Save to** `docs/llm-orchestrator/plans/YYYY-MM-DD-<slug>-plan.md`.
7.5. **Plan review — the step-6 self-review is the primary check.** Run it honestly; it catches most real gaps at a fraction of a subagent round-trip's cost. **Escalate to a fresh reviewer subagent only for high-stakes plans** — security-sensitive work, an irreversible migration, 5+ tasks, or a plan whose line-number/command claims you couldn't verify yourself: dispatch a general-purpose subagent with `skills/writing-plans/plan-document-reviewer-prompt.md`, passing the plan and spec paths. Advisory verdict; if `Issues Found`, fix and re-dispatch, cap 3 iterations, then surface what remains to the user rather than blocking.

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

## Goal
- one line

## Files
- create: path/to/new.ts
- modify: path/to/existing.ts:120–180
- test: path/to/new.test.ts

## Tasks

### 1. <task name>
Independent: yes | no (depends on N)

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
- /worktree to isolate, then /dispatch task 1
```

## Anti-patterns

- Plans without commands to run.
- "Add validation" as a step (specify what validation).
- Plans where every task depends on the previous one (then it isn't a plan, it's prose — keep it short).
- Plans that re-describe the spec. Reference the spec, don't duplicate it.
