---
description: Turn a spec into a dated, checklist-shaped plan at docs/llm-orchestrator/plans/. Uses the writing-plans skill.
---

You are running `/llm-orchestrator:plan`.

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
   - Every task has a `Done when:` line and a `Stop if:` line — the termination contract the implementer envelope pastes; a task without them gives the dispatched agent no way to prove success or stop failing.
   - Every task has at least one `run:` sub-step with an `expect:` output line, and the file ends with a `## Verify done` section.
   - Each task heading carries the `- [ ]` checkbox and is marked `Independent: yes | no (depends on M)`.

6. Report:

```
Changed:
- created docs/llm-orchestrator/plans/<file>
Verify:
- cat docs/llm-orchestrator/plans/<file> | head -40
Next:
- /llm-orchestrator:worktree to isolate, then /llm-orchestrator:dispatch (it routes to sequential or parallel based on task independence)
```

Constraints:
- Plan is one file. No multi-file plans.
- Do not start implementing inside `/llm-orchestrator:plan`. That's `/llm-orchestrator:dispatch` or inline work.
