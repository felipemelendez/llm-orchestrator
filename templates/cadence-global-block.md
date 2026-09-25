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
- Any other `workflow`, or none, is a configuration error; the fix is
  `"workflow": "proportional"`.
- Full uses a refuter only for disagreement or a one-sided serious/
  catastrophic finding. Missing reviews are never agreement. Name dispatch models.
- Writers may run checks and inspect their diff; they cannot supply a required
  independent review/gate.
- Keep useful specs/research/design/runbooks. Reports and copies live outside
  Git; finish cleanup after consumers stop and work is preserved.
- `LAWS.md`, `cadence.json`, `LOCK.sha256`, the deny rules in
  `.claude/settings.json`, the git hook in `.githooks/`, and the marked section
  of `CLAUDE.md` and `AGENTS.md` change only by a numbered ruling, in a commit
  whose message carries that ruling, with the lock rewritten under
  `ORCH_CADENCE_UNLOCK=1` — which the person sets in the environment when
  launching the session, never in a settings file and never by an agent.
  Propose an amendment in the handoff instead.

On Codex read project `CODEX.md` for evidence and hook trust. Installed hooks,
executed checks and instructions are distinct; Git checks do not prove reviews.
<!-- ORCH:LAWS:END -->
