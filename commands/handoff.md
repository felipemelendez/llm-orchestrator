---
description: Write a short handoff note so work resumes cleanly after the context is compacted.
argument-hint: "[slug]"
---

You are running '/llm-orchestrator:handoff'.

User input: $ARGUMENTS — optional slug; defaults to the active plan's slug.

Invoke the `handing-off-to-fresh-context` skill, then:

1. Resolve the slug — use `$ARGUMENTS` if given, else the active plan's slug (or a short kebab-case name for the current work).
2. Write a brief note to `docs/llm-orchestrator/handoffs/<date>-<slug>.md` (overwrite in place if it exists — never a v2 sibling) with: what's done / what's next, the exact verify command and its last green output, and any "don't do X" that emerged this session. Keep it short — link to `git diff` / the plan rather than restating them.
3. Tell the user where the note is and that they can resume from it.

```
Changed:
- docs/llm-orchestrator/handoffs/<date>-<slug>.md — handoff note written

Verify:
- <the verify command> → <its green output>
```

Constraints:
- Keep it short — the plan file (checkboxes on disk) is the source of truth; this note only carries conversational state the code can't.
- Don't paste long agent reports; cite `git diff` / the transcript instead.
