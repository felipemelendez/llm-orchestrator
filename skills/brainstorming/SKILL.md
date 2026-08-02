---
name: brainstorming
description: Use when starting creative work — a new feature, added functionality, a system design, or a behavior change — before any code is written. Not for one-line fixes, mechanical chores, or when an approved spec already exists.
---

# Brainstorming

Short, structured exploration. No code yet.

## When to use

- "Let's build X"
- "I want to add Y"
- "How should we approach Z"

Skip this skill for one-line fixes, typos, or mechanical chores.

## Before you spend questions

If the request describes several independent subsystems — "a platform with chat,
file storage, billing and analytics" — say so immediately. Refining the details
of something that needs decomposing first wastes the questions and produces a
spec nobody can execute. Each sub-project gets its own spec, plan and
implementation cycle.

Cover architecture, components, data flow, error handling and testing. The spec
format below has no slot for error handling or testing, so those are the two that
get forgotten and then get built badly — put them in `## Approach` explicitly.

**Cut ruthlessly.** Remove anything from every candidate approach that the goals
do not require. Over-building is far cheaper to prevent here than to catch in
review, and the reviewer will reject anything it cannot trace to a Goal.

**Cleanup inside the work is in scope; unrelated refactoring is not.** Where
existing code you must touch has problems, include the targeted improvement in
the design — the way a competent engineer improves code they are working in. Say
so explicitly, because anything not traceable to a Goal reads as scope creep
downstream.

**The terminal state is `writing-plans`.** When the spec is approved, invoke
that and nothing else. Do not slide from a design conversation into a UI, MCP,
or framework skill — those are implementation, and implementation follows a plan.

## Steps

1. **Read the room.** Glance at the project (`ls`, `README`, `CLAUDE.md`) so questions are specific.

1.5. **Research gate (Trigger A).** If the user's task mentions a library, framework, SDK, security-sensitive domain, or version-shaped token — or the UserPromptSubmit hook signalled this is research-relevant — invoke the `research-classifier` skill against the raw task text BEFORE asking clarifying questions. Two outcomes:
   - `RESEARCH_SKIP` → proceed to step 2 silently.
   - `RESEARCH_NEEDED` → announce briefly ("Found: research needed (<libraries>). Running pre-spec verification."), dispatch `orch-researcher` with the eight-field envelope in `templates/researcher-prompt.md` (it returns `BLOCKED` on a missing field), wait for the brief. If outcome is `CONTRADICTED`, surface the contradiction inline and revise the framing before proceeding. If `VERIFIED` or `COULDN'T_VERIFY`, fold the findings into your clarifying questions (e.g., "docs show pattern X is current — do you want that or the older pattern?").

1.7. **Architecture grounding (surface, don't ask).** Skip for greenfield projects or trivial edits. For existing codebases with a non-trivial change, apply known decisions as spec constraints. No questions, no dispatching — but state which decisions you're honoring so the user can catch a stale one.
   - Load the library, then call it (the function is not in scope until sourced):
     ```bash
     orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
     L=$(orch_lib orch-arch.sh) && . "$L" && orch_arch_cached "$PWD"
     ```
     Also read the `## Decisions` and `## Conventions` sections of `./CLAUDE.md`. Treat every entry as a constraint the spec must not break.
   - Acknowledge them in ONE line before proposing options, e.g. "Honoring recorded decisions: offline-first via SQLite; data access through the repository layer." This is informational, not a question — if a decision is now wrong, the user can say so.
   - On a cache miss (rc nonzero) with no recorded decisions: apply whatever `## Decisions`/`## Conventions` exist, and at most add one line — "Tip: run `/llm-orchestrator:onboard` once to capture this codebase's architectural decisions." Never a question or interactive prompt.
   - Do not dispatch `orch-explorer`, do not propose `/llm-orchestrator:remember`, do not ask the user anything. Codebase study and decision capture happen once via `/llm-orchestrator:onboard`, not per task.

2. **Ask up to 3 questions, one at a time.** Multiple choice when possible. Stop asking the moment the picture is clear.
3. **Propose 2 options.** Each option has: one-line summary, one-line tradeoff. Mark a recommended option.
4. **On user choice, write the spec.** Save to `docs/llm-orchestrator/specs/YYYY-MM-DD-<slug>-spec.md`. If research ran at step 1.5, fill in the spec's `## Research` section with the brief path, verdict, and notable findings. If no research ran, write "none — no research-relevant signals."
5. **Self-review the spec.** Check for placeholders, contradictions, and "TBD".
5.5. **Spec review — inline by default.** Walk the spec once more against this checklist, inline: no placeholders or TBDs; every Goal has a testable success criterion; Non-goals are stated; the Approach contradicts no recorded `## Decisions` entry; scope matches what the user asked. Fix what you find. An honest inline pass catches most real gaps in seconds; a fresh-subagent round-trip costs minutes for marginal gain at this stage (independence pays off on code diffs, not on a document you just wrote and can re-read cold). **Escalate to a subagent only for high-stakes specs** — security-sensitive, irreversible migration, public API: dispatch a fresh `orch-spec-reviewer` with `skills/brainstorming/spec-document-reviewer-prompt.md`, advisory verdict, cap 3 iterations, surface what remains.
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

## Visual companion (optional)

Offer the browser visual panel **once**, in its own message, only when one or
more upcoming questions are spatial or layout-heavy (wireframes, diagrams,
side-by-side designs). Use the offer wording from `visual-companion.md`.

If the user accepts, read `skills/brainstorming/visual-companion.md` and follow
the operational loop there. For each subsequent question, decide
visual-vs-terminal independently — a UI topic is not automatically a visual
question.

## Anti-patterns

- Asking 5 questions in one message.
- Writing the spec before the user confirms an approach.
- Proposing 4+ options. Two with a clear recommendation is enough.
- "Comprehensive analysis" of an obvious problem.
- Offering the visual panel more than once per session.
