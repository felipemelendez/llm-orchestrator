---
name: verification-before-completion
description: Use when about to claim work is done, fixed, passing, or ready to merge — it forces a real run of the verifying command first. Not for reporting a failure honestly, which needs no gate. Runs last, after any review skill.
---

# Verification before completion

A completion claim carries the command that proves it and the line it printed. That is the whole
contract; everything below describes the machinery that checks it and the evidence traps worth
knowing.

**Do not add verification instructions on top of this.** Current models verify their own work
without being told. Anthropic's Opus 5 guidance is explicit that prompts containing *"include a
final verification step"* or *"use a subagent to verify"* cause over-verification, and that
*"the same applies to legacy harness scaffolding that adds separate verification steps."* What
this skill keeps is the **evidence format** — the claim cites the command and its output because
that is what a human reader (and the gate below) needs, not because the model needs reminding to
check.

## How the gate works

A hook records every verify-shaped command the harness actually executed — command, exit code,
and whether the run had substance — in a ledger the model never writes. The gate reads that
ledger for the current turn. Nothing needs to be cited specially: you run the command and paste
what it printed, exactly as you would anyway.

Two things the ledger catches that a `Verify:` line cannot: a claim of success over a run that
actually failed, and a green run that executed zero tests. `exit 0` is not evidence — a filter
matching no tests exits 0. If the run did not cover the change, that is a `Found:`, not a
`Changed:`.

## Finding the project's gates

Use the detection library rather than hand-inventing commands:

```bash
# Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset
# here; marketplace installs nest under the plugin cache).
orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
L=$(orch_lib orch-detect.sh); [ -n "$L" ] && source "$L" || echo "orch-detect.sh not found — reinstall the plugin" >&2
orch_detect_cached "$PWD"
```

Parse the `## Toolchain` section for `test=`, `typecheck=`, and `lint=` lines and run those. If
detection returns nothing, ask the project (`pnpm test <file>`, `cargo test <module>`,
`tsc --noEmit`). Behavior claims may need a curl, a script, or a manual UI step with screenshot.

## What counts as evidence

- A pasted line from the runner with a pass count.
- A non-zero return code is failure, even if the output looks fine.
- "No output" counts *only* when silence is the command's success signal (e.g. `tsc --noEmit`).
- A pass obtained by re-running until green is not evidence — flakes are bugs.

**A regression test is only proved by watching it fail.** "I added a test that captures the bug"
is the most common unverifiable claim on a bugfix. The cycle that proves it:

1. Write the test. Run it — it should pass against the fixed code.
2. Revert the fix (not the test). Run again — it **must** fail, on the assertion.
3. Restore the fix. Run again — green.

Paste the failing output from step 2. A test that has only ever been green may be asserting
something the bug never violated, and it will not catch the regression when it returns.

**A subagent's `DONE` is verified against `git diff`, not against its report.** The report is a
claim about the work; the diff is the work.

## Native relatives

Native `/verify` builds and runs the app — *"without falling back to tests or type checks"* —
and since v2.1.215 Claude cannot invoke it on its own; it is a good manual complement, not a
substrate this flow can call. `/goal` is a session-scoped Stop hook enforcing *"keep going until
X holds"*; this skill enforces the different thing — *"do not claim X without the command and
its output"*. They compose.

## Output shape

```
Changed:
- <file:line> — <what>
Verify:
- pnpm test users.test.ts → 4 passed
```

If verification fails, do NOT report `Changed:`. Report:

```
Found:
- verification failed: <one-line summary>
- pnpm test → 1 failing: <name> at <file:line>
Next:
- Invoke systematic-debugging.
```
