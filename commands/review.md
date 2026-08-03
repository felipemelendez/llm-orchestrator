---
description: Two-stage review of the current diff, with optional Stage 3 security review when the diff touches auth/crypto/payments/secrets. Stage 1 — spec compliance. Stage 2 — code quality. Stage 3 — security (conditional).
---

You are running `/llm-orchestrator:review`.

User input: $ARGUMENTS (optional — base ref, defaults to origin/main or the project's default branch)

Steps:

1. Invoke `requesting-code-review`. Consult `using-workflows` to route: if the Workflow tool is
   available, prefer the accelerated path in step 7a; otherwise
   run the canonical ordered stages (steps 4–8). The two paths are not behaviorally identical.

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
   - Reviewer reports everything with a 0.0–1.0 confidence tag; you filter below 0.8 into `Notes:`.

5. If Stage 1 verdict is `no`, or `with-fixes` with at least one Critical: stop. Report and return to implementer.

6. Stage 2 — code quality:
   - Dispatch `orch-code-reviewer` (or generic subagent with `templates/code-reviewer-prompt.md`).
   - Pass: diff, project conventions (relevant CLAUDE.md section).

7. Stage 3 — security review (conditional):
   - Check whether the diff is security-sensitive (source `scripts/lib/orch-signals.sh` for `$ORCH_SIG_SECURITY_DIFF`):
     ```bash
     # Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset
     # in command bash; marketplace installs nest under the plugin cache).
     orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
     L=$(orch_lib orch-signals.sh); [ -n "$L" ] && source "$L" || echo "orch-signals.sh not found — reinstall the plugin" >&2
     echo "$DIFF" | grep -qiE "$ORCH_SIG_SECURITY_DIFF"
     ```
     Also check changed file paths for the same keywords.
   - If the grep matches: dispatch `orch-security-reviewer` (or generic subagent with `templates/security-reviewer-prompt.md`). Pass: diff only.
   - If the grep does not match: skip Stage 3 silently. Do not mention it in the report.
   - Stage 3 is advisory. Critical findings from Stage 3 block the merge; Important and below are advisory (recorded, non-blocking).

7a. Preferred path (Workflow tool present) — replaces steps 4–7:
   - Compute `security_sensitive` from `$ORCH_SIG_SECURITY_DIFF` (the same grep as step 7) — the
     single source of truth; never re-derive it in the workflow script.
   - Run `workflows/review-diff.js` with `args = {specText, planText, conventions, diff,
     security_sensitive}`. It reproduces the Stage-1-gates-Stage-2 ordering (early-exits when the
     diff fails spec compliance), demotes findings below 0.8 confidence to `Notes:`, and runs a bounded
     adversarial verify pass (≤4 skeptic agents). It returns `{confirmed, notes, earlyExit, stagesRun, incomplete, failedDimensions}`. If `incomplete` is true a reviewer or a skeptic died — report that plainly and do not present the result as a clean review, however few findings came back. `stagesRun` and `failedDimensions` share one token set (`spec`, `code-quality`, `security`, `verify`). A finding tagged `verifiedBy: "unverified"` was never judged because its skeptic died; surface it as unjudged rather than confirmed.
   - Build the report below from that return, then continue at step 9.

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
- Ready: yes | no | with-fixes — <one line>
Next:
- Fix Critical (if any), then /llm-orchestrator:verify, then /llm-orchestrator:finish.
```

Constraints:
- Never run multiple stages from a single subagent.
- Speculation goes in `Notes:`, not `Issues:`.
- Zero issues is a valid outcome.
- Stage 3 runs only when the diff matches security keywords; otherwise skip silently.
