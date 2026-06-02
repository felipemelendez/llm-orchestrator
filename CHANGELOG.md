# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-06-01

A reliability, cost, and tone pass. The orchestration behaves the same; it now costs far less context per session, says things plainly instead of shouting, ships new opt-in safety nets (all off by default), and is guarded by a wider test net. No breaking changes — every new enforcement is opt-in behind an `ORCH_STRICT_*` flag, and the safety guards explicitly resist the new dry-run switch.

### Changed
- **Far less context burned per session.** The SessionStart injection now sends only a marked protocol core (~545 tokens) instead of the whole meta-skill (~2,100 tokens); the full routing table, red-flag list, and dispatch detail stay in the skill file and load only when the agent reads them. The per-turn reminder was trimmed ~41% (~534 → ~314 tokens). A one-shot session now adds ~900 tokens of orchestrator framing, down from ~2,675. A custom meta-skill without the `<!-- ORCH:EAGER -->` markers falls back to full-body injection, so nothing breaks.
- **Plain voice, no coercion.** Removed the `<EXTREMELY-IMPORTANT>` / "1% chance" / "you have no choice" framing from the meta-skill, the per-turn reminder, and the SessionStart preamble, aligning with Anthropic's own published skills. The rules are unchanged; only the tone is. The skill validator's shouting check is now strict everywhere (no directive-block carve-out).
- **Leaner research-gate payload.** The gate's injected guidance dropped from ~1KB to ~330 bytes (prior-findings markers kept); a version question about the orchestrator plugin itself ("what version of llm-orchestrator is installed") no longer fires the gate, while real library/version lookups still do.
- **`research-classifier` split for readability.** The 2,700-word skill is now a ~1,000-word core plus `STRATEGY.md` (aggressiveness, stakes, MCP-nudge rules) and `EXAMPLES.md` (the curated cases the smoke test checks). Skill descriptions across the catalog were tightened toward trigger form. Subagent codenames were removed from user-facing prose (operational dispatch instructions keep them).

### Added
- **Retry-storm circuit breaker** (`scripts/hooks/orch-retry-cap.sh`, Stop) — when the controller repeats essentially the same reply `ORCH_RETRY_CAP_N` times (default 3), it nudges the user to stop and reassess. Off by default; `ORCH_RETRY_CAP=1` to warn, `ORCH_STRICT_RETRY=1` to block. A different reply resets the counter, so normal progress never trips it.
- **Verification gate** (`scripts/hooks/orch-verify-gate.sh`, Stop) — warns when a `Changed:` block ships without a `Verify:` line. Warn-only by default; `ORCH_STRICT_VERIFY=1` to block. Escapes on a dirty tree or a `wip` commit so work-in-progress isn't nagged.
- **Opt-in usage telemetry** (`scripts/hooks/skill-telemetry.sh`, PostToolUse) — when `ORCH_TELEMETRY=1` (env or project `.orchrc`), appends one line per skill invocation: skill name + timestamp + project hash, and nothing else. Never logs prompts, arguments, or output. Off by default.
- **`ORCH_HOOK_DRY_RUN=1`** — every injecting/grading hook logs what it *would* inject or block, then does nothing. The two git safety guards deliberately ignore it (they can never be made bypassable).
- **`ORCH_DISABLE_PROTOCOL_GRADER=1`** — full opt-out for the protocol grader; `ORCH_STRICT_PROTOCOL=1` always wins.
- **Composite `verify=` key** in `orch-detect.sh` — a single runnable check (documented verify script, else composed test/lint/typecheck) so a verification gate has one command to point at.
- **New tests:** hook latency budget (every per-turn hook < 500ms; SessionStart budgeted separately), opt-in telemetry, the verification gate, and the retry breaker. Plus verify-key detection cases and a SessionStart eager-body budget guard.
- README gains a **Hook precedence** section: defaults permissive, enforcement opt-in (`ORCH_STRICT_*`), capture opt-in (`ORCH_TELEMETRY`).

### Hardened
- **SessionStart latency:** a ~570ms per-session stall (a bash end-of-script buffer artifact, surfaced by the new latency test) is gone; the eager-body trim keeps it lean.
- **`validate-skills.sh`** now actually catches a command that references a non-existent skill (the old reference check was tautological and could never fail), and discovers skills dynamically so a rename needs no test edit.
- **`orch-lock.sh`** cleans its tempfile on interrupt via a subshell-scoped trap that never clobbers the caller's own signal traps.
- **python3 dependency** for the protocol/Status graders now surfaces once, loudly, at session start when it's missing, instead of only at grade time.
- The privacy posture in ARCHITECTURE and the ecosystem doc was amended in step with the new telemetry: tool outputs, arguments, prompts, and transcripts are still never captured — the one opt-in exception is event-only skill telemetry.

## [0.3.0] - 2026-05-31

### Added
- **Code review now runs on Claude Code's dynamic workflows, when that tool is available.** The two reviews (does the code match the spec, then is the code any good) plus the conditional security pass can now execute as a single deterministic script that runs the reviewers in parallel, returns their findings in a structured form, and has independent agents try to disprove each finding before it ever reaches you. Previously the controller coordinated these stages by hand. If the tool isn't present (any non-Claude-Code harness), the original step-by-step markdown flow runs instead — unchanged — so nothing breaks.
  - New `workflows/review-diff.js` — the review pipeline. The spec-compliance review still gates the code-quality review: a diff that doesn't implement the spec exits early instead of paying for the rest. Findings the reviewer is less than 80% sure about are dropped, and a bounded "try to refute this" pass (at most four agents, so a noisy diff can't run up the bill) double-checks what's left before it surfaces.
  - New skill `using-workflows` — the plain-language rule for *when* a workflow is worth it (work that splits into independent parts and is valuable enough to justify the extra agents) versus when to stay in one agent (step-by-step work that shares context — most coding). Grounded in Anthropic's published guidance that multi-agent runs cost roughly 15× the tokens of a single agent, so the fan-out has to earn it.
  - New validator `tests/validate-workflows.sh` — checks every workflow script for syntax and for the constructs the engine forbids that a plain syntax check silently lets through.
  - Reuses the existing `orch-spec-reviewer` / `orch-code-reviewer` / `orch-security-reviewer` agents directly (through the workflow tool's `agentType` option) — no new agent roles.
  - The list of security-sensitive keywords stays defined in exactly one place (`scripts/lib/orch-signals.sh`); the workflow is handed a simple yes/no flag instead of re-implementing the rule, so the two paths can never drift on what counts as security-sensitive.
  - Research brief backing the design (the Workflow tool's contract + Anthropic's cost guidance): `docs/llm-orchestrator/research/2026-05-31-workflow-tool-contract.md`.

### Changed
- ARCHITECTURE gains a **Workflows** component section and admits `workflows/*.js` as a deliberate, Claude-Code-only accelerator for the review layer (and, next, parallel dispatch) — with the plain-markdown path kept as the canonical, runs-anywhere default. AGENTS notes the agent reuse; README adds two feature rows.
- The two-stage review is now a *preferred* substrate, not a hard dependency. The markdown path is the canonical fallback; the workflow path is explicitly higher-rigor, not claimed to be behaviorally identical.

## [0.2.0] - 2026-05-30

### Added
- **Context-aware handoff (Layer 9)** — keeps a long task on track across Claude Code's automatic compaction (when it summarizes older conversation to free space). When token usage first crosses `ORCH_CONTEXT_HANDOFF_TOKENS` (default 800000), the agent is reminded once — not every turn — to write a short handoff note at `docs/llm-orchestrator/handoffs/<date>-<slug>.md`: a few bullets covering what's done, what's next, and the verify command with its result. After compaction, a short reminder tells the next turn to re-read that note, trust the plan file's checkboxes, and re-run the tests before continuing.
  - New hook `scripts/hooks/orch-handoff-nudge.sh` (`UserPromptSubmit`) — the one-time write reminder. Fires once per fill cycle, re-arms after a compaction, and never blocks.
  - `session-start.sh` injects the post-compaction reminder.
  - New skill `handing-off-to-fresh-context` and command `/llm-orchestrator:handoff` — write the note; a clean stopping point (tests green, nothing in flight) is the preferred moment. `executing-plans` writes one at tier boundaries.
  - New lib `scripts/lib/orch-handoff.sh` — context-fill estimation from the transcript.
  - One setting: `ORCH_CONTEXT_HANDOFF_TOKENS` (default 800000) — lower it for a smaller context window.
  - Docs: ARCHITECTURE Layer 9, README feature row, AGENTS command entry, settings.json documentation.

### Added (discoverability)
- New command `/llm-orchestrator:skills` — prints a one-screen catalog of the available skills and commands with their trigger conditions, grouped by phase, with an optional keyword filter. Renders from the session's injected catalog (no filesystem dependency, so it works from any working directory).

### Hardened
- Reliability: the transcript read is bounded to a tail slice for constant per-turn cost on long runs, and the context-window size is validated against non-numeric/empty values.
- Cross-shell + install-layout robustness for commands/skills that source plugin libraries: a shared resolver locates a lib across all install layouts (`$CLAUDE_PLUGIN_ROOT`, the symlink/copy installs, and the version-nested marketplace cache — version-sorted so a stale older copy is never picked), and the libraries self-locate with `${BASH_SOURCE[0]:-$0}` so sibling `source`s work when a lib is loaded under zsh (where `BASH_SOURCE` is unset). Previously a command run from a user's project under a zsh-default shell could fail to find or correctly load a lib. New regression test `tests/test-lib-resolution.sh`.

### Changed
- ARCHITECTURE renamed "Eight layers" → "Nine layers".

## [0.1.0] - 2026-05-23

<!-- Note: date is approximate; no earlier release tag found in git log. -->

### Added
- Initial release: Concise Agent Protocol, skills + commands, two-stage review, research gate, project memory, evidence-based verification, parallel/sequential dispatch, git-worktree isolation.
