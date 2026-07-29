---
description: Root-cause-first debugging. Thin wrapper that invokes the systematic-debugging skill with a small gathering step.
---

You are running `/llm-orchestrator:debug`.

User input: $ARGUMENTS (optional — failing command, file path, or symptom)

Steps:

1. Gather the failing thing:
   - If `$ARGUMENTS` is non-empty, treat it as the symptom or command.
   - Otherwise ask once for the exact failing command and output.
   - Recent touches: `git log --oneline -10 -- <path>` if a path is implied.

2. Invoke the `systematic-debugging` skill. Follow it.

3. When a hypothesis is confirmed, write the failing reproduction test before the fix. Invoke `verification-before-completion` before claiming the bug is fixed.

Output shape: as defined by `systematic-debugging`.

Constraints:
- No fix before root cause.
- Stop after 3 failed hypotheses and ask the user.
- No refactoring during debugging.
