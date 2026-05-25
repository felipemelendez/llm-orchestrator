# Architecture

LLM Orchestrator is folder-shaped. No runtime, no daemon, no compiled binary. The whole system is markdown + JSON + small shell scripts + a few plain-text files in the user's home directory for memory.

This document has two parts. The first part — **Eight layers** — is a failure-mode-oriented walkthrough of what the system does and why each piece exists. The second part — **Component contract** — is the implementation reference: file shapes, frontmatter rules, hook profiles, data flow.

If you want the pitch with worked examples, read the [`README.md`](./README.md). If you want to understand the system to extend it, read this file.

---

## Eight layers

Each solves one of the failure modes that single-agent AI tooling exhibits on real multi-step work.

### Layer 1 — Memory (defers to native, classifies on write)

User-curated project facts live in **your project's `CLAUDE.md`** — Claude Code's native memory. The plugin doesn't reinvent that surface. What it adds is on the write side: `/llm-orchestrator:remember Dana owns the billing service` classifies the fact (Conventions / Decisions / People / Notes) and appends it under the right `## Section` of `./CLAUDE.md`, creating sections as needed. `/llm-orchestrator:forget` soft-deletes matching lines to `~/.llm-orchestrator/memory/.trash/` so accidents are recoverable. Concurrent-safe writes via a portable file lock (`flock` where available, atomic `mkdir` fallback). Cross-project facts go to `~/.claude/CLAUDE.md` the same way.

Plugin-internal memory at `~/.llm-orchestrator/memory/<project-hash>.md` exists only for research-gate state — `## Research config` (aggressiveness knob) and `declined_mcp:` entries — read by the gate hook at trigger time, not loaded ambient. For cross-session continuity, use Claude Code's native `claude --continue` (full JSONL replay) or `/resume` to pick from history. For mid-session lookups, `grep ./CLAUDE.md`.

### Layer 2 — Workflow scaffolding (skills + commands)

Every task category has a defined workflow that produces a durable artifact:

| You ask for...           | Workflow                            | Artifact written                    |
|--------------------------|-------------------------------------|--------------------------------------|
| An open-ended feature    | `brainstorming` skill               | `docs/llm-orchestrator/specs/...md`  |
| Visual brainstorming     | `brainstorming` skill (visual companion) | browser mockups + `docs/llm-orchestrator/specs/...md` |
| Implementation of a spec | `writing-plans` skill               | `docs/llm-orchestrator/plans/...md`  |
| Adversarial spec/plan review | `brainstorming` / `writing-plans` review step | issues list before implementation begins |
| A bug fix                | `systematic-debugging` skill        | failing test + minimal fix           |
| A code review            | `requesting-code-review` skill      | `docs/llm-orchestrator/reviews/...md`|

The spec file gets read by `/llm-orchestrator:plan` (which produces the plan file), the plan file gets read by `/llm-orchestrator:dispatch` (which executes it), and the plan file's checkboxes track state across `/clear`.

16 skills total. The catalog is intentionally small — past ~40 skills, discoverability collapses.

### Layer 3 — State machine for multi-step work

The `executing-plans` skill walks a plan task-by-task. State lives in two places:

1. **Task tools** (`TaskCreate`/`TaskUpdate`/`TaskList`, Claude Code's native task system) — in-memory state board: which task is `in_progress`, which are `pending`, which are `completed`.
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

Before `brainstorming` writes a spec or `writing-plans` writes a plan, the controller dispatches `orch-researcher` (Sonnet) to verify the planned approach against current docs and on-disk state. The researcher returns one of four outcomes: `VERIFIED`, `CONTRADICTED` (halts the workflow until the spec is revised), `COULDN'T_VERIFY` (annotates the spec), or `NOT_APPLICABLE`. The classifier in front of it is biased toward `SKIP` — most tasks don't trigger research.

---

## Component contract

How the pieces fit together at the file level.

### Skills

- File: `skills/<name>/SKILL.md`
- Frontmatter (required): `name`, `description`. Description starts with `Use when` or `You MUST` (imperative-force form).
- Frontmatter (optional): `tools`, `profile`.
- Body: short markdown. Sections: one-line purpose, When to use, When NOT to use, Steps, Output shape, Anti-patterns.
- Linter: `tests/validate-skills.sh`.

### Commands

- File: `commands/<name>.md`
- Frontmatter: `description`.
- Body: a prompt the harness sends when the user types `/<name>`. References skills by name.

### Hooks

- File: `hooks/hooks.json` wires events → `scripts/hooks/<name>.sh`.
- Profiles via env vars:
  - `ORCH_HOOK_PROFILE=minimal` — protocol bootstrap only (meta-skill SessionStart load).
  - `ORCH_HOOK_PROFILE=standard` (default) — adds UserPromptSubmit reminders, PreToolUse guard, SubagentStop validators, Stop-hook retention pruning, and the research gate.
  - `ORCH_HOOK_PROFILE=strict` — all hooks active; protocol grader blocks on malformed replies (`ORCH_STRICT_PROTOCOL=1`); subagent stop blocks on malformed Status blocks (`ORCH_STRICT_STATUS=1`).
- Disable individual hooks with `ORCH_DISABLED_HOOKS="hook-a,hook-b"`.

### Templates

- File: `templates/<name>.md`.
- Used by commands. Output committed to `docs/llm-orchestrator/{specs,plans,reviews}/YYYY-MM-DD-<slug>.md`.

### Memory

- **User-facing facts** live in Claude Code's native `./CLAUDE.md` (project) and `~/.claude/CLAUDE.md` (user). `/remember` classifies on write into `## Conventions` / `## Decisions` / `## People` / `## Notes`. `/forget` soft-deletes to `~/.llm-orchestrator/memory/.trash/`. Both go through `with_lock` (`scripts/lib/orch-lock.sh`, portable across macOS/Linux).
- **Plugin-internal state** lives at `~/.llm-orchestrator/memory/<project-hash>.md` — reserved for `## Research config` (aggressiveness knob) and `declined_mcp:` entries. Read at trigger time by `orch-research-gate.sh`, not at SessionStart.
- **Research cache + brief index** live at `~/.llm-orchestrator/research/cache/<hash>/` and `~/.llm-orchestrator/research/briefs-index/<hash>.md`. Written by the SubagentStop validator after `orch-researcher` returns; read by the gate hook on the next compelled trigger.
- `<project-hash>` = SHA-1 of (a) git remote origin URL, (b) repo root path, or (c) cwd, in that order. Resolved by `scripts/lib/orch-project.sh`.
- SessionStart loads the using-orchestrator meta-skill only. CLAUDE.md loading is Claude Code's native responsibility.
- No background observer. No surveillance hooks.

---

## Layer stack (visual)

```
┌──────────────────────────────────────────────────────────────────┐
│ Harness (Claude Code, Codex, Gemini, Copilot)                    │
│   - loads skills, commands, hooks                                │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Bootstrap: SessionStart hook                                     │
│   - injects using-orchestrator (Concise Agent Protocol)          │
│     wrapped in EXTREMELY_IMPORTANT directive framing             │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Skills (skills/<name>/SKILL.md)                                  │
│   - on-demand via Skill tool                                     │
│   - one file each, two-key frontmatter                           │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Commands (commands/<name>.md)                                    │
│   - user-typed `/<name>`                                         │
│   - body is a prompt; references skills + templates              │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Templates (templates/*.md)                                       │
│   - plan, spec, review, implementer/reviewer prompts             │
│   - artifacts get committed to docs/llm-orchestrator/            │
└─────┬────────────────────────────────────────────────────────────┘
      │
      ▼
┌──────────────────────────────────────────────────────────────────┐
│ Hooks (hooks/hooks.json → scripts/hooks/*.sh)                    │
│   - SessionStart (bootstrap), UserPromptSubmit (reminder),       │
│     PreToolUse (guard), SubagentStop (validators + researcher-   │
│     validator), Stop (retention pruning + protocol grader)       │
│   - profiles: minimal | standard | strict                        │
└──────────────────────────────────────────────────────────────────┘

User home directory (created on first use):
  ~/.llm-orchestrator/
  ├── memory/<project-hash>.md             plugin-internal: ## Research config + declined_mcp only
  ├── memory/.trash/                       soft-deleted lines from /forget
  ├── research/cache/<hash>/<lib>.md       dated doc snapshots per library
  └── research/briefs-index/<hash>.md      brief retrieval index for compounding lookups

User-curated project facts live in Claude Code's native ./CLAUDE.md (loaded by
Claude Code itself, not by this plugin's SessionStart hook).
```

---

## Why this shape

- **No runtime** means the kit works in any harness that can read markdown and run shell.
- **One file per skill** keeps discovery cheap. `ls skills/` is the catalog.
- **Plain-markdown memory** is grep-able, readable, editable, and trivially backed up.
- **Single hooks.json** with calls to `scripts/hooks/*.sh` keeps logic out of inline `node -e` strings.
- **Templates committed to the project** create version-controlled handoffs between phases.

---

## Data flow: one example feature

1. User: "Add support for X."
2. Research gate fires if X touches a library or version (Layer 8). If `CONTRADICTED`, the workflow halts here.
3. Agent invokes `brainstorming` → writes `docs/llm-orchestrator/specs/2026-05-23-X-spec.md`. User reviews.
4. Agent invokes `writing-plans` → writes `docs/llm-orchestrator/plans/2026-05-23-X-plan.md`. User reviews.
5. Agent runs `/llm-orchestrator:worktree` to isolate.
6. Agent runs `/llm-orchestrator:dispatch` per task → implementers return `Status:` blocks. Parallel where independent, sequential where dependent.
7. Agent runs `/llm-orchestrator:review` → spec-reviewer then code-reviewer return `Issues:` blocks. BLOCKED recovery routes invisibly.
8. Agent invokes `verification-before-completion` before claiming done.
9. Agent runs `/llm-orchestrator:finish` → merge / PR / keep / discard menu.
10. Next session resumes via Claude Code's native `claude --continue` or starts fresh; project conventions persist via CLAUDE.md; research priors via the gate hook's cache + brief-index reads.

---

## What lives where

| Path                          | Purpose                                          |
|-------------------------------|--------------------------------------------------|
| Repo root                     | First-look docs (README, LICENSE, ARCHITECTURE)  |
| `docs/`                       | Install guide, manual testing, methodology       |
| `skills/`, `commands/`        | Machine-readable artifacts the harness loads     |
| `agents/`                     | Subagent definitions (`orch-implementer`, etc.)  |
| `templates/`                  | Spec / plan / review templates committed per use |
| `hooks/`, `scripts/`          | Glue + runtime guardrails                        |
| `examples/`                   | Plugin manifest examples                          |
| `docs/examples/`              | Illustrative response-shape examples             |
| `tests/`                      | Validators (smoke, drift detection, portability) |

---

## Non-goals

- Not a multi-agent runtime. Agents are dispatched by the harness, not orchestrated by us.
- Not a surveillance system. PostToolUse capture is out of scope; memory is opt-in.
- Not a security framework. We expose hook profiles; the harness owns sandboxing.
- Not a skill catalog warehouse. We cap first-party skills at ~40 by design.
