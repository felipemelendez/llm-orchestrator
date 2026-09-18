---
name: handing-off-to-fresh-context
description: Use when context is filling on a long task and you should leave a short note so work resumes cleanly after the conversation is compacted.
---

# Handing off to fresh context

Leave a brief note carrying conversational state so work survives compaction. Existing task requirements and source remain authoritative; a handoff is not execution evidence.

## When to use

- At a clean stopping point — a step finished, tests green, nothing in flight. Best moment.
- When the handoff-nudge hook tells you to (it fires once when context first crosses 950K tokens).
- When the user runs `/llm-orchestrator:handoff`.

## When NOT to use

- Legacy: mid-step with edits in flight or tests red — finish to a clean point first. Proportional: preserve an honest pending handoff if context pressure interrupts work.
- Short tasks that will finish before context strains.

## Steps

1. Read project cadence configuration. With `enabled: true` and `workflow: "proportional"`, use task-owned scratch outside the repository. Resolve installed `orch-task-resources.py` through the cadence skill; if needed, allocate with `python3 <helper> start --project <root> --task <slug>`. Acquire a consumer lease before writing `<scratch>/handoff.md`. Report the task ID, recovery state path and note path in the conversation. Never adopt arbitrary scratch or another task's note. Missing/legacy workflow or disabled/absent cadence uses `docs/llm-orchestrator/handoffs/<date>-<slug>.md`. Overwrite the same note, never create v2 siblings.
2. Write a few bullets, nothing more:
   - **What's done / what's next** — one line each.
   - **Verification** — actual command/result and trusted receipt pointer if available, plus pending checks or failures. Never turn a remembered result into fresh evidence.
   - **Don't-do notes** — anything that emerged this session that isn't obvious from the code.
3. Keep it short. Release the lease after consumers stop, but retain unfinished task resources. Call helper `finish` only after deliverables are preserved and the note is consumed; pausing or compaction never marks completion.

## Output shape

Announce `Changed:` with the path and the project's `Verification:` (proportional) or `Verify:` (legacy) disposition. Preserve outstanding source obligations. Don't switch sessions unless context is full.

## Resume contract

Proportional: recover the exact task ID/state, inspect helper `status`, and acquire a lease before reading the note. Reconcile against source and pending work. Reuse matching trusted execution evidence while covered inputs remain unchanged; rerun only affected stale, missing, failed or required checks. A turn boundary alone never requires rerunning checks. Retain the note until consumed.

Legacy: run the verify command first and confirm green. If it diverges from the note, debug that first.

## Anti-patterns

- Writing a long document — it's a few bullets, not a report. Cite `git diff` / the plan for detail.
- Duplicating the plan file's checkboxes — the plan file is the source of truth.
- Treating a handoff's prose as proof of passing checks.
