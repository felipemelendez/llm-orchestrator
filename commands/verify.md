---
description: Run the project's verification (tests, lint, typecheck) and report evidence. No assertion without output.
---

You are running `/verify`.

User input: $ARGUMENTS (optional — a specific test file or filter to focus on)

Steps:

1. Invoke `verification-before-completion`.

2. Detect verification commands using the detection library:

   ```bash
   source scripts/lib/orch-detect.sh
   orch_detect_cached "$PWD"
   ```

   Parse the `## Toolchain` section of the output for `test=`, `typecheck=`, and `lint=` lines.
   Extract each value as the command to run (e.g. `test=npm run test` → run `npm run test`).
   Do NOT run any `build=` command unless the user explicitly requests it.
   If detection returns no `test=`/`typecheck=`/`lint=` lines, ask the user what command to run.

3. Run detected commands in order: typecheck → lint → test. Stop on first failure.

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
- Never run `build=` or deploy commands automatically.
