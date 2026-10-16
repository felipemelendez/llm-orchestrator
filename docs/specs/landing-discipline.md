# Landing discipline: how ticket work lands without endless rounds

Date: 2026-10-13. Status: implemented; revised 2026-10-15 by the owner (the
review loop ends on evidence, not on a count) and 2026-10-16 (the board is a
report; see CHANGELOG 0.18.0).
Research: `docs/llm-orchestrator/research/2026-10-13-long-running-projects-brief.md`.

## Problem

A project run with this plugin opened ten ticket branches at once, each carrying a
copy of an unmerged sibling's code and waiting on it, reviewed each in scoped rounds for four days (370 runs, 319
NOT-READY), spent every READY verdict on new commits or on a wait for a
sibling, and merged nothing until the owner wrote a landing process by hand.
The plugin had no rule that READY means land, no
cross-ticket dependency rule, no whole-branch review at landing, no rule for
when a review loop stops, and treated unreproduced serious findings as
blocking.

## Goals

- A READY verdict (or its equivalents) is landed in the same session; nothing
  else is committed on that head.
- Dispatch reads what a ticket builds on and stacks it on an open dependency
  instead of refusing it.
- Each landing starts with one whole-branch review. Then rounds of one fix
  wave and one scoped re-review continue while each finds new reproduced
  defects or turns a failing check green. A round with neither is a stall:
  every open finding gets a disposition and the branch lands or is split.
  No branch lands over a reproduced defect. After two rounds whose fixes each
  brought new reproduced defects, a read-only `orch-debugger` diagnosis comes
  before any third fix.
- A serious finding the prover could not reproduce lands as a recorded
  follow-up, never as a blocker; reproduced, catastrophic and unranked findings
  block as before.
- A branch builds on main or on the open branch it depends on (revised
  2026-10-16); main is merged into the agent's own open branches, bottom up,
  at every landing.
- The session opens with the landing board: unmerged branches and their age.

## Non-goals

- No change to the four verdicts, the reviewers, the prover or the refuter.
- No new agent, no new command, no daemon. The board is printed where
  dispatch already reads the plan, and by the session-start hook.
- No change to locked project files; existing projects adopt the rulebook line
  by their own ruling.

## Approach

**One reference, cited everywhere.** The rules live in
`skills/finishing-a-branch/references/landing-rules.md`. The flow skills
(`executing-plans`, `dispatching-parallel-agents`, `dispatching-subagents`,
`requesting-code-review`, `receiving-code-review`, `finishing-a-branch`,
`cadence` and its Full path, `brainstorming`, `writing-plans`,
`using-orchestrator`) and the commands `dispatch` and `finish` each state the
rule they enforce in one or two lines and point at the file. The rulebook
template (`skills/cadence/references/laws.md` and its example) carries a
Branches line so new projects start with the rule. The marked global block
is unchanged: it already routes to the cadence skill, which carries the rule,
and changing it would ask every locked project for a ruling about text it
does not need.

**Reproduce to block (R23).** `orch-review.py record` accepts a fifth
disposition, `follow-up`, with a `reference`: the follow-up PR, issue, or plan
task that will carry the finding. It is accepted only for a finding that was
not reproduced, whose prover rank and final rank are both at most `serious`,
whose status is `unverified`, or on the Full path `promoted` or `unresolved`
after the refuter (the refuter judges the words; reproduction is the
experiment), and only when the claimed failure did not show: the prover gave
no repro (a floor raised the rank), or the repro ran on the unpatched copy and
passed. A repro that failed on the unpatched copy showed the bug and is
refused; a repro that never ran (sandbox or runner failure) proved nothing and
is refused too. The R21/R22 guard applies (reproduced, catastrophic or
unranked findings are never follow-ups). A NOT-READY review whose every
blocking finding is recorded `refuted`, `settled` or `follow-up` lands like
READY-WITH-FIXES. The outcome log records the disposition like the others.

**Dispatch.** Before dispatching a ticket, the controller runs the
board script, which lists what is open. The script counts unmerged local
branches against the base, prefers the remote's view of the base when one
exists, skips the `orch/` task branches the materialize engine creates, and
measures a branch's age from its first commit off the base, not its tip.
A plan may carry
`Requires landed:` naming the branch or PR the ticket builds on; landing
rule 4's test says whether it is landed (an ancestor of main, or its PR
merged). If it is
still open, the ticket's branch stacks on it and its PR targets it; the
repository's delete-branch-on-merge setting removes the merged base so GitHub
points the stacked PR at main (revised 2026-10-16). Main is merged into the agent's own open branches, bottom up,
never into branches other agents own.

**Landing board.** One script, `scripts/orch-landing-board.sh`, prints the
count of unmerged branches against the base, the oldest branch's age, and the
names.
`/llm-orchestrator:dispatch` prints it before cutting a ticket branch, and the
session-start hook prints the same line in front of the body, with the
cadence verdict, so truncation cannot drop it. Read-only git, no network,
best effort; off with `ORCH_DISABLED_HOOKS=orch-landing-board`.

**The review loop (revised 2026-10-15).** The first version capped the loop
at three review runs: one review, one fix wave, one re-review, then land or
split. The owner ruled the count wrong: on this project's own release 0.16.0
the re-review found 13 new reproduced findings, three of them catastrophic,
and the count would have shipped them. The loop now ends on evidence. A round
that finds and fixes reproduced defects continues; a round with no new
reproduced finding and no new green check stalls and is adjudicated; two
rounds in a row whose fixes break something new send the branch to a
read-only diagnosis before any third fix. What the count got right stays: a
worry nobody reproduced never extends the loop, and the same review is never
rerun hoping for a different answer.

**Small fixes (revised 2026-10-15).** The owner ruled that the loop still had
a gap: it sent every fix, however small, through a full re-review (two
reviewers, prover, refuter), which made a landing loop feel endless. A small
fix gets a Standard re-review, not a Full one. A fix is small when all three
hold: every finding it answers has a regression test that failed before the
fix and passes after it; it touches only the lines the findings name and
their tests, with no new function, option, field or file and no behaviour
beyond the finding; and its production diff (shipped files, tests excluded)
is under twenty lines. It gets one scoped Standard review of its diff
(`orch-review.py run --path standard --base <the head the previous review
saw>`: one independent built-in reviewer, no refuter), and the
controller also reads the whole diff and runs each regression test without
the fix to see it fail. A finding that review raises is handled like any
other. A fix for a catastrophic finding, or any fix in a diff the security
lens applies to (authentication, secrets, tokens, payments), always gets the
Full re-review. The controller records each finding `fixed` with its test and
writes one line in the outcome record that the fix was reviewed under the
small-fix clause. A small fix is never exempt from independent review; it gets
the proportionate one.

**Alternatives considered.** A new `landing` skill (rejected: the finish skill
already does the landing; a second entry point is one more thing to route to).
Reporting the board from the worktree materialize engine (rejected: that
engine makes task worktrees for one plan, which the integration engine lands
minutes later; the board is about ticket branches). A fifth verdict for unreproduced
findings (rejected: a disposition reuses the landing path R22 already built).

## Constraints

- Skill bodies stay under 250 lines; `tests/validate-skills.sh` passes.
- The global block stays identical in `templates/cadence-global-block.md` and
  `skills/cadence/references/global-block.md`.
- The session-start hook stays inside its latency budget (`tests/test-hook-latency.sh`).
- Bash 3.2; no new dependencies.

## Research

- Verdict: VERIFIED against vendor documentation and prior art read on
  2026-10-13 (the research brief above).
- Notable: Symphony (OpenAI, 2026-04) caps concurrent agents and turns and has
  explicit `Merging` and `Human Review` states; Claude Code Projects has a
  `Landing` state and notes that a number stated in a prompt is not enforced;
  superpowers caps fix rounds at five and then adjudicates; DORA measures
  few active branches; Anthropic's best practices say a reviewer
  asked for gaps will report some even when the work is sound.

## Settled

- **Landing keeps the branch count small.** DORA measures few, short-lived
  active branches in teams that deliver well; a READY-lands-now rule and
  small pull requests produce that without counting.
- **Unreproduced serious findings do not block landing.** The prover's
  experiment is the test; a worry without a failing command is a follow-up.
  Catastrophic and unranked findings still reach the person.
- **The review loop is bounded by progress, not by a count.** A round that
  finds and fixes reproduced defects continues; a round with no new reproduced
  finding stalls and is adjudicated; a landing never happens over a reproduced
  defect.
- **A small fix gets a Standard re-review, not a Full one.** Under twenty
  production lines, only the findings' lines and their tests, no new
  behaviour, each finding with a regression test: one scoped Standard review
  of the fix diff (one independent built-in reviewer, no refuter),
  and the controller reads the whole diff and sees the test fail without the
  fix. Catastrophic and security-lens fixes always get the Full re-review.
- **The rules live in one reference file, not in a new skill.** The finish
  skill is the landing step; the rules describe when it runs.

## Open questions

- none
