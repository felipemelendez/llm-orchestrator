# LLM Orchestrator

**Deploy a coordinated team of AI engineers to any codebase.**

An implementer, a debugger, an architect, an explorer, two reviewers, and a researcher who verifies the team's parametric knowledge against current sources before any spec or plan gets written. They're coordinated by a controller that plans multi-step features, dispatches work in parallel where possible, reviews every diff in two stages, recovers from blockers autonomously, verifies with real evidence, and remembers your project across sessions.

**You delegate the work. The team executes. You merge the PR.**

A structured operating layer on top of Claude Code's native primitives — agents, skills, hooks, plan files. Not a prompt pack. The team has roles, a state machine, a verdict enum, persistent memory, autonomous blocker recovery, and verification that pastes real test output. All plain markdown and shell scripts. No runtime, no daemon, no vendor lock-in.

```
   You: "Add multi-tenant rate limiting with per-tenant Postgres policies."

   ┌─ Controller ──────────────────────────────────────────────────────────┐
   │                                                                       │
   │   orch-brainstormer (Opus)   ──→  writes spec, you approve            │
   │   /llm-orchestrator:plan     ──→  5 tasks identified                  │
   │                                   2 independent + 3 dependent         │
   │   /llm-orchestrator:worktree ──→  isolated branch                     │
   │                                                                       │
   │   ┌── Parallel batch ──────────────────────────────────────────┐      │
   │   │  orch-implementer #1 (Sonnet)  ──→  Status: DONE           │      │
   │   │  orch-implementer #2 (Sonnet)  ──→  Status: DONE           │      │
   │   └────────────────────────────────────────────────────────────┘      │
   │                                                                       │
   │   ┌── Sequential with per-task review ─────────────────────────┐      │
   │   │  orch-implementer #3   ──→  BLOCKED — needs #1's schema    │      │
   │   │    └── Branch 2: paste sibling output, re-dispatch         │      │
   │   │  orch-implementer #3   ──→  Status: DONE                   │      │
   │   │  orch-spec-reviewer    ──→  Ready: yes                     │      │
   │   │  orch-code-reviewer    ──→  Ready: with-fixes (1 Important)│      │
   │   │    └── re-dispatch implementer with fix list               │      │
   │   │  orch-implementer #3   ──→  Status: DONE                   │      │
   │   │  orch-code-reviewer    ──→  Ready: yes                     │      │
   │   │  [tick plan checkbox]                                      │      │
   │   │  …repeat for #4, #5…                                       │      │
   │   └────────────────────────────────────────────────────────────┘      │
   │                                                                       │
   │   /llm-orchestrator:verify   ──→  pnpm test → 47 passed               │
   │   /llm-orchestrator:finish   ──→  recommendation: Push + open PR      │
   │                                                                       │
   └───────────────────────────────────────────────────────────────────────┘

   You: review the PR, hit merge.
   Total interruptions: 0.
```

---

## Meet the team

The starting roster ships seven specialists. The architecture is open — adding a role (`orch-refactorer`, `orch-security-reviewer`, `orch-test-writer`) is one new markdown file plus a `./tests/validate-skills.sh` run. Each agent has a single responsibility, a model chosen to match its job, and a fresh context window per dispatch. The controller routes work between them using a `Status:` enum (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT).

| Agent                  | Model  | Job                                                                  |
|------------------------|--------|----------------------------------------------------------------------|
| `orch-brainstormer`    | Opus   | Open-design explorer. Asks 3 clarifying questions, writes the spec.  |
| `orch-implementer`     | Sonnet | Executes one plan task with TDD. Returns `Status:` block.            |
| `orch-spec-reviewer`   | Sonnet | Stage 1 of review: does the diff match the spec?                     |
| `orch-code-reviewer`   | Sonnet | Stage 2 of review: is the code correct, safe, idiomatic, minimal?    |
| `orch-debugger`        | Sonnet | Root-cause investigator. Diagnoses bugs; does not patch them.        |
| `orch-explorer`        | Haiku  | Read-only codebase scout. Returns `file:line` refs. Cheap and fast.  |
| `orch-researcher`      | Sonnet | Verifies the team's parametric knowledge against current sources before any spec or plan. |

Plus the controller — the agent you talk to — which holds state in `TodoWrite`, ticks plan-file checkboxes, runs the BLOCKED recovery tree, and decides whether tasks fan out in parallel or run sequentially with per-task review.

---

## What this is, briefly

A **Claude Code plugin**: a folder of skills, slash commands, native subagents, and hooks that Claude Code loads automatically. If you've used Claude Code's plugin marketplace, this drops in like any other. If you haven't: it's [Anthropic's terminal coding agent](https://www.anthropic.com/claude-code) — install with `npm install -g @anthropic-ai/claude-code`, then come back.

The plugin adds 10 slash commands prefixed `/llm-orchestrator:`, 16 skills the agent invokes on demand, 7 named subagents, and a few hooks that bootstrap the response protocol, gate research before specs are written, and prune retention.

---

## The problem this solves

AI coding agents are powerful, but you can't trust them with real multi-step work yet. They fail in predictable ways:

- **They forget.** Every new session starts cold. You re-explain your stack, conventions, and team decisions every time.
- **They drift.** Hand them a 5-task feature and they lose track between tasks. They ask "ready to proceed?" after every step, breaking your flow.
- **They stop at the first obstacle.** A subagent blocks, the pipeline halts, you context-switch to unblock them.
- **They claim "done" without proof.** "Tests should pass" instead of "tests pass: 47 of 47."

These aren't intelligence problems — they're **structure** problems. LLM Orchestrator adds the structure: roles, a state machine, durable artifacts, autonomous recovery, evidence-based verification.

---

## Verifies before it commits

Two real runs in this repo, both fired before any spec or plan was written.

**Catch 1 — Stripe webhooks.** A spec proposed a Stripe webhook handler for a custom event named `tenant_policy.updated`. The researcher checked Stripe's actual webhook event types against docs.stripe.com:

> **Spec assumed:** Stripe will deliver a custom webhook event named `tenant_policy.updated`.
>
> **Docs say (Stripe 2026-04-22.preview):** Stripe webhooks only deliver Stripe's predefined event types. There is no custom-event API.
>
> **Severity:** Critical — the planned API surface does not exist.
>
> *— excerpt from [docs/examples/2026-05-24-stripe-webhook-contradicted-brief.md](./docs/examples/2026-05-24-stripe-webhook-contradicted-brief.md)*

Wall-clock: under 60 seconds. User intervention: zero. What was saved: a feature that would have failed at the first webhook delivery test because Stripe wasn't going to send that event.

**Catch 2 — `/cost` command.** A task proposed parsing Claude Code's JSONL transcripts to tally token spend per session. The researcher checked the actual transcripts on disk and Anthropic's current pricing page and surfaced four implementation-altering caveats before the spec was written: no OS env var for session ID, `cache_creation_input_tokens` is a sum of two different rate buckets, $10/1k web-search surcharge needs separate accounting, Opus 4.7 tokenizer can inflate token counts up to 35%. The brief: [docs/examples/2026-05-24-cost-command-verified-brief.md](./docs/examples/2026-05-24-cost-command-verified-brief.md).

### Two epistemic shapes

Verification questions split into two kinds, and the authoritative source is different for each:

- **SOURCES — "what should be."** Current API surface, recommended pattern, deprecation status, vendor expectations, advisory data. Routed to the MCP world: vendor MCPs first (Stripe MCP for Stripe APIs, etc.), Context7 / DeepWiki for general library docs, GitHub MCP for changelogs and advisories.
- **LOCAL_STATE — "what is."** What's installed, what's in a config file, what an on-disk artifact actually contains. Routed to the local disk: `Read`, `Grep`, `Bash`. No MCP is more authoritative than the file itself for state questions.

A single task often spans both — the `/cost` brief above ran SOURCES questions for vendor pricing and LOCAL_STATE questions for the JSONL schema on disk in the same dispatch. Each question gets answered on the axis that fits it.

### How it fires

One gate, two trigger points: **before brainstorming writes a spec**, and **before writing-plans writes a plan**. Nowhere else. A deterministic regex sniffer screens the input first; then a skill-driven classifier decides. **The classifier is biased toward SKIP** — most tasks don't trigger research, and the default behavior is silent. That's deliberate: a gate that fires on everything becomes noise, and noise is how features die. The gate stays out of the way until it earns its keep.

When it does fire, the researcher (a dispatched subagent, fresh context) produces a brief in 30–60 seconds with one of four outcomes:

- `VERIFIED` — docs confirm the plan; proceed.
- `CONTRADICTED` — docs say the plan is wrong; **halts the workflow** until the spec is revised. (The Stripe case.)
- `COULDN'T_VERIFY` — docs unreachable; proceed with low confidence, annotated in the spec.
- `NOT_APPLICABLE` — the question's premise doesn't hold in this repo (e.g., "is there a CVE for our React version?" in a repo with no React).

### What it doesn't do

It doesn't replace human review, doesn't verify business logic, and doesn't catch bugs in your own code — only stale knowledge about external API surfaces. One gate at two specific workflow points, narrowly scoped.

---

## When NOT to use this

Be honest about scope:

- **One-line fixes or single-file edits.** The orchestration overhead isn't worth it. Just edit the file.
- **Throwaway scripts and prototypes.** Skip the plan/dispatch dance — write the code.
- **Projects where you want the AI to surprise you.** The structure intentionally constrains the agent into a recognizable workflow.

Use it for: multi-step features, non-trivial refactors, debugging that needs investigation before fixing, code review at scale, work you want to delegate and walk away from.

---

## How it works (deep dive)

Eight layers. Each solves one of the failure modes above.

### Layer 1 — Memory (defers to native, classifies on write)

User-curated project facts live in **your project's `CLAUDE.md`** — Claude Code's native memory. The plugin doesn't reinvent that surface. What it adds is on the write side: `/llm-orchestrator:remember pnpm not npm` classifies the fact (Conventions / Decisions / People / Notes) and appends it under the right `## Section` of `./CLAUDE.md`, creating sections as needed. `/llm-orchestrator:forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent-safe writes via a portable file lock (`flock` where available, atomic `mkdir` fallback). Cross-project facts go to `~/.claude/CLAUDE.md` the same way.

Plugin-internal memory at `~/.llm-orchestrator/memory/<project-hash>.md` exists only for research-gate state — `## Research config` (aggressiveness knob) and `declined_mcp:` entries — read by the gate hook at trigger time, not loaded ambient. For cross-session continuity, use Claude Code's native `claude --continue` (full JSONL replay) or `/resume` to pick from history. For mid-session lookups, `grep ./CLAUDE.md`.

### Layer 2 — Workflow scaffolding (skills + commands)

Every task category has a defined workflow that produces a durable artifact:

| You ask for...           | Workflow                            | Artifact written                    |
|--------------------------|-------------------------------------|--------------------------------------|
| An open-ended feature    | `brainstorming` skill               | `docs/llm-orchestrator/specs/...md`  |
| Implementation of a spec | `writing-plans` skill               | `docs/llm-orchestrator/plans/...md`  |
| A bug fix                | `systematic-debugging` skill        | failing test + minimal fix           |
| A code review            | `requesting-code-review` skill      | `docs/llm-orchestrator/reviews/...md`|

The spec file gets read by `/llm-orchestrator:plan` (which produces the plan file), the plan file gets read by `/llm-orchestrator:dispatch` (which executes it), and the plan file's checkboxes track state across `/clear`.

16 skills total. The catalog is intentionally small — past ~40 skills, discoverability collapses.

### Layer 3 — State machine for multi-step work

The `executing-plans` skill walks a plan task-by-task. State lives in two places:

1. **`TodoWrite`** (Claude Code's native tool) — in-memory state board: which task is `in_progress`, which are `pending`, which are `completed`.
2. **Plan file checkboxes** — `### 1. Implement nowIso() with TDD  - [ ]` flips to `- [x]` as each task completes. This is the **durable** state — it survives `/clear` and `/exit`.

If you `/clear` mid-orchestration, the next session reads the plan file, counts checked boxes, and knows exactly where to resume.

### Layer 4 — Parallel dispatch when work allows it

When multiple tasks are truly independent (no shared files, no order dependency), the controller dispatches them in **one batch** of parallel implementers. Three implementers running concurrently complete in roughly the time of one. The `dispatching-parallel-agents` skill encodes the routing logic; conflict detection after returns uses `git status --porcelain` to catch any overlap.

When tasks are dependent or touch shared files, the controller falls back to sequential dispatch with per-task review. A single plan can mix both — independent tasks go in a parallel group; dependent ones become sequential. The controller routes automatically.

### Layer 5 — Autonomous blocker recovery

When a subagent returns `Status: BLOCKED`, the controller reads the `Need:` line and routes through a 5-branch recovery tree **before** interrupting you:

```
BLOCKED: Need: <X>
   ├── Branch 1 (Missing context) ──→ paste it inline, re-dispatch
   ├── Branch 2 (Waiting on sibling task) ──→ dispatch sibling, paste output, re-dispatch
   ├── Branch 3 (Task too large/ambiguous) ──→ decompose into 2-3 subtasks
   ├── Branch 4 (Model can't reason about it) ──→ re-dispatch with stronger model
   └── Branch 5 (Genuinely needs the user) ──→ STOP — ask one specific question
```

Branches 1–4 happen invisibly. You only ever see branch 5. Most blocks in our test runs resolve in branches 1–2.

### Layer 6 — Two-stage code review

Every meaningful diff goes through two distinct review passes, each in a fresh subagent context to avoid implementer bias:

**Stage 1 — Spec compliance.** `orch-spec-reviewer` reads the spec, the plan, and the diff. The question: does the diff match what was specified? The reviewer is explicitly told: "Do not trust the implementer's DONE claim. Read the diff against the spec yourself."

**Stage 2 — Code quality.** Only runs after Stage 1 passes. `orch-code-reviewer` reads the diff against project conventions. Correctness, safety, idiom, minimalism, test coverage.

Both reviewers apply an explicit confidence threshold: **only raise an issue if ≥80% confident it's real**. Lower-confidence observations go into a separate `Notes:` section. This kills the "padding to look thorough" failure mode.

Verdict routing is mechanical:
- Critical issues → re-dispatch implementer immediately
- Important issues → re-dispatch
- Minor-only → record and carry forward (per the DONE_WITH_CONCERNS policy)

### Layer 7 — Evidence-based completion

Every claim of "done" includes the actual command output that proves it. A `Changed:` block without a `Verify:` line is incomplete:

```
Changed:
- src/users.ts:42 — guard against undefined session
- src/users.test.ts — new test: guest with no session
Verify:
- pnpm test → 142 passed (was 141 + 1 failing)
```

Reinforced two ways: a `UserPromptSubmit` hook injects a per-turn reminder of the rule, and a `verification-before-completion` skill auto-fires when the agent is about to claim something works. Failed verifications open with `Found:` (the bug) and a debugging path — not `Changed:`. The team never pretends.

### Layer 8 — Pre-spec verification

Before `brainstorming` writes a spec or `writing-plans` writes a plan, the controller dispatches `orch-researcher` (Sonnet) to verify the planned approach against current docs and on-disk state. The researcher returns one of four outcomes: `VERIFIED`, `CONTRADICTED` (halts the workflow until the spec is revised), `COULDN'T_VERIFY` (annotates the spec), or `NOT_APPLICABLE`. The classifier in front of it is biased toward `SKIP` — most tasks don't trigger research. See [Verifies before it commits](#verifies-before-it-commits) above for two real catches in this repo.

---

## What it costs to run

Seven subagents per feature sounds expensive. The architecture keeps token use bounded:

- **`orch-explorer` is Haiku** — the cheapest reads (file searches, "what files handle X") cost roughly a tenth of Sonnet.
- **Two-stage reviews dispatch reviewers, not new implementers.** Review passes read a diff and a spec; they don't rewrite anything.
- **Parallel dispatch shortens wall-clock time without multiplying tokens.** Three implementers running concurrently on independent tasks use roughly the same total tokens as one running sequentially.

Real per-feature dollar figures will land when the v0.2 `/cost` command ships — already verified via the research gate ([brief](./docs/examples/2026-05-24-cost-command-verified-brief.md)).

---

## Why this is a great project to extend

This is intentionally a small, opinionated kit. That's a feature for contributors:

- **Pure markdown + shell.** No runtime to learn. No build step. Add a skill in 10 minutes by copying `templates/skill.md`.
- **Small catalog (16 skills).** Your contribution actually gets noticed and used. Past ~40 skills the catalog gets unscannable — we cap there on purpose.
- **Real test suite.** Three scripts (`smoke.sh`, `validate-skills.sh`, `test-portability.sh`) run in 5 seconds and gate every commit. They catch regressions in JSON schemas, hook output formats, concurrency, portability (bash 3.2 / BSD / macOS), and shape-checking.
- **TDD-for-skills loop documented.** `writing-skills` walks through: write a skill, dispatch a test subagent with no other context, see if the subagent follows the skill, refine.
- **Native Claude Code primitives.** Your contribution works for everyone who uses Claude Code — no parallel platform support needed.
- **Honest about influences.** Borrows the single-file skill format from [Superpowers](https://github.com/obra/superpowers) and the memory model from [ECC](https://github.com/affaan-m/ECC). The comparison table credits each.
- **Hard non-goals.** No background observers. No on-by-default telemetry. No proprietary runtime.

To contribute a skill, command, or new subagent role:

```bash
# Skill
cp templates/skill.md skills/<your-name>/SKILL.md
$EDITOR skills/<your-name>/SKILL.md
./tests/validate-skills.sh    # must pass

# Slash command
$EDITOR commands/<your-name>.md
./tests/smoke.sh              # must pass

# New team role (subagent)
cp agents/orch-implementer.md agents/orch-<your-role>.md
$EDITOR agents/orch-<your-role>.md
./tests/validate-skills.sh
```

Open issues with this shape:

```
Found:
- <symptom or gap>
Recommendation:
- <what you'd add/change>
Next:
- <smallest first step>
```

---

## Quick Start

```bash
# 1. Clone and verify
git clone <this-repo> ~/code/llm-orchestrator
cd ~/code/llm-orchestrator
./tests/smoke.sh                                  # → "All 56 checks passed."

# 2. Install as Claude Code plugin
./scripts/install.sh --link                       # creates ~/.claude/llm-orchestrator symlink

# 3. In a Claude Code session
/plugin marketplace add ~/.claude/llm-orchestrator
/plugin install llm-orchestrator@llm-orchestrator # pick "Install for you (user scope)"

# 4. Restart Claude Code, then try memory
/llm-orchestrator:remember pnpm not npm
# Quit, reopen — Claude Code loads ./CLAUDE.md natively; the team will still know about pnpm
```

Project memory writes go to `./CLAUDE.md` (Claude Code native). Plugin-internal state lives at `~/.llm-orchestrator/` (override with `ORCH_HOME`). For per-project installs (`--copy`) and hook wiring, see [`docs/install.md`](./docs/install.md).

---

## A real session

Unedited transcripts from a test session.

### Asking for an approach gets a real plan

```
> What's the best approach to add a /cost command that tallies token spend?

Plan:
- 1. Locate the data source — Claude Code writes per-session JSONL
     transcripts under ~/.claude/projects/<hashed-cwd>/<session-id>.jsonl
- 2. Write a parser script that streams the JSONL, sums tokens per model
- 3. Externalize pricing in scripts/cost-pricing.json
- 4. Add skills/cost/SKILL.md
- 5. Support args: bare /cost = current session, --all = project totals

Risks:
- "Current session" detection is fragile — no documented env var
- Pricing drifts silently — needs a last_updated field

Verify after each step:
- Step 1: head -1 <one>.jsonl | jq '.message.usage'
- Step 2: run the parser, eyeball totals
```

Hand this back to the team as `/llm-orchestrator:plan` input. No re-prompting needed.

### Memory survives a full restart

```
> /llm-orchestrator:remember pnpm not npm

Changed:
- ./CLAUDE.md — added under Conventions
Verify:
- tail -10 ./CLAUDE.md
```

Quit Claude Code. Reopen — `./CLAUDE.md` is loaded natively at session start. Ask:

```
> What's our package manager?

Found:
- pnpm not npm — from ./CLAUDE.md, ## Conventions (2026-05-23)
```

For mid-orchestration continuity (resuming exactly where you left off across `/clear` or `--exit`), use Claude Code's native `claude --continue` — the conversation JSONL replays in full.

### The team recovers from a blocker without paging you

A 2-task plan where task 2 needs a constant exported by task 1. Dispatched task 2 first:

```
[orch-implementer runs task 2]
Status: BLOCKED
Need: src/constants.js exporting ISO_DATE_REGEX — file does not exist
Tried: ls src/ (only time.js present)
```

Controller routes via Branch 2 (waiting on sibling). Dispatches task 1, then re-dispatches task 2 with task 1's output pasted in.

```
[orch-implementer runs task 1]            Status: DONE
[orch-implementer runs task 2, retry]     Status: DONE
12 tests pass.
```

Three subagent dispatches, one autonomous recovery, zero user interruptions.

---

## Compared to other systems

### vs single-agent assistants (Cursor, Aider, Copilot, Devin)

Those give you **one** agent. Cursor and Copilot are excellent autocompletes with chat; Aider pairs with you on a single thread; Devin claims to be a single AI engineer. LLM Orchestrator gives you a **team** with role separation: an implementer who writes code, two reviewers who don't trust the implementer, a debugger who investigates before patching, an explorer that's cheap to dispatch for reads, and a designer that uses a stronger model for spec work. The team has a controller that routes work between them with structured status reporting. You stay in Claude Code; you don't switch tools.

### vs multi-agent kits (Superpowers, ECC)

| Dimension                                          | Superpowers      | ECC                  | LLM Orchestrator |
|----------------------------------------------------|------------------|----------------------|------------------|
| Named subagents with per-role model selection      | partial          | partial              | ✓ (7 roles)      |
| Parallel dispatch for independent tasks            | partial          | ✗                    | ✓                |
| Per-task two-stage review                          | ✓                | ✗                    | ✓                |
| Verifies parametric knowledge against current sources before generation | ✗ | ✗ | ✓ |
| Status enum (DONE / BLOCKED / etc.)                | ✓                | ✗                    | ✓                |
| BLOCKED recovery tree (autonomous)                 | ✗ (stops & asks) | ✗                    | ✓ (5 branches)   |
| Continuous execution (no "ready?" pauses)          | ✓                | ✗                    | ✓                |
| Cross-session memory (CLAUDE.md + classification)  | ✗                | ✓ (heavy / SQLite)   | ✓ (native + classifier on write) |
| Concurrent-safe writes                             | n/a              | partial              | ✓ (portable lock)|
| Soft-delete recovery (`/forget`)                   | n/a              | ✗                    | ✓ (`.trash/`)    |
| Privacy: no background observer                    | ✓                | ✗ (off by default)   | ✓                |
| Plan file as durable cross-clear state             | ✗                | ✗                    | ✓ (checkbox tick)|
| Native output style + per-turn reminder            | ✗                | ✗                    | ✓                |
| First-class on macOS bash 3.2                      | partial          | partial              | ✓                |
| First-party skill count                            | ~80              | 232                  | 16               |

Influences: borrows the single-file skill format and two-stage review from [Superpowers](https://github.com/obra/superpowers), and the cross-session memory model from [ECC](https://github.com/affaan-m/ECC). What's new here: a coordinated team of named, model-tiered agents; the 5-branch BLOCKED recovery tree; the portable concurrent-safe lock; the plan-checkbox state model that survives `/clear`.

---

## Recipes

### Fix a bug

```
> There's a bug in src/auth.ts — login fails for emails with apostrophes. Fix it.
```

`orch-debugger` is dispatched for root-cause analysis. `orch-implementer` follows TDD: failing test, minimal fix, verify with real test runner.

### Remember a project convention

```
/llm-orchestrator:remember we use tRPC for the internal API, not GraphQL
/llm-orchestrator:remember Sara owns the auth subsystem
```

Persists under `## Conventions` / `## People` / `## Notes` in `./CLAUDE.md` (Claude Code native memory). Loaded at the start of every future session by Claude Code itself.

### Recover from an accidental `/forget`

```
ls -1t ~/.llm-orchestrator/memory/.trash/
# Inspect the trash file, then append matching content back to the source file
# (typically ./CLAUDE.md or ~/.claude/CLAUDE.md depending on where the fact lived)
```

`/forget` always soft-deletes to `.trash/` before removing, regardless of source file.

---

## Reference

### Slash commands

| Command                            | Purpose                                                 |
|------------------------------------|----------------------------------------------------------|
| `/llm-orchestrator:init`           | Scaffold conventions + CLAUDE.md in a project           |
| `/llm-orchestrator:plan`           | Spec → dated, checklist-shaped plan                     |
| `/llm-orchestrator:worktree`       | Create isolated git worktree with provenance marker     |
| `/llm-orchestrator:dispatch`       | Execute plan tasks (auto-routes sequential vs parallel) |
| `/llm-orchestrator:review`         | Two-stage review (spec compliance, then code quality)   |
| `/llm-orchestrator:debug`          | Root-cause-first debugging                              |
| `/llm-orchestrator:verify`         | Run tests/lint/typecheck, report evidence               |
| `/llm-orchestrator:finish`         | Merge / PR / keep / discard menu                        |
| `/llm-orchestrator:remember`       | Append fact to CLAUDE.md (auto-classified by section)   |
| `/llm-orchestrator:forget`         | Soft-delete (with confirmation) to `.trash/`            |

### Hook profiles

Set `ORCH_HOOK_PROFILE` to one of:

- `minimal` — SessionStart bootstrap (Concise Agent Protocol load) only.
- `standard` (default) — SessionStart + UserPromptSubmit protocol reminder + PreToolUse guard against `--no-verify` + SubagentStop validator + Stop hook for retention pruning.

Disable individual hooks: `ORCH_DISABLED_HOOKS=orch-guard,orch-stop`.

Full skill and agent catalogs: [`AGENTS.md`](./AGENTS.md) for the team roster, [`architecture.md`](./architecture.md) for the architecture, [`concise-agent-protocol.md`](./concise-agent-protocol.md) for the response-format details.

---

## Testing

Three scripts gate every commit:

```bash
./tests/validate-skills.sh   # structural: frontmatter, names, length
./tests/test-portability.sh  # bash 3.2 / BSD / macOS safe
./tests/smoke.sh             # behavior: hooks, lock, install, classifier (~5s)
```

End-to-end testing inside a live Claude Code session: [`docs/manual-testing.md`](./docs/manual-testing.md).

---

## Roadmap & non-goals

See [`roadmap.md`](./roadmap.md) for upcoming work. Durable non-goals (we will never):

- Ship a proprietary runtime.
- Enable telemetry by default.
- Accept more than ~40 first-party skills.
- Add background observers. Memory is what you opt into via `/remember`.

---

## License

MIT.
