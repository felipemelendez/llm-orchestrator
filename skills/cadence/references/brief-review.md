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

**C. Class.** `CODE` unless `PROSE` is argued file by file in your report.
`PROSE` means nothing the ticket touches is executed, or read by any program to
decide behaviour — no script, hook, config, rule file, JSON, workflow or template
a program consumes, whatever runs it — only prose a person reads: skill bodies,
references, docs, markdown templates. A git hook, a settings file and any JSON a
program reads are `CODE`; one such file in the set makes the ticket `CODE`. Name
every file and say which it is. The default is `CODE`; the burden is on the
argument for `PROSE`.

**D. Split.** Split into sequential tickets with disjoint file sets when the
brief touches more than about fifteen production files, or two files the
project's laws name as hubs, or two runtimes. Propose the cut; the controller
writes the briefs.

**E. Active skips.** Read `<notes_dir>/CADENCE_STATE.md` and report every skip
that is live: the stage, the class it applies to, the three rows it cites, its
expiry, and whether it still qualifies under the amendment mechanism. When no
state file exists the answer is `active skips: none`.

Rank every correction by the project's harm ranking. Mark anything you could not
reach `UNVERIFIED`.

## Report

`<SCRATCH>/<TICKET>_BRIEFREV_report.md`, printed as your final message. It opens
with a `Status:` block of at most 20 lines — `Started: <YYYY-MM-DD HH:MM:SS>`
first, the verdict `BRIEF: READY | READY-WITH-CORRECTIONS | NOT-READY`, the
class, the split, the skips, `Finished: <…>` last — then a `---` line with
sections A–E below it. Write a progress line every 15 minutes. Keep it under
about 250 lines; a longer report is not a better one.
