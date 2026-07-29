---
name: verification-before-completion
description: You MUST use this before claiming any work is done, fixed, passing, or ready to merge. Forces a real run of the verifying command first.
---

# Verification before completion

Claims of success cost nothing. Evidence costs a single command. Always pay it.

## When to use

- About to say "done", "fixed", "passing", "ready to merge".
- About to mark a task `DONE` in a `Status:` block.
- About to close a `Plan:` checkbox.

## Delegation

Two things this skill does **not** delegate, and one it must not do.

Native `/verify` builds and runs the app — *"without falling back to tests or type checks"* — and since v2.1.215 Claude cannot invoke it on its own. It is a good manual complement, not a substrate this flow can call.

`/goal` is the closer relative: a session-scoped prompt-based Stop hook whose evaluator re-checks a completion condition after every turn. It enforces *"keep going until X holds"*. This skill enforces the different thing — *"do not claim X without pasting the command and its output"*. Use both; they compose.

**Do not instruct the model to verify.** Current models already do. Anthropic's Opus 5 guidance is explicit that prompts containing *"include a final verification step"* or *"use a subagent to verify"* cause over-verification, and that *"the same applies to legacy harness scaffolding that adds separate verification steps."* What survives is the **evidence format** below — a completion claim carries the command and its output, because that is what a human reader needs, not because the model needs reminding.

## The gate

Before claiming, run through these in order:

1. **Identify** — what command proves this is done?
   - Use the detection library to find the project's real gates:
     ```bash
     # Locate the lib across install layouts (CLAUDE_PLUGIN_ROOT is often unset
     # here; marketplace installs nest under the plugin cache).
     orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
     L=$(orch_lib orch-detect.sh); [ -n "$L" ] && source "$L" || echo "orch-detect.sh not found — reinstall the plugin" >&2
     orch_detect_cached "$PWD"
     ```
     Parse the `## Toolchain` section for `test=`, `typecheck=`, and `lint=` lines.
     Use those values as the commands to run — do not hand-invent commands.
   - If detection returns nothing, fall back to asking: `pnpm test <file>`, `cargo test <module>`, `tsc --noEmit`.
   - Behavior checks: a curl, a script, a manual UI step with screenshot.
2. **Run** — execute it now. Not "I would run it"; run it.
3. **Read** — read the output. Don't skim.
4. **Verify** — does the output match the success criterion? Number of passing tests, absence of error lines, expected response.
5. **Claim** — only now is the success claim allowed, and it cites the evidence.

## What counts as evidence

- A pasted line from the test runner with a pass count.
- A non-zero return code is failure, even if the output looks fine.
- "No output" is fine *only* if the command's success signal is silence (e.g., `tsc --noEmit`).
- A `git diff --quiet && echo clean` is fine for "no uncommitted changes".

**The evidence stamp.** When the evidence-ledger hook is active, verify-shaped commands (test/lint/typecheck/build) print a final `[orch-evidence <stamp> exit=N]` line. Copy that line into the `Verify:` block verbatim. The stamp is minted by a hook and recorded in a ledger the model never writes, so the gate can check a claim against recorded reality instead of trusting the text: a made-up stamp fails lookup, and a stamp from a failing run carries its non-zero exit with it. Evidence without a stamp is still accepted (custom scripts fall outside the stamp regex) — but a stamped command's stamp is not optional.

## What does NOT count

- "I think this should pass." — run it.
- "The change is small, it can't break anything." — run it.
- "Tests were passing earlier." — run it now.
- "I'll verify in a follow-up." — verify before claiming.

## Output shape

After running the command:

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

## Common failures

- Reading the wrong line of output (count of tests run vs. passed).
- Claiming `Changed:` when the test still fails on an edge case.
- Mistaking "lint warnings" for "lint passed".
- Skipping verification because the change is "obvious".

## Anti-patterns

- "Tests pass" without pasting the line.
- Verifying a different scenario than the one that broke.
- Re-running tests until they happen to pass (flakes are bugs).
- Pasting the command but not the output.
