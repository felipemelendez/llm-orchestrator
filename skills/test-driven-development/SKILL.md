---
name: test-driven-development
description: You MUST use this when implementing any feature or bugfix where tests are practical — before writing implementation code. Enforces red-green-refactor with verification at each step.
---

# Test-driven development

The discipline, briefly. No rationalization tables.

## Loop

1. **Red** — Write the smallest failing test.
2. **Verify red** — Run it. Confirm it fails with the expected message.
3. **Green** — Write the minimum code to pass.
4. **Verify green** — Run it. Confirm it passes.
5. **Refactor** — Tidy. Re-run.
6. **Commit** — One green step, one commit.

## When this applies

- Most application code.
- Anything with deterministic inputs and outputs.
- Bug fixes (write the failing test that reproduces the bug first).

## When to relax

- Throwaway scripts.
- Generated code.
- Config and infra glue.
- UI prototyping where a test would be longer than the code.

If you're not sure, write the test.

## What "verify" means

Not "I think this would fail." Actually run it. Paste the line that proves it.

```
Verify red:
- `pnpm test users.test.ts` → "expected 'admin', got undefined"

Verify green:
- `pnpm test users.test.ts` → "1 passed"
```

## If a fix doesn't take

After 3 failed attempts on the same green step, stop. Investigate with `systematic-debugging`. Don't try fix #4 blind.

## Output shape

```
Changed:
- src/users.ts:42 — added role default
- src/users.test.ts — new test
Why:
- bug: users without role hit `undefined` in policy check
Verify:
- pnpm test users.test.ts → 1 passed
```

## What not to do

- Don't write the implementation before the test (delete it if you did — once, not as a ritual).
- Don't expand the test to cover more after it goes green; write a new test.
- Don't claim "tests pass" without running them.
