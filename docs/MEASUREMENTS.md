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

## Instrument incidents (kept because they shaped the harness)

- `archive/POISONED-2026-08-04T131538Z-*` — a session limit returned 94/100
  normal-looking $0 results; graded as failures they produced a confident
  false "REGRESSION p=0.000". The runner now excludes error rows, aborts on
  three consecutive errors, and invalidates arms with >10% loss.
- 2026-08-05 — arm names containing `/` (branch refs) broke scratch paths;
  the abort-don't-pay guard stopped the run after one arm was already paid.
  Fixed with `ORCH_EVAL_DRY_RUN` coverage (`tests/test-eval-runner-paths.sh`).

## Not yet measured

The remaining deferred runs and every case marked "unrun detector" in
`tests/evals/cases/` — see the open items in the dated plan under
`docs/llm-orchestrator/plans/`. An unmeasured bet stays a bet; this ledger
only ever grows by paid runs.
