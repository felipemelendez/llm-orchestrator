---
description: Write a short handoff note so work resumes cleanly after the context is compacted.
argument-hint: "[slug]"
---

You are running '/llm-orchestrator:handoff'.

User input: $ARGUMENTS — optional slug; defaults to the active plan's slug.

Invoke the `handing-off-to-fresh-context` skill, then:

1. Resolve the slug — use `$ARGUMENTS` if given, else the active plan's slug (or a short kebab-case name for the current work).
2. Follow the skill's config-backed path choice: enabled proportional cadence uses task-owned external scratch and a consumer lease; without an enabled cadence it is `docs/llm-orchestrator/handoffs/<date>-<slug>.md`. Record what's done/next, actual verification results and receipt pointers, pending failures and useful constraints. Refresh the same note.
3. Report the note path and, for proportional tasks, the helper task ID/recovery path. Keep it while work is pending; finish cleanup only after the note is consumed and deliverables preserved. Resume reuses matching trusted evidence; compaction alone does not require rerunning checks.

Output without an enabled cadence below; an enabled cadence uses the shared `Verification:` disposition.

```
Changed:
- docs/llm-orchestrator/handoffs/<date>-<slug>.md — handoff note written

Verify:
- <the verify command> → <its green output>
```

Constraints:
- Keep it short — the plan file (checkboxes on disk) is the source of truth; this note only carries conversational state the code can't.
- Don't paste long agent reports; cite `git diff` / the transcript instead.
