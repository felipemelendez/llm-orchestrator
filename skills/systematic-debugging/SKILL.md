---
name: systematic-debugging
description: Use when a bug, test failure, exception, regression, or unexpected behavior appears, before proposing or applying a fix — it forces root-cause investigation first. Not for the expected red phase of TDD: a failing test you just wrote is progress, not a bug. Runs before test-driven-development when both match.
---

# Systematic debugging

Find the cause, then fix it — never the other way around. When the trigger was a failure rather than new work, this skill runs before `test-driven-development`: the failing test that captures a bug is written after you know what the bug is, because a test written against a guess captures the guess.

## Investigate

Reproduce the failure yourself and capture the exact command and error. Check what changed: `git log -p -S '<symbol>' --since='3 days ago'`.

**Trace the value, not the stack.** The trace shows where the program *noticed*; it often says nothing about where the bad value was *created*. Walk up — what called this, with what — until you reach the place the value goes wrong. That is the fix site. Patching where it surfaced leaves the cause in place, and the next symptom appears somewhere else.

When reading isn't enough, instrument — in a way that can actually tell you something:

- Log immediately **before** the dangerous operation (after is too late to see the input), with the value, the arguments, `cwd`, and a captured stack (`new Error().stack` or equivalent) so you see who called.
- In tests, write to stderr rather than the project logger — a runner may swallow the logger, and you'll conclude the code never ran.
- For a failure crossing several components, instrument every boundary and run **once** to find which boundary it breaks at, then narrow. Instrumenting and hypothesising at the same time gives you two unknowns.

**Compare against something that works.** Find the closest working sibling — the other handler, the other adapter, the same call in a passing test — read it completely rather than skimming, and list *every* difference: argument order, a missing await, a lifecycle hook, an extra config key. The difference you skip because "that can't matter" is exactly where the bug hides. When one test poisons another, bisect: run the test files one at a time and stop at the first that creates the bad state.

Then hypothesise one at a time: "if X, then Y", the smallest observation that distinguishes X from not-X, one variable changed, output read before deciding anything.

## Fix

Only after the cause is found: write a failing test that captures the bug and watch it fail (`test-driven-development`), make the smallest change that turns it green — at the source, not the symptom — and run the full suite. If the reported line and the fixed line differ, say so: that difference is the finding.

Report investigation with `Found:` (error, origin, last touch, hypothesis) and the fix with `Changed:` plus a `Why:` line naming the root cause versus where it surfaced, and `Verify:` showing the failing run before and the passing run after.

## Flaky tests

A fixed sleep is a race you haven't found yet — it fails on a slower machine. Wait on the thing the assertion depends on (event, state, count, file): poll every ~10ms up to a timeout, and throw a named error on timeout so the failure says what never happened. A fixed delay is defensible only when you already wait for the triggering condition first, the duration comes from a known timing characteristic rather than a guess, and a comment says why.

## When to stop

**Three failed hypotheses:** stop; do not try a fourth blind. Step up a level — is the assumption wrong, the architecture wrong, or the reproduction not actually reproducing the reported bug?

**Architectural signs** (act on these even before strike three): each fix reveals new shared state or coupling elsewhere, each fix creates a new symptom in a different place, or the obvious fix requires restructuring far beyond the bug. Then the finding *is* the architecture — report it rather than continuing to patch.

**No root cause to find:** some failures are genuinely environmental, timing-dependent, or external. A legitimate terminal state, but it has to be earned — say what you investigated and ruled out, implement the handling the situation actually needs (a retry, a timeout, a clear error message), and add the logging that makes the next occurrence diagnosable.

Not acceptable in any of these states: fixing the test instead of the bug, catching and ignoring the error, claiming a fix without re-running the failing case, or refactoring while debugging (separate commit, separate skill).
