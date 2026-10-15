# Landing rules

How ticket work is cut, reviewed and landed on a long project, so that a review
loop ends in a merge or a split once it stops finding real defects. Every flow skill points here; the rules
are stated once. A project's laws may set other numbers; the defaults below
apply where they say nothing.

Learned on a project that opened ten ticket branches at once, cut from an
unmerged sibling, reviewed each in scoped rounds for four days (370 review runs,
319 NOT-READY), spent every READY verdict on new commits or on a wait for a
sibling, and merged nothing until the owner wrote these rules by hand. Once
applied, four branches landed in nine hours.

## The rules

1. **At most two unmerged implementation branches at a time.** A third ticket
   waits for a landing. Research, planning and read-only work may run in
   parallel; implementation may not exceed the limit. The count is
   `scripts/orch-landing-board.sh` (`--check` exits 3 when there is no room
   for one more): unmerged local branches against the base, skipping the
   `orch/` task branches the materialize engine makes, since parallel *tasks of
   one ticket*, landed together by the integration engine in the same session,
   are one branch for this count. A stale branch that is not ticket work counts
   until it is deleted; the board names it so it can be. The limit is two
   unless the project's `cadence.json` sets `wip_limit` (by ruling) or the
   person sets `ORCH_WIP_LIMIT`.

2. **A READY verdict is a landing event.** READY, READY-WITH-FIXES with its mild
   findings handled, or NOT-READY with every blocking finding recorded
   `refuted`, `settled` or `follow-up`: land it now, in this session, through
   `finishing-a-branch` option 1. When merging is not authorized, opening the
   PR now is the half of the landing the agent always owns; it then stops and
   reports the URL. The verdict is bound to the head it reviewed: after it,
   the only commits allowed are the mild-finding fixes and a conflict-free
   merge of the base with green checks; anything else is new work, which goes
   to a follow-up PR cut from main after the landing, and a READY head is never
   reviewed again unless a fix changed behaviour.

3. **No "merge after X" chains.** A branch never waits for a sibling. If it
   cannot land before a sibling, it was cut wrong (rule 4): land the sibling it
   depends on first, then merge main into this branch, run the checks, and land.

4. **Every branch is cut from main; a hub change lands first.** A ticket that
   changes a shared hub file (the project's laws name them) lands before its
   dependents are dispatched; dependents are cut from main after it lands.
   A plan's `Requires landed:` line names what must be on main before the
   ticket is cut; `git merge-base --is-ancestor <sha> <base>` decides. A branch
   never carries a copy of another ticket's code.

5. **Main is merged into every open branch at every landing.** After each PR
   merges and the base checks are green, merge the base into each still-open
   branch and run its checks, so no branch is ever more than one landing
   behind. Conflicts are resolved then, while they are small.

6. **The review loop ends on evidence, not on a count.** Each landing starts
   with one whole-branch review against the merge base with main
   (`--base <base>`), after main has been merged in, never on a scoped diff of
   the last fix. Then rounds: in each, one implementer fixes every open finding
   (one fix wave with the whole list, never one fixer per finding), and one
   scoped re-review checks the fix diff (`--base` at the head the previous
   review saw).
   - A round made progress when its review found at least one new reproduced
     finding, or a blocking finding was fixed and its failing check now
     passes. Rounds continue while they make progress.
   - A round with no new reproduced finding and no new green check is a
     stall. Stop there and adjudicate: one written disposition per open
     finding (`fixed`, `refuted`, `settled`, `follow-up`, or `ignored` by the
     person), then land or split. Never run the same review again hoping for
     a different answer.
   - A small fix gets a Standard re-review, not a Full one. A fix is small
     when all three hold: (1) every finding it answers has a regression test
     that failed before the fix and passes after it; (2) it touches only the
     lines the findings name and their tests: no new function, option, field
     or file, and no behaviour beyond the finding; (3) the production diff
     (shipped files, tests excluded) is under twenty lines. It gets one
     scoped Standard review of its diff (`orch-review.py run --path standard
     --base <the head the previous review saw>`: one independent built-in
     reviewer, no prover or refuter), and the controller also reads the
     whole diff and runs each regression test without the fix to see it
     fail. A finding that review raises is handled like any other finding.
     A fix for a catastrophic finding, or any fix in a diff the security
     lens applies to (authentication, secrets, tokens, payments), always gets
     the Full re-review. The controller records each finding `fixed` with its
     test and writes one line in the outcome record that the fix was
     reviewed under the small-fix clause.
   - A reproduced finding is always fixed, never deferred. A branch never
     lands over a known reproduced defect, whatever the round.
   - After two rounds in a row whose re-review found new reproduced defects
     in the fix itself, stop patching: the fixes are the problem. One
     read-only diagnosis owner (`orch-debugger`, which never edits) finds why
     before any third fix wave, and the history goes to the person. Repairs
     and tests stay with one assigned implementer. The debugger's limit of
     three hypotheses is a separate rule.
   - A finding the re-review raises on untouched code is recorded, not fixed
     in another round, unless it is reproduced and blocking; then it is fixed
     like any other.
   - Reviews of single tasks during the build (`dispatching-subagents`) are
     for tasks the plan marks sensitive; a routine task relies on the landing
     review.

7. **Reproduce to block.** A serious finding whose repro passed on the
   unpatched copy, or that had none, is recorded `follow-up` with the
   reference of the PR, issue or plan task that will carry it, and the branch
   lands. A repro that failed showed the bug: it is fixed. Catastrophic and
   unranked findings reach the person. Mild findings are fixed in the next fix
   wave or recorded with a reason. A `BLOCKED` with one specific question is a
   good outcome at any step; a READY or PASS that is not true is the worst.

8. **A branch lands within one working day of its first green test, or it is
   split.** Land what is green; the rest becomes a follow-up PR with its own
   plan tasks. The landing board's age column is the trigger.

9. **The board is read first.** At session start, before dispatching anything,
   land what is READY and merge main into what is open. A session that ends
   with "nothing merged" while a READY branch existed broke rule 2.

## What this changes for the controller

- Before `/llm-orchestrator:dispatch`: count unmerged branches (rule 1), check
  `Requires landed:` (rule 4). Over the limit or missing a dependency: land
  first, do not dispatch.
- After `/llm-orchestrator:review` returns a landing verdict (rule 2): go
  straight to `/llm-orchestrator:finish`; never commit more work first.
- After each landing: merge the base into every open branch (rule 5), then
  take the next item from the board.
- At a stall (rule 6): record a disposition for every open finding
  (`fixed`, `refuted`, `settled`, `follow-up`, or `ignored` by the person),
  then land or split. A reproduced finding is fixed, never given a disposition
  that lets the branch land over it.
- Before re-reviewing a fix (rule 6): check the small-fix clause. If its
  three conditions hold and no finding is catastrophic or security-lens, run
  one scoped Standard review of the fix diff instead of a Full round, read
  the whole diff, run each regression test without the fix to see it fail,
  record each finding `fixed` with its test, and write the small-fix line in
  the outcome record.
- After two rounds whose fixes each brought new reproduced defects (rule 6):
  dispatch `orch-debugger` for a diagnosis before any third fix wave.

## Why these numbers

Two branches: DORA's measured threshold is three or fewer active branches; the
project that failed chose two for one orchestrator; agent-team guidance puts
three to five workers on *tasks*, not branches; the orchestrators that publish
a cap default to one to three concurrent units. The review loop: the research
says a round with no new outside evidence corrects nothing (that is the stall
rule) and a reviewer asked again will find something again (that is why only
reproduced findings extend the loop). Release 0.15.0 used a count, three review
runs at most, as a stand-in for that evidence. The count was the wrong proxy:
this project's own release 0.16.0 hit a re-review with 13 new reproduced
findings, three of them catastrophic, that the count would have shipped. The
first project's lesson still holds: its 319 NOT-READY verdicts came from
reruns on worries nobody reproduced, which the stall rule and rule 7 end. One working day:
trunk-based development's "a couple of days" halved for an agent that works around the clock, and the
measured 80% reliability horizon of today's models is about an hour of expert
work, so a ticket is sized to that and a day is generous.

Sources, with citations: `docs/llm-orchestrator/research/2026-10-13-long-running-projects-brief.md`.
