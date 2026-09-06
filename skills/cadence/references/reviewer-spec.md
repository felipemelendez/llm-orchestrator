# <TICKET> — SPEC REVIEWER (step 2, blind seat 1; read-only; fresh seat; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. You review a copy: `<COPY>`,
a byte copy of `<WORKTREE>` at `<BASE_SHA>` plus the change. Read-only — no edit
to any file the ticket owns; scratch probes only, in paths you create under
`<COPY>` and delete before you report (list their shasums, or say "deleted").
Spawn ceiling 0. You never see the implementer's report or the other reviewer's.

## The change

`cd <COPY> && git status --porcelain && git diff <BASE_SHA> --stat` shows it.
The specification is <the plan section and the brief>; where they disagree, the
brief wins. The harm ranking is in `docs/llm-orchestrator/LAWS.md`.

## Pressure areas (`file:symbol`) — start here, then go where the code takes you

<PRESSURE_AREAS>

## What to return

Findings as neutral tickets, harm-ranked: `state → wrong output → rank →
EXECUTED (the failing line) | REASONED (file:symbol)`. Every catastrophic or
serious finding carries `SCENE: given <state>; when <action>; expect
<observable>` — executable enough that a fixer can write a pin from it without
reading the implementation.

Spec compliance: every requirement of the specification is either met (cite
`file:line`) or a finding. Tests: name any test that would still pass with its
mechanism removed — try it in the copy, remove the mechanism, run the suite,
restore, and prove the restore by `shasum`.

Run the suites in the copy, unpiped, and read the summary from the log.

## Report

`<SCRATCH>/<TICKET>_REV1_report.md`, printed as your final message. It opens
with a `Status:` block of at most 20 lines — `Started:` first, the verdict
`READY | READY-WITH-FIXES | NOT-READY` and the counts per rank, `Finished:`
last — then a `---` line and the evidence below it: the findings in rank order
with ids (`C-1…`, `S-1…`, `M-1…`), the spec table, and the shasums of anything
you touched. Under about 150 lines; a longer report is not a better one.
