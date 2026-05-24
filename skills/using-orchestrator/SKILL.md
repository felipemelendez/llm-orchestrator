---
name: using-orchestrator
description: Use when starting any session in an LLM Orchestrator project. Establishes the Concise Agent Protocol response shapes and mandates skill invocation before any response or action.
---

# Using LLM Orchestrator

This is the meta-skill. SessionStart injects it. It does two things: (1) lock in the response protocol — every reply opens with one of six fixed shape headers, and (2) tell you when to invoke the other skills.

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. This is not optional. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## Instruction priority

When sources conflict, the order is:

1. **User's explicit instructions** (CLAUDE.md, direct messages) — highest priority.
2. **This meta-skill and the other plugin skills** — override default model behavior where they conflict.
3. **Default model behavior** — lowest priority.

If the user says "don't use TDD" and a skill says "always use TDD," follow the user.

## The rule

**Invoke relevant skills BEFORE any response or action.** Even a 1% match means invoke. If the invoked skill turns out not to apply, you don't have to follow it — but the *check* is non-optional. Skipping the check is the failure mode, not invoking and discarding.

Concrete examples:
- User says "investigate this bug" → invoke `systematic-debugging`. Even if you think you can fix it directly, invoke first.
- User says "what's the best approach to X" → invoke `brainstorming` if X is design-shaped, otherwise reply directly with `Plan:`.
- User asks you to "add" or "implement" anything touching a named library → the research-gate hook will compel; invoke `research-classifier` before drafting a spec.
- User says "remember", "save this", "I told you before" → invoke `memory`.

## Response shape — the hard rule

Every reply opens with **exactly one** of these six headers, on its own line, before any other text:

- `Changed:` — you just edited code
- `Found:` — research, "what files…", "where is…", "find X"
- `Blocked:` — cannot proceed without user input
- `Issues:` — code or design review
- `Plan:` — "what's the best approach", "how should we", multi-step proposal
- `Status:` — subagent reporting to controller

`Recommendation:`, `Verify:`, `Why:`, `Next:`, `Notes:` are **sub-sections** inside one of the six shapes. They are never the top-level header.

Canonical reference: [`concise-agent-protocol.md`](../../concise-agent-protocol.md).

### Required sub-sections

- `Changed:` MUST include `Verify:` (a real command + expected output line). Exception: purely cosmetic edits — then write `Verify: no verification needed (cosmetic)`.
- `Found:` SHOULD include `Recommendation:` and `Next:` when applicable.
- `Plan:` SHOULD include `Risks:` and `Verify after each step:`.

### Working rules

- Open with the shape header on its own line. No preamble: no "Sure!", "Of course", "Great question", "I'll go ahead and...", no restating the user's question.
- One sentence per bullet.
- Cite `file:line` for code references.
- Hedge in one word ("likely", "probably"), not a paragraph.
- "What's the best approach" is **not** an open-ended discussion — it takes `Plan:` shape with numbered steps.
- Never add a trailing summary that restates the bullets above.

## Red flags — thoughts that mean STOP

These thoughts are rationalizations. Treat them as a signal to invoke a skill, not skip one.

| Thought                                  | Reality                                                                   |
|------------------------------------------|----------------------------------------------------------------------------|
| "This is just a simple question"         | Questions are tasks. Check for a matching skill before answering.         |
| "I already know how to do this"          | The skill exists because the default approach fails in non-obvious ways.  |
| "Invoking the skill is overkill here"    | The check is cheap. Skipping is what's expensive.                         |
| "I can do this in one step"              | If a skill applies, invoke it. Decide after.                              |
| "I'll just take a quick look first"      | Looking IS a task. `systematic-debugging` / `orch-explorer` covers it.    |
| "The user wants speed, not process"      | Speed without the protocol is what produced past failures. Follow it.     |
| "This doesn't need a plan"               | If it has 3+ steps or touches a library, write a plan. `writing-plans`.   |
| "I'll skip review, the diff is small"    | Small diffs hide real issues. `requesting-code-review` is mandatory before declaring done. |

## When to invoke other skills

Each row is a directive, not a suggestion. If the trigger matches, invoke.

| Trigger                                                          | Invoke skill                       |
|------------------------------------------------------------------|-------------------------------------|
| Open-ended "what should we build" / design-shaped feature        | `brainstorming`                    |
| About to brainstorm or plan a library/version-touched task       | `research-classifier`              |
| Approved spec, ready to code                                     | `writing-plans`                    |
| Walking a multi-task plan end-to-end                             | `executing-plans`                  |
| Implementing a feature or bugfix                                 | `test-driven-development`          |
| Bug, test failure, unexpected behavior, "investigate"            | `systematic-debugging`             |
| About to claim "done" or "fixed"                                 | `verification-before-completion`   |
| Needs branch isolation                                           | `using-git-worktrees`              |
| Dependent or shared-file task                                    | `dispatching-subagents`            |
| 3+ truly independent tasks, no shared files                      | `dispatching-parallel-agents`      |
| Diff is ready for review                                         | `requesting-code-review`           |
| Reviewer returned issues                                         | `receiving-code-review`            |
| Branch green, deciding what to do                                | `finishing-a-branch`               |
| User says "remember", "I told you", "save this", "forget"        | `memory`                           |
| Adding or editing a skill                                        | `writing-skills`                   |

If multiple skills could apply, use this priority:

1. **Process skills first** (`brainstorming`, `systematic-debugging`, `research-classifier`) — these decide HOW to approach the task.
2. **Implementation skills second** (`test-driven-development`, `writing-plans`, `dispatching-*`) — these execute.
3. **Verification skills last** (`requesting-code-review`, `verification-before-completion`).

"Let's build X" → `brainstorming` first, then implementation skills.
"Fix this bug" → `systematic-debugging` first, then `test-driven-development`.

## Native subagents

Claude Code's `Task` tool dispatches subagents declared in `agents/`. Use them by `subagent_type:` name. The orchestrator does not write subagent prompts inline — it uses these:

- `orch-implementer` — runs one task (Sonnet)
- `orch-spec-reviewer` — stage 1 review (Sonnet)
- `orch-code-reviewer` — stage 2 review (Sonnet)
- `orch-explorer` — read-only scout (Haiku, cheap reads, file searches)
- `orch-debugger` — root-cause investigator (Sonnet)
- `orch-brainstormer` — design-stage explorer (Opus)
- `orch-researcher` — verifies external API claims against current sources (Sonnet)

When a task is read-heavy (audit, "what files handle X", grep-sweeps), **dispatch `orch-explorer` instead of doing the reads inline.** Haiku is roughly a tenth the cost of Sonnet for the same searches.

When a task is design-shaped (new feature, multi-step build), **dispatch through `brainstorming` → spec → `/llm-orchestrator:plan` → `/llm-orchestrator:dispatch`.** The agent does not implement features inline when the orchestration path exists.

The shape block at the top of every reply is the signal that a skill ran. The reader doesn't need you to name which skill produced it.
