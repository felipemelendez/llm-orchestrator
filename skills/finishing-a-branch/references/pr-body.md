# Writing the pull request

The PR is how a person learns what the agents did. Write it for someone who
was not in the conversation and has two minutes.

## Rules

- **Plain words.** Say what changed for the people who use the project, not
  how the agent got there. No internal labels: no finding ids, test-case codes,
  tool names or agent roles. If a technical term is unavoidable, say what it
  means in a few words.
- **Short.** A normal ticket's body fits on one screen, around 150 to 250
  words. One idea per bullet, one line per bullet where possible.
- **Outcome first.** The first line of the Summary says what is different now.
  The reason comes right after it.
- **Evidence, not logs.** One result line per check, never pasted output.
- **Honest.** Say what was not done or not checked. "None" is a fine answer
  for Decisions and Open items.
- **Title:** what changed, in plain words, under 70 characters, in the
  project's naming style. Not the branch name.

## Shape

```markdown
## Summary
<One or two sentences: what is different now, and why.>

- <the main change, in plain words>
- <another change, if any>

## Decisions
- <a choice made> — <why, and the option not taken>

## Review
<Who reviewed it and the result.> <What they found and what was done about
it, one bullet each, or "Nothing to fix.">

## Verification
- `<command>` → <its result line>

## Manual checklist for the owner
- [ ] <something only a person can check, written as a step to try>

## Open items
- <what is left, or "None">
```

## Example

```markdown
## Summary
Invoices can now be marked as partly paid, so the unpaid total no longer
counts money already received.

- New "Partly paid" status with the amount received.
- The unpaid total subtracts partial payments.

## Decisions
- Partial payments are stored on the invoice, not as separate records — simpler,
  and no report needs them one by one yet.

## Review
One independent review. It found that a refund could make the paid amount
negative; that is now refused, with a test.

## Verification
- `npm test` → 214 passed
- `npm run typecheck` → no errors

## Manual checklist for the owner
- [ ] Mark an invoice partly paid and check the dashboard total drops by that amount.

## Open items
- None
```
