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

If you push back and are wrong, state the correction plainly and implement. No
apology or defence.

## Working through a batch

Findings are ranked by the project's harm ranking (`LAWS.md`) as the prover
ranked them: the consequence if the claim is true, never the reviewer's label.
A catastrophic finding blocks the work until it is fixed, or ignored by the
person; a serious one until it is fixed, refuted or settled; their fixes are
re-reviewed, a serious finding's small fix by Standard review (landing rule
6's small-fix clause). Mild findings are fixed now or
recorded with a reason, and a review that returned only mild findings
(`READY-WITH-FIXES`) is the last one: handle them in one commit, run the
checks, read the diff, record each disposition, land — unless a fix turned out
to change behaviour, which goes back for review. "Mild" is a judgment about
impact, not a label for work you'd rather avoid.

A finding that reopens a decision the spec lists under `## Settled` with no
new argument against its reason is recorded `settled`; it blocks nothing and
costs no round. A reproduced, catastrophic or unranked finding is never settled. A
decision ruled a second time goes into `## Settled`, with its reason, in the
file the review reads as `--spec`, before the next review. A `design-simplicity` finding asks:
Is this the simplest correct version? (`requesting-code-review`'s
`references/design-simplicity.md`). It is fixed, refuted with evidence that
its simpler alternative is not correct for this codebase, or settled by the
spec; it is never set aside as style. Reply to a GitHub review thread on the
thread itself (`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`),
not in a new top-level PR comment.

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
  "codex-review-3": {"disposition": "ignored", "reason": "wording only"},
  "codex-review-4": {"disposition": "settled", "entry": "the cache is keyed by user id"},
  "codex-review-5": {"disposition": "follow-up", "reference": "PR #14: retry on a closed socket"}
}
```

- `fixed` names the check that failed before the fix and passes after it.
- `refuted` quotes one line of the reviewed files that contradicts the claim;
  the script checks the quote, and refuses it for a reproduced, catastrophic
  or unranked finding (those are fixed, or ignored by the person).
- `settled` quotes one whole entry of the spec's `## Settled` section; the
  script checks it against the spec the run read and refuses it for a
  reproduced, catastrophic or unranked finding.
- `follow-up` names the PR, issue or plan task that will carry an unreproduced
  serious finding whose repro passed or was never attempted (rule 7 of
  `finishing-a-branch`'s `references/landing-rules.md`); the script refuses it
  for a reproduced finding or a failed or unrun repro; a security, privacy or
  data-integrity finding needs `"person_approved": true`.
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
- Record the dispositions, then one scoped re-review of a serious or catastrophic finding's fix, Standard under the small-fix clause (new reproduced defects mean another round); a mild-only fix lands without another review unless it changed behaviour; then /llm-orchestrator:finish.
```

The `Verify:` line is the check that the reviewer's fix actually compiles and tests green in this
repo — implementing a suggested fix verbatim does not exempt it from verification.
