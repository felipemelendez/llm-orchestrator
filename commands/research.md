---
description: Verify an approach, API surface, or version assumption against current sources before committing to it. Returns one of four outcomes; CONTRADICTED halts the work.
---

Run the research gate explicitly on: $ARGUMENTS

Skip the classifier — the user asked for this directly, so treat it as `RESEARCH_NEEDED`.

1. Dispatch the `orch-researcher` subagent with `templates/research-brief.md`. Paste the
   question, the target library or API surface, and any version pinned in the project's
   manifest or lockfile. Do not pass a file path — paste the content.

2. The researcher returns exactly one outcome:
   - `VERIFIED` — sources confirm the approach. Proceed; cite the brief.
   - `CONTRADICTED` — sources say the approach is deprecated, renamed, removed, or wrong
     for the target version. **This halts the work.** Surface what was assumed, what the
     docs say, the citation with its retrieval date, and the recommended revision.
   - `COULDN'T_VERIFY` — sources unreachable. Proceed with low confidence and annotate it.
   - `NOT_APPLICABLE` — the question's premise doesn't hold in this repo.

3. Report in one `Found:` block: the outcome, the one-line reason, and the brief path
   under `docs/llm-orchestrator/research/`. Don't paste the brief inline — link it.

The classifier normally decides whether this runs. Invoking it directly is the override
for when you already know the answer matters — a version bump, a security-sensitive
surface, or a library you suspect has moved.
