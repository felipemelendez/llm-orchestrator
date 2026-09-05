# <TICKET> — GATE SEAT (step 5b; fresh seat; a throwaway copy of the fixed tree; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. Work only in `<COPY>`, a
byte copy of `<WORKTREE>` at `<BASE_SHA>` plus the fix. It is a throwaway:
mutate it freely, but restore every mutation and prove the restore by `shasum`.
Spawn ceiling 0. git: reads only.

## Inputs

The union: `<SCRATCH>/<TICKET>_UNION.md`. The fixer's report:
`<SCRATCH>/<TICKET>_FIX_report.md`. The gate script's report from step 5a, run
by the controller: `<GATE_MECH_LOG>` — read it first and never repeat its steps.
The reviewer reports `<TICKET>_REV1_report.md` and `<TICKET>_REV2_report.md`,
for the probes you replay.

## What only you do

1. Replay every reviewer probe from the executed findings on the fixed tree.
   Each now passes, or you report the failing line.
2. For each union item, revert its **hunk** alone — not the whole file — to the
   pre-fix state, run the pin, expect red; restore, prove by `shasum`.
3. The degenerate-pin check: for each pin the fixer named, remove the mechanism
   the pin claims to protect, run the pin, expect red; restore.
4. Novel mutations aimed at the changed hunks, typically three. For each: the
   mutation, and the suite that caught it or the line that did not. The count is
   evidence, never a pass threshold — a mutation-clean tree is not a fault-free
   tree.
5. Anything the script reported as `RUNNER_UNKNOWN`, skipped, or
   `REVERT_STAYS_GREEN`: do that proof by hand and say so.

## Verdict

`PASS` · `PASS-with-fixes` (list each, ranked; mild-only means the controller
folds them at landing) · `FAIL` (any catastrophic or serious finding, each with
its `SCENE:` line).

## Report

`<SCRATCH>/<TICKET>_GATE_report.md`, printed as your final message: `Started:`,
the five sections above, the shasums, a `Status:` block (≤ 15 lines),
`Finished:`, and the literal last line `EXIT=0` on a pass (or a
pass-with-mild-fixes), else `EXIT=1`. The landing check reads that last line.

On a mild-only ticket there is no gate seat, and the file under this same name
is the complete output of the gate script, saved by the controller inside the
landing — every landing has one.
