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

Results land in `tests/evals/results/benchmark.json` and a human summary is printed.

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

## Read the checks, not the aggregate

A case's pass/fail combines protocol checks and behavioural checks, and they move
independently. The 2026-07-28 n=3 run is the worked example
(`results/benchmark.json`, `interpretation` key): `tdd-bugfix` shows the plugin arm
"winning" 100%–0% — but the held-out execution check passed 3/3 in **both** arms. The
bare model fixed the bug just as reliably; the measured win was the evidence format, at
+14% cost per behaviourally-solved task. Reporting that as "the plugin makes the agent
fix bugs" would be false. Always split the delta by check kind before claiming anything.

## Model pinning

Runs pin `--model` (default `opus`, override with `--model`/`ORCH_EVAL_MODEL`) instead of
inheriting the session default. An exhausted or unavailable session model returns its
limit notice as a normal-looking $0 result and silently fails every check.
