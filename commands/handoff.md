---
description: Regenerate the context-handoff artifact for the current task and hand control to a fresh session.
argument-hint: "[slug]"
---

You are running '/handoff'.

User input: $ARGUMENTS — optional slug; defaults to the active plan's slug.

Invoke the `handing-off-to-fresh-context` skill.

Steps:

1. Resolve the slug. If `$ARGUMENTS` is non-empty, use it. Otherwise read the active plan from `docs/llm-orchestrator/plans/` and extract its slug.

2. Resolve the artifact path: `docs/llm-orchestrator/handoffs/<date>-<slug>.md`. If the file exists, this is a regeneration — overwrite in place, never write a v2 sibling.

3. Set `trigger: user` in the artifact's frontmatter (this is the user-invoked path, not `tier-boundary` or `threshold`).

4. Populate all 10 slots from `templates/handoff.md` per the skill: bootstrap from `CLAUDE.md` + architecture memory, reconcile plan checkboxes, paste the last 3–5 subagent reports verbatim, fill the verification baseline with exact commands and expected output.

5. Bump `revision` via `orch_handoff_next_revision`, set `last_regenerated_at` to now (ISO8601), set `context_estimate_pct` to the current estimate or `unknown`.

6. Run the no-op check via `orch_handoff_is_noop`. If noop, still write (revision + timestamp increment) but flag it to the user.

7. Two-stage review: dispatch `orch-spec-reviewer` (all slots filled, all citations live?) then `orch-code-reviewer` (self-sufficient, no stale references, no ambiguous shorthand). On either failing, revise and re-review before proceeding.

8. Present the resume prompt from the artifact to the user.

```
Changed:
- docs/llm-orchestrator/handoffs/<date>-<slug>.md — revision N, trigger: user, context: <pct>%

Verify:
- spec+code reviewers passed

Blocked:
- Context is too full to continue in this session.

Need:
- Start a fresh session and paste the resume prompt from the artifact above.

Tried:
- Regenerated the artifact (vN); spec and code reviewers passed.
```

Constraints:
- `trigger` is always `user` when this command fires (not `tier-boundary` or `threshold`).
- Never summarise subagent reports — paste verbatim.
- Never duplicate plan checkbox state in the artifact; the plan file is the source of truth.
- Never skip the two-stage review gate, even for a no-op regeneration.
- Do not proceed if either reviewer fails — revise first.
