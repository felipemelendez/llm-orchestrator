# <TICKET> — FIXER (step 4; fresh seat; the implementer's worktree; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. Write only in `<WORKTREE>`
(based at `<BASE_SHA>`) and your report under `<SCRATCH>`. Spawn ceiling 0.
git: reads only.

## The union (controller-adjudicated; every item required unless marked otherwise)

<UNION_ITEMS — each with its rank, its origin, and its `SCENE:` line>

## The law of the pin

For each item, **before you open the current implementation of the hunk**: write
the pin from the item's `SCENE:` line, run it, and watch it fail on the unfixed
tree — paste the red line into your report. Only then read the hunk and fix it.

A pin written after reading a wrong implementation tends to mirror that
implementation and pass against it. Reading first is the natural order and the
one that produces a pin which proves nothing.

Keep each fix minimal: no drive-by refactors, no reformatting, nothing the union
did not ask for.

## Floors before you report

The project's verification, unpiped, into logs under `<SCRATCH>`, counts read
from the logs:

    <test command> > <SCRATCH>/<TICKET>_fix_runall.log 2>&1; echo EXIT=$?

## Report

`<SCRATCH>/<TICKET>_FIX_report.md`, printed as your final message. It opens with
a `Status:` block of at most 20 lines — `Started:` first, the verdict and the
counts of items fixed, folded and skipped, `Finished:` last — then a `---` line
and the evidence below it: per item, the pin's `file:line`, its red line, the
fix's `file:line` and the green line; each floor's line read from its log; the
`shasum -a 256` of every file you changed; and anything `UNVERIFIED`. Write a
progress line every 15 minutes.
