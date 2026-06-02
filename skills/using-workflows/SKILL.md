---
name: using-workflows
description: Use when a breadth-first task fans out into independent subagents (multi-dimension review, parallel implementation, multi-source research) and you're choosing the Workflow tool versus inline.
---

# Using workflows

Claude Code's `Workflow` tool runs a deterministic JavaScript script that fans out subagents
(`agent()`/`parallel()`/`pipeline()`, structured `schema`, token `budget`, resume). It is a
*preferred Claude-Code-only accelerator* for a few orchestrator layers — not a hard dependency.
The markdown flow stays canonical and portable. See the contract brief at
`docs/llm-orchestrator/research/2026-05-31-workflow-tool-contract.md`.

## When to prefer a workflow

All three must hold (Anthropic's cost guidance — multi-agent runs ~15× the tokens of a single
agent, so the fan-out has to earn it):

1. **Breadth-first** — the work splits into parts that can run at once.
2. **Independent** — the parts don't share context or depend on each other's output mid-flight.
3. **High enough value** — the result justifies the multiplier (review of a real diff, a real
   migration, a real research sweep — not a one-line edit).

Good fits today: the two-stage code review (`workflows/review-diff.js`), parallel implementation
of genuinely independent plan tasks, high-stakes multi-source research.

## The isolation invariant (applies inside scripts too)

The same rule as `dispatching-parallel-agents`: **no two agents write the same working tree at
once.** It does not relax just because the fan-out is scripted.

- **Read-only fan-out** (review, research, explore) — the agents only read and report. Safe to
  `parallel()`/`pipeline()` on the shared checkout. `workflows/review-diff.js` is this shape.
- **Writer fan-out** (parallel implementation) — every writing `agent()` MUST take
  `isolation: 'worktree'` so each runs in its own checkout; the script then merges the branches
  back sequentially. Never `parallel()` two writers without it — they would race the shared tree.

So: writer agents → `agent(prompt, { isolation: 'worktree', ... })`; reviewer/research agents →
plain `agent()`. If a script fans out writers without `isolation: 'worktree'`, that is a bug.

## When to stay inline

- Sequential or interdependent work where each step needs the previous one's result. Most coding
  is this. Forcing it through a workflow pays the 15× multiplier for no parallelism.
- Trivial tasks. A single short edit never needs a fan-out.

## Routing — try-then-fallback

There is no deterministic shell signal for whether the Workflow tool is present (the decision is
made by the model at read time), so do not write a shell capability probe — it would assert a
capability it cannot verify. Instead:

1. If the `Workflow` tool is available (and the user has not set `ORCH_WORKFLOWS=0`), run the
   preferred workflow path.
2. If the tool is absent, errors, or the user set `ORCH_WORKFLOWS=0`, run the canonical markdown
   path for that skill. Set `ORCH_WORKFLOWS=1` to force-prefer where a skill leaves it optional.

The two paths are **not** claimed equivalent: the workflow path adds structured findings and an
adversarial verify pass the prose path does not reproduce step-for-step. The markdown path is the
lower-rigor, always-available canonical mode.

## Single source of truth for gates

Workflow scripts cannot `import` shell libraries, so never re-derive gate logic in JavaScript.
The security-sensitive token set lives once, in `scripts/lib/orch-signals.sh`
(`ORCH_SIG_SECURITY_DIFF`). The controller computes the boolean and passes it into the script via
`args`. Same rule for any future gate: compute in shell, pass as `args`.

## Authoring rules

- Begin every script with a pure-literal `export const meta = {...}` (no variables or calls).
- Plain JavaScript only — no TypeScript, no imports. The nondeterministic time/random builtins
  throw at runtime; a token in a prompt string counts, so keep banned names out of strings too.
- `pipeline()` by default; `parallel()` only when a stage needs all prior results (a barrier).
- Reuse existing subagents via `agentType` (e.g. `orch-spec-reviewer`); compose with `schema`.
- Bound any per-finding fan-out so a noisy input can't exhaust the budget.
- Validate with `tests/validate-workflows.sh` (syntax + a static scan for the banned constructs —
  `node --check` alone does not catch the runtime-throw builtins).

## Anti-patterns

- Routing sequential, shared-context work through a workflow to look sophisticated.
- A shell `orch_workflow_available` probe with no real input signal.
- Re-deriving the security regex (or any gate) inside a script instead of taking it via `args`.
- Claiming the workflow and markdown paths are behaviorally identical.
- One skeptic agent per finding with no cap.
- Fanning out writer agents without `isolation: 'worktree'` — they race the shared checkout.
