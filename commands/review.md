---
description: Two-stage review of the current diff, with optional Stage 3 security review when the diff touches auth/crypto/payments/secrets. Stage 1 — spec compliance. Stage 2 — code quality. Stage 3 — security (conditional).
---

You are running `/review`.

User input: $ARGUMENTS (optional — base ref, defaults to origin/main or the project's default branch)

Steps:

1. Invoke `requesting-code-review`.

2. Determine the base ref:
   - If `$ARGUMENTS` is non-empty, use it.
   - Otherwise: `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@'`. Fall back to `origin/main` if that fails.

   Then compute the diff:
   ```bash
   BASE_SHA=$(git merge-base HEAD "$BASE")
   git diff "$BASE_SHA"..HEAD
   ```

3. Locate spec + plan if they exist:
   - `docs/llm-orchestrator/specs/` latest
   - `docs/llm-orchestrator/plans/` latest

4. Stage 1 — spec compliance:
   - Dispatch the native `orch-spec-reviewer` agent (or, if unavailable, a generic subagent with `templates/spec-reviewer-prompt.md`).
   - Pass: spec content (pasted), plan content (pasted), diff (pasted).
   - Confidence threshold: ≥80% to raise an Issue.

5. If Stage 1 verdict is `no`, or `with-fixes` with at least one Critical: stop. Report and return to implementer.

6. Stage 2 — code quality:
   - Dispatch `orch-code-reviewer` (or generic subagent with `templates/code-reviewer-prompt.md`).
   - Pass: diff, project conventions (relevant CLAUDE.md section).

7. Stage 3 — security review (conditional):
   - Check whether the diff is security-sensitive (source `scripts/lib/orch-signals.sh` for `$ORCH_SIG_SECURITY_DIFF`):
     ```bash
     source scripts/lib/orch-signals.sh
     echo "$DIFF" | grep -qiE "$ORCH_SIG_SECURITY_DIFF"
     ```
     Also check changed file paths for the same keywords.
   - If the grep matches: dispatch `orch-security-reviewer` (or generic subagent with `templates/security-reviewer-prompt.md`). Pass: diff only.
   - If the grep does not match: skip Stage 3 silently. Do not mention it in the report.
   - Stage 3 is advisory. Critical findings from Stage 3 block the merge; Important and below are advisory (recorded, non-blocking).

8. Merge all `Issues:` blocks (from whichever stages ran) into one report.

9. Save to `docs/llm-orchestrator/reviews/YYYY-MM-DD-<slug>-review.md`:
   ```bash
   mkdir -p docs/llm-orchestrator/reviews
   ```

10. Report:

```
Issues:
- Critical: <count>
- Important: <count>
- Minor: <count>
Verdict:
- yes | no | with-fixes — <one line>
Next:
- Fix Critical (if any), then /verify, then /finish.
```

Constraints:
- Never run multiple stages from a single subagent.
- Speculation goes in `Notes:`, not `Issues:`.
- Zero issues is a valid outcome.
- Stage 3 runs only when the diff matches security keywords; otherwise skip silently.
