# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versioning: [Semantic Versioning](https://semver.org/).

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
