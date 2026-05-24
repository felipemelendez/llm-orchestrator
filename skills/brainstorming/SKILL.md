---
name: brainstorming
description: You MUST use this before any creative work — building features, adding functionality, designing systems, or changing behavior. Explores intent and produces a short spec the user can approve before any code is written.
---

# Brainstorming

Short, structured exploration. No code yet.

## When to use

- "Let's build X"
- "I want to add Y"
- "How should we approach Z"

Skip this skill for one-line fixes, typos, or mechanical chores.

## Steps

1. **Read the room.** Glance at the project (`ls`, `README`, `CLAUDE.md`) so questions are specific.

1.5. **Research gate (Trigger A).** If the user's task mentions a library, framework, SDK, security-sensitive domain, or version-shaped token — or the UserPromptSubmit hook signalled this is research-relevant — invoke the `research-classifier` skill against the raw task text BEFORE asking clarifying questions. Two outcomes:
   - `RESEARCH_SKIP` → proceed to step 2 silently.
   - `RESEARCH_NEEDED` → announce briefly ("Found: research needed (<libraries>). Running pre-spec verification."), dispatch `orch-researcher`, wait for the brief. If outcome is `CONTRADICTED`, surface the contradiction inline and revise the framing before proceeding. If `VERIFIED` or `COULDN'T_VERIFY`, fold the findings into your clarifying questions (e.g., "docs show pattern X is current — do you want that or the older pattern?").

2. **Ask up to 3 questions, one at a time.** Multiple choice when possible. Stop asking the moment the picture is clear.
3. **Propose 2 options.** Each option has: one-line summary, one-line tradeoff. Mark a recommended option.
4. **On user choice, write the spec.** Save to `docs/llm-orchestrator/specs/YYYY-MM-DD-<slug>-spec.md`. If research ran at step 1.5, fill in the spec's `## Research` section with the brief path, verdict, and notable findings. If no research ran, write "none — no research-relevant signals."
5. **Self-review the spec.** Check for placeholders, contradictions, and "TBD".
6. **Hand off to `writing-plans`.**

## Spec format

Use the template at `templates/spec.md`. Required sections:

```
# <Title>

## Problem
- one or two lines

## Goals
- bullet
- bullet

## Non-goals
- bullet

## Approach
- bullet — chosen option, one-line why

## Open questions
- bullet (or "none")
```

Spec is short — one screen. If it's longer, the scope is too big; split it.

## Response shape

When asking questions:
```
Found:
- <one line of context>
Question:
- <single question, A/B/C choices if it fits>
```

When proposing options:
```
Found:
- <one-line restatement of the goal>
Options:
- A: <name> — <one-line tradeoff>
- B: <name> — <one-line tradeoff>
Recommendation:
- A (or B), because <one line>
Next:
- Confirm choice, then I'll write the spec.
```

## Anti-patterns

- Asking 5 questions in one message.
- Writing the spec before the user confirms an approach.
- Proposing 4+ options. Two with a clear recommendation is enough.
- "Comprehensive analysis" of an obvious problem.
