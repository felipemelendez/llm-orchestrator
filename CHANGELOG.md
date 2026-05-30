# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-05-30

### Added
- **Context-aware handoff (Layer 9)** — the controller no longer works from a saturated context window on long multi-tier tasks. A versioned, self-sufficient handoff artifact (`docs/llm-orchestrator/handoffs/<date>-<slug>.md`) is regenerated latest-wins (git log is the history) so a fresh session resumes with zero state loss.
  - New skill `handing-off-to-fresh-context` — tier-boundary detection is the primary trigger (fire at a clean green seam past ~50% context); threshold hook and the command are fallbacks.
  - New command `/llm-orchestrator:handoff` — user-invoked regeneration.
  - New template `templates/handoff.md` — 10 required slots (mission, memory index, plan state, active task context, verbatim agent reports, in-flight observations, verification baseline, known gotchas, what-not-to-do, resume prompt) + versioned frontmatter.
  - New hook `scripts/hooks/orch-context-pressure.sh` on `UserPromptSubmit` (advisory) and `PreCompact` (catches silent native auto-compaction) — profile-aware; estimates context fill from the transcript's `message.usage.input_tokens` (no token-count API needed); advisory by default, blocks only under `ORCH_HOOK_PROFILE=strict` + `ORCH_STRICT_CONTEXT_PRESSURE=1`.
  - New lib `scripts/lib/orch-handoff.sh` — context-fill estimation, body hashing + no-op detection, revision counting.
  - Continuation contract: a resumed controller runs the verification baseline first and invokes systematic-debugging on divergence before proceeding.
  - Two-stage review (spec + code) runs on every regeneration; no-op regenerations are flagged.
  - `executing-plans` now hands off at tier boundaries; new env knobs `ORCH_CONTEXT_WARN_PCT` (70), `ORCH_CONTEXT_BLOCK_PCT` (85), `ORCH_CONTEXT_WINDOW_TOKENS` (200000).
  - Docs: ARCHITECTURE Layer 9, README feature row, AGENTS command entry, settings.json env documentation.

### Hardened
- `Active task context` slot — records the files/line-ranges and key conventions the next action touches, so a fresh controller does not re-discover them.
- Lean-artifact discipline — cap recent agent reports to the last 3–5 blocks, trim long reports to their verdict lines and cite git history or the prior transcript for the rest, so the handoff itself never strains the new window.
- Re-hydration pointer in the resume prompt — git history (`git log -p <artifact>`) plus the prior session transcript, so a lean artifact stays safe.
- Rollback affordance — a degraded or accidental regeneration can be reverted via `git checkout HEAD~1 -- <artifact>` (git history is the version record).
- Reliability fixes from review: frontmatter stripping no longer collapses an interrupted/unterminated write to an empty body (which would have caused a false no-op); the transcript read is bounded to a tail slice for constant per-turn cost on long runs; and the context-window size is validated against non-numeric/empty values.

### Changed
- ARCHITECTURE renamed "Eight layers" → "Nine layers".

## [0.1.0] - 2026-05-23

<!-- Note: date is approximate; no earlier release tag found in git log. -->

### Added
- Initial release: Concise Agent Protocol, skills + commands, two-stage review, research gate, project memory, evidence-based verification, parallel/sequential dispatch, git-worktree isolation.
