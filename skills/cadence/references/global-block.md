<!-- ORCH:LAWS:START -->
## The cadence

If `docs/llm-orchestrator/cadence.json` is absent, or does not have
`"enabled": true`, this project has not opted in: nothing here applies. Work
normally.

Otherwise, before anything else:

- Read `docs/llm-orchestrator/LAWS.md` first. It is the project's constitution,
  and it is never restated from memory.
- Every change to production code or tests goes through the cadence in the
  `cadence` skill — brief review, implementer, two independent blind reviews,
  the refuter only for disagreement or a one-sided catastrophic or serious
  finding, the union, the fixer, the gate script, the gate seat on code, landing.
  Agreement on findings, severity and disposition skips the refuter regardless
  of count; missing or incomplete reviews are never agreement. Explicit project
  amendments govern. Docs-only edits do not.
- Every dispatch names the model it runs on.
- Never verify your own work. The seat that wrote a change does not review or
  gate it.
- `LAWS.md`, `cadence.json`, `LOCK.sha256`, the deny rules in
  `.claude/settings.json`, the git hook in `.githooks/`, and the marked section
  of `CLAUDE.md` and `AGENTS.md` change only by a numbered ruling, in a commit
  whose message carries that ruling, with the lock rewritten under
  `ORCH_CADENCE_UNLOCK=1` — which the person sets in the environment when
  launching the session, never in a settings file and never by an agent.
  Propose an amendment in the handoff instead.

Claude Code normally prints a `cadence:` verdict at startup. On Codex, use the
project's `CODEX.md` to check hook trust, evidence policy and the rule verdict;
absence of a startup line alone does not establish whether hooks loaded.
Instructions, executed checks and mechanically enforced gates are distinct.
<!-- ORCH:LAWS:END -->
