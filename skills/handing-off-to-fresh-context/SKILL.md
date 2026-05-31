---
name: handing-off-to-fresh-context
description: Use when context is filling on a long task and you should leave a short note so work resumes cleanly after the conversation is compacted.
---

# Handing off to fresh context

Leave a brief note so a fresh session (or the same session after compaction) can pick the work back up. The note carries *conversational* state the code can't hold — the plan file (checkboxes on disk) remains the real source of truth.

## When to use

- At a clean stopping point — a step finished, tests green, nothing in flight. Best moment.
- When the handoff-nudge hook tells you to (it fires once when context first crosses ~800K tokens).
- When the user runs `/llm-orchestrator:handoff`.

## When NOT to use

- Mid-step with edits in flight or tests red — finish to a clean point first.
- Short tasks that will finish before context strains.

## Steps

1. Pick the path: `docs/llm-orchestrator/handoffs/<date>-<slug>.md` (overwrite in place — never a v2 sibling).
2. Write a few bullets, nothing more:
   - **What's done / what's next** — one line each.
   - **Verify command + its green output** — the exact command and the result you last saw.
   - **Don't-do notes** — anything that emerged this session that isn't obvious from the code.
3. Keep it short. Link to `git diff` / the plan instead of restating them.

## Output shape

Announce as `Changed:` with the note path and the verify line. Don't switch sessions unless context is actually full — the note exists either way.

## Resume contract

On resume, run the verify command first and confirm green before touching anything. If it diverges from the note, debug that first — don't assume the note is current.

## Anti-patterns

- Writing a long document — it's a few bullets, not a report. Cite `git diff` / the plan for detail.
- Duplicating the plan file's checkboxes — the plan file is the source of truth.
- Proceeding on resume without running the verify command first.
