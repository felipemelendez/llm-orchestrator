---
name: test-driven-development
description: Use when implementing a feature or bugfix where tests are practical, before writing implementation code. Enforces red-green-refactor with a verified red phase. Not for docs-only or config-only changes with no testable behavior, and not before systematic-debugging when the trigger was a failure rather than new work.
---

# Test-driven development

Write the test. Watch it fail. Write the least code that makes it pass.

**The load-bearing step is watching it fail.** A test you never saw fail has not been shown to test anything — it may assert nothing, never execute, mirror the implementation back at itself, or cover behavior that already worked, and a green suite hides all four. This is also why "write the code first, tests after" fails even when it feels equivalent: an after-the-fact test passes on its first run, which proves nothing, and it is shaped by the code that already exists — so it covers the cases you remembered, not the ones a test-first pass would have forced you to discover. Under deadline pressure, "tests after achieve the same purpose" is precisely the rationalization to refuse; the pressure is the reason for the discipline, not the exception to it.

## The loop

Red → verify red → green → verify green → refactor. One behavior per test — a name containing "and" is two tests — and name the behavior, not the function: `retries a failed call three times`, not `test retry`. Write against real code; reach for a mock only when the real dependency is slow or external, and read [writing-good-tests.md](./writing-good-tests.md) before adding one.

**Verify red** — the step that gets skipped. Run the test and confirm three things: it *failed* rather than errored (an import error or typo proves nothing about the behavior — fix and re-run until the failure is the assertion); the failure message is the one you predicted (if you can't say in advance what the failure will look like, you don't yet know what the test is for); and it failed because the behavior is missing, not because the test is wrong. If it *passed*, you're testing behavior that already exists — either the assertion is empty or this isn't the test you need. Passed or errored both mean fix the test, not the code.

**Green** — only enough code to pass the test you just watched fail. No options the test didn't ask for, no refactoring of neighbouring code, no improvements noticed along the way — separate cycles. But least code is not *narrowest* code: the test is one example of a rule, so write the rule, not a branch that recognises the example. `if n == 3: return True` passes and generalizes to nothing — a green line bought by moving the bug out of the test's line of sight. Same trap: special-casing the test's fixture path, returning the literal the assertion expects instead of computing it. Fewer options is the goal; fewer inputs handled correctly is not.

**Verify green** — run again: the test passes, every other test still passes, and the output is clean (no new warnings or stack traces that "don't matter"). If it still fails, fix the code — editing the assertion to match the code you wrote is how a suite stops meaning anything. If the test itself turns out wrong — it asserts something the spec doesn't ask for, or the task can't be done as written — say so and stop. A wrong test is a finding to report, not an obstacle to route around; every route around it (the edited assertion, the special case, the `skip`) leaves a suite that lies.

**Refactor** only once green: duplication, names, helpers. No new behavior, re-run after each step.

## Bug fixes

A bug is a missing test. Reproduce it as a failing test first, then fix; the test stops the bug returning, and the red run proves the test actually reproduces it. If the cause isn't obvious, invoke `systematic-debugging` first — find the cause, then write the test that captures it. A failing test you just wrote is the red phase, not a bug; don't send it back into debugging.

## When testing is hard

Difficulty testing is design feedback, not a reason to skip. Can't see how to test it → write the call you wish existed, then the assertion; if it still resists, the interface is unclear — a design finding. Enormous setup → the unit does too much or its dependencies aren't injectable. Mocking nearly everything → the code is tightly coupled, and mocking around it tests the mocks. Test more complex than the code → simplify the interface, not the test.

## When to relax

Docs, config, and formatting have no behavior to test. Throwaway exploration is fine — then delete it and start the real work with a test. A test that legitimately passes first because the behavior already worked happens — say so rather than deleting it. Relaxing is a decision stated out loud, not a default; "too simple to test," applied silently, is the exception swallowing the rule.

## Enforcement

The evidence-ledger hook records every test run the harness executed, with its exit code. A completion claim naming a test command that never ran green this turn is caught (`orch-verify-gate`), and a turn that changed a test file while the suite was only ever seen green gets flagged — that green-only history is the signature of a test written after the code. Both are notes, not blocks; the exceptions above are real. And the ledger sees exit codes, not reasons — a broken import also exits non-zero — so telling a real red from a broken one remains your job, at verify-red.

## Output

Report both runs — that pair is what makes the cycle legible:

```
Verify:
- `pytest tests/test_retry.py -q` → 1 failed (before)
- `pytest tests/test_retry.py -q` → 1 passed (after)
```

If verification fails, the reply is `Found:` with the failure — not `Changed:`.
