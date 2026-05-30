# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-05-30

### Added
- **Context-aware handoff (Layer 9)** — the controller no longer works from a saturated context window on long multi-tier tasks. A versioned, self-sufficient handoff artifact (`docs/llm-orchestrator/handoffs/<date>-<slug>.md`) is regenerated latest-wins (git log is the history) so a fresh session resumes with zero state loss.
  - New skill `handing-off-to-fresh-context` — tier-boundary detection is the primary trigger (fire at a clean green seam past ~50% context); threshold hook and the command are fallbacks.
  - New command `/llm-orchestrator:handoff` — user-invoked regeneration.
  - New template `templates/handoff.md` — 10 required slots (mission, memory index, plan state, active task context, verbatim agent reports, in-flight observations, verification baseline, known gotchas, what-not-to-do, resume prompt) + versioned frontmatter.
  - New hook `scripts/hooks/orch-context-pressure.sh` on `UserPromptSubmit` (advisory) and `PreCompact` (in strict profile, blocks an auto-compaction so a handoff can run first — PreCompact supports only `decision:block`, not context injection) — profile-aware; estimates context fill from the transcript's `message.usage.input_tokens` (no token-count API needed); advisory by default, blocks only under `ORCH_HOOK_PROFILE=strict` + `ORCH_STRICT_CONTEXT_PRESSURE=1`. The post-compaction reminder is injected by `session-start.sh` on `source=compact` (the SessionStart event supports `additionalContext` and fires after compaction).
  - New lib `scripts/lib/orch-handoff.sh` — context-fill estimation, body hashing + no-op detection, revision counting.
  - Continuation contract: a resumed controller runs the verification baseline first and invokes systematic-debugging on divergence before proceeding.
  - Two-stage review (spec + code) runs on every regeneration; no-op regenerations are flagged.
  - `executing-plans` now hands off at tier boundaries; new env knobs `ORCH_CONTEXT_WARN_PCT` (70), `ORCH_CONTEXT_BLOCK_PCT` (85), `ORCH_CONTEXT_WINDOW_TOKENS` (1000000), `ORCH_CONTEXT_HANDOFF_TOKENS` (120000), `ORCH_CONTEXT_BLOCK_TOKENS` (140000).
  - Token-floor-aware advisory: because percentage thresholds are miscalibrated on a 1M window (native auto-compaction fires near ~150K tokens, ~15% fill), the `UserPromptSubmit` advisory also fires on an absolute token floor (`ORCH_CONTEXT_HANDOFF_TOKENS`, default 120000) sized to nudge a handoff before native compaction; it advises each turn while above the floor (like the per-turn protocol reminder) until a handoff resets the session. The strict block gains a matching absolute ceiling (`ORCH_CONTEXT_BLOCK_TOKENS`, default 140000) so strict enforcement engages on a 1M window before native compaction. New lib helpers `orch_handoff_total_tokens` (skips synthetic all-zero usage lines so a transcript ending on an interrupt/`<synthetic>` line still reports true fill) and `orch_handoff_window_tokens`.
  - Hardened threshold parsing: `ORCH_CONTEXT_WARN_PCT` / `ORCH_CONTEXT_BLOCK_PCT` are now validated before arithmetic, so a malformed value falls back to its default instead of silently disabling the advisory/block under `set -u`.
  - Docs: ARCHITECTURE Layer 9, README feature row, AGENTS command entry, settings.json env documentation.

### Added (discoverability)
- New command `/llm-orchestrator:skills` — prints a one-screen catalog of the available skills and commands with their trigger conditions, grouped by phase, with an optional keyword filter. Renders from the session's injected catalog (no filesystem dependency, so it works from any working directory).

### Hardened
- `Active task context` slot — records the files/line-ranges and key conventions the next action touches, so a fresh controller does not re-discover them.
- Lean-artifact discipline — cap recent agent reports to the last 3–5 blocks, trim long reports to their verdict lines and cite git history or the prior transcript for the rest, so the handoff itself never strains the new window.
- Re-hydration pointer in the resume prompt — git history (`git log -p <artifact>`) plus the prior session transcript, so a lean artifact stays safe.
- Rollback affordance — a degraded or accidental regeneration can be reverted via `git checkout HEAD~1 -- <artifact>` (git history is the version record).
- Reliability fixes from review: frontmatter stripping no longer collapses an interrupted/unterminated write to an empty body (which would have caused a false no-op); the transcript read is bounded to a tail slice for constant per-turn cost on long runs; and the context-window size is validated against non-numeric/empty values.
- Cross-shell + install-layout robustness for commands/skills that source plugin libraries: a shared resolver locates a lib across all install layouts (`$CLAUDE_PLUGIN_ROOT`, the symlink/copy installs, and the version-nested marketplace cache — version-sorted so a stale older copy is never picked), and the libraries self-locate with `${BASH_SOURCE[0]:-$0}` so sibling `source`s work when a lib is loaded under zsh (where `BASH_SOURCE` is unset). Previously a command run from a user's project under a zsh-default shell could fail to find or correctly load a lib. New regression test `tests/test-lib-resolution.sh`.

### Changed
- ARCHITECTURE renamed "Eight layers" → "Nine layers".

## [0.1.0] - 2026-05-23

<!-- Note: date is approximate; no earlier release tag found in git log. -->

### Added
- Initial release: Concise Agent Protocol, skills + commands, two-stage review, research gate, project memory, evidence-based verification, parallel/sequential dispatch, git-worktree isolation.
