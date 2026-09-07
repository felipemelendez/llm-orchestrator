---
name: cadence
description: Use when a change is about to be built, reviewed or landed in a project that has docs/llm-orchestrator/cadence.json. Not for docs-only edits or projects without it.
license: MIT
compatibility: Claude Code or Codex; bash 3.2+; git; python3 for the gate script and for init's settings merge (the check script's verdict runs without it)
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/cadence-detect.sh *)
---

# The cadence

A project whose `docs/llm-orchestrator/cadence.json` has `"enabled": true` runs
every change to production code or tests through these steps. Absent or not
enabled, nothing applies; docs-only edits are out of scope.

Full text: [CADENCE.md](./CADENCE.md). Seat briefs:
[references/](./references/).

## The steps

- **Brief review** — a fresh read-only seat checks the brief's claims against the
  tree and returns the class (`CODE`, or `PROSE` when nothing it touches is
  executed or read by a program), the split verdict and the active skips.
- **Implementer** — fresh, its own worktree, a failing test before every
  mechanism.
- **The blind pair** — a spec seat and a plain-language adversarial seat, each on
  its own copy, shown neither the other's report nor the implementer's.
- **The refuter** — read-only, only when the pair's findings exceed eight or a
  catastrophic or serious one is reasoned, not executed. It promotes or drops by
  citation; the burden is on it to drop; doubt promotes.
- **The union** — the controller adjudicates: catastrophic or serious goes to
  the fixer and the gate; mild-only folds into the landing behind a red
  witness.
- **The fixer** — writes each pin from the finding's `SCENE:` line before
  opening the hunk.
- **The gate** — the script always, then on code a seat: probe replay,
  hunk-level revert-to-red, a degenerate-pin check, novel mutations as evidence.
- **Landing** — the full floors, the evidence files under `notes_dir`, a commit
  by explicit pathspec, one ledger row.

A catastrophic or serious gate finding opens the next round; the ticket stops
when that round's finding repeats the last one's class and returns to brief
review. The orchestrator may skip the gate seat or the refuter — those two only
— on three cited ledger rows; the skip expires, any catastrophic re-arms it, and
the session line carries the count.

## The files

| Path | What it is |
|---|---|
| `docs/llm-orchestrator/LAWS.md` | the constitution |
| `docs/llm-orchestrator/cadence.json` | the switch and the runner |
| `docs/llm-orchestrator/LOCK.sha256` | the manifest |
| `docs/llm-orchestrator/HANDOFF_TEMPLATE.md` | state only |
| `docs/llm-orchestrator/DESIGN_RULINGS.md` | append-only |
| `docs/llm-orchestrator/TRAPS.md` | append-only |
| `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh` | the git layer |
| `<notes_dir>/<TICKET>_*_report.md` | the evidence |
| `<notes_dir>/CADENCE_STATE.md` | the skips |

## The scripts

`${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh` runs a gate's deterministic
half. `${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh` carries `--verdict`,
`--lock`, `--landing <ticket>`, `--commit-msg <msgfile>`, `--audit <rev>` and
`--version`. Unexpanded: `scripts/orch-cadence-gate.sh` and
`scripts/orch-cadence-check.sh`.

`templates/cadence-global-block.md` is the pointer block the installers render
into a global instruction file. A session with no `cadence:` line says so first.

## Discipline

Every dispatch names its model; the plain-language adversarial seat may run on a
different one from every other seat.

Never verify your own work: the seat that wrote a change never reviews or gates
it. Never resume a seat whose model matters. Seats run on throwaway copies or
worktrees, deleted once the report is finished.

Hooks and deny rules are guardrails, not guarantees; a native deny rule beats
every hook, and the git `commit-msg` layer holds across tools and CI.
