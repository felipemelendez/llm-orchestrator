# Architecture

LLM Orchestrator is folder-shaped. No runtime, no daemon, no compiled binary. The whole system is markdown + JSON + small shell scripts + a few plain-text files in the user's home directory for memory. One optional, additive exception: `workflows/*.js` — deterministic orchestration scripts for Claude Code's `Workflow` tool. These run only inside that harness and are a *preferred accelerator* for two layers (parallel dispatch and code review); the markdown path stays canonical. The skills/commands/agent prompts (markdown) are portable to any harness that can read them; the hook-based **enforcement** (protocol grader, research gate, guards, handoff) is Claude Code-specific — see "Why this shape" for the precise split. See the "Workflows" entry in the Component contract.

This document has two parts. The first part — **Nine layers** — is a failure-mode-oriented walkthrough of what the system does and why each piece exists. The second part — **Component contract** — is the implementation reference: file shapes, frontmatter rules, hook profiles, data flow.

If you want the pitch, read the [`README.md`](./README.md); for a worked example, see [`docs/examples/sample-session.md`](./docs/examples/sample-session.md). If you want to understand the system to extend it, read this file.

---

## Nine layers

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
| Spec/plan review (inline self-review; subagent escalation for high-stakes) | `brainstorming` / `writing-plans` review step | issues fixed before implementation begins |
| A bug fix                | `systematic-debugging` skill        | failing test + minimal fix           |
| A code review            | `requesting-code-review` skill      | `docs/llm-orchestrator/reviews/...md`|

The spec file gets read by `/llm-orchestrator:plan` (which produces the plan file), the plan file gets read by `/llm-orchestrator:dispatch` (which executes it), and the plan file's checkboxes track state across `/clear`.

18 first-party skills today, capped at ~40 by design — past that, discoverability collapses. Published skill-library research also reports that selection accuracy drops sharply once trigger descriptions become semantically confusable, so the binding constraint is distinct triggers, not the raw count.

### Layer 3 — State machine for multi-step work

The `executing-plans` skill walks a plan task-by-task. State lives in two places:

1. **Task tools** (`TaskCreate`/`TaskUpdate`/`TaskList`, Claude Code's native task system) — in-memory state board: which task is `in_progress`, which are `pending`, which are `completed`.
2. **Plan file checkboxes** — `### 1. Implement nowIso() with TDD  - [ ]` flips to `- [x]` as each task completes. This is the **durable** state — it survives `/clear` and `/exit`.

If you `/clear` mid-orchestration, the next session reads the plan file, counts checked boxes, and knows exactly where to resume.

### Layer 4 — Parallel dispatch when work allows it

When multiple tasks are truly independent (no shared files, no order dependency), the controller dispatches them in **one batch** of parallel implementers. Three implementers running concurrently complete in roughly the time of one. The `dispatching-parallel-agents` skill encodes the routing logic.

**The isolation invariant.** No two agents ever write the same working tree concurrently — concurrent writes to one checkout race and clobber each other (a parallel agent that ran `git stash` on the shared tree once silently discarded in-flight work; `git stash` internally runs `git reset --hard`). So parallelism is allowed in exactly two safe shapes: (1) **read-only fan-out** — reviewers, explorers, researchers only read and report, safe to run together on the shared checkout; (2) **isolated writers** — each parallel implementer runs in its own git worktree (separate dir + branch), and the controller merges the branches back **sequentially** after review. Two backstops enforce this beyond the prose: the read-only agent prompts forbid mutating git, and a `PreToolUse/Bash` guard (`scripts/hooks/guard-destructive-git.sh`) blocks working-tree-destroying commands for the controller and every subagent — `stash` save forms, `reset --hard/--keep/--merge`, `clean -f`, `checkout`/`switch` (branch switch *and* path discard), `restore` (worktree), `git rm -f`, `branch -D`, `worktree remove --force`, and `rm -rf` of `.git`/`.worktrees`. It normalizes git's global options (`-C <dir>`, `--git-dir=`, `-c k=v`) before matching, so `git -C /repo reset --hard` cannot slip past. Overridable only via `ORCH_ALLOW_DESTRUCTIVE_GIT=1` in the hook's own environment (an inline prefix in the scanned command does not disarm it). **Context-scoped:** the worktree-local commands (`stash`/`reset --hard`/`clean`/`checkout`/`restore`/`git rm`) are *allowed* when the command runs inside one of our isolated worktrees (detected fail-closed via `$PWD/.git` being a file + an `.orch-worktree` marker), so agents can freely test on a clean tree there — but they stay blocked on the shared main checkout, and a directory-retargeting form (`git -C`, `cd`, `env -C`, an interpreter) refuses the relaxation. The reach-beyond commands (`branch -D`, `worktree remove --force`, `rm -rf .git/.worktrees`, `stash drop/clear`) are blocked everywhere. The guard is the backstop; the primary control is structural — parallel writers run in **separate worktree directories**, so their file writes physically cannot collide, and the implementer agent returns `BLOCKED` if dispatched into a parallel batch without an isolated worktree.

**Merge-back (the join half).** Splitting safely is only half of orchestration; the value is the recombined result. `scripts/orch-worktree-integrate.sh` is the symmetric partner to materialize, and since v0.6 it runs a **speculative merge queue** by default — the discipline Zuul and GitHub merge queues use: all N branches are merged sequentially onto a throwaway integration branch in an isolated worktree, and the detected suite runs **once** against the combined tip. Green tip → the base fast-forwards to it atomically (N branches land for one suite run instead of N). Red tip → the engine first re-tests the *base* state inside the same worktree (a suite red for environmental reasons — untracked deps — must not eject an innocent branch; that case falls back to the serial engine), then bisects the merge points for the longest explicitly-tested-green prefix, lands exactly that, ejects the first failing branch (kept on the integration branch for inspection), and reports the rest `Pending` with a `Re-run:` line. The safety invariant is *stronger* than the old serial engine's: the base's only mutation is ever a `--ff-only` move to a suite-green SHA — it never holds an untested or half-merged commit. `--serial` keeps the original engine (merge → test → merge → test, failed merge left on base for inspection). Both modes abort conflicts cleanly, stop on empty branches (a BLOCKED writer that produced nothing must not silently "pass"), release registry claims, and remove merged worktrees.

When tasks are dependent or touch shared files — or the writers cannot be isolated — the controller falls back to sequential dispatch with per-task review (safe by construction: one writer on the tree at a time). A single plan can mix both — independent tasks go in an isolated-worktree parallel group; dependent ones become sequential. The controller routes automatically.

### Layer 5 — Autonomous blocker recovery

When a subagent returns `Status: BLOCKED`, the controller reads the `Need:` line and routes through a 5-branch recovery tree **before** interrupting you:

```
BLOCKED: Need: <X>
   ├── Branch 1 (Missing context) ──→ RESUME the same agent via SendMessage (by agentId)
   ├── Branch 2 (Waiting on sibling task) ──→ dispatch sibling, paste output, re-dispatch fresh
   ├── Branch 3 (Task too large/ambiguous) ──→ decompose into 2-3 subtasks
   ├── Branch 4 (Model can't reason about it) ──→ re-dispatch with stronger model
   └── Branch 5 (Genuinely needs the user) ──→ STOP — ask one specific question
```

Branches 1–4 happen invisibly. You only ever see branch 5 — the tree is designed so a blocker gets four autonomous resolution attempts before it costs the user attention.

Branch 1 (and `NEEDS_CONTEXT`) is a **resume, not a redo**: the controller sends the missing context to the blocked agent's `agentId` via `SendMessage`, and the agent continues with its full working context — the files it already read, the exact point it stopped — instead of a cold re-dispatch that re-derives everything (redo-from-zero is itself the step-repetition failure mode, MAST FM-1.3). Resume is scoped narrowly on purpose: branch 4 *cannot* resume (SendMessage has no model parameter), and branches 2–3 re-dispatch fresh because the ground truth of the task changed. The `PARTIAL` status (a fired `Stop if:` with `Progress:`/`Remaining:`) routes the same way — resume with unblocking guidance by default, fresh dispatch with the progress pasted when the transcript shows a retry storm.

### Layer 6 — Two-stage code review

Every meaningful diff goes through two distinct review passes, each in a fresh subagent context to avoid implementer bias:

**Stage 1 — Spec compliance.** `orch-spec-reviewer` reads the spec, the plan, and the diff. The question: does the diff match what was specified? The reviewer is explicitly told: "Do not trust the implementer's DONE claim. Read the diff against the spec yourself."

**Stage 2 — Code quality.** Only runs after Stage 1 passes. `orch-code-reviewer` reads the diff against project conventions. Correctness, safety, idiom, minimalism, test coverage.

Both reviewers are told to **report every finding and tag it with a confidence from 0.0 to 1.0** — explicitly not to be conservative. The controller (or `workflows/review-diff.js`) then demotes anything below 0.8 into a separate `Notes:` section; nothing is discarded. The threshold lives in the filter, never in the reviewer: an instruction to withhold is followed literally and costs recall, which is why Anthropic's Opus 5 guidance says to "ask it to report everything and filter in a separate pass instead." Padding is countered by the concrete-evidence rule on Critical findings, not by suppression.

Verdict routing is mechanical:
- Critical issues → re-dispatch implementer immediately
- Important issues → re-dispatch
- Minor-only → record and carry forward (per the DONE_WITH_CONCERNS policy)

**Execution substrate.** The review dimensions are independent and breadth-first, so when Claude
Code's `Workflow` tool is present this layer prefers `workflows/review-diff.js` — Stage 1 still
gates Stage 2 (early-exit on a spec mismatch), Stage 3 stays conditional on the
`scripts/lib/orch-signals.sh` security signal (passed in, not re-derived), findings are
confidence-filtered and adversarially verified before they surface. The canonical markdown stages
remain the fallback. Routing lives in the `using-workflows` skill. The same substrate is the
planned path for Layer 4 (parallel dispatch over independent tasks).

### Layer 7 — Evidence-based completion (unfakeable by construction)

Every claim of "done" includes the actual command output that proves it. A `Changed:` block without a `Verify:` line is incomplete:

```
Changed:
- src/users.ts:42 — guard against undefined session
- src/users.test.ts — new test: guest with no session
Verify:
- pnpm test → 142 passed (was 141 + 1 failing)
[orch-evidence 3f2a9c1d4e5b exit=0]
```

The sharp question for any verification gate is: **does the model sit between the check and the verdict?** A gate that only checks "a Verify: line exists" is defeated by fabrication — the model writes plausible output for a command it never ran (MAST FM-2.6, reasoning-action mismatch, 13.2% of failures). v0.6 closes that path with an **evidence ledger**: `orch-evidence-ledger.sh` runs on `PostToolUse` *and* `PostToolUseFailure` for Bash, and when the command is verify-shaped (test/lint/typecheck/build — command-position anchored, so `git add tests/x.sh` or `echo pytest passed` mint nothing), it records `⟨stamp, exit, command⟩` in a session ledger only the hook writes. The platform contract here was verified live against v2.1.220: success and failure are distinguished by *which event fires* (Bash `tool_response` exposes no exit code), and the stamp reaches the model by rewriting the successful result via `hookSpecificOutput.updatedToolOutput` — which must be an object matching the Bash output schema (`{stdout, stderr, interrupted, isImage}`); the model then sees `[orch-evidence <stamp> exit=0]` appended to the real stdout, end-to-end confirmed in a live session. The Stop-hook verify gate (`orch-verify-gate.sh`) validates cited stamps against the ledger: a stamp with no ledger entry (fabricated) warns, or blocks under `ORCH_STRICT_VERIFY=1`; failing runs are ledgered (via the failure event) but never mint a citable stamp — there is nothing green to cite. The SubagentStop validator applies the same check to an implementer's `DONE` claim. The model no longer authors its own verdict.

Honest boundary: this defeats fabrication and hallucination — the failure mode that actually occurs — not a deliberately adversarial model, which could use its shell to edit the ledger itself. Stampless evidence (custom scripts outside the verify-shape regex) is still accepted with a soft note, never a block.

The gate's WIP escape is deliberately narrow: **dirty tree AND a `wip` commit subject**. (It used to skip on any dirty tree — the normal mid-task state — which meant it almost never fired.)

Reinforced two more ways: a `UserPromptSubmit` hook injects a per-turn reminder of the rule, and a `verification-before-completion` skill auto-fires when the agent is about to claim something works. Failed verifications open with `Found:` (the bug) and a debugging path — not `Changed:`. The team never pretends.

### Layer 8 — Pre-spec verification

Before `brainstorming` writes a spec or `writing-plans` writes a plan, the controller dispatches `orch-researcher` (Sonnet) to verify the planned approach against current docs and on-disk state. The researcher returns one of four outcomes: `VERIFIED`, `CONTRADICTED` (halts the workflow until the spec is revised), `COULDN'T_VERIFY` (annotates the spec), or `NOT_APPLICABLE`. The classifier in front of it is biased toward `SKIP` — most tasks don't trigger research.

### Layer 9 — Context-aware handoff

**What it does.** On a long task the context window fills up, and Claude Code compacts the conversation — summarizing older history to free space. The summary is lossy: in-flight detail (which files were mid-edit, exact test counts, the verification baseline) can drop out. This layer carries that detail across the gap. The agent writes a short handoff note while the detail is still in context, and a post-compaction reminder tells the next turn to read it back.

The handoff note is a short file at `docs/llm-orchestrator/handoffs/<date>-<slug>.md` — a few plain bullets: what's done, what's next, the verify command and its result. One per task, overwritten in place as work progresses. Three triggers write it: (1) **stage boundary** (preferred) — the agent writes at a clean seam, e.g. after a green test run or between batches; (2) **handoff-nudge hook** (`scripts/hooks/orch-handoff-nudge.sh`, `UserPromptSubmit`) — when token usage first crosses `ORCH_CONTEXT_HANDOFF_TOKENS` (default 950000) it reminds the agent once to write the note; (3) **`/llm-orchestrator:handoff`** — manual. The note references plan-file checkboxes and TaskList state rather than copying them, so a fresh controller orients in one read.

After compaction, `session-start.sh` injects a short recovery note pointing to the newest handoff artifact. It tells the next turn to re-read that note, treat the summary as lossy, reconcile against the plan-file checkboxes (authoritative), re-verify if the baseline looks stale, and stop if all tasks are checked.

**The one setting.** `ORCH_CONTEXT_HANDOFF_TOKENS` (default 950000, ~95% of a 1M window) — the token count at which the nudge fires. Lower it for a smaller context window.

### Engineering features (cross-layer)

**Termination discipline (MAST-informed).** The MAST taxonomy ([arXiv:2503.13657](https://arxiv.org/abs/2503.13657), N=1642 traces) puts step repetition at 15.7% of multi-agent failures, unawareness of termination conditions at 12.4%, and premature termination at 6.2%. v0.6 attacks all three mechanically:

- *Termination contracts.* Every dispatched task carries `Done when:` (the observable end state — the only path to `DONE`) and `Stop if:` (the abort conditions — a fired one returns `PARTIAL` or `BLOCKED`, never more attempts). The plan template requires both per task; `writing-plans` enforces it; the templates paste them into every envelope. A `type: "prompt"` SubagentStop hook (cheap-model, single-turn) additionally judges an implementer's final message against the contract and feeds a correction back when it trails off mid-work or claims DONE without evidence. (Note: prompt-type hooks cannot read `ORCH_HOOK_PROFILE`, so this one entry is active in every profile — the single exception to profile gating.)
- *Retry-storm breaker.* `orch-retry-cap.sh` is ON by default (warn-only; `ORCH_RETRY_CAP=0` disables, `ORCH_STRICT_RETRY=1` blocks). On `Stop` it fingerprints the controller's replies (3 near-identical in a row → stuck loop). On `SubagentStop` it scans the agent's own transcript for the same tool call with the same arguments executed ≥3 times consecutively — the step-repetition shape itself, keyed on `agent_id`.
- *Premature termination is failure.* A subagent that finishes with an empty final message used to pass silently; `subagent-stop.sh` now treats it as a failure signal. The five read-only agents carry `maxTurns` caps; the implementer deliberately does not (a hard cap would strand its writer mutex), and a SubagentStop **reaper** (`orch-worktree-reaper.sh`) releases a mutex abandoned by a dead implementer — but only on *proof of ownership*: the mutex map the evidence-ledger hook records per `agent_id` (sound because PostToolUse fires only for succeeding commands, so a lost `mkdir` race records no claim), or a worktree named in a success-shaped final message (never a BLOCKED one, which routinely names a *sibling's* held tree). Anything unprovable is reported, not reaped — a live sibling's mutex must never be released — and the controller frees true leftovers by hand once all implementers finish.

Four further capabilities span multiple layers and are documented here rather than in a single layer:

**Toolchain-aware verification.** Before a `Verify:` line is written, `scripts/lib/orch-detect.sh` inspects the project root for manifest and config files (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Makefile`) to identify the test runner and build tool. Node projects always map to `npm run <script>`; the package manager itself is not detected. The detected commands are used verbatim in `Verify:` lines. Results are cached under `~/.llm-orchestrator/toolchain/<hash>/config.md` and re-detected only when manifest content changes.

**Regression guard.** When a worktree is created (`using-git-worktrees` skill), `orch_regression_baseline` (`scripts/lib/orch-regression.sh`) runs the detected test suite and records the outcome to `~/.llm-orchestrator/toolchain/<hash>/baseline.md`. Before a branch is merged or a PR opened (`finishing-a-branch` skill), `orch_regression_check` re-runs the suite and compares against that baseline. If a previously-green test now fails, finishing is refused until the regression is fixed or the user explicitly overrides.

**Security review (orch-security-reviewer).** An optional third review pass — `orch-security-reviewer` (Sonnet) — runs automatically after the two standard review stages when the diff matches security-sensitive tokens (auth, crypto, payments, secrets, jwt, oauth, tls/ssl). The reviewer looks specifically for injection risks, missing auth checks, exposed secrets, and unsafe dependency patterns. Like the code reviewer, it reports every finding with a confidence tag; the controller filters below 0.8 into `Notes:`.

**Convention detection.** The shell function `orch_detect_conventions` reads manifest and config files to detect coding conventions — naming patterns, linter, formatter, test runner, indentation hints. It is an on-demand helper (e.g., to seed or audit `./CLAUDE.md`) rather than auto-injected into every dispatch. Conventions are sourced from `./CLAUDE.md`; implementers read the pasted `## Conventions` section in the `## Project conventions` slot of `templates/implementer-prompt.md`. Detection results are cached per-project in `~/.llm-orchestrator/toolchain/<hash>/config.md`. `/llm-orchestrator:remember` writes to `## Conventions` in CLAUDE.md.

**Architecture grounding (per-task, silent).** When brainstorming a non-trivial change on an existing codebase (skipped for greenfield projects and trivial edits), the brainstorming skill silently reads the recorded `## Decisions` and `## Conventions` sections of `./CLAUDE.md` and, on a cache hit from `orch_arch_cached "$PWD"`, the arch cache as well — then applies them as hard constraints on the spec. No questions are asked, no `orch-explorer` is dispatched, and no `/llm-orchestrator:remember` proposal is made during a task. Codebase study, the surfacing of decisions, and the proposal to record them happen once via `/llm-orchestrator:onboard` (see the paragraph below). On a cache miss, the brainstorming skill still applies whatever `## Decisions`/`## Conventions` exist in `./CLAUDE.md` silently, and at most emits one tip line suggesting the user run `/llm-orchestrator:onboard`.

The recorded `## Decisions` section of CLAUDE.md flows downstream to both `templates/implementer-prompt.md` (the `## Decisions` slot, treated as hard constraints) and `templates/code-reviewer-prompt.md` / `agents/orch-code-reviewer.md` (checked explicitly: a diff that violates a recorded decision is raised as a Critical issue). Previously only `## Conventions` was fed to these downstream agents.

**`/llm-orchestrator:onboard` — one-time capture front-end.** `/llm-orchestrator:onboard` (`commands/onboard.md`) is the user-facing entry point for the architecture-grounding pipeline. It is designed to run once per project, before the first feature task. Steps: (1) idempotency check via `orch_arch_cached "$PWD"` (`scripts/lib/orch-arch.sh`) — if already onboarded, it prints a notice and exits immediately; (2) read-only study via `orch-explorer` to map the stack, data layer, module boundaries, error-handling, and key dependencies, plus `orch_detect_conventions` for coding conventions; (3) drafts `## Decisions` and `## Conventions` content; (4) single approval gate — shows the draft and asks once "Write this to `./CLAUDE.md`? (yes / no)" — no other questions; (5) on approval, appends to `./CLAUDE.md` via `append_under_section` (never overwrites existing content) and calls `orch_arch_record` to mark the project onboarded. All per-task work after `/llm-orchestrator:onboard` reads the recorded decisions silently through the normal architecture-grounding path; the user is not asked again.

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
- Profiles via `ORCH_HOOK_PROFILE`:
  - `minimal` — bootstrap only: loads `using-orchestrator` (the Concise Agent Protocol — fixed response shapes) at SessionStart.
  - `standard` (default) — adds UserPromptSubmit reminders, the research gate, PreToolUse guards, the PostToolUse evidence ledger, SubagentStop validators + retry breaker + implementer mutex reaper, and Stop-hook verify gate + retry breaker + retention pruning.
  - `strict` — all hooks active and blocking: malformed replies (`ORCH_STRICT_PROTOCOL=1`), malformed Status blocks (`ORCH_STRICT_STATUS=1`), failed evidence-stamp lookups (`ORCH_STRICT_VERIFY=1`), retry storms (`ORCH_STRICT_RETRY=1`).
- Disable individual hooks with `ORCH_DISABLED_HOOKS="hook-a,hook-b"`.
- One exception to profile gating: the `type: "prompt"` SubagentStop termination-contract hook is a single-turn cheap-model evaluation the platform runs directly — it cannot read `ORCH_HOOK_PROFILE` and is active in every profile.

### Templates

- File: `templates/<name>.md`.
- Used by commands. Output committed to `docs/llm-orchestrator/{specs,plans,reviews}/YYYY-MM-DD-<slug>.md`.

### Workflows (Claude-Code-only accelerator)

- File: `workflows/<name>.js` — a deterministic script for Claude Code's `Workflow` tool. Plain
  JavaScript only (no TypeScript, no imports; the nondeterministic time/random builtins throw at
  runtime). Begins with a pure-literal `export const meta = {...}`.
- A *preferred* substrate for the breadth-first, independent-fan-out layers — today **Layer 6**
  (code review, `workflows/review-diff.js`) and, when added, **Layer 4** (parallel dispatch). It
  is never a hard dependency: every skill that prefers a workflow keeps its canonical markdown
  path, and routing is the try-then-fallback heuristic in the `using-workflows` skill.
- Reuses the existing `agents/orch-*.md` subagents via the `agentType` option (composed with a
  structured `schema`); it adds no new agent roles.
- Gate logic is never re-derived in JS — the controller computes it in shell (e.g.
  `security_sensitive` from `scripts/lib/orch-signals.sh`) and passes it in via `args`.
- Linter: `tests/validate-workflows.sh` (syntax via `node --check` **plus** a static token scan,
  because parse-only validation does not catch the runtime-throw builtins).

### Context-handoff components

- **Skill:** `skills/handing-off-to-fresh-context/SKILL.md` — fires at stage boundaries (after a green test run, between batches) and on manual invocation; writes the handoff artifact and instructs the controller to surface a resume prompt for the fresh session.
- **Command:** `commands/handoff.md` — `/llm-orchestrator:handoff`; user-facing entry point.
- **Proactive hook:** `scripts/hooks/orch-handoff-nudge.sh` — on `UserPromptSubmit`, estimates fill from the transcript's `message.usage` and, when usage first crosses `ORCH_CONTEXT_HANDOFF_TOKENS` (default 950000), injects a one-time `additionalContext` nudge telling the agent to write the handoff note. Fire-once per fill cycle via a per-session marker under `${ORCH_HOME:-~/.llm-orchestrator}/llm-orchestrator:handoff/nudged.<session_id>` (re-armed when usage drops back below the floor, e.g. after a compaction; pruned by `orch-stop.sh`). It never blocks. Silent under `ORCH_HOOK_PROFILE=minimal` and `ORCH_DISABLED_HOOKS=orch-handoff-nudge`.
- **Reactive hook:** `scripts/hooks/session-start.sh` on `source=compact` injects the lean post-compaction recovery note (no meta-skill body, under the 10,000-char `additionalContext` cap; derives the newest handoff artifact by mtime). Same minimal/disable suppression.
- **Lib:** `scripts/lib/orch-handoff.sh` — token/fill estimation from the transcript (`orch_handoff_total_tokens` skips synthetic all-zero usage lines; `orch_handoff_window_tokens`; `orch_handoff_estimate_pct`), used by the nudge hook to decide when usage has crossed the floor.
- **Note format:** there is no rigid template — the skill (`skills/handing-off-to-fresh-context/SKILL.md`) describes the few bullets to write (what's done / next, the verify command + its green output, any "don't do X"). The note is a convenience; the plan file remains the authoritative recovery anchor.

### Memory

- **User-facing facts** live in Claude Code's native `./CLAUDE.md` (project) and `~/.claude/CLAUDE.md` (user). `/llm-orchestrator:remember` classifies on write into `## Conventions` / `## Decisions` / `## People` / `## Notes`. `/llm-orchestrator:forget` soft-deletes to `~/.llm-orchestrator/memory/.trash/`. Both go through `with_lock` (`scripts/lib/orch-lock.sh`, portable across macOS/Linux). The `## Decisions` section is fed into the implementer prompt and code-reviewer prompt so recorded architectural choices are visible at review time — not just at write time.
- **Plugin-internal state** lives at `~/.llm-orchestrator/memory/<project-hash>.md` — reserved for `## Research config` (aggressiveness knob) and `declined_mcp:` entries. Read at trigger time by `orch-research-gate.sh`, not at SessionStart.
- **Research cache + brief index** live at `~/.llm-orchestrator/research/cache/<hash>/` and `~/.llm-orchestrator/research/briefs-index/<hash>.md`. Written by the SubagentStop validator after `orch-researcher` returns; read by the gate hook on the next compelled trigger.
- `<project-hash>` = SHA-1 of (a) git remote origin URL, (b) repo root path, or (c) cwd, in that order. Resolved by `scripts/lib/orch-project.sh`.
- SessionStart loads the using-orchestrator meta-skill only. CLAUDE.md loading is Claude Code's native responsibility.
- No background observer. No content capture. The only PostToolUse hook is opt-in event-only skill telemetry (skill name + timestamp + project hash; off by default — see Non-goals).

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
│     plain-voice protocol core (~545 tokens; body on demand)      │
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
│   - SessionStart (bootstrap + post-compaction recovery),         │
│     UserPromptSubmit (reminder + research gate + handoff nudge), │
│     PreToolUse (guards), PostToolUse (evidence ledger),          │
│     SubagentStop (validators + retry breaker + mutex reaper +    │
│     prompt-type termination contract),                           │
│     Stop (verify gate + retry breaker + protocol grader + prune) │
│   - profiles: minimal | standard | strict                        │
└──────────────────────────────────────────────────────────────────┘

User home directory (created on first use):
  ~/.llm-orchestrator/
  ├── memory/<project-hash>.md             plugin-internal: ## Research config + declined_mcp only
  ├── memory/.trash/                       soft-deleted lines from /llm-orchestrator:forget
  ├── research/cache/<hash>/<lib>.md       dated doc snapshots per library
  ├── research/briefs-index/<hash>.md      brief retrieval index for compounding lookups
  ├── toolchain/<hash>/config.md           detected test runner / build tool per project
  │                 baseline.md          baseline test-run outcome for regression guard
  └── architecture/<hash>/decisions.md    cached architectural decisions per project
                                           (manifest-sha stamped; stale on manifest change)

User-curated project facts live in Claude Code's native ./CLAUDE.md (loaded by
Claude Code itself, not by this plugin's SessionStart hook).
```

---

## Why this shape

- **No runtime** keeps the kit simple, but be precise about what is portable: the **skills, commands, and agent prompts are plain markdown** and work as guidance in any harness that can read them. The **enforcement layer is Claude Code-specific** — the hooks (`hooks/hooks.json`: protocol grader, research gate, no-verify guard, destructive-git guard, handoff nudge, Status validator) depend on Claude Code's hook events and `additionalContext` injection. In another harness you get the skills as instructions, not the mechanical enforcement. Making the enforcement cross-harness would mean porting the hook scripts to each harness's hook system (which LLM Orchestrator does not ship today).
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
6a. When context usage crosses `ORCH_CONTEXT_HANDOFF_TOKENS` (default 950000, ≈95% of the window) — or at any clean stage boundary the controller chooses — it regenerates the handoff artifact (`docs/llm-orchestrator/handoffs/<date>-<slug>.md`) and the user resumes in a fresh session — which runs the embedded verification baseline before continuing.
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
| `workflows/`                  | Claude-Code-only `Workflow` scripts; preferred accelerator for Layer 6 today (Layer 4 planned); markdown canonical |
| `hooks/`, `scripts/`          | Glue + runtime guardrails                        |
| `examples/`                   | Plugin manifest examples                          |
| `docs/examples/`              | Illustrative response-shape examples             |
| `tests/`                      | Validators (smoke, drift detection, portability) |
| `docs/llm-orchestrator/handoffs/` | Versioned controller-handoff artifacts (one per long task) |

---

## Non-goals

- Not a multi-agent runtime. Agents are dispatched by the harness, not orchestrated by us.
- Not a surveillance system. Tool outputs, arguments, prompts, and transcripts are never captured. The one optional exception is event-only skill telemetry (`ORCH_TELEMETRY=1`, off by default): it appends skill name + timestamp + project hash to `~/.llm-orchestrator/telemetry/skills.jsonl` — and nothing else. Opt-in only.
- Not a security framework. We expose hook profiles; the harness owns sandboxing.
- Not a skill catalog warehouse. We cap first-party skills at ~40 by design.
