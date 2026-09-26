# Measurements

Every skill, rule, and hook in this repo is a bet that some text or mechanism
improves agent behaviour. This file is the ledger of the bets that have been
**measured** — with real A/B runs against durable on-disk outcomes, not by
reading the prose and nodding. Method: `tests/evals/README.md`. Raw evidence
for every entry: `tests/evals/results/archive/`.

Conventions: n = paid model sessions per arm; "behavioural pass" = the graded
on-disk outcome for that case (e.g. bug fixed AND a covering test exists,
under an explicit instruction to skip tests); p = two-tailed Fisher exact.
All runs below: Opus, case `tdd-under-pressure` unless noted. The instrument's
noise floor at n=100 is ~12–13 points — differences under that are reported
as bounds, not findings.

## Ledger

### 2026-08-03 — The 22% compression regressed behaviour
`archive/2026-08-03-tdd-under-pressure-REGRESSION-FOUND.json`
Cutting the instructional layer 22% (per current cut-the-prose guidance)
dropped behavioural pass 76/100 → 56/100. Pooled with the 08-04 re-run:
144/200 vs 56/100, p=0.0065. **Acted on:** full revert (786d37d).

### 2026-08-04 — The suspected file was innocent
`archive/2026-08-04-tdd-restore-DID-NOT-RECOVER.json`
Restoring the test-driven-development skill body moved the number by exactly
zero (56/100 before and after). Mechanism found by mining session transcripts:
post-cut runs invoked skills **0/205** vs ~23% pre-cut, and invoked runs
passed 76/77 — the cut had deleted the always-loaded *invocation mandate*,
not any load-bearing body. Cost of the null result: ~$70; the transcript
mining that explained it: free. Method and full table:
`archive/2026-08-04-transcript-mining-INVOCATION-MECHANISM.md`.

### 2026-08-04 — The invocation nudge backfired (negative result)
`archive/2026-08-04-skill-nudge-AB-NEGATIVE-RESULT.json`
A deterministic hook nudging bug-shaped prompts toward the debugging/TDD
skills — predicted to lift pass toward 90% — measured **worse**: 70/100 vs
85/100, p=0.017. Where the user's instruction was blunt, naming the skills
next to it made the model comply with the instruction deliberately (8% vs 56%
on that variant), and the inline mention halved formal skill invocation.
Lesson: invocation is a **marker** of good runs, not a lever; making a
conflict salient resolves it in the instruction's favour. **Acted on:** hook
removed (e1829fb); any future trigger design must beat this archived baseline.

### 2026-08-05 — The compression is safe with the mandate kept (bounded)
`archive/2026-08-05-compression-mandate-kept-CONFIRMED.json`
The 22%-cut tree with only the three always-loaded mandate surfaces restored:
78/100 vs uncut 84/100, p=0.368; skill invocation fully recovered (44% vs
43%). Bound: a true gap ≥ ~13 points would have shown; observed direction
−6. **Acted on:** compression re-applied to main minus the mandate surfaces
(01e1671). Resolves the 08-03 tension: the bodies were padding; one paragraph
was load-bearing.

### 2026-08-05 — Warn vs block: unanswerable at this ceiling (inconclusive)
`archive/2026-08-05-warn-vs-block-CEILING-INCONCLUSIVE.json`
Should the verify gate BLOCK an unproven "done" claim instead of warning?
Both arms scored 100/100 — in 200 runs the dishonest claim never occurred
(the agent verified, or disclosed honestly), so the instrument cannot see the
gate at all. **Acted on:** warn stays the default — blocking's benefit is
unmeasurable here while its false-positive cost is documented from live
operation. The case pair needs pressure that actually induces false claims
before this question can be re-asked. An honest inconclusive, logged as such.

### 2026-09-25/26 — The Full review found no more than /code-review or codex review
`tests/evals/review-compare/` (method: `tests/evals/README.md`, "The review
comparison"). Raw results stay in the run's ignored `review-compare/work/`
folder, not in Git.
83 cases (69 with planted defects, 14 clean), 134 planted defects, one try per
case, three arms: `full` (this plugin's `orch-review.py`, Claude seat and
refuter on claude-opus-5-5, Codex seat on gpt-6-astra), `code-review`
(`/code-review high` on claude-opus-5-5) and `codex-review` (`codex review` on
gpt-6-astra). 5 of 83 `full` runs ended INCOMPLETE and are left out of its
numbers: in four the contract seat listed something it had not checked
(multi-line CSV cells twice, a large Decimal amount, a case-sensitive file
system), and in one the contract seat dropped out because its sandbox check did
not show a refused write outside the copy.

**The `code-review` arm never received its spec sentence.** It was passed with
`--append-system-prompt`, and a live check on 2026-09-26 showed that text does
not reach the subagent `/code-review` reviews in (a required marker line and the
spec path were ignored; the same text in the `-p` prompt was obeyed). So the
`code-review` row below is `/code-review` without the spec, while `full` and
`codex-review` had it. The arm now carries the sentence in its `-p` text and is
to be re-run.

Scored with the corrected scorer. The first scoring read each `/code-review`
reply as one finding, because that reply puts its findings in a JSON array in a
fenced block and the scorer split only on list items and headings: it saw 84
findings where there were 700, and gave `code-review` 48/134. The scorer now
reads one finding per array item.

| arm | found | serious | mild | tampering | false | false/run | clean runs with no finding | minutes per case |
|---|---|---|---|---|---|---|---|---|
| `code-review` | 125/134 (93%) | 59/63 | 66/71 | 14/14 | 481 | 5.8 | 0/14 | 0.6 |
| `codex-review` | 130/134 (97%) | 61/63 | 69/71 | 14/14 | 107 | 1.3 | 3/14 | 1.1 |
| `full` (78 complete) | 123/126 (98%) | 59/61 | 64/65 | 14/14 | 258 | 3.3 | 0/13 | 3.3 |

Paired on the defects both arms saw (exact McNemar): `full` against
`code-review`, 6 found only by `full` and 1 only by `code-review`, p = 0.125;
`full` against `codex-review`, 1 and 1, p = 1.0; `codex-review` against
`code-review`, 7 and 2, p = 0.18. None is a difference.

The "false" column overstates noise. A finding is false when it points at no
planted defect, and the clean cases turned out to hold real bugs the set did
not plant. An audit read 80 sampled false findings (40 `full`, 25
`codex-review`, 15 `code-review`): almost all were true, either real bugs or
spec gaps the set did not plant, or minor notes that the tests do not cover
something. None of the 80 was wrong.

**Conclusion.** `full` did not detect more than `/code-review` or `codex
review`, and took three to five and a half times as long. What it adds is a
run: on its 78 complete runs, 477 of the 538 findings it reported (89%, every
finding except notes and dropped ones) were reproduced by a failing command
and a patch, and it blocks. It returned NOT-READY on all 78 complete runs, including
all 13 complete clean cases, partly because it ranked notes that the tests do
not cover something as serious. **Acted on:** such a note is now a `test-gap`
finding, mild unless it carries a failing command; test tampering stays serious.
Then, in T22 (`docs/specs/review-design.md`), the seats were replaced by the
built-in reviewers: `/code-review` and `codex review` find, and `orch-review.py`
proves, decides and records. The seat arms (`full`, `full-swap`,
`full-no-refuter`, `full-split` and the Standard seat arms) were removed with the
seats, the last four never run; the built-in arms are `full-builtin`,
`standard-builtin`, `standard-builtin-codex` and `full-builtin-single`, not yet
run.

## Field records (not A/B)

Everything above this line is an A/B run. Everything below it is not, and the
difference matters more than the numbers do. These are operating records from
real work: **one operator, one process, no control arm, no randomization, and
outcomes graded by the same process that produced them** — a defect counts as
"caught" because a stage in this cadence filed it, and nothing here can say
whether another process would have caught it too, or caught it cheaper. Read
them as costs and yields observed once, not as evidence that this sequence beats
an alternative. The A/B that would settle it is registered under "Not yet
measured".

### Record one — a private codebase, twelve landings in one working day

Twelve landings over about eight hours. Across them the refuter kept 76 findings
and dropped 12, every drop carrying a citation to the line that refuted it. The
severity rule — mild-only findings fold into the landing behind a firsthand red
witness instead of opening a round — avoided five fixer-plus-gate rounds in a
single session. Two tickets returned to the brief review, one at round 3 and one
when both reviewers rejected it; both were re-entered and both landed. No ticket
reached a fourth round. The full floors were green at every landing.

### Record two — this plugin's own cadence machinery, about forty seat dispatches in one day

Where the 21 catastrophic defects caught before landing were first found:

| stage | catastrophic | serious | cost per run |
|---|---|---|---|
| brief review (before any code) | 4 | 9 | 12 min, one seat |
| reviewer A — spec | 2 | 11 | ~20 min, parallel with B |
| reviewer B — plain-language, adversarial | 10 | 19 | ~15 min, parallel with A |
| refuter | 0 originated | 0 originated | 8–15 min |
| gate script | 0 | 2 | 53–199 s |
| gate seat (code only) | 5 | 4 | 14–47 min |

Two rows carry more than their numbers. The plain-language seat found ten of the
twenty-one catastrophic items **alone**, and where both seats found something the
two never overlapped — which is the argument for a pair, and against a third
seat. The refuter originated nothing, by design: its 9 drops out of 76 raw
findings — a count of this build's own findings, independent of, and only
coincidentally equal to, the 76 the refuter kept in record one — each carried a
citation, so what it bought was re-execution of other
seats' claims rather than filtering. The gate script, at under a minute a run the
cheapest stage in the sequence, found two defects in its own tooling that no
reading seat had seen. The gate seat found catastrophic items on executable code
that three earlier reading stages had missed — and on a prose-only ticket it
returned nothing for 14 minutes, which is why it now runs on code and not on
prose.

The largest cost that day was not review. About 5.7 hours were lost to a sleeping
machine and two harness outages, against about 5.3 hours spent on extra review
rounds. That comparison produced the standing environment rule — hold the machine
awake for an unattended run, stop and re-dispatch a seat silent for twenty
minutes, write a progress line every fifteen — and after it was adopted the
recorded dead time was **0 minutes on every stage row that followed**.

Under the amended process the same build produced about 50 further stage rows.
One prose ticket landed in a single round: 21 minutes to implement, 8 and 10 for
the pair, 8 for the refuter, 33 to fix, 4 to land; 28 raw findings, 17 promoted,
6 dropped with citations. One code ticket landed after five rounds and two
returns to the brief review, its fixer rounds running 29, 18, 16, 21 and 15
minutes and its gate rounds 17 to 30 minutes each, the gate script itself taking
10 to 33 seconds a run. Dead time on every one of those rows: 0.

**The clearest cost lesson in the record is a mechanism that was deleted.** A
shell guard that read each Bash command's text and refused the ones naming a
locked path consumed about 16 of that build's 28 seat-hours. It failed five gate
rounds in a row — each round closing one command spelling and the next round
finding another — and four catastrophic holes were still open in it when a
decision audit went looking for the threat it was built against and found **zero
recorded cases, across both data sets, of an agent deliberately editing a rules
file, a config, a settings file or a hook it had not been asked to touch**. What
the records did hold was one accidental clobber by a mutated script, caught by a
seat's own before-and-after hashes rather than by any guard, and drift in the
wording of the rules themselves, which a reader catches and a command parser
cannot. The guard was removed and the lock became two layers. The lesson is not
that locks are useless; it is that a mechanism should be sized to a measured
threat, and this one never was.

## Instrument incidents (kept because they shaped the harness)

- `archive/POISONED-2026-08-04T131538Z-*` — a session limit returned 94/100
  normal-looking $0 results; graded as failures they produced a confident
  false "REGRESSION p=0.000". `claude plugin eval` still grades such runs and
  does not mark the suite partial, so read each run's `error` field before
  trusting a score (`tests/evals/README.md`).
- 2026-08-05 — arm names containing `/` (branch refs) broke scratch paths;
  the abort-don't-pay guard stopped the run after one arm was already paid.
  That runner has since been replaced by `claude plugin eval`.

## Not yet measured

The remaining deferred runs, every case in `tests/evals/cases/` since its move
to `claude plugin eval`, and the review comparison's other arms in
`tests/evals/review-compare/` (its three main arms are in the ledger) — see the open items in the dated plan under
`docs/llm-orchestrator/plans/`. An unmeasured bet stays a bet; this ledger
only ever grows by paid runs.

**The refuter, with and without.** The field records above show what the refuter
cost and what it dropped, but not what it was worth: no arm ran without it. The
settling run is a held-out set of tickets put through the cadence twice, once
with the refuter stage and once without, graded on defects that reach a landing
and on rounds spent. The review comparison's `full` and `full-no-refuter` arms
measure the review step's part of this. Until that runs, "the refuter pays above a threshold" is an
operating rule taken from one operator's experience, not a measured finding.
