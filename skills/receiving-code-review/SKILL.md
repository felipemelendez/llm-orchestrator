---
name: receiving-code-review
description: Use when responding to code review feedback — from a human, from another agent, or from the two-stage review flow. Resists performative agreement and blind implementation.
---

# Receiving code review

Reviews are signal. Treat each issue as a hypothesis, not a verdict.

## When to use

- Reviewer (human or agent) returns an `Issues:` block.
- A user pastes "you should change X" feedback.
- After `/llm-orchestrator:review` returns Critical or Important findings.

## The default response

For each issue, decide one of:

1. **Agree, fix** — issue is real, fix is clear. Do it.
2. **Agree, push back on the fix** — issue is real but the suggested fix is wrong; propose an alternative.
3. **Disagree, with reason** — issue is not real; explain why with evidence.
4. **Need more info** — issue is ambiguous; ask one clarifying question.

Never blanket-agree. Never silently ignore.

## Steps

1. Read every Issue. One pass, no skipping.
2. For each Critical: stop and address before continuing.
3. For each Important: fix before moving past this area.
4. For each Minor: decide — fix now or note as follow-up.
5. For each item, decide which of the four responses applies.

## Understand everything before implementing anything

If any item is unclear, stop — and do not implement the ones you *did*
understand. Findings are frequently related: a partial fix built on partial
understanding is how a review round produces new findings.

Ask about the unclear items, then work the whole set.

## Check it before you accept it

Evidence is required to disagree, so it must also be required to agree — an
unchecked suggestion is accepted on the reviewer's authority, not its merit.
Before implementing, confirm:

- It is correct for *this* codebase, not in general.
- It does not break existing behaviour.
- There is no reason the current implementation is the way it is.
- It holds across the platforms and versions this project supports.
- The reviewer had the context to judge — an external reviewer often does not.

When the reviewer suggests "implementing this properly", grep for actual usage
first. Building out dead surface is the most common bad suggestion on
agent-written code; if nothing calls it, the answer is to delete it.

## Pushing back

Pushback is fine. Required form:

```
Disagreed:
- <file:line> — reviewer said X. Evidence shows Y.
- Reason: <one line — what proves it>
```

Push back with evidence, not opinion. If you don't have evidence, ask.

## Legitimate grounds for pushback

- It breaks existing functionality.
- The reviewer lacked context you have.
- It violates YAGNI — nothing needs it.
- It is wrong for this stack or this platform.
- A legacy or compatibility reason explains the current shape.
- It conflicts with a recorded architectural decision (`## Decisions` in
  ./CLAUDE.md). Do not implement over a recorded decision — stop and raise the
  conflict; one of the two is out of date and the user decides which.

If you push back and turn out to be wrong, state the correction plainly and
implement. No apology, no defence of why you pushed back — both cost words and
neither changes the code.

## Working through a batch

Blocking items first, then the simple mechanical ones (typos, imports), then
the ones needing real thought. Reply to a GitHub review thread on the thread
itself — `gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies` — not as
a new top-level PR comment, which detaches the answer from the question.

## Output shape

After processing the review:

```
Changed:
- <file:line> — addressed Critical from review
- <file:line> — addressed Important from review

Disagreed:
- <file:line> — <one-line reason + evidence>

Deferred:
- <file:line> — Minor, tracked as follow-up

Verify:
- <command> → <line>
Next:
- Re-run /llm-orchestrator:review on updated diff.
```

## Anti-patterns

- "Good points, I'll fix all of them" → that's the response of someone who didn't read them.
- Implementing the reviewer's exact fix without checking it actually compiles/tests green.
- Silently dropping an Issue because it's awkward.
- Calling everything "Minor" to avoid work.
- Treating reviewer confidence as truth — verify the claim.
