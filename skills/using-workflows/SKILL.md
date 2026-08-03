---
name: using-workflows
description: Use when deciding whether an already-chosen fan-out (multi-dimension review, parallel implementation, multi-source research) runs on the Workflow tool or inline. Do not use to decide whether to parallelize at all — that is dispatching-parallel-agents.
---

# Using workflows

Claude Code's `Workflow` tool runs a deterministic JavaScript script that fans out subagents
(`agent()`/`parallel()`/`pipeline()`, structured `schema`, token `budget`, resume). It is a
*preferred Claude-Code-only accelerator* for a few orchestrator layers — not a hard dependency.
The markdown flow stays canonical and portable. See the contract brief at
`docs/llm-orchestrator/research/2026-05-31-workflow-tool-contract.md`.

## When a chosen fan-out should run on the Workflow tool

Whether to fan out at all is `dispatching-parallel-agents`' decision. Once a fan-out is chosen,
route it through a workflow only if all three hold — a fan-out has to earn its coordination cost:

1. **Breadth-first** — the work splits into parts that can run at once.
2. **Independent** — the parts don't share context or depend on each other's output mid-flight.
3. **High enough value** — the result justifies the multiplier (review of a real diff, a real
   migration, a real research sweep — not a one-line edit).

Good fits today: the two-stage code review (`workflows/review-diff.js`), parallel implementation
of genuinely independent plan tasks, high-stakes multi-source research.

**The cost, correctly attributed.** Multi-agent runs use **3–10× the tokens of a single agent on the
same task** ([Anthropic, 2026-01-23](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)).
The widely-quoted **15×** is against *chat*, not against a single agent
([Anthropic, 2025-06-13](https://www.anthropic.com/engineering/multi-agent-research-system)); don't
use it as the bar here. Anthropic publishes no multiplier for dynamic workflows specifically, and
the "5–10× expected tokens" figure in secondary write-ups is not theirs. All directional.

## The isolation invariant (applies inside scripts too)

The worktree half of `dispatching-parallel-agents`' invariant applies here unweakened: **no two
agents write the same working tree at once.** A scripted fan-out has no writer envelope in which
to declare a shared-checkout partition, so writer isolation stays mandatory — it does not relax
just because the fan-out is scripted.

- **Read-only fan-out** (review, research, explore) — the agents only read and report. Safe to
  `parallel()`/`pipeline()` on the shared checkout. `workflows/review-diff.js` is this shape.
- **Writer fan-out** (parallel implementation) — each writing `agent()` is dispatched against a
  worktree created by `scripts/orch-worktree-materialize.sh`, with the path pasted into the agent's
  prompt; the script then merges the branches back sequentially.

**Inside a workflow script, do not use `isolation: 'worktree'`.** (This is scoped to scripted
fan-out, where the engine gives you no hook to fix up what the option gets wrong.
`using-git-worktrees` governs the interactive case.) The native option looks like the right
primitive and is not:
it branches from the **default branch**, not the parent's `HEAD`, unless `worktree.baseRef: "head"`
is set — a *user* setting a plugin cannot ship ([sub-agents](https://code.claude.com/docs/en/sub-agents),
retrieved 2026-08-03). It also provides no slug→path mapping, has no atomic batch rollback, and its
native cleanup skips worktrees still holding work — all three assessed in
`docs/llm-orchestrator/research/2026-07-28-v0.6-platform-drift-brief.md:259`, which rejected the
option for exactly this substitution. `scripts/orch-worktree-materialize.sh` supplies the first
three; worktree removal is handled separately by `scripts/orch-worktree-integrate.sh`.

Be honest about what enforces this: it is a **prompt-level convention, not an API guarantee**.
`agent()` has no `cwd` option, so nothing mechanically stops a writer from editing the shared
checkout. The mechanical backstop is `scripts/hooks/guard-destructive-git.sh`, which blocks
tree-destroying git outside an isolated worktree.

## When to stay inline

- Sequential or interdependent work where each step needs the previous one's result. Most coding
  is this. Forcing it through a workflow pays the multi-agent multiplier for no parallelism.
- Trivial tasks. A single short edit never needs a fan-out.

## Routing — try-then-fallback

There is no deterministic shell signal for whether the Workflow tool is present (the decision is
made by the model at read time), so do not write a shell capability probe — it would assert a
capability it cannot verify. Instead:

1. If the `Workflow` tool is available, run the preferred workflow path.
2. If the tool is absent or errors, run the canonical markdown path for that skill.

There is no `ORCH_WORKFLOWS` switch. This section used to document `=0` / `=1`
overrides; no code anywhere reads that variable — `grep -r ORCH_WORKFLOWS
scripts/` comes back empty, and that grep is the test that matters. (Absence
from `templates/settings.json` proves nothing: real knobs, including the two
hard-guard escape hatches, have gone undeclared there before.) A documented
toggle that does nothing is worse than none — it gets set, and then trusted.

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
- **Size agents for resume.** Replay follows the order agents *started*: cached results stop at the
  first agent that didn't finish, and everything started after it re-runs even if it completed
  ([workflows](https://code.claude.com/docs/en/workflows), retrieved 2026-08-03). Many small agents
  therefore preserve more progress than one long one. Live trade-off: `review-diff.js` batches into
  4 fat skeptics — cheaper in tokens, worse on resume. Deliberate, not accidental.
- **This skill is main-thread-only.** The `Workflow` tool is stripped from every subagent
  ([sub-agents](https://code.claude.com/docs/en/sub-agents), retrieved 2026-08-03), so a dispatched
  agent cannot start a workflow. Only the controller can route here.
- Validate with `tests/validate-workflows.sh` (syntax + a static scan for the banned constructs —
  `node --check` alone does not catch the runtime-throw builtins).

## Anti-patterns

- Routing sequential, shared-context work through a workflow to look sophisticated.
- A shell `orch_workflow_available` probe with no real input signal.
- Re-deriving the security regex (or any gate) inside a script instead of taking it via `args`.
- Claiming the workflow and markdown paths are behaviorally identical.
- One skeptic agent per finding with no cap.
- Fanning out writer agents onto the shared checkout without a materialized worktree path.
