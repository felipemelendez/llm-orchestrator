# LLM Orchestrator

[![License](https://img.shields.io/github/license/felipemelendez/llm-orchestrator?color=blue)](./LICENSE) [![Last commit](https://img.shields.io/github/last-commit/felipemelendez/llm-orchestrator)](https://github.com/felipemelendez/llm-orchestrator/commits/main) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)

**Plan it, build it, review it, and check it — in Claude Code.**

LLM Orchestrator is a Claude Code plugin for work you want to hand off: agree on what to make, save the plan in the project, then have the assistant implement it, get the changes reviewed by fresh agents, and run the tests.

1. **Plan.** Explore the idea, settle the requirements, save the approved plan in your project.
2. **Build.** Point the assistant at the plan and ask it to follow the project's cadence — the agreed steps for implementation, review, and testing.
3. **Check.** It runs independent reviews and the relevant tests, and reports what passed and what still needs attention.

For example: “Implement the approved plan in `docs/feature-plan.md`. Follow this project's cadence and report the reviews and test results.” Replace the example path with your actual plan.

**New in v0.11.0:** Codex is supported again. One command installs the cadence skill and three small hooks: a guard for the project's rulebook, a check that sends the assistant back once when a reply claims tests passed and none ran, and a cleanup for temporary files. [How to install it](./docs/codex.md) · [What changed](./CHANGELOG.md).

## Quick Start

Run these commands one at a time inside Claude Code:

```text
/plugin marketplace add felipemelendez/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator
```

Restart Claude Code. The slash menu should include `/llm-orchestrator:onboard` and the other orchestrator commands. On an existing project, run `/llm-orchestrator:onboard` to help the assistant learn its structure and conventions.

To enable the shared review process for that project, run:

```text
/llm-orchestrator:cadence-init
```

It proposes the project's test commands and rules for you to review, then explains the remaining setup steps. Cadence is per project: you choose which ones enable it. Full setup guide: [Enable cadence in a project](./docs/install.md#enable-cadence-in-a-project).

### What happens when cadence is enabled?

**Cadence** matches the amount of checking to the size of the risk. Before changing code or tests, the assistant reads the project's rulebook (`docs/llm-orchestrator/LAWS.md`) and picks one of three paths:

- **Simple** — a small, local, easily reversible change. The assistant makes it, reads the whole diff, runs the relevant tests, and delivers. No extra agents.
- **Standard** — a bounded change in behavior with real edge cases. The assistant states what "done" means, makes the change, runs focused tests, and gets one independent reviewer to check it.
- **Full** — anything that touches several systems, is hard to undo, or changes how verification or security works. The design is reviewed first, two reviewers inspect the result independently with different briefs, findings are fixed, and the final result is verified by someone other than the writer.

Whatever the path, the same rule applies at the end. The assistant reports **PASS** only when it ran the project's checks and they passed on the final code. It reports **PENDING** when validation is unfinished, **BLOCKED** when something it needs is unavailable, and, for low-risk work with no meaningful automated test, **NOT APPLICABLE** with the manual inspection it did instead. A hook reads the session transcript at the end of each turn and, when a reply claims PASS with no passing check behind it, sends the assistant a note saying so. The note goes to the assistant only; nothing is shown to you. Temporary review notes and copies are cleaned up when the task finishes; specs and design notes are kept.

The process applies to code and test changes in enabled projects. Documentation-only edits and ordinary questions need no review path. The project's own rulebook always takes priority.

**Requirements:** Claude Code, Bash, Git, and Python 3 (a few hooks use it). The visual brainstorming panel needs Node.js.

Already installed? Follow [Updating to v0.11.0](./docs/install.md#updating-to-v0110). Publishing a release does not update installed copies automatically.

For a task walkthrough, see [the sample session](./docs/examples/sample-session.md).

### Using Codex?

Codex gets a smaller part of the plugin: the cadence skill and three small hooks. In your terminal, clone this repository into a folder you will keep and run the installer:

```sh
git clone https://github.com/felipemelendez/llm-orchestrator.git
cd llm-orchestrator
./scripts/install.sh --codex
```

Then open a new Codex session and run `/hooks` to trust the three hooks. Codex only runs a hook you have trusted. What you get and what it never does: [Codex](./docs/codex.md).

---

## What it does

| Feature | What it does | Why it matters |
|---|---|---|
| **Research gate** | Verifies the planned approach against current docs (vendor MCPs, Context7, web) and on-disk state before any code is written | Catches deprecated APIs and bad version assumptions before they ship |
| **Two-stage code review (+ conditional security pass)** | Spec-compliance reviewer gates a code-quality reviewer, each in a fresh subagent context; diffs touching auth/crypto/payments/secrets get a third, security-focused pass. Critical findings must state a concrete failure scenario or they're downgraded. Runs as one parallel, self-checking workflow script when Claude Code's Workflow tool is present; step-by-step anywhere else | Catches bugs implementers miss in their own diffs, without drowning you in false alarms |
| **Safe parallel dispatch + speculative merge queue** | Independent tasks fan out to implementers in isolated per-agent worktrees, claimed atomically in an ownership registry; a guard blocks work-destroying git on the shared tree. Merge-back runs a speculative queue (the Zuul / GitHub-merge-queue discipline): all branches batch onto an isolated integration branch, the suite runs once at the combined tip, and the base only ever fast-forwards to a suite-green SHA — red tips bisect out the regressor and land the tested-green prefix | Agents can't clobber each other's work, N branches land for one suite run instead of N, and the base never holds an untested commit |
| **Autonomous BLOCKED recovery — resume, not redo** | When an agent gets stuck, the controller tries four autonomous fixes before paging you: send the missing context to the SAME agent (a `SendMessage` resume that keeps its partial work and context), run the prerequisite task first, split the work, or retry with a stronger model — only the fifth branch reaches you. A `PARTIAL` status (with `Progress:`/`Remaining:`) means a stop-condition fired: completed work is kept, never redone | Blockers get four chances to resolve themselves before costing you attention, and partial work survives instead of being thrown away |
| **Evidence-based completion** | Every "done" claim must include the output of the command that proves it. At the end of each turn a hook reads the transcript the harness already wrote: if the reply is labelled `Verification: PASS` and no check ran and passed in that turn, it tells the agent so; nothing is shown to you | Stops agents from declaring code finished without running the tests — invented output has nothing behind it |
| **Visual brainstorming** | During brainstorming, a local zero-dependency panel server (you open the printed `localhost` URL) renders live HTML mockups; the agent pushes screens and reads your clicks back, iterating before any code is written | Lets you see and react to UI/layout/structure choices instead of parsing them from prose |
| **One-time onboarding + architecture grounding** | `/llm-orchestrator:onboard` studies the codebase once and records `## Decisions` + `## Conventions` in `./CLAUDE.md` behind a single approval gate; every later spec, implementation, and review silently applies them as constraints, and a diff that breaks a recorded decision is flagged Critical | A new feature can't silently violate an established choice — e.g. adding a network dependency to an offline-first SQLite app |
| **Context-aware handoff** | On a long task, the agent is nudged once (when context crosses ≈95% of the window) to write a short handoff note; after auto-compaction, a reminder tells the next turn to re-read it, reconcile against the plan, and re-verify | A long run continues cleanly across a compaction instead of drifting on a lossy summary |
| **CLAUDE.md classification** | `/llm-orchestrator:remember <fact>` appends the fact to your project's CLAUDE.md under the right section — `## Conventions`, `## Decisions`, `## People`, or `## Notes` — chosen automatically; `/llm-orchestrator:forget` soft-deletes recoverably | Persistent project memory without organizing it by hand |

The mechanics behind these rows — toolchain detection, convention detection, and the workflow-vs-markdown routing — are documented in [`ARCHITECTURE.md`](./ARCHITECTURE.md). The behavioural claims are not taken on faith: every measured bet — including the ones that lost — is recorded with its numbers and raw evidence in [`docs/MEASUREMENTS.md`](./docs/MEASUREMENTS.md).

---

## What's native vs. what this adds

Claude Code ships first-party versions of several things this kit does. This plugin does not compete with them — it uses the native mechanism where that mechanism does the job and keeps the layer the harness doesn't enforce: *when* a step is mandatory, *what counts as evidence*, and *in what order* stages run. (The native features below were checked on 2026-09-25 against the Claude Code docs and Claude Code v2.1.282 in a scratch repository; the harness changes often, so check again before building on them.)

| Capability | Native Claude Code | This plugin's layer |
|---|---|---|
| Verification | Native `/verify` skill (manual-only since v2.1.215; builds and runs the app, not the tests) | The gate: no done/fixed/passing claim without pasted evidence, plus an end-of-turn check that a `Verification: PASS` really had a passing run behind it |
| Code review | `/code-review` (runs as a background subagent; Claude can start it on its own since v2.1.246), `/security-review` | Spec-compliance Stage 1 (native review doesn't check the diff against a spec), spec-gates-quality order, failure-scenario rule for Critical findings. The plugin's review flow does not call `/code-review` |
| Worktrees | Per-agent worktrees (`isolation: worktree`), branched from the remote default branch, not your current `HEAD`, unless you set `worktree.baseRef: "head"` yourself (a plugin cannot set it); uncommitted changes are never carried over | Its own worktrees cut from your current `HEAD`, an atomic ownership registry, green-baseline capture, speculative test-gated merge queue |
| Memory | CLAUDE.md + auto-memory (plus per-agent `memory:`, which the plugin does not use) | Write-side classification (`/llm-orchestrator:remember`) and recoverable `/llm-orchestrator:forget` |
| Planning | Native plan mode | Durable spec/plan artifacts whose checkboxes survive `/clear` |
| Exploration | Built-in Explore agent | `orch-explorer` as a tools-restricted Sonnet variant with a `file:line` output contract |
| Fan-out orchestration | `Workflow` tool | The when-to-fan-out policy (`using-workflows`) and ready-made scripts like `workflows/review-diff.js` |

Still exclusively this plugin's ground: the Concise Agent Protocol response shapes, the research gate, TDD and root-cause-first debugging enforcement, and the BLOCKED recovery tree. Full map with the delegation rules: [`docs/anthropic-ecosystem.md`](./docs/anthropic-ecosystem.md).

## How is this different from Superpowers or Everything Claude Code?

Fair question — from the outside they look similar (skills, agents, workflows). They occupy different points on one axis: **how much of the system still works on the turns the model ignores its instructions.**

**[Superpowers](https://github.com/obra/superpowers)** is a skills library — genuinely good written discipline (TDD, systematic debugging, plan execution, worktrees) that this plugin's own skill catalog descends from. Its enforcement surface is one session-start hook that loads the skill index; from there on, every rule holds only if the model chooses to follow it, every turn (verified on disk against v6.2.0, 2026-07-29).

**[Everything Claude Code (ECC)](https://github.com/affaan-m/everything-claude-code)** is a breadth play: a very large catalog of agents, skills, rules, and hooks spanning Claude Code, Cursor, Codex, and OpenCode. If you want one resource that covers many harnesses and many workflows, that's the one — this plugin doesn't try to compete on surface area.

**LLM Orchestrator is depth on a single question: can you trust the result without having watched the work?** It uses Claude Code hooks to catch the following problems:

| The failure | What this plugin does about it — mechanically |
|---|---|
| Agent claims tests passed without running them | At the end of the turn a hook reads the transcript rather than the reply: a `Verification: PASS` with no passing check in that turn gets a note sent back to the agent (nothing is shown to you) |
| Two agents write the same files at once | Atomic per-worktree locks plus a guard that physically blocks work-destroying git commands — for the controller *and* every subagent |
| Broken parallel work reaches your branch | A speculative merge queue tests the combined result and only ever fast-forwards your branch to a state the suite passed on |
| Plan built on a hallucinated or outdated API | A pre-spec research gate whose `CONTRADICTED` verdict **halts the workflow** until the plan is revised |
| Agent loops on the same failing action | A breaker detects the identical action repeated 3× in a row and intervenes |
| Agent quits halfway; silence reads as success | Empty returns are flagged as failures; every task carries `Done when:` / `Stop if:`, with an honest `PARTIAL` status that preserves finished work |
| "Does any of this actually help?" | A committed eval benchmark (`tests/evals/results/benchmark.json`) — including the cases where the plugin does **not** help |

**When to choose which.** They compose: this plugin alongside an instruction library is a sensible setup, and both neighbors are better choices for what they're best at — Superpowers for a battle-tested skill catalog with a big community, ECC for cross-harness breadth. Choose LLM Orchestrator for the thing written guidance alone cannot provide: delegating multi-step work and trusting the *result* — claims that are verifiable and failures that are recoverable — rather than trusting the model's compliance.

---

**Grounding.** The design follows the published evidence rather than habit: the scaffold alone moved GAIA accuracy by up to 28 points within one model, and the most capable Anthropic model tested gained the most from a structured scaffold (GAIA scaffold comparison, [arXiv:2606.08529](https://arxiv.org/abs/2606.08529)); on coding tasks a later study found the harness moved pass rates by at most 8 points but tokens per solved task by up to 40x ([arXiv:2607.22585](https://arxiv.org/abs/2607.22585)); missing or incorrect verification accounts for 17.3% of failures across 1,642 multi-agent traces (MAST taxonomy, NeurIPS 2025, [arXiv:2503.13657](https://arxiv.org/abs/2503.13657)); LLM code reviewers systematically over-flag correct code — and prompts asking for more explanation make it *worse*, not better; the paper's own countermeasure is a fix-guided filter that treats a proposed correction as **executable** counterfactual evidence ([arXiv:2603.00539](https://arxiv.org/abs/2603.00539)), which the skeptic pass in `workflows/review-diff.js` now implements — every finding carries a proposed fix, and skeptics execute it in a scratch copy where the claim is runnable, labelling survivors `verifiedBy: executed`, `reasoned`, or `unverified`; and Anthropic advises adding complexity only when it demonstrably improves outcomes (Anthropic, [Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)). Hence: keep the policy, and let the platform supply the mechanics it already has.

---

## Safe parallel work — agents can't overwrite each other

Running several agents at once is only useful if they don't clobber each other. The danger: when two agents edit the same project at the same time, one can silently overwrite the other's work — and you don't find out until it's gone. (That happened to us in development — a background agent ran a routine git cleanup and wiped another agent's in-progress changes.)

This system makes that collision impossible by construction, not by asking agents to be careful:

1. **Each writing agent gets its own copy of the project.** Read-only agents (the reviewers, the researcher) share the one project safely. Any agent that *writes* code works in a separate folder on its own branch — so two writers can't touch the same file. A small registry file tracks who owns which copy, and claiming one is all-or-nothing, so two agents can never grab the same workspace. When a project rules out separate copies, writers may share the one checkout only under an explicitly declared, controller-partitioned file ownership (disjoint exclusive file lists, a stated writer cap, no locks or hold-markers) — the file list, not a lock, is then the boundary.

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
 └─ orch-explorer            → read-only sweeps
```

| Agent                  | Model  | Job                                                                  |
|------------------------|--------|----------------------------------------------------------------------|
| `orch-implementer`     | Opus   | Executes one plan task with TDD. Returns `Status:` block.            |
| `orch-spec-reviewer`   | Opus   | Stage 1 of review: does the diff match the spec?                     |
| `orch-code-reviewer`   | Opus   | Stage 2 of review: is the code correct, safe, idiomatic, minimal?    |
| `orch-debugger`        | Opus   | Root-cause investigator. Diagnoses bugs; does not patch them.        |
| `orch-explorer`        | Sonnet | Read-only codebase scout. Returns `file:line` refs.                  |
| `orch-researcher`      | Opus   | Verifies external APIs against current sources before any spec.      |
| `orch-security-reviewer` | Opus   | Checks diffs for injection, auth gaps, exposed secrets, unsafe deps. |

Every agent sets `model: opus` (Opus 5.5) except the read-only explorer, which sets `model: sonnet` (the latest Sonnet) because it runs often and costs half as much. Fable was dropped after its review route was rate-limited, and Opus costs less per token. Both run the same safety classifiers, so on either model a request flagged as cybersecurity re-runs on Opus 4.8. The three reviewers set `effort: high`, because a reviewer that stops early misses findings. The other agents set no `effort:` and inherit the session's level, which is `medium` on Opus 5.5 when nobody has chosen one.

The controller — the agent you interact with — holds state via the native Task tools (`TaskCreate`/`TaskUpdate`/`TaskList`), ticks plan-file checkboxes (which survive `/clear`), runs the BLOCKED recovery tree, and routes tasks to parallel or sequential dispatch.

Adding a role (`orch-refactorer`, `orch-test-writer`) is one new markdown file in `agents/` plus wiring it into a workflow skill or template — `./tests/validate-skills.sh` then confirms shape.

---

## The workflow

Each phase is a skill the controller invokes when the task matches its trigger. Ordinary questions, explanations and small edits need no skill.

1. **`research-classifier`.** Fires before any spec is written if signals match (library + version, vendor API, security verb, architectural change). Emits `RESEARCH_NEEDED` or `RESEARCH_SKIP`. On `RESEARCH_NEEDED`, the controller dispatches the `orch-researcher` subagent, which returns a brief with one of four outcomes: `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`. `CONTRADICTED` halts the workflow before the spec is drafted.
2. **`brainstorming`.** Refines the rough idea through clarifying questions, explores alternatives in sections for validation. Writes the spec to `docs/llm-orchestrator/specs/<date>-<slug>.md`, then self-reviews it inline against a fixed checklist (placeholders, testable goals, non-goals, decision conflicts, scope). High-stakes specs — security-sensitive, irreversible migration, public API — additionally get a fresh `orch-spec-reviewer` subagent pass (advisory, capped at 3 iterations).
3. **`using-git-worktrees`.** Isolates the work on a new branch in a dedicated worktree. Captures a green test baseline when one is obvious; defers to the user when it isn't.
4. **`writing-plans`.** Breaks the approved spec into bite-sized tasks. Every task lists exact files, complete code stubs where useful, verification steps, and optionally an `Interfaces:` block declaring what it introduces and consumes — the executor prefers declared interfaces over body-scanning for dependency routing. The plan is self-reviewed against the no-placeholder rule; high-stakes plans (security-sensitive, irreversible, 5+ tasks) additionally get a fresh reviewer subagent pass (advisory, capped at 3). Plan committed to `docs/llm-orchestrator/plans/<date>-<slug>.md` — its checkboxes are the durable state and survive `/clear`.
5. **`executing-plans` → `dispatching-subagents` / `dispatching-parallel-agents`.** Dispatches a fresh-context subagent per task. Independent tasks fan out in parallel; dependent ones serialize. The controller scans plan-task bodies for symbol references that other tasks introduce and downgrades wrongly-claimed independence to sequential.
6. **`test-driven-development`.** Red-green-refactor inside each implementer: failing test first, watch it fail, write minimal code, watch it pass, commit. If implementation gets written before its test, the skill instructs the implementer to delete it and start over test-first.
7. **`requesting-code-review`.** Two reviewers in fresh contexts per task. Stage 1 — spec compliance: does the diff match what was specified? Stage 2 — code quality: correct, safe, idiomatic, minimal? Reviewers report every finding with a confidence tag and are told explicitly not to be conservative; the controller then demotes anything below 0.8 into a separate `Notes:` section. The filtering is deliberately downstream — a reviewer instructed to withhold follows that literally and loses real bugs.
8. **`receiving-code-review`.** When the reviewer returns issues, the controller routes through a 5-branch BLOCKED recovery tree (missing context, sibling wait, decomposition, model escalation, genuinely needs the user). Branches 1–4 resolve invisibly; only branch 5 reaches you.
9. **`verification-before-completion`.** Fires before any "done" claim. The claim must carry the actual command run and its output. In a cadence-enabled project a per-turn hook reinforces the rule.
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

Ten layers, each solving a specific failure mode of single-agent AI tooling on real multi-step work:

1. **Memory** — additive to Claude Code's native CLAUDE.md, not a replacement. `/llm-orchestrator:remember` auto-classifies facts into `## Conventions` / `## Decisions` / `## People` / `## Notes` of your project's `./CLAUDE.md`, creating sections as needed. `/llm-orchestrator:forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent sessions serialize writes through a portable file lock. Alongside CLAUDE.md, the plugin maintains a TTL-pruned doc cache and a brief index under `~/.llm-orchestrator/research/` that surfaces prior researcher verdicts to future tasks on the same library.
2. **Workflow scaffolding** — skills and commands produce durable artifacts (specs, plans, reviews) committed under `docs/llm-orchestrator/`.
3. **State machine** — the native Task tools plus plan-file checkboxes survive `/clear`. The next session reads the plan file and knows exactly where to resume.
4. **Dispatch routing + collision-proof isolation** — parallel for independent tasks, sequential for dependent. The controller scans plan-task bodies for symbol references to other tasks and downgrades `Independent: yes` to sequential when it spots a real dependency. Parallel *writers* never share a checkout undeclared: by default each runs in its own git worktree, claimed atomically in an ownership registry (`scripts/orch-worktree-materialize.sh`) — and when a project rules out worktrees, writers may share the checkout only under an explicitly declared, controller-partitioned file-ownership mode (disjoint exclusive file lists, a stated writer cap, no locks or hold-markers). A `PreToolUse` guard blocks the working-tree-destroying git commands for the controller and every sub-agent. Read-only agents (review/research/explore) safely share the tree. Merge-back is a speculative queue: one suite run at the combined tip for the green path, bisect-and-eject on red, and the base only ever fast-forwards to a suite-green SHA. See "Safe parallel work" above.
5. **Autonomous BLOCKED recovery** — when a subagent returns `Status: BLOCKED`, the controller routes through a 5-branch tree (missing context, sibling wait, decomposition, model escalation, or genuinely needs the user). Missing context is a `SendMessage` **resume** of the same agent — its partial work and context survive; only genuine model escalation pays for a cold re-dispatch. `PARTIAL` returns (a fired `Stop if:`) keep completed work and enumerate the remainder. Branches 1–4 happen invisibly; only branch 5 ever reaches you.
6. **Two-stage code review** — fresh-context reviewers, told explicitly not to trust the implementer. Reviewers report everything with a confidence tag; the controller demotes below 0.8 into `Notes:`. Filtering never happens inside the reviewer. In the workflow path, every finding carries a proposed fix, and the skeptic pass **executes** the fix in a scratch copy where the claim is runnable — a finding whose fix changes nothing observable is refuted (the fix-guided filter from arXiv:2603.00539). A refuted finding is removed from the confirmed set but never deleted from the record: the workflow returns it in a separate `refuted` list with the method and reason that cleared it.
7. **Evidence-based completion** — every `Changed:` block requires a `Verify:` line with the actual command and its output. At the end of the turn, `orch-verify-gate.sh` reads the transcript the harness already wrote and asks one question: the reply says `Verification: PASS` — did a check actually run and pass in this turn? If not, it sends the agent a note saying so; nothing is shown to you. It reads only that label, never the reply's prose, and it warns rather than blocks.
8. **Pre-spec verification — the research gate** — described above. Returns `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`; `CONTRADICTED` halts the workflow until the spec is revised.
9. **Context-aware handoff** — on a long task the controller's context window fills up, which quietly degrades its work. When usage crosses ~950K tokens (≈95% of a 1M window) the agent is reminded once to write a short handoff note (what's done, what's next, the verify command); after Claude Code auto-compacts the conversation, a reminder tells the next turn to re-read that note, trust the plan file's checkboxes, and re-run the tests before continuing. The plan file remains the durable recovery anchor.
10. **The cadence and the lock** — opt-in per project, inert everywhere else. Each change takes a Simple, Standard or Full path chosen by risk, and a lock protects the project's rulebook: deny rules stop the edit, and the `commit-msg` git hook refuses the commit. Turned on by `/llm-orchestrator:cadence-init`; described under [The cadence](#the-cadence).

Implementation reference with code links and the layer-stack diagram: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## The cadence

**What it is.** A project that opts in gets three things both people and agents can read: a rulebook (`docs/llm-orchestrator/LAWS.md`), a config that says how to run its tests (`cadence.json`), and a lock over both. The Simple, Standard and Full paths, and the completion rule, are described above under [What happens when cadence is enabled?](#what-happens-when-cadence-is-enabled). On Full work a third read-only agent, the refuter, steps in only when the two reviewers disagree or one of them alone reports something serious. Passing results are reused as long as the code they covered has not changed, so nothing is rerun for show.

Projects initialized before this release keep the older fixed sequence (brief review, implementer, two blind reviewers, refuter, fixer, gate, landing with five report files) until they migrate. It is described in full in the cadence skill's [`CADENCE.md`](./skills/cadence/CADENCE.md).

**Why.** Cadence keeps low-risk changes quick and gives risky changes independent review, with real checks before anything is called done. The stage-by-stage counts from one operator's use, and what those counts cannot show, are in [`docs/MEASUREMENTS.md`](./docs/MEASUREMENTS.md); the claims the design rests on, with their sources, are in [`docs/cadence-evidence.md`](./docs/cadence-evidence.md).

**How to turn it on.** Run `/llm-orchestrator:cadence-init` inside your project. The assistant proposes the `cadence.json` for you to confirm, writes the rulebook from a template, adds the deny rules that stop agents editing the rulebook, installs the git hooks under `.githooks/`, and then prints the steps only you can take: fill in the rulebook (a filled-in example ships as [`laws-example.md`](./skills/cadence/references/laws-example.md); the assistant can draft wording, you decide), re-record the lock, enable this clone's git hooks with the one line it prints, and commit. `./scripts/install.sh --global`, run from the plugin's own checkout, puts the same pointer block in `~/.claude/CLAUDE.md` so a plain launch sees it. Nothing changes for a project that never runs the init.

**The lock, two layers.** Layer 1 is the `Edit(...)` deny rules the init writes into `.claude/settings.json`: Claude Code refuses to edit the rulebook, the config, the lock file, the settings file and the git hooks, through its file tools and through shell commands alike, in every permission mode. Layer 2 is the git `commit-msg` hook, which refuses a commit that changes a protected file without a numbered ruling. Two smaller things report rather than prevent: the session-start line, which names a rulebook that changed since the lock was recorded, and `orch-cadence-check.sh --audit <rev>` in CI for a clone whose hooks were never enabled. Changing the rules on purpose is a separate path: start the session with `ORCH_CADENCE_UNLOCK=1` set in your own shell (never in a settings file), make the change, re-run `--lock`, and commit with `Ruling <N>` in the message. How the deny rules were verified is recorded in [`docs/cadence-evidence.md`](./docs/cadence-evidence.md).

**The boundary, stated plainly.** A write the deny rules do not stop, such as one made by a script the agent runs, still happens. It is named at the next session start and refused at the commit.

---

## How the hooks behave

Four rules, so you can predict them without reading the source:

1. **Defaults warn, never block.** Out of the box nothing stops your turn. Hooks add context, check shapes, and warn — the retry-storm breaker (on by default, warn-only; `ORCH_RETRY_CAP=0` disables it) and the end-of-turn completion check (a note to the model, never a message to you) included. On Codex the same completion check sends the assistant back once instead, because Codex has no way to hand it a quiet note; it never prints a message for you ([`docs/codex.md`](./docs/codex.md)). No hook changes tool output. The guards are the deliberate exception: `guard-destructive-git`, `guard-no-verify`, `guard-config-protection`, `guard-dispatch-model`, the cadence unlock guard, and on Codex the cadence file guard refuse the command outright, because a guard that only warns is not a guard. A refusal is addressed to the agent, as the reason its command was refused. Their escape hatches are in [`docs/install.md`](./docs/install.md#escape-hatches-for-the-hard-guards).
2. **Blocking is opt-in.** `ORCH_STRICT_STATUS=1` blocks a malformed or empty subagent return; `ORCH_STRICT_RETRY=1` blocks at the repetition threshold (`ORCH_RETRY_CAP_N`, default 3); `ORCH_STRICT_RESEARCH=1` blocks a malformed research brief. `ORCH_HOOK_PROFILE=strict` turns on the first two at once. The completion check has no strict mode: 200 runs comparing warn against block scored the same either way ([`docs/MEASUREMENTS.md`](./docs/MEASUREMENTS.md), 2026-08-05), so on Claude Code it always warns, and on Codex it always takes the one route to the agent that harness offers.
3. **Local-only state.** Nothing leaves your machine. Skill telemetry is opt-in (`ORCH_TELEMETRY=1`, off by default).
4. **Quiet outside cadence projects.** In a project without an enabled `docs/llm-orchestrator/cadence.json`, this is all the hooks add to the conversation:
   - **Session start:** a short note on when a skill applies (ordinary questions and small edits need none). After a compaction, the same note plus a short recovery note ("if a plan or handoff file exists, reconcile against it").
   - **Each turn:** nothing, except two notes that fire only on a match. The research gate adds one when the message names a library, version or security-sensitive area alongside a build or design verb, a package-manager command, a version, advisory or deprecation question, or an explicit `/llm-orchestrator:research`; the note says the research step is for new features and design work, and a small edit needs none. The handoff nudge adds one once, when the context passes `ORCH_CONTEXT_HANDOFF_TOKENS`.
   - **End of turn:** the completion check adds a note only when a reply says `Verification: PASS` and no check ran; subagent returns are checked for their shapes.

   The reply-format rule (the six headers in [`concise-agent-protocol.md`](./concise-agent-protocol.md)) and its per-turn reminder are added only in a cadence-enabled project, and a reply format set by the project's own CLAUDE.md or AGENTS.md wins over them. The guards run in every project either way.

`ORCH_HOOK_DRY_RUN=1` makes the hooks that add context or check shapes print what they would have done and then do nothing. Use it to tune behavior before turning a strict flag on. The guards ignore it on purpose; the Stop pruner and the worktree reaper never implemented it.

---

## Install from source

For contributors and local development:

```bash
git clone https://github.com/felipemelendez/llm-orchestrator
cd llm-orchestrator
./tests/smoke.sh                           # → "81 checks passed, 1 skipped." (~90s)
claude --plugin-dir "$(pwd)"               # session-mount the plugin for live iteration
```

Plugin code (skills, hooks, agents, commands) is read once at startup — there is no in-session reload. After editing files in the repo, restart Claude Code (or relaunch with `--plugin-dir`) to pick up the changes; `/clear` is not enough.

Other modes:

- **Persistent symlink.** `./scripts/install.sh --link` then `/plugin marketplace add ~/.claude/llm-orchestrator`.
- **Per-project copy.** `./scripts/install.sh --copy <project-dir>` — copies the plugin into a project's `.claude/` directory.
- **Codex.** `./scripts/install.sh --codex` — the cadence skill, the shared instructions and three small hooks, into your Codex setup; then trust the hooks with `/hooks`. See [`docs/codex.md`](./docs/codex.md).
- **Minimal hook profile.** `ORCH_HOOK_PROFILE=minimal` — bootstrap only; skips per-turn protocol reminders (which only cadence-enabled projects get) and the research gate.
- **Disable specific hooks.** `ORCH_DISABLED_HOOKS=orch-research-gate,orch-stop`.
- **`ORCH_CONTEXT_HANDOFF_TOKENS`.** Default `950000` (≈95% of a 1M-token window) — the token count at which the agent is reminded once to write a handoff note before native compaction kicks in. Lower it for a smaller context window.

Full installation guide: [`docs/install.md`](./docs/install.md). Slash command reference, agent roster, and response-protocol details: [`AGENTS.md`](./AGENTS.md), [`concise-agent-protocol.md`](./concise-agent-protocol.md).

---

## Contributing

Small, opinionated kit. New skills, slash commands, and subagent roles welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the scaffolding pattern, test discipline, and issue format.

---

## License

MIT. See [`LICENSE`](./LICENSE).
