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

## Pushing back

Pushback is fine. Required form:

```
Disagreed:
- <file:line> — reviewer said X. Evidence shows Y.
- Reason: <one line — what proves it>
```

Push back with evidence, not opinion. If you don't have evidence, ask.

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
