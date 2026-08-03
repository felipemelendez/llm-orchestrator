# LLM Orchestrator

[![License](https://img.shields.io/github/license/felipemelendez/llm-orchestrator?color=blue)](./LICENSE) [![Last commit](https://img.shields.io/github/last-commit/felipemelendez/llm-orchestrator)](https://github.com/felipemelendez/llm-orchestrator/commits/main) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)

A team of specialized Claude Code subagents — implementer, spec reviewer, code reviewer, security reviewer, debugger, explorer, and a researcher that verifies external APIs against current docs before any spec is written. A controller routes work between them: plans tasks, dispatches in parallel where independent, runs two-stage code review on every diff, and recovers from blockers autonomously. Where Claude Code now ships a native mechanism (verification, code review, worktree isolation, memory), the plugin delegates to it and keeps only the policy layer — when a step is mandatory, what counts as evidence, and in what order stages run.

**You delegate. The team executes. You review the diff.**

---

## Quick Start

In a Claude Code session, run these one at a time (let the first finish before the second):

```
/plugin marketplace add felipemelendez/llm-orchestrator
```
```
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code. The slash menu now includes the orchestrator commands (`/llm-orchestrator:onboard`, `/llm-orchestrator:plan`, `/llm-orchestrator:dispatch`, `/llm-orchestrator:review`, `/llm-orchestrator:remember`, …). That's the install verified.

On a new project, run `/llm-orchestrator:onboard` first. It studies the codebase once, proposes `## Decisions` and `## Conventions` for `./CLAUDE.md`, and writes them on your approval. Skip it on a brand-new project with no code yet — there is nothing to study.

On a long task, the controller's context window fills up over time and its work quietly degrades. To prevent that, it hands off to a fresh session at a clean boundary between stages — no manual triage needed. You can trigger a handoff yourself at any point with `/llm-orchestrator:handoff`.

To use the orchestrator on a real task, see [`AGENTS.md`](./AGENTS.md) for the command reference and [`docs/examples/sample-session.md`](./docs/examples/sample-session.md) for a walkthrough.

**Requirements:** Claude Code, plus `bash` and `git`. Two optional features have their own dependency: visual brainstorming needs **Node.js** (to run the panel server) and the protocol grader needs **`python3`** (to parse transcripts). If either is missing, that one feature is skipped with a notice — the rest of the orchestrator works normally.

**Model recommendation:** Run Claude Code's controller on **Opus** (or whatever is the latest, most-capable Claude Code model). The orchestrator is tuned for the best available model — multi-stage research, parallel dispatch, two-stage review, and the handoff layer all benefit from Opus-class reasoning. The handoff nudge's ~950K-token (≈95%) default assumes Opus's 1M-token context window; lower `ORCH_CONTEXT_HANDOFF_TOKENS` if you run the controller on a smaller-window model (e.g. Haiku).

---

## What it does

| Feature | What it does | Why it matters |
|---|---|---|
| **Research gate** | Verifies the planned approach against current docs (vendor MCPs, Context7, web) and on-disk state before any code is written | Catches deprecated APIs and bad version assumptions before they ship |
| **Two-stage code review (+ conditional security pass)** | Spec-compliance reviewer gates a code-quality reviewer, each in a fresh subagent context; diffs touching auth/crypto/payments/secrets get a third, security-focused pass. Critical findings must state a concrete failure scenario or they're downgraded. Runs as one parallel, self-checking workflow script when Claude Code's Workflow tool is present; step-by-step anywhere else | Catches bugs implementers miss in their own diffs, without drowning you in false alarms |
| **Safe parallel dispatch + speculative merge queue** | Independent tasks fan out to implementers in isolated per-agent worktrees, claimed atomically in an ownership registry; a guard blocks work-destroying git on the shared tree. Merge-back runs a speculative queue (the Zuul / GitHub-merge-queue discipline): all branches batch onto an isolated integration branch, the suite runs once at the combined tip, and the base only ever fast-forwards to a suite-green SHA — red tips bisect out the regressor and land the tested-green prefix | Agents can't clobber each other's work, N branches land for one suite run instead of N, and the base never holds an untested commit |
| **Autonomous BLOCKED recovery — resume, not redo** | When an agent gets stuck, the controller tries four autonomous fixes before paging you: send the missing context to the SAME agent (a `SendMessage` resume that keeps its partial work and context), run the prerequisite task first, split the work, or retry with a stronger model — only the fifth branch reaches you. A `PARTIAL` status (with `Progress:`/`Remaining:`) means a stop-condition fired: completed work is kept, never redone | Blockers get four chances to resolve themselves before costing you attention, and partial work survives instead of being thrown away |
| **Evidence-based completion** | Every "done" claim must include the output of the command that proves it — and a hook records every real test/lint/build run into a ledger the model never writes. The Stop gate reads that ledger for the current turn: it asks whether a verify command actually ran green since this turn began, so the model is not in the loop at all — nothing to cite, nothing appended to its tool output, and a stale green from an earlier turn does not count. The ledger also records *why* a run was green, so `exit 0` on a suite that executed zero tests is reported rather than accepted | Stops agents from declaring code finished without actually running the tests — including by inventing plausible output, and including when the tests ran but covered nothing |
| **Visual brainstorming** | During brainstorming, a local zero-dependency panel server (you open the printed `localhost` URL) renders live HTML mockups; the agent pushes screens and reads your clicks back, iterating before any code is written | Lets you see and react to UI/layout/structure choices instead of parsing them from prose |
| **One-time onboarding + architecture grounding** | `/llm-orchestrator:onboard` studies the codebase once and records `## Decisions` + `## Conventions` in `./CLAUDE.md` behind a single approval gate; every later spec, implementation, and review silently applies them as constraints, and a diff that breaks a recorded decision is flagged Critical | A new feature can't silently violate an established choice — e.g. adding a network dependency to an offline-first SQLite app |
| **Context-aware handoff** | On a long task, the agent is nudged once (when context crosses ≈95% of the window) to write a short handoff note; after auto-compaction, a reminder tells the next turn to re-read it, reconcile against the plan, and re-verify | A long run continues cleanly across a compaction instead of drifting on a lossy summary |
| **CLAUDE.md classification** | `/llm-orchestrator:remember <fact>` appends the fact to your project's CLAUDE.md under the right section — `## Conventions`, `## Decisions`, `## People`, or `## Notes` — chosen automatically; `/llm-orchestrator:forget` soft-deletes recoverably | Persistent project memory without organizing it by hand |

The mechanics behind these rows — the protocol grader, toolchain detection, convention detection, and the workflow-vs-markdown routing — are documented in [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## What's native vs. what this adds

Claude Code ships first-party versions of several things this kit does. This plugin does not compete with them — it delegates to the native mechanism when present and keeps the layer the harness doesn't enforce: *when* a step is mandatory, *what counts as evidence*, and *in what order* stages run. (Native feature names below were verified against a live Claude Code session on 2026-07-02; the harness evolves fast, so re-verify before building on them.)

| Capability | Native Claude Code | This plugin's layer |
|---|---|---|
| Verification | Native `/verify` skill (manual-only since v2.1.215; builds and runs the app, not the tests) | The gate: no done/fixed/passing claim without pasted evidence, backed by the hook-written evidence ledger |
| Code review | `/code-review`, `/security-review` | Spec-compliance Stage 1 (native review doesn't check the diff against a spec), spec-gates-quality order, failure-scenario rule for Critical findings |
| Worktrees | Per-agent isolated worktrees | Atomic ownership registry, green-baseline capture, speculative test-gated merge queue |
| Memory | CLAUDE.md + auto-memory | Write-side classification (`/llm-orchestrator:remember`) and recoverable `/llm-orchestrator:forget` |
| Planning | Native plan mode | Durable spec/plan artifacts whose checkboxes survive `/clear` |
| Exploration | Built-in Explore agent | `orch-explorer` as the tools-restricted Opus variant with a `file:line` output contract |
| Fan-out orchestration | `Workflow` tool | The when-to-fan-out policy (`using-workflows`) and ready-made scripts like `workflows/review-diff.js` |

Still exclusively this plugin's ground: the Concise Agent Protocol response shapes, the research gate, TDD and root-cause-first debugging enforcement, and the BLOCKED recovery tree. Full map with the delegation rules: [`docs/anthropic-ecosystem.md`](./docs/anthropic-ecosystem.md).

## How is this different from Superpowers or Everything Claude Code?

Fair question — from the outside they look similar (skills, agents, workflows). They occupy different points on one axis: **how much of the system still works on the turns the model ignores its instructions.**

**[Superpowers](https://github.com/obra/superpowers)** is a skills library — genuinely good written discipline (TDD, systematic debugging, plan execution, worktrees) that this plugin's own skill catalog descends from. Its enforcement surface is one session-start hook that loads the skill index; from there on, every rule holds only if the model chooses to follow it, every turn (verified on disk against v6.2.0, 2026-07-29).

**[Everything Claude Code (ECC)](https://github.com/affaan-m/everything-claude-code)** is a breadth play: a very large catalog of agents, skills, rules, and hooks spanning Claude Code, Cursor, Codex, and OpenCode. If you want one resource that covers many harnesses and many workflows, that's the one — this plugin doesn't try to compete on surface area.

**LLM Orchestrator is depth on a single question: can you trust the result without having watched the work?** It bets everything on one harness (Claude Code's hook events) and wires the *policy* into machinery that checks the model's actual behavior:

| The failure | What this plugin does about it — mechanically |
|---|---|
| Agent claims tests passed without running them | A hook records every real test run into a ledger the model never writes; the Stop gate reads that ledger for the current turn rather than trusting the reply, so invented evidence has nothing behind it and a stale green does not carry over |
| Two agents write the same files at once | Atomic per-worktree locks plus a guard that physically blocks work-destroying git commands — for the controller *and* every subagent |
| Broken parallel work reaches your branch | A speculative merge queue tests the combined result and only ever fast-forwards your branch to a state the suite passed on |
| Plan built on a hallucinated or outdated API | A pre-spec research gate whose `CONTRADICTED` verdict **halts the workflow** until the plan is revised |
| Agent loops on the same failing action | A breaker detects the identical action repeated 3× in a row and intervenes |
| Agent quits halfway; silence reads as success | Empty returns are flagged as failures; every task carries `Done when:` / `Stop if:`, with an honest `PARTIAL` status that preserves finished work |
| "Does any of this actually help?" | A committed eval benchmark (`tests/evals/results/benchmark.json`) — including the cases where the plugin does **not** help |

**When to choose which.** They compose: this plugin alongside an instruction library is a sensible setup, and both neighbors are better choices for what they're best at — Superpowers for a battle-tested skill catalog with a big community, ECC for cross-harness breadth. Choose LLM Orchestrator for the thing written guidance alone cannot provide: delegating multi-step work and trusting the *result* — claims that are verifiable and failures that are recoverable — rather than trusting the model's compliance.

---



**Grounding.** The design follows the published evidence rather than habit: methodology-level scaffolding still swings agent results by 20+ points even on frontier Anthropic models (GAIA scaffold comparison, [arXiv:2606.08529](https://arxiv.org/abs/2606.08529)); incorrect or absent verification is a leading cause of multi-agent failure (MAST taxonomy, [arXiv:2503.13657](https://arxiv.org/abs/2503.13657)); LLM code reviewers systematically over-flag correct code — and prompts asking for more explanation make it *worse*, not better; the paper's own countermeasure is a fix-guided filter that treats a proposed correction as **executable** counterfactual evidence ([arXiv:2603.00539](https://arxiv.org/abs/2603.00539)), which the skeptic pass in `workflows/review-diff.js` now implements — every finding carries a proposed fix, and skeptics execute it in a scratch copy where the claim is runnable, labelling survivors `verifiedBy: executed`, `reasoned`, or `unverified`; and duplicated mechanics are a liability as the platform absorbs them (Anthropic, [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)). Hence: keep the policy, delegate the mechanics.

---

## Safe parallel work — agents can't overwrite each other

Running several agents at once is only useful if they don't clobber each other. The danger: when two agents edit the same project at the same time, one can silently overwrite the other's work — and you don't find out until it's gone. (That happened to us in development — a background agent ran a routine git cleanup and wiped another agent's in-progress changes.)

This system makes that collision impossible by construction, not by asking agents to be careful:

1. **Each writing agent gets its own copy of the project.** Read-only agents (the reviewers, the researcher) share the one project safely. Any agent that *writes* code works in a separate folder on its own branch — so two writers can't touch the same file. A small ledger tracks who owns which copy, and claiming one is all-or-nothing, so two agents can never grab the same workspace. When a project rules out separate copies, writers may share the one checkout only under an explicitly declared, controller-partitioned file ownership (disjoint exclusive file lists, a stated writer cap, no locks or hold-markers) — the file list, not a lock, is then the boundary.

2. **Inside its own copy, an agent is free — including to test however it likes.** It can stash, reset, and clean to run tests on a clean tree, because the only work it can affect there is its own disposable copy.

3. **On the shared main project, dangerous git is blocked.** A guard refuses the handful of git commands that silently discard uncommitted work — for the controller and every sub-agent — so neither a confused agent nor a stray cleanup script can wipe *your* uncommitted changes. (A deliberate human override exists for the rare real case.)

**Putting it back together.** Splitting work apart is only half the job; the value is the combined result. The branches merge back through a speculative queue: all of them are combined on an isolated integration branch and the test suite runs **once** against the combined result — one suite run for N branches, and your working copy only ever moves forward to a state the tests passed on. If the combined result fails, the engine finds the branch that broke it, lands the branches before it that tested green, keeps the failing state on a named branch for inspection, and tells you exactly what landed and what didn't — with a ready-to-paste command for the rest. A suite that is red for environmental reasons (missing untracked dependencies in the fresh worktree) falls back to the classic one-merge-one-test path instead of blaming an innocent branch.

**In one sentence:** split the work so agents can't clobber each other, let each test freely in its own copy, then merge back test-gated — enforced by the filesystem and the test runner, so it holds even if an agent misbehaves.

---

## The research gate

Most multi-agent kits write code from the model's parametric knowledge alone. This one doesn't. Before `brainstorming` writes a spec, and again before `writing-plans` writes a plan, a fast keyword check screens the input. If signals match (library mention + version, security verb, architectural change), a classifier decides whether to dispatch the researcher.

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

Seven specialists, each with a single responsibility, a model chosen to match its job, and a fresh context window per dispatch. The controller routes work between them by output shape — the implementer returns a `Status:` enum (DONE / DONE_WITH_CONCERNS / PARTIAL / BLOCKED / NEEDS_CONTEXT), the read-only agents return `Found:` or `Issues:`.

```
You
 ↓
Controller (the agent you talk to)
 ↓
 ├─ orch-researcher     → verification brief
 ├─ orch-implementer ×N → code (TDD)
 ├─ orch-spec-reviewer       → does the diff match the spec?
 ├─ orch-code-reviewer       → is it idiomatic, safe, minimal?
 ├─ orch-security-reviewer   → injection, auth, secrets, unsafe deps
 ├─ orch-debugger            → root cause
 └─ orch-explorer            → read-only sweeps (Opus — a scout's false negative silently narrows every downstream decision)
```

| Agent                  | Model  | Job                                                                  |
|------------------------|--------|----------------------------------------------------------------------|
| `orch-implementer`     | Opus   | Executes one plan task with TDD. Returns `Status:` block.            |
| `orch-spec-reviewer`   | Opus   | Stage 1 of review: does the diff match the spec?                     |
| `orch-code-reviewer`   | Opus   | Stage 2 of review: is the code correct, safe, idiomatic, minimal?    |
| `orch-debugger`        | Opus   | Root-cause investigator. Diagnoses bugs; does not patch them.        |
| `orch-explorer`        | opus | Read-only codebase scout. Returns `file:line` refs. Cheap and fast.  |
| `orch-researcher`      | Opus   | Verifies external APIs against current sources before any spec.      |
| `orch-security-reviewer` | Opus | Checks diffs for injection, auth gaps, exposed secrets, unsafe deps. |

The controller — the agent you interact with — holds state via the native Task tools (`TaskCreate`/`TaskUpdate`/`TaskList`), ticks plan-file checkboxes (which survive `/clear`), runs the BLOCKED recovery tree, and routes tasks to parallel or sequential dispatch.

Adding a role (`orch-refactorer`, `orch-security-reviewer`, `orch-test-writer`) is one new markdown file in `agents/` plus wiring it into a workflow skill or template — `./tests/validate-skills.sh` then confirms shape.

---

## The workflow

Each phase is a skill the controller invokes before acting. Mandatory checks, not suggestions — the controller scans for the relevant skill at every step and refuses to skip.

1. **`research-classifier`.** Fires before any spec is written if signals match (library + version, vendor API, security verb, architectural change). Emits `RESEARCH_NEEDED` or `RESEARCH_SKIP`. On `RESEARCH_NEEDED`, the controller dispatches the `orch-researcher` subagent, which returns a brief with one of four outcomes: `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`. `CONTRADICTED` halts the workflow before the spec is drafted.
2. **`brainstorming`.** Refines the rough idea through clarifying questions, explores alternatives in sections for validation. Writes the spec to `docs/llm-orchestrator/specs/<date>-<slug>.md`, then self-reviews it inline against a fixed checklist (placeholders, testable goals, non-goals, decision conflicts, scope). High-stakes specs — security-sensitive, irreversible migration, public API — additionally get a fresh `orch-spec-reviewer` subagent pass (advisory, capped at 3 iterations).
3. **`using-git-worktrees`.** Isolates the work on a new branch in a dedicated worktree. Captures a green test baseline when one is obvious; defers to the user when it isn't.
4. **`writing-plans`.** Breaks the approved spec into bite-sized tasks. Every task lists exact files, complete code stubs where useful, verification steps, and optionally an `Interfaces:` block declaring what it introduces and consumes — the executor prefers declared interfaces over body-scanning for dependency routing. The plan is self-reviewed against the no-placeholder rule; high-stakes plans (security-sensitive, irreversible, 5+ tasks) additionally get a fresh reviewer subagent pass (advisory, capped at 3). Plan committed to `docs/llm-orchestrator/plans/<date>-<slug>.md` — its checkboxes are the durable state and survive `/clear`.
5. **`executing-plans` → `dispatching-subagents` / `dispatching-parallel-agents`.** Dispatches a fresh-context subagent per task. Independent tasks fan out in parallel; dependent ones serialize. The controller scans plan-task bodies for symbol references that other tasks introduce and downgrades wrongly-claimed independence to sequential.
6. **`test-driven-development`.** Red-green-refactor inside each implementer: failing test first, watch it fail, write minimal code, watch it pass, commit. If implementation gets written before its test, the skill instructs the implementer to delete it and start over test-first.
7. **`requesting-code-review`.** Two reviewers in fresh contexts per task. Stage 1 — spec compliance: does the diff match what was specified? Stage 2 — code quality: correct, safe, idiomatic, minimal? Reviewers report every finding with a confidence tag and are told explicitly not to be conservative; the controller then demotes anything below 0.8 into a separate `Notes:` section. The filtering is deliberately downstream — a reviewer instructed to withhold follows that literally and loses real bugs.
8. **`receiving-code-review`.** When the reviewer returns issues, the controller routes through a 5-branch BLOCKED recovery tree (missing context, sibling wait, decomposition, model escalation, genuinely needs the user). Branches 1–4 resolve invisibly; only branch 5 reaches you.
9. **`verification-before-completion`.** Fires before any "done" claim. Every `Changed:` block must include a `Verify:` line with the actual command run and its output. A per-turn hook reinforces the rule.
10. **`finishing-a-branch`.** Verifies tests pass, presents merge / PR / keep / discard options, cleans up the worktree. Never destructive without explicit confirmation.

---

## When to use / when not to use

**This trades tokens for correctness.** Every non-trivial task runs research, planning, fresh-context reviews, and verification — that costs more tokens than a single-prompt edit, on purpose. It's built for substantial work where getting it right matters more than minimizing spend: multi-step features, refactors, anything you want to delegate and trust. If you're optimizing for low token cost on small tasks, a lighter setup is the better fit — the overhead won't pay off.

**Use it for:**

- Multi-step features (3+ tasks)
- Non-trivial refactors touching multiple files
- Debugging that needs investigation before fixing
- Code review at scale

**Don't use it for:**

- One-line fixes or single-file edits — orchestration overhead exceeds the value

---

## How it works

Nine layers, each solving a specific failure mode of single-agent AI tooling on real multi-step work:

1. **Memory** — additive to Claude Code's native CLAUDE.md, not a replacement. `/llm-orchestrator:remember` auto-classifies facts into `## Conventions` / `## Decisions` / `## People` / `## Notes` of your project's `./CLAUDE.md`, creating sections as needed. `/llm-orchestrator:forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent sessions serialize writes through a portable file lock. Alongside CLAUDE.md, the plugin maintains a TTL-pruned doc cache and a brief index under `~/.llm-orchestrator/research/` that surfaces prior researcher verdicts to future tasks on the same library.
2. **Workflow scaffolding** — skills and commands produce durable artifacts (specs, plans, reviews) committed under `docs/llm-orchestrator/`.
3. **State machine** — the native Task tools plus plan-file checkboxes survive `/clear`. The next session reads the plan file and knows exactly where to resume.
4. **Dispatch routing + collision-proof isolation** — parallel for independent tasks, sequential for dependent. The controller scans plan-task bodies for symbol references to other tasks and downgrades `Independent: yes` to sequential when it spots a real dependency. Parallel *writers* never share a checkout undeclared: by default each runs in its own git worktree, claimed atomically in an ownership registry (`scripts/orch-worktree-materialize.sh`) — and when a project rules out worktrees, writers may share the checkout only under an explicitly declared, controller-partitioned file-ownership mode (disjoint exclusive file lists, a stated writer cap, no locks or hold-markers). A `PreToolUse` guard blocks the working-tree-destroying git commands for the controller and every sub-agent. Read-only agents (review/research/explore) safely share the tree. Merge-back is a speculative queue: one suite run at the combined tip for the green path, bisect-and-eject on red, and the base only ever fast-forwards to a suite-green SHA. See "Safe parallel work" above.
5. **Autonomous BLOCKED recovery** — when a subagent returns `Status: BLOCKED`, the controller routes through a 5-branch tree (missing context, sibling wait, decomposition, model escalation, or genuinely needs the user). Missing context is a `SendMessage` **resume** of the same agent — its partial work and context survive; only genuine model escalation pays for a cold re-dispatch. `PARTIAL` returns (a fired `Stop if:`) keep completed work and enumerate the remainder. Branches 1–4 happen invisibly; only branch 5 ever reaches you.
6. **Two-stage code review** — fresh-context reviewers, told explicitly not to trust the implementer. Reviewers report everything with a confidence tag; the controller demotes below 0.8 into `Notes:`. Filtering never happens inside the reviewer. In the workflow path, every finding carries a proposed fix, and the skeptic pass **executes** the fix in a scratch copy where the claim is runnable — a finding whose fix changes nothing observable is refuted (the fix-guided filter from arXiv:2603.00539). A refuted finding is removed from the confirmed set but never deleted from the record: the workflow returns it in a separate `refuted` list with the method and reason that cleared it.
7. **Evidence-based completion** — every `Changed:` block requires a `Verify:` line with the actual command and its output — checked against a hook-written evidence ledger scoped to the current turn. The model cites nothing; the gate reads the record. A `Verify:` naming a command the harness never ran this turn is caught, as is a run that failed, or one that exited 0 having executed no tests.
8. **Pre-spec verification — the research gate** — described above. Returns `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`; `CONTRADICTED` halts the workflow until the spec is revised.
9. **Context-aware handoff** — on a long task the controller's context window fills up, which quietly degrades its work. When usage crosses ~950K tokens (≈95% of a 1M window) the agent is reminded once to write a short handoff note (what's done, what's next, the verify command); after Claude Code auto-compacts the conversation, a reminder tells the next turn to re-read that note, trust the plan file's checkboxes, and re-run the tests before continuing. The plan file remains the durable recovery anchor.

Implementation reference with code links and the layer-stack diagram: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Hook precedence

The hooks follow three rules so their behavior is predictable without reading the source:

1. **Defaults warn, never block.** Out of the box, no hook blocks your turn. Hooks inject context, grade output, and warn — including the retry-storm breaker (on by default, warn-only; `ORCH_RETRY_CAP=0` disables it) and the evidence-ledger check. **No hook modifies tool output.** The evidence ledger is append-only; the stamp line that used to be injected into Bash stdout is off by default (`ORCH_EVIDENCE_MARKER=1` restores an inert form for cross-agent evidence transport).
2. **Enforcement is opt-in, always under an `ORCH_STRICT_*` flag.** A hook only blocks when you ask it to: `ORCH_STRICT_PROTOCOL=1` makes the protocol grader block off-shape replies; `ORCH_STRICT_VERIFY=1` blocks a `Changed:` claim in three cases — its `Verify:` names a verify-shaped command the harness has no green record of running this turn, a verify run this turn failed and was never re-run green, or there is no `Verify:` section at all. A `Verify:` naming a command outside the verify-shape regex (a project's own script) is never blocked and never warned: there the gate genuinely knows nothing. A green run that executed zero tests gets a soft note, never a block; `ORCH_STRICT_STATUS=1` blocks malformed or empty subagent returns; `ORCH_STRICT_RETRY=1` blocks at the repetition threshold (`ORCH_RETRY_CAP_N`, default 3). Unset, each warns at most. One platform-level exception: the prompt-type SubagentStop termination-contract check is evaluated by the harness itself and blocks with a corrective reason when an implementer terminates without an honest Status block — it cannot read `ORCH_*` env and is active in every profile.
3. **Local-only state, and one default-on record.** Nothing leaves your machine. Skill telemetry is opt-in (`ORCH_TELEMETRY=1`, off by default). The evidence ledger is **on** under the `standard` profile and writes, per verify-shaped command, its first 160 characters plus exit code, timestamp, and a one-word substance verdict derived from the output — all under `~/.llm-orchestrator/state/`, pruned after 7 days, never transmitted. `ORCH_HOOK_PROFILE=minimal` or `ORCH_DISABLED_HOOKS=orch-evidence-ledger` turns it off. See [`ARCHITECTURE.md`](./ARCHITECTURE.md).

Two switches cut across all of the above:

- **`ORCH_DISABLE_PROTOCOL_GRADER=1`** turns the protocol grader off entirely. `ORCH_STRICT_PROTOCOL=1` wins if both are set — strict mode is never silently disabled.
- **`ORCH_HOOK_DRY_RUN=1`** makes every hook log what it *would* inject or block to stderr and then do nothing. Use it to tune behavior safely before turning a strict flag on.

When two flags conflict, the safer reading wins: a strict flag beats a disable flag, and dry-run beats an enforcement action.

---

## Install from source

For contributors and local development:

```bash
git clone https://github.com/felipemelendez/llm-orchestrator
cd llm-orchestrator
./tests/smoke.sh                           # → "71 passed, 0 failed."
claude --plugin-dir "$(pwd)"               # session-mount the plugin for live iteration
```

Plugin code (skills, hooks, agents, commands) is read once at startup — there is no in-session reload. After editing files in the repo, restart Claude Code (or relaunch with `--plugin-dir`) to pick up the changes; `/clear` is not enough.

Other modes:

- **Persistent symlink.** `./scripts/install.sh --link` then `/plugin marketplace add ~/.claude/llm-orchestrator`.
- **Per-project copy.** `./scripts/install.sh --copy <project-dir>` — copies the plugin into a project's `.claude/` directory.
- **Minimal hook profile.** `ORCH_HOOK_PROFILE=minimal` — bootstrap only; skips per-turn protocol reminders and the research gate.
- **Disable specific hooks.** `ORCH_DISABLED_HOOKS=orch-research-gate,orch-stop`.
- **`ORCH_CONTEXT_HANDOFF_TOKENS`.** Default `950000` (≈95% of a 1M-token window) — the token count at which the agent is reminded once to write a handoff note before native compaction kicks in. Lower it for a smaller context window.

Full installation guide: [`docs/install.md`](./docs/install.md). Slash command reference, agent roster, and response-protocol details: [`AGENTS.md`](./AGENTS.md), [`concise-agent-protocol.md`](./concise-agent-protocol.md).

---

## Contributing

Small, opinionated kit. New skills, slash commands, and subagent roles welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the scaffolding pattern, test discipline, and issue format.

---

## License

MIT. See [`LICENSE`](./LICENSE).
