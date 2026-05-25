# LLM Orchestrator

[![License](https://img.shields.io/github/license/felipemelendez/llm-orchestrator?color=blue)](./LICENSE) [![Last commit](https://img.shields.io/github/last-commit/felipemelendez/llm-orchestrator)](https://github.com/felipemelendez/llm-orchestrator/commits/main) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)

A team of specialized Claude Code subagents — architect, implementer, two reviewers, debugger, explorer, and a researcher that verifies external APIs against current docs before any spec is written. A controller routes work between them: plans tasks, dispatches in parallel where independent, runs two-stage code review on every diff, and recovers from blockers autonomously.

**You delegate. The team executes. You review the diff.**

---

## Quick Start

In a Claude Code session:

```
/plugin marketplace add felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code. The slash menu now includes the orchestrator commands (`/llm-orchestrator:plan`, `/llm-orchestrator:dispatch`, `/llm-orchestrator:review`, `/llm-orchestrator:remember`, …). That's the install verified.

To use the orchestrator on a real task, see [`AGENTS.md`](./AGENTS.md) for the command reference and [`docs/examples/sample-session.md`](./docs/examples/sample-session.md) for a walkthrough.

---

## What it does

| Feature | What it does | Why it matters |
|---|---|---|
| **Research gate** | Verifies the planned approach against current docs (vendor MCPs, Context7, web) and on-disk state before any code is written | Catches deprecated APIs and bad version assumptions before they ship |
| **Two-stage code review** | Spec-compliance reviewer, then code-quality reviewer — each in a fresh subagent context | Catches bugs implementers miss in their own diffs |
| **Autonomous BLOCKED recovery** | When an agent gets stuck, the controller tries four fixes before interrupting you: paste the missing context, run the prerequisite task first, split the work into smaller steps, or retry with a stronger model | Most blockers resolve without paging you |
| **Parallel dispatch** | Independent tasks fan out to multiple implementers in one batch; dependent ones serialize | 3 concurrent implementers ≈ 1 sequential's wall time |
| **Evidence-based completion** | Every "done" claim must include the output of the command that proves it — the test result, the typecheck pass, the linter exit code | Stops agents from declaring code finished without actually running the tests |
| **CLAUDE.md classification** | `/remember <fact>` appends the fact to your project's CLAUDE.md (Claude Code's native memory file) under the right section — `## Conventions`, `## Decisions`, `## People`, or `## Notes` — chosen automatically | Persistent project memory without you having to organize it by hand |
| **Visual brainstorming** | Produces a diagram alongside the spec during the brainstorming phase, making structural choices visible before any code is written | Design decisions are reviewable at a glance rather than buried in prose |
| **Adversarial spec/plan review** | A dedicated adversarial pass challenges the spec or plan for gaps, contradictions, and hidden assumptions before implementation begins | Catches design flaws that both author and standard reviewer miss |
| **Protocol grader** | The Stop hook `scripts/hooks/orch-protocol-grader.sh` grades every controller reply against the six Concise Agent Protocol shapes; non-blocking by default, set `ORCH_STRICT_PROTOCOL=1` to block | Keeps agent output machine-readable and reviewable over long sessions |

---

## The research gate

Most multi-agent kits write code from the model's parametric knowledge alone. This one doesn't. Before `brainstorming` writes a spec, and again before `writing-plans` writes a plan, a deterministic regex sniffer screens the input. If signals match (library mention + version, security verb, architectural change), a classifier decides whether to dispatch the researcher.

**The classifier is biased toward SKIP.** Most tasks don't trigger research, and the default behavior is silent. When it does fire, the researcher (a dispatched subagent, fresh context) returns one of four outcomes:

- `VERIFIED` — docs confirm the plan; proceed.
- `CONTRADICTED` — docs say the plan is wrong; **halts the workflow** until the spec is revised.
- `COULDN'T_VERIFY` — docs unreachable; proceed with low confidence, annotated in the spec.
- `NOT_APPLICABLE` — the question's premise doesn't hold in this repo.

### Two epistemic shapes

Verification questions split into two kinds, and the authoritative source is different for each:

- **SOURCES — "what should be."** Current API surface, recommended pattern, deprecation status, vendor expectations, advisory data. Routed to vendor MCPs first (Stripe MCP for Stripe APIs, etc.), Context7 / DeepWiki for general library docs, GitHub MCP for changelogs and advisories.
- **LOCAL_STATE — "what is."** What's installed, what's in a config file, what an on-disk artifact actually contains. Routed to local `Read`, `Grep`, `Bash`. No MCP is more authoritative than the file itself for state questions.

The gate doesn't replace human review, doesn't verify business logic, and doesn't catch bugs in your own code — only stale knowledge about external API surfaces.

---

## Meet the team

Seven specialists, each with a single responsibility, a model chosen to match its job, and a fresh context window per dispatch. The controller routes work between them using a `Status:` enum (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT).

```
You
 ↓
Controller (the agent you talk to)
 ↓
 ├─ orch-brainstormer   → spec
 ├─ orch-researcher     → verification brief
 ├─ orch-implementer ×N → code (TDD)
 ├─ orch-spec-reviewer  → does the diff match the spec?
 ├─ orch-code-reviewer  → is it idiomatic, safe, minimal?
 ├─ orch-debugger       → root cause
 └─ orch-explorer       → cheap reads (Haiku)
```

| Agent                  | Model  | Job                                                                  |
|------------------------|--------|----------------------------------------------------------------------|
| `orch-brainstormer`    | Opus   | Open-design explorer. Asks 3 clarifying questions, writes the spec.  |
| `orch-implementer`     | Sonnet | Executes one plan task with TDD. Returns `Status:` block.            |
| `orch-spec-reviewer`   | Sonnet | Stage 1 of review: does the diff match the spec?                     |
| `orch-code-reviewer`   | Sonnet | Stage 2 of review: is the code correct, safe, idiomatic, minimal?    |
| `orch-debugger`        | Sonnet | Root-cause investigator. Diagnoses bugs; does not patch them.        |
| `orch-explorer`        | Haiku  | Read-only codebase scout. Returns `file:line` refs. Cheap and fast.  |
| `orch-researcher`      | Sonnet | Verifies external APIs against current sources before any spec.      |

The controller — the agent you interact with — holds state via the native Task tools (`TaskCreate`/`TaskUpdate`/`TaskList`), ticks plan-file checkboxes (which survive `/clear`), runs the BLOCKED recovery tree, and routes tasks to parallel or sequential dispatch.

Adding a role (`orch-refactorer`, `orch-security-reviewer`, `orch-test-writer`) is one new markdown file in `agents/` plus wiring it into a workflow skill or template — `./tests/validate-skills.sh` then confirms shape.

---

## The workflow

Each phase is a skill the controller invokes before acting. Mandatory checks, not suggestions — the controller scans for the relevant skill at every step and refuses to skip.

1. **`research-classifier`.** Fires before any spec is written if signals match (library + version, vendor API, security verb, architectural change). Emits `RESEARCH_NEEDED` or `RESEARCH_SKIP`. On `RESEARCH_NEEDED`, the controller dispatches the `orch-researcher` subagent, which returns a brief with one of four outcomes: `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`. `CONTRADICTED` halts the workflow before the spec is drafted.
2. **`brainstorming`.** Refines the rough idea through clarifying questions, explores alternatives in sections for validation. Writes the spec to `docs/llm-orchestrator/specs/<date>-<slug>.md`.
3. **`using-git-worktrees`.** Isolates the work on a new branch in a dedicated worktree. Captures a green test baseline when one is obvious; defers to the user when it isn't.
4. **`writing-plans`.** Breaks the approved spec into bite-sized tasks (2–5 minutes each). Every task lists exact files, complete code stubs where useful, and verification steps. Plan committed to `docs/llm-orchestrator/plans/<date>-<slug>.md` — its checkboxes are the durable state and survive `/clear`.
5. **`executing-plans` → `dispatching-subagents` / `dispatching-parallel-agents`.** Dispatches a fresh-context subagent per task. Independent tasks fan out in parallel; dependent ones serialize. The controller scans plan-task bodies for symbol references that other tasks introduce and downgrades wrongly-claimed independence to sequential.
6. **`test-driven-development`.** Red-green-refactor inside each implementer: failing test first, watch it fail, write minimal code, watch it pass, commit. If implementation gets written before its test, the skill instructs the implementer to delete it and start over test-first.
7. **`requesting-code-review`.** Two reviewers in fresh contexts per task. Stage 1 — spec compliance: does the diff match what was specified? Stage 2 — code quality: correct, safe, idiomatic, minimal? Issues raised only at ≥80% confidence; lower-confidence observations land in a separate `Notes:` section.
8. **`receiving-code-review`.** When the reviewer returns issues, the controller routes through a 5-branch BLOCKED recovery tree (missing context, sibling wait, decomposition, model escalation, genuinely needs the user). Branches 1–4 resolve invisibly; only branch 5 reaches you.
9. **`verification-before-completion`.** Fires before any "done" claim. Every `Changed:` block must include a `Verify:` line with the actual command run and its output. A per-turn hook reinforces the rule.
10. **`finishing-a-branch`.** Verifies tests pass, presents merge / PR / keep / discard options, cleans up the worktree. Never destructive without explicit confirmation.

---

## When to use / when not to use

**Use it for:**

- Multi-step features (3+ tasks)
- Non-trivial refactors touching multiple files
- Debugging that needs investigation before fixing
- Code review at scale
- Work you want to delegate and walk away from

**Don't use it for:**

- One-line fixes or single-file edits — orchestration overhead exceeds the value

---

## How it works

Eight layers, each solving a specific failure mode of single-agent AI tooling on real multi-step work:

1. **Memory** — additive to Claude Code's native CLAUDE.md, not a replacement. `/remember` auto-classifies facts into `## Conventions` / `## Decisions` / `## People` / `## Notes` of your project's `./CLAUDE.md`, creating sections as needed. `/forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent sessions serialize writes through a portable file lock. Alongside CLAUDE.md, the plugin maintains a TTL-pruned doc cache and a brief index under `~/.llm-orchestrator/research/` that surfaces prior researcher verdicts to future tasks on the same library.
2. **Workflow scaffolding** — skills and commands produce durable artifacts (specs, plans, reviews) committed under `docs/llm-orchestrator/`.
3. **State machine** — the native Task tools plus plan-file checkboxes survive `/clear`. The next session reads the plan file and knows exactly where to resume.
4. **Dispatch routing** — parallel for independent tasks, sequential for dependent. The controller scans plan-task bodies for symbol references to other tasks and downgrades `Independent: yes` to sequential when it spots a real dependency.
5. **Autonomous BLOCKED recovery** — when a subagent returns `Status: BLOCKED`, the controller routes through a 5-branch tree (missing context, sibling wait, decomposition, model escalation, or genuinely needs the user). Branches 1–4 happen invisibly; only branch 5 ever reaches you.
6. **Two-stage code review** — fresh-context reviewers, told explicitly not to trust the implementer. Issues raised only when ≥80% confident; lower-confidence observations go into a separate `Notes:` section.
7. **Evidence-based completion** — every `Changed:` block requires a `Verify:` line with the actual command and its output. A per-turn hook reinforces the rule.
8. **Pre-spec verification — the research gate** — described above. Returns `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`; `CONTRADICTED` halts the workflow until the spec is revised.

Implementation reference with code links and the layer-stack diagram: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Install from source

For contributors and local development:

```bash
git clone https://github.com/felipemelendez/llm-orchestrator
cd llm-orchestrator
./tests/smoke.sh                           # → "All 56 checks passed."
claude --plugin-dir "$(pwd)"               # session-mount the plugin for live iteration
```

Inside that session, edit files in the repo and run `/reload-plugins` to pick up changes without restarting.

Other modes:

- **Persistent symlink.** `./scripts/install.sh --link` then `/plugin marketplace add ~/.claude/llm-orchestrator`.
- **Per-project copy.** `./scripts/install.sh --copy <project-dir>` — copies the plugin into a project's `.claude/` directory.
- **Minimal hook profile.** `ORCH_HOOK_PROFILE=minimal` — bootstrap only; skips per-turn protocol reminders and the research gate.
- **Disable specific hooks.** `ORCH_DISABLED_HOOKS=orch-research-gate,orch-stop`.

Full installation guide: [`docs/install.md`](./docs/install.md). Slash command reference, agent roster, and response-protocol details: [`AGENTS.md`](./AGENTS.md), [`concise-agent-protocol.md`](./concise-agent-protocol.md).

---

## Contributing

Small, opinionated kit. New skills, slash commands, and subagent roles welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the scaffolding pattern, test discipline, and issue format.

---

## License

MIT. See [`LICENSE`](./LICENSE).
