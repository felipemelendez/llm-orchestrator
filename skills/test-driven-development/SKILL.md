---
name: test-driven-development
description: Use when implementing a feature or bugfix where tests are practical, before writing implementation code. Enforces red-green-refactor with a verified red phase. Not for docs-only or config-only changes with no testable behavior, and not before systematic-debugging when the trigger was a failure rather than new work.
---

# Test-driven development

Write the test. Watch it fail. Write the least code that makes it pass.

**The load-bearing step is watching it fail.** A test you never saw fail has not been shown to test anything. It may assert nothing, never execute, mirror the implementation back at itself, or cover behavior that already worked — and a green suite hides all four. The red run is the only evidence that the test can catch the bug you are about to fix.

That step is checked here, not merely asked for — see [Enforcement](#enforcement).

## The loop

```
Red           write one failing test
  ↓
Verify red    run it; confirm it fails, and fails for the reason you expect
  ↓
Green         write the least code that passes it
  ↓
Verify green  run it; confirm it passes and nothing else broke
  ↓
Refactor      clean up, staying green
  ↓
repeat
```

## Red — write one failing test

One behavior per test. A name containing "and" is two tests.

Name the behavior, not the function: `retries a failed call three times`, not `test retry`.

Write it against real code. Reach for a mock only when the real dependency is slow or external — and read [writing-good-tests.md](./writing-good-tests.md) before adding one.

## Verify red — the step that gets skipped

Run it. Then confirm three things:

1. **It failed rather than errored.** An import error or a typo is not a red phase. Fix it and re-run until the failure is the assertion.
2. **The failure message is the one you predicted.** If you cannot say in advance what the failure will look like, you do not yet know what the test is for.
3. **It failed because the behavior is missing**, not because the test is wrong.

Two outcomes mean fix the test, not the code:

- **It passed.** You are testing behavior that already exists. Either the assertion is empty, or the feature is already there and this is not the test you need.
- **It errored.** An erroring test proves nothing about the behavior.

## Green — the least code that passes

Write only enough to pass the test you just watched fail.

```python
# enough
def retry(fn, attempts=3):
    for i in range(attempts):
        try:
            return fn()
        except Exception:
            if i == attempts - 1:
                raise

# too much — nothing asked for backoff, jitter, or a callback
def retry(fn, attempts=3, backoff="exponential", jitter=True, on_retry=None):
    ...
```

No options the test did not ask for, no refactoring of neighbouring code, no improvements you noticed on the way. Those are separate cycles.

## Verify green

Run it again. Confirm:

- The test passes.
- Every other test still passes.
- The output is clean — no new warnings, no stack traces that "don't matter".

If it still fails, fix the code. Editing the assertion to match the code you wrote is how a suite stops meaning anything.

## Refactor

Only once green. Remove duplication, improve names, extract helpers. Add no behavior. Re-run after each step.

## Bug fixes

A bug is a missing test. Reproduce it as a failing test first, then fix it. The test is what stops the bug returning; the red run is what proves the test actually reproduces it.

If the cause is not obvious, invoke `systematic-debugging` first — find the cause, then write the test that captures it. A failing test you just wrote is the red phase, not a bug; do not send it back into debugging.

## When it is hard

| Symptom | What it usually means |
|---|---|
| You cannot work out how to test it | Write the call you wish existed, then the assertion. If it still resists, the interface is unclear — a design finding, not a testing problem. |
| The test needs enormous setup | The unit does too much, or its dependencies are not injectable. |
| You must mock nearly everything | The code is tightly coupled; mocking around it tests the mocks. |
| The test is more complex than the code | Simplify the interface, not the test. |

## When to relax

- Docs, config, and formatting changes have no behavior to test.
- Throwaway exploration: fine — then delete it and start the real work with a test.
- A test that legitimately passes first because the behavior already worked. That happens; say so rather than deleting the test.

Relaxing is a decision to state out loud, not a default.

## Enforcement

The evidence-ledger hook records every test run the harness actually executed, with its exit code. Two things follow, and neither asks anything of you but honesty:

- A completion claim naming a test command that never ran green this turn is caught (`orch-verify-gate`).
- If this turn changed a test file and the suite was only ever seen green — never red — the gate says so. That is the signature of a test written after the code.

Both are notes, not blocks; the exceptions above are real. And the ledger sees exit codes, not reasons — a test that failed to import also exits non-zero, so it can tell you the suite was never red, but it cannot tell a real red from a broken one. That distinction is still yours to make, at step 1 above.

## Output shape

```
Changed:
- src/retry.py:12 — retry() now stops after three attempts
- tests/test_retry.py — new: stops after three attempts

Verify:
- `pytest tests/test_retry.py -q` → 1 failed (before the fix)
- `pytest tests/test_retry.py -q` → 1 passed (after)
```

Report both runs. Two lines, and the cycle is legible.

If verification fails, this is not a `Changed:` reply. Report `Found:` with the failure and what you know about it.

## What not to do

- Writing the code first and the test after. Tests written after pass on the first run, which proves nothing, and they are shaped by the code that already exists — so they cover the cases you remembered rather than the ones you would have discovered.
- Editing the assertion until it passes.
- Asserting on a mock's behavior instead of the code's.
- Skipping the red run because the test "obviously" fails.
- Adding tests at the end for coverage. A test that exists to satisfy a number costs maintenance forever and catches nothing.
