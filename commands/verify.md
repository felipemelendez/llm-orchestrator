---
description: Run the project's verification (tests, lint, typecheck) and report evidence. No assertion without output.
---

You are running `/verify`.

User input: $ARGUMENTS (optional — a specific test file or filter to focus on)

Steps:

1. Invoke `verification-before-completion`.

2. Detect verification commands:
   - `package.json` scripts: `test`, `typecheck`, `lint` (or `tsc`, `eslint`)
   - `Cargo.toml` → `cargo test`, `cargo clippy`
   - `pyproject.toml` → `pytest`, `ruff check`, `mypy`
   - `go.mod` → `go test ./...`, `go vet ./...`
   - `Makefile` → `make test`
   - If none detected, ask the user.

3. Run them in order: typecheck → lint → test. Stop on first failure.

4. If `$ARGUMENTS` is non-empty, scope test runs to that filter.

5. Capture the last meaningful line of each command (pass/fail count, error summary).

6. Report:

```
Verify:
- typecheck: <last line>
- lint: <last line>
- test: <pass/fail count>
Next:
- If all green: /review.
- If failure: /debug.
```

Constraints:
- Never claim "tests pass" without an actual run.
- Paste the line from the output that proves it.
- Don't pipe to `|| true` to mask failures.
