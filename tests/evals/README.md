# Behavioural evals

`tests/*.sh` check that the shell mechanics work. Nothing there checks whether the
plugin **changes what the agent does**. These evals do.

Every skill, rule, and hook in this repo is a bet that some prompt text improves agent
behaviour. Until a bet is measured, adding it and removing it are equally defensible —
which is how a repo ends up with rules nobody can justify and nobody dares delete.

The published evidence is blunt about this. In a 5,832-run study across 18 skill-library
conditions, regressions cancelled **59% of gross gains**, only 3 of 18 conditions survived
Bonferroni correction, and ranking libraries by *gross* gain versus *net* effect reversed
the order ([arXiv:2607.22520](https://arxiv.org/abs/2607.22520)). A component ablation on
Terminal-Bench found parts summing to +11.1 pp while the assembled stack delivered +7.3,
with a **system-prompt-only change measuring −2.3 pp**
([arXiv:2604.25850](https://arxiv.org/abs/2604.25850)). Anthropic's own skill guidance says
to build the eval first and establish a baseline without the skill.

## What it measures

Each case runs the same prompt twice, in a scratch project:

- **arm `with`** — the plugin's skills and hooks installed, from the working tree
- **arm `without`** — a bare project, no plugin
- **arm `ref:<gitref>`** — the plugin as of that commit

and grades both. A case earns its keep only if `with` beats `without`. A case where both
arms pass is telling you the model already does it — that rule is restating a default and
is costing tokens for nothing.

`ref:` is what makes this a **regression** instrument and not only an existence proof.
`with` vs `without` answers *does the plugin do anything*. It cannot answer *did this
week's edit make it better or worse* — and that is the question every compression or
rule-deletion pass raises. Compare the two plugin versions directly:

```bash
tests/evals/run-evals.sh --arm "ref:4f6815f with" --case tdd-bugfix --n 5
```

`ref:` exports the whole commit, not just `skills/` — the hook scripts and libs of that
commit are part of what the arm is testing, and pairing old prose with new enforcement
would measure neither. Exports are cached per SHA, so N iterations pay for one export,
and an unknown ref fails loudly rather than quietly building a half-populated arm.

Use it before deleting instructional content. Deleting a rule that turns out to be
load-bearing is the failure this instrument exists to catch: obra/superpowers cut their
TDD skill's rationale as padding, measured it, found test-first behaviour under pressure
dropped from 8/10 to 5/10, and reversed the cut. `tdd-bugfix` is the case in this suite
most likely to show that effect, because its checks execute the code rather than grading
the prose.

Both directions are tested on purpose. `research-gate-skips` asserts the gate stays
*quiet*; a gate that fires on everything is as broken as one that never fires. One-sided
evals produce one-sided optimisation.

## Noise floor

Single-run pass rates on agentic benchmarks vary by 2.2–6.0 pp, with std ≥1.5 pp even at
temperature 0 ([arXiv:2602.07150](https://arxiv.org/abs/2602.07150)). A 1-of-1 difference
between arms is not a result. Default is `N=3` per arm; raise it before believing anything
smaller than a clean sweep.

## Cost

Each run is a cold `claude -p` session — roughly **$0.15–0.30**, mostly cache creation.
A full pass at `N=3` over `C` cases is about `C × 6` runs. Budget before running the
whole suite; `--case` runs one.

## Usage

```bash
tests/evals/run-evals.sh                  # all cases, N=3
tests/evals/run-evals.sh --n 1            # smoke, one run per arm
tests/evals/run-evals.sh --case shape-header
tests/evals/run-evals.sh --arm with       # one arm only

# Did an edit help or hurt? Compare two plugin versions on the same case.
tests/evals/run-evals.sh --arm "ref:4f6815f with" --case tdd-bugfix --n 5
```

Results land in `tests/evals/results/` (see *Results are append-only* below) and a human
summary is printed.

## Adding a case

One JSON file in `cases/`:

```json
{
  "id": "verify-evidence",
  "why": "The rule this case exists to defend, in one line.",
  "prompt": "What the user types.",
  "setup": ["shell commands run in the scratch project first"],
  "expect": {
    "must_match": ["^Verify:"],
    "must_not_match": ["\\bshould pass\\b"]
  }
}
```

`must_match` / `must_not_match` are extended regexes tested against the assistant's final
text. An optional `check` array holds shell commands run **in the scratch project after
the session** — all must exit 0. That is the behavioural grader: "did the held-out test
actually pass on disk", not "did the prose look right". An optional `with_env` object is
merged into the with-arm's settings env, which is how hook ablations are built (e.g.
`{"ORCH_DISABLED_HOOKS": "orch-user-prompt-submit"}`).

Keep graders mechanical — two people reading the same transcript must reach the same
verdict, or the case is measuring taste rather than behaviour.

Prefer execution checks over `expect` regexes for anything you intend to draw a conclusion
from. Protocol-format regexes only ever *subtract* from the pass rate, and they subtract
noisily: on `tdd-under-pressure` they turned a p=0.004 behavioural regression into a
p=0.46 aggregate. The two newest cases carry no `expect` block at all, so their headline
and their behaviour are the same number.

**Validate a case before paying for it.** `tests/test-eval-cases.sh` runs on every commit
and enforces the properties a broken case fails silently on: ids match filenames, regexes
compile, every case carries at least one assertion and a `why`, every `check` command
parses as shell, and — the load-bearing one — each case is **red before the agent runs**.
A case whose checks already pass on its own setup measures the setup. Two drafts of
`tdd-under-pressure` shipped broken exactly that way: one where the planted bug was not a
bug, one with a check that could never pass. Neither failed loudly; both returned a
confident wrong answer on a run that had already been paid for.

### The cases

| case | defends | grader |
|---|---|---|
| `shape-header` | protocol shape on a lookup question | text |
| `shape-header-no-turn-hook` | ablation: the per-turn protocol injection | text |
| `verify-evidence` | a completion claim carries the command and its output | text |
| `research-gate-skips` | negative control — the gate stays quiet on pure logic | text |
| `tdd-bugfix` | test-first on an ordinary bug | execution |
| `tdd-under-pressure` | test-first when the user says not to bother | execution |
| `writer-isolation-shared-file` | writers that share a file are serialised, not raced | execution |
| `reviewer-recall-planted-defect` | a real defect is still reported (check 1) without inventing one (check 2) | execution |

The last two exist because the 2026-08-03 compression pass cut seventeen skills and only
one of them was measured. `dispatching-subagents` lost the most words in the catalogue
(608), and it carries the invariant that two tasks touching one file run sequentially —
so that case demands three simultaneous writers on one dict literal and grades whether all
the work survived. The reviewer case is the other direction: the cuts to the reviewer
agents are tiny by word count (−1, −25, −7) but all push toward **precision** — the
deleted Anti-patterns block and the new "a finding invented to look thorough costs a human
round-trip" clause now sit beside the surviving "do not withhold, do not be conservative".
An instruction to be conservative is followed literally and lowers recall, so that case
plants one real, executable defect and one correct-looking decoy and measures both sides.

## Read the checks, not the aggregate

A case's pass/fail combines protocol checks and behavioural checks, and they move
independently. The 2026-07-28 n=3 run is the worked example
(`results/benchmark.json`, `interpretation` key): `tdd-bugfix` shows the plugin arm
"winning" 100%–0% — but the held-out execution check passed 3/3 in **both** arms. The
bare model fixed the bug just as reliably; the measured win was the evidence format, at
+14% cost per behaviourally-solved task. Reporting that as "the plugin makes the agent
fix bugs" would be false. Always split the delta by check kind before claiming anything.

This section was here, correct, and ignored — by the reporter. On 2026-08-03 a 200-run
A/B moved TDD-under-pressure behaviour from **76/100 to 56/100 (p=0.004)** and the
summary table printed *inconclusive, p=0.46*, because the verdict was computed from the
aggregate the paragraph above warns about. The regression was three lines below the
headline that said there wasn't one.

So the summary now leads with the behavioural rate and computes the verdict from it,
falling back to the overall rate only for cases with no execution checks. Each `check`
command is also graded and reported **separately** (`per_check` in the benchmark JSON), so
a case can carry two independent measurements — `reviewer-recall-planted-defect` measures
recall in check 1 and precision in check 2, and collapsing them into one bit would report
only that "something failed". `tests/test-eval-reporter.sh` replays the archived 2026-08-03
numbers through the shipped reporter on every CI run and fails if the verdict stops naming
that drop a regression.

## Statistics, not rate comparisons

Two rates are not a result. The first verdict this harness shipped printed
`WORSE — REGRESSION` for 2/5 vs 3/5 — a one-run gap on an instrument whose own noise floor
section says to treat that as noise. The comparison is now **Fisher's exact test** on the
2×2 (pass/fail × arm), stdlib-only and correct at the sample sizes a paid eval can afford,
where a normal approximation is not. Below p<0.05 it reports `inconclusive` *and prints the
gap*, so the next decision is obvious.

Size the run before spending. Power against a true 20-point drop:

| n/arm | power | | n/arm | power |
|------:|------:|-|------:|------:|
| 5     | 5%    | | 40    | 38%   |
| 15    | 10%   | | 60    | 53%   |
| 20    | 15%   | | 100   | 77%   |

At n=15 there is a 90% chance of missing a real 20-point regression and reporting
"inconclusive" as though it were reassurance. Binary pass/fail needs ~200 runs to speak
about an effect that size.

**Measured between-run variance on an identical arm.** `ref:4f6815f` was run twice on
`tdd-under-pressure`, same commit, n=100 each: behavioural **76%** then **68%**. Eight
points of swing with nothing changed. That is consistent with binomial noise (SE ≈ 4.5pp per
arm at that rate, so SE of the difference ≈ 6.3pp), and it is the number to hold in your head
when reading any single comparison here: **a 100-run-per-arm result cannot resolve anything
smaller than roughly 12–13 points.** The TDD regression was measurable because it was 20.
Do not re-run an arm and treat the second number as a correction of the first — average them
or say the interval.

## Results are append-only

Every run writes `raw.<case>.<UTC-timestamp>.jsonl` and
`benchmark.<case>.<UTC-timestamp>.json`; the un-timestamped names are a **copy** of the
newest run, kept only so older docs and tooling resolve. This is not tidiness. The stable
names were once the only ones, and the confirmation run for the regression above began
overwriting the raw rows that proved it — the run checking the finding was destroying the
evidence for it. Only the benchmark summary survived, archived by hand at
`results/archive/2026-08-03-tdd-under-pressure-REGRESSION-FOUND.json`.

## Model pinning

Runs pin `--model` (default `opus`, override with `--model`/`ORCH_EVAL_MODEL`) instead of
inheriting the session default. An exhausted or unavailable session model returns its
limit notice as a normal-looking $0 result and silently fails every check.
