---
name: receiving-code-review
description: Use when responding to code review feedback from a person or an agent. Check each point before changing code; no performative agreement.
---

# Receiving code review

Treat each issue as a hypothesis, not a verdict. For each one: agree and fix, agree but propose a
better fix, disagree with evidence, or ask one clarifying question. Never blanket-agree, never
silently drop an issue — "good points, I'll fix all of them" is the response of someone who
didn't read them.

## Understand everything before implementing anything

If any item is unclear, stop — and do not implement the ones you *did* understand. Findings are
frequently related: a partial fix built on partial understanding is how a review round produces
new findings. Ask about the unclear items, then work the whole set.

## Check it before you accept it

Evidence is required to disagree, so it must also be required to agree — an unchecked suggestion
is accepted on the reviewer's authority, not its merit. Before implementing, confirm the
suggestion is correct for *this* codebase (stack, platforms, versions), doesn't break existing
behaviour, and isn't fighting a reason the current implementation is the way it is. An external
reviewer often lacked context you have.

When the reviewer suggests "implementing this properly", grep for actual usage first. Building
out dead surface is the most common bad suggestion on agent-written code; if nothing calls it,
the answer is to delete it.

If a suggestion conflicts with a recorded architectural decision (`## Decisions` in ./CLAUDE.md),
do not implement over it — stop and raise the conflict; one of the two is out of date and the
user decides which.

## Pushing back

Push back with evidence, not opinion; if you don't have evidence, ask.

```
Disagreed:
- <file:line> — reviewer said X. Evidence shows Y.
- Reason: <one line — what proves it>
```

If you push back and turn out to be wrong, state the correction plainly and implement. No
apology, no defence of why you pushed back — both cost words and neither changes the code.

## Working through a batch

Findings are ranked by the project's harm ranking (`LAWS.md`). Catastrophic and
serious findings block the work until each is fixed or refuted; mild findings
are fixed now or recorded with a reason, but "mild" is a judgment about impact,
not a label for work you'd rather avoid. Reply to a GitHub review thread on the
thread itself — `gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies` —
not as a new top-level PR comment, which detaches the answer from the question.

## Recording what happened (after `orch-review.py`)

After an `orch-review.py` review, record one disposition per finding id in
`review.json`, then run `orch-review.py record <run-dir> --dispositions <file>`.
The file is a JSON object keyed by id (`code-review-1-3` when one reviewer ran
twice):

```json
{
  "code-review-1": {"disposition": "fixed", "check": "python3 tests/test-x.py"},
  "codex-review-2": {"disposition": "refuted",
                     "evidence": {"type": "file-line", "file": "src/a.py", "line": 12, "quote": "return total"}},
  "codex-review-3": {"disposition": "ignored", "reason": "wording only"}
}
```

- `fixed` names the check that failed before the fix and passes after it.
- `refuted` quotes one line of the reviewed files that contradicts the claim;
  the script checks the quote.
- `ignored` gives a reason. A blocking finding may be ignored only when the
  person said so; add `"person_approved": true`.

`record` rejects a file that leaves a finding out, and records a run only once.

## Output shape

After processing the review:

```
Changed:
- <file:line> — fixed a catastrophic or serious finding

Disagreed:
- <file:line> — <one-line reason + evidence>

Deferred:
- <file:line> — mild, tracked as follow-up

Verify:
- <command> → <line>
Next:
- Record the dispositions, then re-run /llm-orchestrator:review on the updated change.
```

The `Verify:` line is the check that the reviewer's fix actually compiles and tests green in this
repo — implementing a suggested fix verbatim does not exempt it from verification.
