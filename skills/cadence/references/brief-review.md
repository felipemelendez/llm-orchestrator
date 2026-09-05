# <TICKET> — BRIEF REVIEW (step 0; read-only; fresh seat; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. Read-only: you write nothing
outside `<SCRATCH>`. Spawn ceiling 0.

## What you receive

The brief for `<TICKET>`, the plan section it implements, and the tree at
`<BASE_SHA>` (read `<WORKTREE>` or the main checkout — read anything, write
nothing). The project's laws are `docs/llm-orchestrator/LAWS.md`; the harm
ranking there is what you rank findings by.

## What you return

**A. Claim verification.** Every `file:line`, symbol, command and mechanism the
brief asserts, checked against the tree: `CONFIRMED` with the real location, or
`WRONG` with what is actually there and the correction. A brief that names a
line which moved sends the implementer to the wrong place, and the implementer
will not notice.

**B. The headline scenes.** Walk the change through the brief as written: does
it fire, does it fire once, and what does the person on the other end see? Each
scene gets a verdict — `SOUND`, `SILENT` (the brief does not say) or
`CONTRADICTORY` (the brief says two things) — and the fix.

**C. Tier.** `FULL` unless `LOCAL` is argued file by file in your report.
`LOCAL` is available only when every file the brief will touch is a test, a doc,
a fixture, a dev-only screen, a generated file, or a leaf that imports nothing
from the hub list the laws name. Anything under a hub directory, or whose name
carries one of the project's risk words, is `FULL`. The default is `FULL`.

**D. Split.** Split into sequential tickets with disjoint file sets when the
brief touches more than about fifteen production files, or two hub files, or two
runtimes. Propose the cut; the controller writes the briefs.

Rank every correction by the project's harm ranking. Mark anything you could not
reach `UNVERIFIED`.

## Report

`<SCRATCH>/<TICKET>_BRIEFREV_report.md`, printed as your final message. Open
with `Started: <YYYY-MM-DD HH:MM:SS>`, close with `Finished: <…>`, and write a
progress line every 15 minutes. Sections A–D, then a `Status:` block (≤ 40
lines) ending in the verdict `BRIEF: READY | READY-WITH-CORRECTIONS | NOT-READY`.
Keep it under about 250 lines; a longer report is not a better one.
