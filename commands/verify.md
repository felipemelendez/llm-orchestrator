---
description: Run the project's verification (tests, lint, typecheck) and report evidence. No assertion without output.
---

You are running `/llm-orchestrator:verify`.

User input: $ARGUMENTS (optional — a specific test file or filter to focus on)

Steps:

1. Invoke `verification-before-completion`.

2. Detect verification commands using the detection library:

   ```bash
   # Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset in
   # command bash; marketplace installs nest under the plugin cache, so fall back
   # to a version-sorted find).
   orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
   L=$(orch_lib orch-detect.sh); [ -n "$L" ] && source "$L" || echo "orch-detect.sh not found — reinstall the plugin" >&2
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
- If all green: /llm-orchestrator:review.
- If failure: /llm-orchestrator:debug.
```

Constraints:
- Never claim "tests pass" without an actual run.
- Paste the line from the output that proves it.
- Don't pipe to `|| true` to mask failures.
- Never run `build=` or deploy commands automatically.
