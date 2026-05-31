# LLM Orchestrator

[![License](https://img.shields.io/github/license/felipemelendez/llm-orchestrator?color=blue)](./LICENSE) [![Last commit](https://img.shields.io/github/last-commit/felipemelendez/llm-orchestrator)](https://github.com/felipemelendez/llm-orchestrator/commits/main) ![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)

A team of specialized Claude Code subagents — architect, implementer, two reviewers, debugger, explorer, and a researcher that verifies external APIs against current docs before any spec is written. A controller routes work between them: plans tasks, dispatches in parallel where independent, runs two-stage code review on every diff, and recovers from blockers autonomously.

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

**Model recommendation:** Run Claude Code's controller on **Opus** (or whatever is the latest, most-capable Claude Code model). The orchestrator is tuned for the best available model — multi-stage research, parallel dispatch, two-stage review, and the handoff layer all benefit from Opus-class reasoning. The handoff nudge's ~800K-token default assumes Opus's 1M-token context window; lower `ORCH_CONTEXT_HANDOFF_TOKENS` if you run the controller on a smaller-window model (e.g. Haiku).

---

## What it does

| Feature | What it does | Why it matters |
|---|---|---|
| **Research gate** | Verifies the planned approach against current docs (vendor MCPs, Context7, web) and on-disk state before any code is written | Catches deprecated APIs and bad version assumptions before they ship |
| **Two-stage code review** | Spec-compliance reviewer, then code-quality reviewer — each in a fresh subagent context. When Claude Code's dynamic workflows are available, the stages run as one parallel, self-checking script; otherwise the same review runs step by step | Catches bugs implementers miss in their own diffs |
| **Dynamic-workflow acceleration** | The code review (and, next, parallel implementation) can run on Claude Code's dynamic workflows — a deterministic script that fans the agents out, returns their findings in a structured form, and has independent agents try to disprove each finding before you see it. The plain step-by-step path keeps the kit working in any tool that can read markdown and run shell | Uses Anthropic's newest orchestration engine where it genuinely helps, without tying the kit to one tool |
| **Autonomous BLOCKED recovery** | When an agent gets stuck, the controller tries four autonomous fixes before paging you: paste the missing context, run the prerequisite task first, split the work into smaller steps, or retry with a stronger model (a fifth branch surfaces to you) | Most blockers resolve without paging you |
| **Parallel dispatch** | Independent tasks fan out to multiple implementers in one batch; dependent ones serialize | 3 concurrent implementers ≈ 1 sequential's wall time |
| **Evidence-based completion** | Every "done" claim must include the output of the command that proves it — the test result, the typecheck pass, the linter exit code | Stops agents from declaring code finished without actually running the tests |
| **CLAUDE.md classification** | `/remember <fact>` appends the fact to your project's CLAUDE.md (Claude Code's native memory file) under the right section — `## Conventions`, `## Decisions`, `## People`, or `## Notes` — chosen automatically | Persistent project memory without you having to organize it by hand |
| **Visual brainstorming** | During brainstorming, a local zero-dependency panel server (you open the printed `localhost` URL) renders live HTML mockups; the agent pushes screens and reads your clicks back, iterating before any code is written | Lets you see and react to UI/layout/structure choices instead of parsing them from prose |
| **Spec & plan review** | A fresh reviewer subagent checks the spec, then the plan, for completeness, internal consistency, ambiguity, and scope before implementation begins — an advisory verdict biased toward approval that loops back only on real gaps | Catches design flaws that both author and standard reviewer miss |
| **Protocol grader** | The Stop hook `scripts/hooks/orch-protocol-grader.sh` grades the controller's reply on each Stop event against the six Concise Agent Protocol shapes (when the hook is active); non-blocking by default, set `ORCH_STRICT_PROTOCOL=1` to block | Keeps agent output machine-readable and reviewable over long sessions |
| **Toolchain-aware verification** | Before running any verify command, the orchestrator detects the test runner and build tool from manifest/config files on disk (package.json, pyproject.toml, Cargo.toml, go.mod, Makefile), then uses those exact commands in `Verify:` lines | Prevents false "tests passed" from running the wrong test runner |
| **Regression guard** | When a worktree is created the baseline test suite is captured; before a branch is merged or a PR opened, the suite is re-run and finishing is refused if a previously-green test now fails | Catches regressions introduced by the implementer before the branch lands |
| **Security review** | `orch-security-reviewer` runs as an optional third review pass, scanning the diff for injection risks, missing auth checks, exposed secrets, and unsafe dependency patterns | Surfaces common security issues that code-quality reviewers are not specifically looking for |
| **Convention detection** | The orchestrator can detect repo conventions on demand (`orch_detect_conventions`) to help seed `./CLAUDE.md`; subagents read conventions from `./CLAUDE.md` (kept lean, not auto-injected into every task prompt) | Conventions stay in one place you control; detection is available when you need to bootstrap or audit them |
| **Architecture grounding** | Per-task brainstorming silently reads the recorded `## Decisions`/`## Conventions` from `./CLAUDE.md` (and the arch cache) and applies them as constraints on the spec — no questions, no explorer dispatch. A diff that breaks a recorded decision is flagged by the code reviewer. | Stops a new feature from silently violating an established choice — e.g. adding a network dependency to an offline-first SQLite app |
| **One-time codebase onboarding** | `/llm-orchestrator:onboard` studies the codebase once (stack, data layer, module boundaries, error handling, key dependencies) and proposes `## Decisions` + `## Conventions` for `./CLAUDE.md` behind a single approval gate. Idempotent — skips if already run. After that, every task reads those decisions silently. | Seeds CLAUDE.md with the codebase's load-bearing decisions so every future implementer and reviewer works from the same constraints, without you having to write them by hand |
| **Context-aware handoff** | On a long task, the agent is nudged once (when context crosses ~800K tokens) to write a short handoff note; after the context is auto-compacted, a reminder tells the next turn to re-read it, reconcile against the plan, and re-verify | A long run continues cleanly across a compaction instead of drifting on a lossy summary |

> **"When dynamic workflows are available"** — that means you're running inside Claude Code, on a recent enough version (the feature shipped 2026-05-28), and the work has opted into it. In that case the review runs as one fast, self-checking parallel script. Anywhere else — a different tool, an older Claude Code — the *same* review runs the original step-by-step way. You never lose the review, only the speed-up. The kit doesn't probe for the tool; it simply tries the workflow path and falls back if it isn't there. Force the choice with `ORCH_WORKFLOWS=1` (always prefer) or `ORCH_WORKFLOWS=0` (always use the step-by-step path).

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

Eight specialists, each with a single responsibility, a model chosen to match its job, and a fresh context window per dispatch. The controller routes work between them using a `Status:` enum (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT).

```
You
 ↓
Controller (the agent you talk to)
 ↓
 ├─ orch-brainstormer   → spec
 ├─ orch-researcher     → verification brief
 ├─ orch-implementer ×N → code (TDD)
 ├─ orch-spec-reviewer       → does the diff match the spec?
 ├─ orch-code-reviewer       → is it idiomatic, safe, minimal?
 ├─ orch-security-reviewer   → injection, auth, secrets, unsafe deps
 ├─ orch-debugger            → root cause
 └─ orch-explorer            → cheap reads (Haiku)
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
| `orch-security-reviewer` | Sonnet | Checks diffs for injection, auth gaps, exposed secrets, unsafe deps. |

The controller — the agent you interact with — holds state via the native Task tools (`TaskCreate`/`TaskUpdate`/`TaskList`), ticks plan-file checkboxes (which survive `/clear`), runs the BLOCKED recovery tree, and routes tasks to parallel or sequential dispatch.

Adding a role (`orch-refactorer`, `orch-security-reviewer`, `orch-test-writer`) is one new markdown file in `agents/` plus wiring it into a workflow skill or template — `./tests/validate-skills.sh` then confirms shape.

---

## The workflow

Each phase is a skill the controller invokes before acting. Mandatory checks, not suggestions — the controller scans for the relevant skill at every step and refuses to skip.

1. **`research-classifier`.** Fires before any spec is written if signals match (library + version, vendor API, security verb, architectural change). Emits `RESEARCH_NEEDED` or `RESEARCH_SKIP`. On `RESEARCH_NEEDED`, the controller dispatches the `orch-researcher` subagent, which returns a brief with one of four outcomes: `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`. `CONTRADICTED` halts the workflow before the spec is drafted.
2. **`brainstorming`.** Refines the rough idea through clarifying questions, explores alternatives in sections for validation. Writes the spec to `docs/llm-orchestrator/specs/<date>-<slug>.md`. A fresh `orch-spec-reviewer` subagent then checks the spec for completeness, consistency, clarity, and scope before planning — an advisory verdict (`Approved` | `Issues Found`); on issues the controller revises and re-checks, capped at 3 passes, then surfaces anything unresolved to you.
3. **`using-git-worktrees`.** Isolates the work on a new branch in a dedicated worktree. Captures a green test baseline when one is obvious; defers to the user when it isn't.
4. **`writing-plans`.** Breaks the approved spec into bite-sized tasks. Every task lists exact files, complete code stubs where useful, and verification steps. A fresh general-purpose reviewer subagent then checks the plan against the spec for completeness, spec-coverage, and buildability before any task is dispatched — advisory, same 3-pass cap. Plan committed to `docs/llm-orchestrator/plans/<date>-<slug>.md` — its checkboxes are the durable state and survive `/clear`.
5. **`executing-plans` → `dispatching-subagents` / `dispatching-parallel-agents`.** Dispatches a fresh-context subagent per task. Independent tasks fan out in parallel; dependent ones serialize. The controller scans plan-task bodies for symbol references that other tasks introduce and downgrades wrongly-claimed independence to sequential.
6. **`test-driven-development`.** Red-green-refactor inside each implementer: failing test first, watch it fail, write minimal code, watch it pass, commit. If implementation gets written before its test, the skill instructs the implementer to delete it and start over test-first.
7. **`requesting-code-review`.** Two reviewers in fresh contexts per task. Stage 1 — spec compliance: does the diff match what was specified? Stage 2 — code quality: correct, safe, idiomatic, minimal? Issues raised only at ≥80% confidence; lower-confidence observations land in a separate `Notes:` section.
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

1. **Memory** — additive to Claude Code's native CLAUDE.md, not a replacement. `/remember` auto-classifies facts into `## Conventions` / `## Decisions` / `## People` / `## Notes` of your project's `./CLAUDE.md`, creating sections as needed. `/forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent sessions serialize writes through a portable file lock. Alongside CLAUDE.md, the plugin maintains a TTL-pruned doc cache and a brief index under `~/.llm-orchestrator/research/` that surfaces prior researcher verdicts to future tasks on the same library.
2. **Workflow scaffolding** — skills and commands produce durable artifacts (specs, plans, reviews) committed under `docs/llm-orchestrator/`.
3. **State machine** — the native Task tools plus plan-file checkboxes survive `/clear`. The next session reads the plan file and knows exactly where to resume.
4. **Dispatch routing** — parallel for independent tasks, sequential for dependent. The controller scans plan-task bodies for symbol references to other tasks and downgrades `Independent: yes` to sequential when it spots a real dependency.
5. **Autonomous BLOCKED recovery** — when a subagent returns `Status: BLOCKED`, the controller routes through a 5-branch tree (missing context, sibling wait, decomposition, model escalation, or genuinely needs the user). Branches 1–4 happen invisibly; only branch 5 ever reaches you.
6. **Two-stage code review** — fresh-context reviewers, told explicitly not to trust the implementer. Issues raised only when ≥80% confident; lower-confidence observations go into a separate `Notes:` section.
7. **Evidence-based completion** — every `Changed:` block requires a `Verify:` line with the actual command and its output. A per-turn hook reinforces the rule.
8. **Pre-spec verification — the research gate** — described above. Returns `VERIFIED` / `CONTRADICTED` / `COULDN'T_VERIFY` / `NOT_APPLICABLE`; `CONTRADICTED` halts the workflow until the spec is revised.
9. **Context-aware handoff** — on a long task the controller's context window fills up, which quietly degrades its work. When usage crosses ~800K tokens the agent is reminded once to write a short handoff note (what's done, what's next, the verify command); after Claude Code auto-compacts the conversation, a reminder tells the next turn to re-read that note, trust the plan file's checkboxes, and re-run the tests before continuing. The plan file remains the durable recovery anchor.

Implementation reference with code links and the layer-stack diagram: [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Install from source

For contributors and local development:

```bash
git clone https://github.com/felipemelendez/llm-orchestrator
cd llm-orchestrator
./tests/smoke.sh                           # → "All 61 checks passed."
claude --plugin-dir "$(pwd)"               # session-mount the plugin for live iteration
```

Plugin code (skills, hooks, agents, commands) is read once at startup — there is no in-session reload. After editing files in the repo, restart Claude Code (or relaunch with `--plugin-dir`) to pick up the changes; `/clear` is not enough.

Other modes:

- **Persistent symlink.** `./scripts/install.sh --link` then `/plugin marketplace add ~/.claude/llm-orchestrator`.
- **Per-project copy.** `./scripts/install.sh --copy <project-dir>` — copies the plugin into a project's `.claude/` directory.
- **Minimal hook profile.** `ORCH_HOOK_PROFILE=minimal` — bootstrap only; skips per-turn protocol reminders and the research gate.
- **Disable specific hooks.** `ORCH_DISABLED_HOOKS=orch-research-gate,orch-stop`.
- **`ORCH_CONTEXT_HANDOFF_TOKENS`.** Default `800000` — the token count at which the agent is reminded once to write a handoff note before native compaction kicks in. Lower it for a smaller context window.

Full installation guide: [`docs/install.md`](./docs/install.md). Slash command reference, agent roster, and response-protocol details: [`AGENTS.md`](./AGENTS.md), [`concise-agent-protocol.md`](./concise-agent-protocol.md).

---

## Contributing

Small, opinionated kit. New skills, slash commands, and subagent roles welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the scaffolding pattern, test discipline, and issue format.

---

## License

MIT. See [`LICENSE`](./LICENSE).
