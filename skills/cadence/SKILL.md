---
name: cadence
description: Use when a change is about to be built, reviewed or landed in a project that has docs/llm-orchestrator/cadence.json. Not for docs-only edits or projects without it.
license: MIT
compatibility: Claude Code or Codex; bash 3.2+; git; python3 for the gate script and for init's settings merge (the check script's verdict runs without it)
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/cadence-detect.sh *)
---

# The cadence

Production code and test changes follow this cadence when
`docs/llm-orchestrator/cadence.json` has `"enabled": true`.
Absent or disabled configurations and docs-only edits are out of scope.

Full procedure: [CADENCE.md](./CADENCE.md). Seat briefs: [references/](./references/).

Before dispatch, read project `LAWS.md`; its explicit review and refuter amendments
override these defaults. On Codex, read project `CODEX.md` when present for
native and external routing and verification evidence.

## Steps

- **Brief review** — fresh, read-only; checks claims against the tree, returns
  class (`CODE`, or `PROSE` if nothing is executed or read by a program), split
  verdict and active skips.
- **Implementer** — fresh, its own worktree; a failing test before every mechanism.
- **Blind pair** — always two independent reviews, spec and plain-language
  adversarial, each on its own copy, seeing neither the other's nor implementer's
  report. Obtain missing or incomplete reviews before adjudicating; neither counts
  as agreement.
- **Refuter** — read-only, only for disagreement on actionable findings, severity
  or disposition, or a catastrophic or serious finding from one reviewer alone.
  Agreement skips it regardless of count; matching PASS verdicts alone are
  insufficient. Assess only those findings; originate none. Promote or drop by
  citation; burden to drop, doubt promotes.
- **Union** — controller adjudicates: catastrophic or serious goes to fixer and gate;
  mild-only folds into landing behind a red witness.
- **Fixer** — writes each pin from the finding's `SCENE:` before opening the hunk.
- **Gate** — script always; then on code, a seat: probe replay, hunk-level
  revert-to-red, degenerate-pin check, novel mutations as evidence.
- **Landing** — full floors, evidence under `notes_dir`, commit by explicit
  pathspec, one ledger row.

Catastrophic or serious gate findings open another round; repeating the previous
round's finding class stops the ticket for brief review. Three cited ledger rows
can qualify a gate-seat skip: it expires, any catastrophic re-arms it, and the
session line counts skips. Historical refuter skips cannot bypass required
adjudication; agreement needs no ledger rows. Details: `CADENCE.md`.

## Files

| Path | Purpose |
|---|---|
| `docs/llm-orchestrator/LAWS.md` | Constitution |
| `docs/llm-orchestrator/cadence.json` | Switch, runner |
| `docs/llm-orchestrator/LOCK.sha256` | Manifest |
| `docs/llm-orchestrator/HANDOFF_TEMPLATE.md` | State only |
| `docs/llm-orchestrator/DESIGN_RULINGS.md`, `docs/llm-orchestrator/TRAPS.md` | Append-only |
| `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh` | Git layer |
| `<notes_dir>/<TICKET>_*_report.md` | Evidence |
| `<notes_dir>/CADENCE_STATE.md` | Skips |

## Scripts

`${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh`: deterministic gate.
`${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh`: `--verdict`, `--lock`,
`--landing <ticket>`, `--commit-msg <msgfile>`, `--audit <rev>`, `--version`.
Unexpanded: `scripts/orch-cadence-gate.sh`, `scripts/orch-cadence-check.sh`.

Installers render `templates/cadence-global-block.md` into global instructions.
A session lacking a `cadence:` line says so first.

## Discipline

Name every dispatch's model; the adversarial seat may use a different model.
Never self-verify: writers cannot review or gate their changes. Never resume a
seat whose model matters. Delete throwaway copies or worktrees after reports finish.

Hooks and deny rules are guardrails, not guarantees. Native deny rules beat hooks;
Git's `commit-msg` layer holds across tools and CI.
