---
name: systematic-debugging
description: You MUST use this when ANY bug, test failure, exception, regression, or unexpected behavior appears — before proposing or applying any fix. Forces root-cause investigation.
---

# Systematic debugging

Find the cause. Then fix it. Not the other way around.

## Phases

### 1. Reproduce
- Run the failing thing yourself.
- Capture the exact error and the command.
- Note the last change that might have caused it (`git log -p -S '<symbol>' --since='3 days ago'`).

### 2. Locate
- Read the trace top-down. Stop at the first line of your code.
- Open that file. Open the file that calls it.
- If it spans multiple layers, instrument at every boundary — temporary `console.log` / `print` is fine; remove before committing.

### 3. Hypothesize (one at a time)
- State the smallest hypothesis: "If X, then Y."
- Design the smallest test that distinguishes X from not-X.
- Change one variable. Run. Read.

### 4. Fix
- Write a failing test that captures the bug.
- Make the smallest change that turns it green.
- Run the full suite — no regressions.

## Stopping rule

If 3 hypotheses fail, stop debugging. Step up: is the architecture wrong? Is the assumption wrong? Ask the user. Don't try hypothesis 4.

## Output shape during investigation

```
Found:
- error: `TypeError: cannot read 'id' of undefined` at users.ts:117
- last touched: 2026-05-21 by commit a3b1c2 (added user.session)
- hypothesis: session may be unset for guest users
Next:
- check guest flow in middleware.ts:34
```

## Output shape after fix

```
Changed:
- users.ts:117 — guard against undefined session
- users.test.ts — new test: guest user with no session
Why:
- root cause: middleware leaves session unset for guest path
Verify:
- pnpm test → 142 passed (was 141 + 1 failing)
```

## Anti-patterns

- "Let me try a few things" — pick one thing.
- Catching and ignoring the error.
- Fixing the test instead of the bug.
- Claiming a fix without re-running the failing case.
- Refactoring while debugging — separate commit, separate skill.
