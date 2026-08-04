---
name: systematic-debugging
description: Use when a bug, test failure, exception, regression, or unexpected behavior appears, before proposing or applying a fix — it forces root-cause investigation first. Not for the expected red phase of TDD: a failing test you just wrote is progress, not a bug. Runs before test-driven-development when both match.
---

# Systematic debugging

Find the cause. Then fix it. Not the other way around.

## Phases

### 1. Reproduce
- Run the failing thing yourself.
- Capture the exact error and the command.
- Note the last change that might have caused it: `git log -p -S '<symbol>' --since='3 days ago'`.

### 2. Locate

Read the trace top-down. Stop at the first line of your code. Open that file, and the file that calls it.

**When the error surfaces far from its cause, trace the value, not the stack.** A stack trace tells you where the program noticed; it often says nothing about where the bad value came from. Ask: where does this value originate? What called this with it? Keep walking up until you reach the place the value is *created wrong* — that is the fix site. Fixing where it was noticed leaves the cause in place, and the next symptom appears somewhere else.

When reading is not enough, instrument:
- Log immediately **before** the dangerous operation, not after — after is too late to see the input.
- Log the value, the arguments, `cwd`, and any relevant environment alongside it.
- Include `new Error().stack` (or your language's equivalent) to capture who called.
- In tests, use `console.error` / stderr rather than the project logger — a logger may be captured or suppressed by the test runner and you will conclude the code never ran.

For a failure crossing several components, instrument every boundary and run **once** to find out which boundary it breaks at. Then stop and narrow to that component. Instrumenting and hypothesising at the same time gives you two unknowns.

### 3. Compare against something that works

Before hypothesising, find the closest thing in this codebase that does work — the sibling handler, the other adapter, the same call in a passing test.

Read the working one completely rather than skimming for the interesting part, then list **every** difference between it and the broken one. Order of arguments, a missing await, a different lifecycle hook, an extra config key. The instinct to skip a difference because "that can't matter" is exactly where the bug hides.

If a test is at issue and you need to know *which other test* breaks it, bisect: run the test files one at a time, checking after each for the state that causes the failure. Stop at the first file that creates it.

### 4. Hypothesise (one at a time)
- State the smallest hypothesis: "If X, then Y."
- Design the smallest observation that distinguishes X from not-X.
- Change one variable. Run. Read the output before deciding anything.

### 5. Fix
- Write a failing test that captures the bug, and watch it fail (`test-driven-development`).
- Make the smallest change that turns it green — at the source, not at the symptom.
- Run the full suite. No regressions.

## Flaky tests and arbitrary waits

A test that sleeps for a fixed duration is a test that fails on a slower machine. Replace the delay with a wait on the thing you actually care about — poll for the condition every ~10ms up to a timeout, and throw a named error when the timeout is hit so the failure says what never happened.

Wait for the event, the state, the count, or the file — whichever the assertion depends on.

A fixed delay is defensible only when all three hold: you first wait for the triggering condition, the duration comes from a known timing characteristic rather than a guess, and a comment says why. Otherwise the flake is not a flake — it is a race you have not found yet.

## Stopping rules

**Three failed hypotheses.** Stop. Do not try a fourth blind. Step up a level: is the assumption wrong, is the architecture wrong, is the reproduction actually reproducing the reported bug?

**Signs the problem is architectural, not local** — reachable before strike three:
- Each fix reveals new shared state or coupling somewhere else.
- Each fix creates a new symptom in a different place.
- The obvious fix requires restructuring far beyond the bug.

When these appear, the finding is the architecture. Report it rather than continuing to patch.

**When there is no root cause to find.** Some failures are genuinely environmental, timing-dependent, or external. That is a legitimate terminal state, not a failure to investigate — but it has to be earned. Say what you investigated and ruled out, implement the handling the situation actually needs (a retry, a timeout, a clear error message), and add the logging that will make the next occurrence diagnosable.

## Output shape during investigation

```
Found:
- error: `TypeError: cannot read 'id' of undefined` at users.ts:117
- origin: session is created in middleware.ts:34, which skips the guest path
- last touched: 2026-05-21 by commit a3b1c2 (added user.session)
- hypothesis: session is unset for guest users
Next:
- confirm by calling the guest flow directly
```

## Output shape after fix

```
Changed:
- middleware.ts:34 — set an empty session on the guest path
- users.test.ts — new test: guest user reaches the policy check
Why:
- root cause: middleware left session unset for guests; users.ts:117 was where it surfaced
Verify:
- `pnpm test` → 1 failed (before), 142 passed (after)
```

Fix at the origin. If the reported line and the fixed line differ, say so — that difference is the finding.

## Anti-patterns

- "Let me try a few things" — pick one thing.
- Fixing where the error surfaced instead of where the value went wrong.
- Catching and ignoring the error.
- Fixing the test instead of the bug.
- Claiming a fix without re-running the failing case.
- Adding a sleep until the flake goes away.
- Refactoring while debugging — separate commit, separate skill.
