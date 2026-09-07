# <TICKET> — IMPLEMENTER (step 1; fresh seat; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. Write only in `<WORKTREE>`
(based at `<BASE_SHA>`) and in your report under `<SCRATCH>`. Spawn ceiling 0.
git: reads only — the controller lands, you do not.

## What you receive

The brief for `<TICKET>` and the brief-review corrections, which are binding
where they touch your files. Where the plan and the corrections disagree, the
corrections win. The project's laws are `docs/llm-orchestrator/LAWS.md`.

## Files you own

<the exact list; nothing else>

## The law of red first

For every mechanism you add, write the test first, run it, and paste the line
that shows it failing on the unfixed tree. Only then write the code. A pin
written after the implementation tends to mirror the implementation, including
where the implementation is wrong — and a pin that passes with its mechanism
removed is worth nothing at all.

Keep the change minimal: no drive-by refactors, no reformatting, nothing the
brief did not ask for. Follow the conventions already in the files you touch.

## Floors before you report

Run the project's verification unpiped, into a log under `<SCRATCH>`, and read
the counts from the log. Name each floor and paste the line it printed:

    <test command> > <SCRATCH>/<TICKET>_impl_runall.log 2>&1; echo EXIT=$?

## Report

`<SCRATCH>/<TICKET>_impl_report.md`, printed as your final message. It opens
with a `Status:` block of at most 20 lines — `Started:` first, the verdict
`DONE | PARTIAL | BLOCKED` and the counts, `Finished:` last — then a `---` line
and the evidence below it: the file list with what changed in each, each floor's
line read from its log, the `shasum -a 256` of every file you created or
changed, and anything `UNVERIFIED`. Write a progress line every 15 minutes.
