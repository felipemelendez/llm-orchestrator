<!-- ORCH:LAWS:START -->
## The cadence

Absent/disabled `docs/llm-orchestrator/cadence.json` is inert; work normally.

Otherwise, before anything else:

- Read `docs/llm-orchestrator/LAWS.md` first, never from memory.
- Read `workflow` in the configuration. For `proportional`, use the `cadence`
  skill's smallest sufficient path: Simple edits/checks/delivery; Standard adds
  one independent review; Full adds a reviewed spec, two independent blind
  reviews, findings resolution and independent verification. Choose by risk,
  uncertainty and reversibility. User directions and project amendments govern.
  Ordinary questions/docs need no pipeline.
- Missing or `legacy` workflow retains the legacy brief/implementer/blind-pair/
  adjudication/fixer/gate/landing sequence and its reports. Unknown workflow is
  an error. Installing this block does not migrate a project.
- Full/legacy uses a refuter only for disagreement or a one-sided serious/
  catastrophic finding. Missing reviews are never agreement. Name dispatch models.
- Writers may run checks and inspect their diff in proportional mode; they
  cannot supply a required independent review/gate. Legacy independence stays.
- Keep useful specs/research/design/runbooks. Proportional reports/copies live
  outside Git; finish cleanup after consumers stop and work is preserved.
- `LAWS.md`, `cadence.json`, `LOCK.sha256`, the deny rules in
  `.claude/settings.json`, the git hook in `.githooks/`, and the marked section
  of `CLAUDE.md` and `AGENTS.md` change only by a numbered ruling. To propose
  one, explain why, write the change as a patch file outside Git, and show the
  diff. If the person agrees, give them the one command that applies it,
  `cadence-ruling.sh <patch> "<their wording>"` from the `cadence` skill's
  `scripts/`, to run in their own terminal. Never run it yourself.

On Codex read project `CODEX.md` for evidence and hook trust. Installed hooks,
executed checks and instructions are distinct; Git checks do not prove reviews.
<!-- ORCH:LAWS:END -->
