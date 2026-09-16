# `CADENCE_STATE.md` — the stage skips

<!--
Template for `<notes_dir>/CADENCE_STATE.md`. It holds one thing: which cadence
stages the orchestrator has skipped under the amendment mechanism, and until
when. It is not locked and it is not a ruling — a skip is a downward move the
orchestrator may make on cited evidence, and it expires on its own.
-->

Append-only, dated, newest last. One entry per physical line, never wrapped, on
one of three shapes:

    skip: <stage> · class <CODE|PROSE> · rows <ticket>, <ticket>, <ticket> · expires after <ticket> · <date>
    re-armed: <stage> · class <CODE|PROSE> · by <ticket> <finding id> · <date>
    expired: <stage> · class <CODE|PROSE> · <date>

`<stage>` is the stage the orchestrator stopped running; under the shared
default only the gate seat on `CODE` is retirable. `rows` are the three landed
`CODE` ledger rows with no catastrophic or serious gate-seat finding that
qualified the skip. `expires after <ticket>` is the fifth landed ticket after
the one that wrote it, after which the
stage runs again until three fresh rows qualify it; the orchestrator appends the
`expired:` line when that ticket lands.

A `re-armed:` line ends a skip early and permanently. Any catastrophic finding,
by any seat, on any later ticket of any class re-arms every live skip; the
controller appends the line at that ticket's union, before step 4, and only the
owner's ruling lifts it.

Agreement skipping the refuter needs no retirement entry. Historical refuter
skips do not qualify under the shared default and cannot bypass disagreement or
a one-sided catastrophic or serious finding. The controller preserves their
history and marks them expired at brief review; explicit project amendments
take precedence.

The file is read at step 0 — the brief-review seat reports which skips are live
and whether each still qualifies. The check script's `--verdict` appends
` · skips: <n>` while a state file exists, where `<n>` counts the `skip:` lines not
cancelled by a later `re-armed:` or `expired:` line naming the same stage and
the same class.

Nothing else belongs here. The pair, never self-verify, the harm ranking, the
stop rule, the lock's shape, every threshold and the refuter trigger change only
by a numbered ruling in `LAWS.md`, under the unlock.

## Example

    skip: gate seat · class CODE · rows <ticket>, <ticket>, <ticket> · expires after <ticket> · <date>
    re-armed: gate seat · class CODE · by <ticket> <finding id> · <date>
    expired: gate seat · class CODE · <date>
