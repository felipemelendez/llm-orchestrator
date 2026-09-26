# AGENTS.md

Subagent roles. Each name below is the `subagent_type` the Agent tool expects,
and matches the `name:` in `agents/orch-*.md`.

| `subagent_type` | Model | Purpose |
|---|---|---|
| `orch-explorer` | opus | Finds where code lives. Read-only; returns `Found:` with file:line refs. |
| `orch-implementer` | opus | Does one task from a plan; returns a `Status:` block. |
| `orch-spec-reviewer` | opus | Reviews a written spec document during brainstorming. Code review is `scripts/lib/orch-review.py`, which runs the built-in `/code-review` and `codex review`, not an agent. |
| `orch-debugger` | opus | Finds the cause of a bug before anyone edits; returns `Found:`. |
| `orch-researcher` | opus | Checks an API or version against current docs; returns VERIFIED, COULDN'T_VERIFY, CONTRADICTED or NOT_APPLICABLE. |

The Model column copies each file's frontmatter in `agents/`. If the two ever
differ, the agent file is the truth.

How much process a change needs — Simple, Standard or Full — is in
`skills/cadence/SKILL.md`.

Every agent ends with `Verification: PASS | PENDING | BLOCKED | NOT APPLICABLE — reason`.
Only a check you actually ran supports PASS.

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
  of `CLAUDE.md` and `AGENTS.md` change only by a numbered ruling. To propose
  one, explain why, write the change as a patch file outside Git, and show the
  diff. If the person agrees, give them the one command that applies it,
  `cadence-ruling.sh <patch> "<their wording>"` from the `cadence` skill's
  `scripts/`, to run in their own terminal. Never run it yourself.

On Codex read project `CODEX.md` for evidence and hook trust. Installed hooks,
executed checks and instructions are distinct; Git checks do not prove reviews.
<!-- ORCH:LAWS:END -->
