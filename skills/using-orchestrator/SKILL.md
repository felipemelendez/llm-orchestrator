---
name: using-orchestrator
description: Use when starting any session in an LLM Orchestrator project, or when deciding which orchestrator skill applies to the work at hand.
---

<!-- ORCH:EAGER:START -->
# Using LLM Orchestrator

This is the meta-skill. SessionStart injects the core below; the rest of this file (instruction priority, the skill map, subagent dispatch) is reference — open the full `using-orchestrator` skill when a routing call is unclear.

**If you were dispatched as a subagent to run one task, stop here.** Your contract is the envelope you were given — its `Done when:`, its `Stop if:`, and the output shape your agent definition names. Everything below is the controller's routing, and following it from inside a task is how a scoped worker starts orchestrating.

**Skills carry this project's process** — root cause before fix, spec before code, evidence before "done" — the steps that inline improvisation drops under momentum. Each skill's description states when it applies: when the work in front of you matches one, read it and let it shape the work; when nothing matches, proceed — most messages need no skill. When two triggers match at once, order follows the work: process → implementation → verification (decide how, then build, then check).

## Response shape — the hard rule

Every reply opens with **exactly one** of these six headers, on its own line, before any other text:

- `Changed:` — you just edited code
- `Found:` — research, "what files…", "where is…", "find X", and explanation queries ("what does X do", "how does Y work")
- `Blocked:` — cannot proceed without user input
- `Issues:` — code or design review
- `Plan:` — "what's the best approach", "how should we", a multi-step proposal
- `Status:` — subagent reporting to controller

`Recommendation:`, `Verify:`, `Why:`, `Next:`, `Notes:` are sub-sections, never the top-level header. `Changed:` MUST include a `Verify:` line (a real command + its output; for cosmetic edits write `Verify: no verification needed (cosmetic)`). `Plan:` should include `Risks:` and a verify-after-each-step note. Lead with the answer in one plain sentence, cite `file:line`, no preamble, no trailing summary, be brief. Canonical reference: [`concise-agent-protocol.md`](../../concise-agent-protocol.md).
<!-- ORCH:EAGER:END -->

## Instruction priority

When sources conflict, the order is:

1. **User's explicit instructions** (CLAUDE.md, direct messages) — highest priority.
2. **This meta-skill and the other plugin skills** — override default model behavior where they conflict.
3. **Default model behavior** — lowest priority.

If the user says "don't use TDD" and a skill says "always use TDD," follow the user.

## When a skill applies

The catalog exists because certain failures repeat under momentum: patching a symptom instead of the cause, drafting a spec against a remembered API surface, claiming done without running anything. Each skill encodes the counter-procedure, and its frontmatter description states the trigger.

The judgment call is yours, and the cost asymmetry is worth knowing when you make it: a skill opened and discarded costs a few hundred tokens; a procedure skipped costs a rework cycle. So a plausible trigger match is worth the read, a clear non-match is not, and no skill is a substitute for thinking about the task itself.

## Skill map

The triggers in one place. Each skill's own description is authoritative; this table is the map.

| Work in front of you                                             | Skill                              |
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
| Fan-out already chosen — script it or run it inline?             | `using-workflows`                  |
| Diff is ready for review                                         | `requesting-code-review`           |
| Reviewer returned issues                                         | `receiving-code-review`            |
| Branch green, deciding what to do                                | `finishing-a-branch`               |
| User says "remember", "I told you", "save this", "forget"        | `managing-memory`                  |
| Context filling on a long task, or about to be compacted         | `handing-off-to-fresh-context`     |
| Adding or editing a skill                                        | `writing-skills`                   |

When two rows match at once, the order follows the work — process → implementation → verification:

1. **Process** (`brainstorming`, `systematic-debugging`, `research-classifier`) decides how to approach the task.
2. **Implementation** (`test-driven-development`, `writing-plans`, `dispatching-*`) executes.
3. **Verification** (`requesting-code-review`, `verification-before-completion`, `finishing-a-branch`) checks.

So "the auth test is failing, fix it" is `systematic-debugging` first (find the cause), then `test-driven-development` (capture it in a test), then `verification-before-completion`. A failing test you just wrote is the red phase, not a bug — that one starts at tier 2.

## Response detail

The eager core above carries what the per-turn grader checks. The rest — required sub-sections per shape, the working rules, the write-for-the-engineer guidance — is defined once in [`concise-agent-protocol.md`](../../concise-agent-protocol.md); read it there rather than from a copy here.

## Dispatching subagents

Read-heavy and specialized work goes to dedicated subagents through the `Agent` tool (`TaskCreate` manages the task list; it dispatches nothing) — each runs in its own fresh context. The exact `subagent_type` names and their models are listed in the Agent tool's agent roster; the dispatch skills (`dispatching-subagents`, `requesting-code-review`, and others) name the specific one to use at each step. The orchestrator does not write subagent prompts inline — it dispatches the declared agents.

The roster covers, by role:

- a read-only explorer for audits, "what files handle X", and grep-sweeps;
- an implementer that runs one plan task at a time;
- a spec reviewer and a code reviewer for the two-stage review, plus an optional security reviewer;
- a debugger for root-cause investigation;
- a researcher that verifies external API claims against current sources.

When a task is read-heavy (audit, "what files handle X", grep-sweeps), **dispatch a read-only explorer instead of doing the reads inline** — the win is context, not cost: the sweep's output stays out of the controller's window.

Delegate for size, not reflexively. Current models delegate readily on their own, and a subagent costs a fresh context that must re-gather what the controller already knows. If you can finish it in a handful of tool calls, do it inline. If one agent can do it, use one.

When a task is design-shaped (new feature, multi-step build), **go through `brainstorming` → spec → `/llm-orchestrator:plan` → `/llm-orchestrator:dispatch`.** Don't implement features inline when the orchestration path exists.

The shape header at the top of every reply is the signal that a skill ran. The reader doesn't need you to name which subagent produced it.
