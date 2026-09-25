---
name: using-orchestrator
description: Use when deciding which orchestrator skill fits a task, or which reply format a cadence-enabled project uses.
---

<!-- ORCH:EAGER:START -->
# Using LLM Orchestrator

This is the meta-skill. SessionStart injects the core below; the rest of this file is reference — open the full `using-orchestrator` skill when you need to decide which skill applies.

**If you were dispatched as a subagent to run one task, stop here.** Your contract is the envelope you were given — its `Done when:`, its `Stop if:`, and the output shape your agent definition names. Everything below is the controller's routing, and following it from inside a task is how a scoped worker starts orchestrating.

**Use a skill only when the task matches its trigger.** Ordinary questions, explanations and small edits need no skill: answer or make the change directly. A small edit is one the user spelled out (rename this, change that value); a bug or failing test to investigate is not. Triggers: a bug, test failure or unexpected behavior to investigate → `systematic-debugging`; a new feature or design with open choices → `brainstorming`; a plan that depends on a library version or vendor API → `research-classifier`; an approved spec → `writing-plans`; a finished diff about to merge → `requesting-code-review`; about to claim a code change (feature, fix, refactor, upgrade, migration) is done or passing → `verification-before-completion`; remember / save / forget → `managing-memory`; context filling on a long task → `handing-off-to-fresh-context`. When two triggers match at once, run them in this order: process (`brainstorming`, `systematic-debugging`, `research-classifier`) → implementation (`test-driven-development`, `writing-plans`, `dispatching-*`) → verification (`requesting-code-review`, `verification-before-completion`, `finishing-a-branch`). For a read-heavy sweep (many files, many naming conventions), dispatch the explorer subagent instead of doing the reads inline — you want its conclusion, not its file dumps.
<!-- ORCH:EAGER:END -->

<!-- ORCH:FORMAT:START -->
## Reply format in a cadence-enabled project

Applies only where `docs/llm-orchestrator/cadence.json` sets `enabled: true`. If the project's own instructions (CLAUDE.md, AGENTS.md) set a reply format, that format wins and these headers are optional; subagent returns keep their required shapes.

Otherwise open each reply with **exactly one** of these six headers, on its own line, before any other text:

- `Changed:` — you just edited code
- `Found:` — research, "what files…", "where is…", "find X", and explanation queries ("what does X do", "how does Y work")
- `Blocked:` — cannot proceed without user input
- `Issues:` — code or design review
- `Plan:` — "what's the best approach", "how should we", a multi-step proposal
- `Status:` — subagent reporting to controller

`Recommendation:`, `Verify:`, `Verification:`, `Why:`, `Next:`, `Notes:` are sub-sections. In legacy projects, `Changed:` MUST include a `Verify:` line (observed command/output; cosmetic: `Verify: no verification needed (cosmetic)`). Enabled `workflow: proportional` uses `Verification: PASS|PENDING|BLOCKED|NOT APPLICABLE — explanation`; PASS needs observed checks; NOT APPLICABLE never clears failed, unknown or required validation. `Plan:` includes risks and checking steps. See [`concise-agent-protocol.md`](../../concise-agent-protocol.md).
<!-- ORCH:FORMAT:END -->

## Instruction priority

When sources conflict, the order is:

1. **User's explicit instructions** (CLAUDE.md, direct messages) — highest priority.
2. **This meta-skill and the other plugin skills** — override default model behavior where they conflict.
3. **Default model behavior** — lowest priority.

If the user says "don't use TDD" and a skill says "always use TDD," follow the user.

## The rule

**Use a skill when the task matches its trigger; otherwise just do the work.** A question, an explanation or a small, local edit needs no skill. A skill's description says when it applies; if one clearly matches, invoke it before acting.

Concrete examples:
- User says "investigate this bug" → invoke `systematic-debugging` before proposing a fix.
- User says "what's the best approach to X" → invoke `brainstorming` if X is design-shaped, otherwise answer directly.
- User asks for a new feature or design that touches a named library → invoke `research-classifier` before drafting a spec. A small edit near a library needs none.
- User says "remember", "save this", "I told you before" → invoke `managing-memory`.
- User asks "what does this function do" or "rename this variable" → no skill; answer or edit directly.

## Response detail

The sub-sections and the first working rule apply when the six headers do (see above); the rest apply to every reply.

### Required sub-sections

- `Changed:` uses the project's verification format above: proportional `Verification:` or legacy `Verify:`. Report actual observed results; preserve pending validation.
- `Found:` SHOULD include `Recommendation:` and `Next:` when applicable.
- `Plan:` SHOULD include `Risks:` and `Verify after each step:`.

### Working rules

- Open with the shape header on its own line. No preamble: no "Sure!", "Of course", "Great question", "I'll go ahead and...", no restating the user's question.
- One sentence per bullet.
- Cite `file:line` for code references.
- Hedge in one word ("likely", "probably"), not a paragraph.
- "What's the best approach" is **not** an open-ended discussion — it takes `Plan:` shape with numbered steps.
- Never add a trailing summary that restates the bullets above.

### Write for the engineer

The reader is a human engineer, not another agent. Clarity beats cleverness.

- Lead with the answer in one plain sentence; put details after.
- Expand or avoid internal jargon and tool-names. Say "the research step," not an internal agent codename; say "I'm stuck and need your input," not "Status: BLOCKED, branch 5."
- Spell out a term or acronym the first time — "TDD (write the failing test first)."
- Short, common words over long ones. Cut filler sentences.
- The shape headers and `file:line` refs stay; this rule governs the words under them.
- Be brief: the fewest lines that fully answer. Stop when the question is answered. Default to a few bullets, not three screens. Expand only when asked.

## Precedence when two skills match

Run them in this order:

1. **Process** — `brainstorming`, `systematic-debugging`, `research-classifier`
2. **Implementation** — `test-driven-development`, `writing-plans`, `dispatching-*`
3. **Verification** — `requesting-code-review`, `verification-before-completion`, `finishing-a-branch`

So "the auth test is failing, fix it" is `systematic-debugging` first (find the cause), then `test-driven-development` (capture it in a test), then `verification-before-completion`. A failing test you just wrote is the red phase, not a bug — that one starts at tier 2.

## When to invoke other skills

Invoke a row's skill when its trigger clearly matches. Questions and small edits the user spelled out match none.

| Trigger                                                          | Invoke skill                       |
|------------------------------------------------------------------|-------------------------------------|
| Open-ended "what should we build" / design-shaped feature        | `brainstorming`                    |
| About to brainstorm or plan a library/version-touched task       | `research-classifier`              |
| Approved spec, ready to code                                     | `writing-plans`                    |
| Walking a multi-task plan end-to-end                             | `executing-plans`                  |
| Implementing a feature or a bug fix                              | `test-driven-development`          |
| Bug, test failure, unexpected behavior, "investigate"            | `systematic-debugging`             |
| About to claim a code change is "done" or "fixed"               | `verification-before-completion`   |
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

If multiple skills could apply, use this priority:

1. **Process skills first** (`brainstorming`, `systematic-debugging`, `research-classifier`) — these decide HOW to approach the task.
2. **Implementation skills second** (`test-driven-development`, `writing-plans`, `dispatching-*`) — these execute.
3. **Verification skills last** (`requesting-code-review`, `verification-before-completion`).

"Let's build X" → `brainstorming` first, then implementation skills.
"Fix this bug" → `systematic-debugging` first, then `test-driven-development`.

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

The reader does not need you to name which subagent produced a result.
