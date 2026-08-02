# Writing good tests

Read this when writing or changing a test, adding a mock, or adding a helper that only tests use.

Two rules generate everything below:

```
1. Every test names the break it catches.
2. Every test exercises the real thing.
```

A test written first and watched failing against real code satisfies both by construction. That is most of why the red phase matters.

## Name the break

Before writing the body, answer: **what change to the production code should make this test fail?**

If the answer is a bug — a wrong branch, a missing side effect, a wrong argument, an unhandled boundary, a broken contract — the test earns its place. If the answer is only "someone deliberately changed a decision", it is a change detector: it fires on every intentional edit and sleeps through real bugs.

Not `assert MAX_RETRIES == 5`. Instead: a failing call is retried five times and the sixth never happens. Test the behavior that depends on the decision, not the decision.

If you cannot name a break at all, there is nothing to test yet. Redesign around an observable behavior.

## Derive the expected value by hand

An expectation computed by the code under test passes no matter what that code does.

```python
# mirror assertion — the same function computes both sides, so it can never fail
expected = build_query(tag="urgent")
assert build_query(tag="urgent") == expected

# hand-derived literal
assert build_query(tag='urgent') == 'tag:"urgent"'
```

Literals and hand-checked fixtures. Table-driven cases with literal `want` values are the best shape available. If the expected value is hidden behind a loop, a builder, or a helper that shares logic with the subject, it is not an expectation.

## Test behavior, not text

Asserting that a file contains a line proves only that the file is the file. Run the thing and assert on what it did — output, exit code, side effect, resulting state.

This applies to scripts, config, and generated artifacts. Prose written for humans earns no test at all.

## Test your boundary, not the framework

Test the contract your code makes: the route you register, the query you emit, the payload you produce. Upstream mechanics belong to their maintainers' test suites — asserting that your router invokes a handler you registered tests the router, not you.

The same boundary applies inside your own code. Constructors, getters, and trivial forwarding earn a test when they validate, normalize, default, derive, or cause a side effect. Otherwise assert the first consumer-visible result that depends on them.

When upstream behavior genuinely surprised you, one narrow characterization test naming the assumption is worth having.

## The mock earns no assertions

An assertion on a mock passes when the mock is present and fails when it is absent. It says nothing about your code.

```javascript
// asserts the mock exists
expect(screen.getByTestId('sidebar-mock')).toBeInTheDocument();

// asserts the behavior
expect(screen.getByRole('navigation')).toBeInTheDocument();
```

If the mock is what you are checking, unmock it or delete the assertion. The question to ask yourself: *am I testing the behavior of a mock?*

## Mock at the right level

Learn what the real thing does before replacing it. Mock the slow or external layer; keep everything the test depends on real.

```javascript
// the mock also swallows the config write that the assertion depends on
vi.mock('ToolCatalog', () => ({ discoverAndCacheTools: vi.fn() }));

// mock only the slow server start; the config write stays real
vi.mock('MCPServerManager');
```

When unsure, run against the real implementation first and watch what has to happen.

Two more rules that follow from this:

- **Mirror the real structure completely.** Mock every documented field, not just the ones this test reads. A partial mock passes while integration breaks, because downstream code reads a field you omitted.
- **Make doubles specific.** When arguments, call counts, or ordering are part of the contract, assert them. A fake that accepts anything verifies nothing, and each branch — success, error, malformed — needs its own fixture so the wrong one cannot satisfy the expectation.

When mock setup outgrows the test logic, or breaks every time the real component changes, switch to an integration test with real components.

## Production classes carry production methods only

Cleanup that only tests need belongs in test utilities, not as a `destroy()` on the production class. If a method is called only from test files, it is test scaffolding living in the wrong place.

## The mutation check

Before you finish, mentally mutate the production code. At least one test should fail for each of:

- a wrong constant or argument
- the wrong branch taken
- a missing state change or side effect
- an empty or default return
- missing validation for zero, empty, null, unauthorized, or malformed input

A mutation nothing catches means that behavior is unprotected, or the test that covers it is tautological.

## Warning signs

- Setup and assertion share an object, guaranteeing equality.
- The test can only fail by crashing, never by asserting.
- It fails on every intentional change and never on an accidental one.
- The expected value is produced by the code under test.
- It greps source text instead of running anything.
- It would still pass if your code were deleted and only the framework remained.
- It exists for coverage and checks no outcome.
- An assertion names a `*-mock` identifier, or fails if you remove the mock.
- A method is called only from test files.
- Mock setup is more than half the test, or you cannot say why the mock is needed.

## Credit

The structure and several of the rules here follow `superpowers:test-driven-development/writing-good-tests.md`, whose test-quality discipline is better than what this catalog previously carried. Restated in this catalog's style, with the mock-level and mutation sections kept close to the original because they were already right.
