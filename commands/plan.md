---
description: Turn a spec into a dated, checklist-shaped plan at docs/llm-orchestrator/plans/. Uses the writing-plans skill.
---

You are running `/plan`.

User input: $ARGUMENTS (optional — spec path or "latest")

Steps:

1. Find the spec:
   - If `$ARGUMENTS` is a path, use it.
   - If it's "latest" or empty, pick the newest file in `docs/llm-orchestrator/specs/`.
   - If no spec exists, invoke `brainstorming` and stop until a spec is written and approved.

2. Invoke the `writing-plans` skill.

3. Ensure directory:
   ```bash
   mkdir -p docs/llm-orchestrator/plans
   ```

4. Produce the plan file at `docs/llm-orchestrator/plans/YYYY-MM-DD-<slug>-plan.md`:
   - Date in ISO format.
   - Slug from the spec title (lowercase, hyphens).

5. Self-review:
   - No "TBD", "similar to N", "etc.".
   - Every task has at least one `Verify:` command.
   - Each task is marked `Independent: yes | no (depends on M)`.

6. Report:

```
Changed:
- created docs/llm-orchestrator/plans/<file>
Verify:
- cat docs/llm-orchestrator/plans/<file> | head -40
Next:
- /worktree to isolate, then /dispatch (it routes to sequential or parallel based on task independence)
```

Constraints:
- Plan is one file. No multi-file plans.
- Do not start implementing inside `/plan`. That's `/dispatch` or inline work.
