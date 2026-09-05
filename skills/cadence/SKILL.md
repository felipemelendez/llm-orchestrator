---
name: cadence
description: Use when a change is about to be built, reviewed or landed in a project that has docs/llm-orchestrator/cadence.json. Not for docs-only edits or projects without it.
license: MIT
compatibility: Claude Code or Codex; bash 3.2+; git; python3 for the gate script and for init's settings merge (the check script's verdict runs without it)
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/cadence-detect.sh *)
---

# The cadence

A project whose `docs/llm-orchestrator/cadence.json` has `"enabled": true` runs
every change to production code or tests through the steps below. Absent or not
enabled, nothing here applies. Docs-only edits are out of scope.

Full text: [CADENCE.md](./CADENCE.md). Seat briefs and templates:
[references/](./references/).

## The steps

- **Brief review** — a fresh read-only seat verifies the brief's claims against
  the tree and returns a tier (`FULL` unless `LOCAL` is argued file by file) and
  a split verdict.
- **Implementer** — fresh, its own worktree, a failing test first for every
  mechanism.
- **The blind pair** — a spec seat and a plain-language adversarial seat, each
  on its own copy, neither shown the other's report nor the implementer's.
- **The refuter** — read-only; reads both reports and promotes or drops each
  finding by citation. The burden is on it to drop, so doubt promotes.
- **The union** — the controller adjudicates the promoted list. Severity rule:
  catastrophic or serious goes to the fixer and the gate; mild-only folds into
  the landing with a firsthand red witness.
- **The fixer** — writes each pin from the finding's `SCENE:` line before
  opening the hunk, because a pin written after the hunk mirrors it.
- **The gate** — the script first, then a seat for what needs judgement: probe
  replay, hunk-level revert-to-red, a degenerate-pin check by mechanism
  removal, novel mutations as evidence, not a threshold.
- **Landing** — the project's full floors, the evidence files under
  `notes_dir`, a commit by explicit pathspec, one ledger line.

A catastrophic or serious gate finding opens round 2. A ticket that would enter
round 3 returns to brief review. There is no round 4.

## The files

| Path | What it is |
|---|---|
| `docs/llm-orchestrator/LAWS.md` | the constitution; changed only by a numbered ruling |
| `docs/llm-orchestrator/cadence.json` | the switch, the runner, the path classes |
| `docs/llm-orchestrator/LOCK.sha256` | the manifest |
| `docs/llm-orchestrator/HANDOFF_TEMPLATE.md` | state only; history in the ledger row |
| `docs/llm-orchestrator/DESIGN_RULINGS.md` | append-only, dated |
| `docs/llm-orchestrator/TRAPS.md` | append-only, dated |
| `.githooks/commit-msg`, `.githooks/orch-cadence-check.sh` | the git layer |
| `<notes_dir>/<TICKET>_*_report.md` | the landing evidence |

## The scripts

`${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh` runs a gate's deterministic
half. `${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh` carries `--verdict`,
`--lock`, `--landing <ticket>`, `--commit-msg <msgfile>`, `--audit <rev>` and
`--version`. Unexpanded, those are the `scripts/orch-cadence-gate.sh` and
`scripts/orch-cadence-check.sh` files in this skill's folder.

`templates/cadence-global-block.md` is the pointer block an install renders into
a global instruction file. A session that printed no `cadence:` line says so
first.

## Discipline

Every dispatch names its model; the plain-language adversarial seat may run on a
different model from every other seat. This governs the seats a controller
dispatches, not this plugin's shipped agent files, which carry their own pins.

Never verify your own work: the seat that wrote a change never reviews or gates
it. Never resume a seat whose model matters.

Hooks and deny rules are guardrails, not guarantees; a native deny rule beats
every hook, and the git `commit-msg` layer is what holds across tools and CI.
