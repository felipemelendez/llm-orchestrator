# Paid evals

`tests/*.sh` check that the shell mechanics work. The evals here check whether the
plugin changes what the agent does, and how the plugin's review compares with the
built-in ones. Every run is a real model call. Nothing here runs in CI or in
`tests/run-all.sh`; only the free checks below do.

- `cases/` holds behaviour cases for `claude plugin eval`. They were checked
  against Claude Code 2.1.282; the plugin-evals docs name 2.1.269 as the first
  version with the command, which was not tested here. Each case runs 8 times with the plugin and 8 times without it.
- `review-compare/` holds small changes with planted defects, and a script that
  runs several reviewers on the same changes and scores them.
- `results/benchmark.json`, `results/raw.jsonl` and `results/archive/` are the
  results of the old runner, kept as the record behind `docs/MEASUREMENTS.md`.

## Free checks

```bash
bash tests/test-eval-cases.sh      # every case: schema, red before, green after
bash tests/test-review-compare.sh  # every planted defect is real; scorer dry run
```

`claude plugin eval` has no dry-run option, so `test-eval-cases.py` checks each
case against the case schema that Claude Code 2.1.282 enforces (read from the
installed binary). It then runs the case's scaffold with the environment the eval
gives it and requires at least one grader to fail before the agent acts. It also
applies the case's `reference.sh` and `reference-reply.md` and requires every
grader to pass on them. It cannot run `tool_used` and `tool_order` graders,
because they read the session transcript; those are only checked for syntax.

`test-review-compare.py` runs every template's held-out check on the clean change
and on each planted defect, builds the cases twice to show the build is
deterministic, and runs three arms through `run` and `score` with fake `claude`,
`codex` and `orch-review.py` programs. It checks that the report counts exactly
what the fakes reported.

## Running the behaviour cases

Run from the repository root, in a terminal (the first run asks you to trust the
directory):

```bash
claude plugin eval . --eval-dir tests/evals --model opus --scaffold -j 4 \
  --threshold 0 --no-publish --max-cost-usd 150 --allow-tools Bash Write Edit
```

- 19 cases × 8 runs × 2 arms is 304 sessions. The old runner's recorded runs
  on Opus averaged $0.24 to $0.38 per session (`results/raw.jsonl` and the
  `.jsonl` files in `results/archive/`), so expect about $75 to $115. The
  `--max-cost-usd 150` ceiling leaves room for longer runs. No case uses a judge
  grader, so there is no judge cost.
- `--scaffold` runs each case's `scaffold.sh` as you; it only writes fixture files
  and a git repository into the run's empty workspace.
- One case: add `--case tdd-bugfix`. One family: `--tag tdd-under-pressure`.
- The report and `aggregate-result.json` go to `tests/evals/results/<timestamp>/`
  (ignored by git).
- Before trusting a score, read each run's `error` in the JSON. A usage limit ends
  runs with an error, they are still graded, and the suite is not marked partial.

What the port changed, and what the eval cannot reproduce:

- `claude plugin eval` has no custom-code graders. The old cases ran Python checks
  on the finished workspace; each one is now a regex over a file, a `file_exists`
  glob or a `tool_used` check on the transcript. Each case's description ends with
  one sentence saying what its graders approximate. A correct fix written in an
  unexpected form can fail, and a wrong one that looks right can pass.
- Runs load no CLAUDE.md, user settings, memory or other plugins, run in `-p`
  mode, and receive only `EVAL_*` environment variables. They do not reproduce an
  interactive session with the person's own setup.
- Two old cases were removed. `shape-header-no-turn-hook` switched a hook off with
  `ORCH_DISABLED_HOOKS`, which an eval run cannot receive (only `EVAL_*` variables
  pass, and runs read user settings only, so a workspace `.claude/settings.json`
  is ignored). `verify-under-pressure-strict` set `ORCH_STRICT_VERIFY`, which no
  code reads any more, so it was the same case as `verify-under-pressure`.
- Variants became separate cases tagged with their family, so
  `--tag tdd-under-pressure` runs all four.
- Comparing two plugin versions (the old `ref:` arm) means running the same
  command in a worktree of each version.

## The review comparison

`review-compare/templates/` holds a curated set of 14 small Python changes,
each with a base commit, a spec under `docs/specs/`, committed tests, and a
held-out check that is never copied into a case. Each template lists 8 to 10
defects, each a small edit inside the lines the change touches.
`review_compare.py build` turns them into cases: one clean case per template, and
one case per pair of defects in listed order, each a git repository with the
change left uncommitted. Every defect fails the held-out check and passes the
committed tests, so running the tests does not reveal it. Each template has at
least one test-tampering defect (the code is wrong and a test was changed to
match), which covers the spec's item 7. Four templates change more than 150
lines, for the split arm.

The set has 134 planted defects in 83 cases (69 with defects,
14 clean). The literature research estimates 100 to 170 defects to detect a
rise in detection from 50% to 65% with a paired test.

Arms (`review-compare/arms.json`), all on the same cases, with the change
uncommitted and no other prompt text:

| arm | command |
|---|---|
| `full` | `orch-review.py run --path full --writer claude --base HEAD --spec <spec>` |
| `code-review` | `claude -p "/code-review high" --model opus --effort high --safe-mode` |
| `codex-review` | `codex review --uncommitted -c model_reasoning_effort="high"` |
| `full-swap` | `full` with `--adversarial-provider claude` |
| `full-no-refuter` | `full` with `--no-refuter` |
| `full-split` | `full` with `--split` (run with `--large-only`) |
| `standard-contract`, `standard-adversarial` | `--path standard` with each `--brief` |
| `full-effort-unset` | not runnable: `orch-review.py` always asks for effort `high`, and the spec defines no option to leave it unset |

`review_compare.py score` reads `review.json` for the orch-review arms (every
finding except notes and dropped ones) and the reply text for the other two (one
finding per list item that names a file and line). A finding counts for the
nearest planted defect in the same file within 3 lines of the defect's lines;
any other finding is false, so every finding on a clean case is false. It reports
defects found, split by planted rank (serious, mild), false findings per run,
clean cases with no finding, cost, tokens and minutes, and an exact McNemar test
for each pair of arms on the defects both arms saw in their first try. Codex
reports tokens but no dollar cost.

Limits of the comparison:

- A finding counts as false whenever it is not near a planted defect, so a real
  problem the set did not plant is counted as wrong. Read the false findings
  before concluding.
- Free-text parsing needs the reply to name `file:line`, `file, line N` or
  `file#LN`. A finding with no location is not counted at all.
- Two defects in the same case are not independent, and McNemar treats them as
  if they were. With one try per case there is one sample per defect.
- Not verified without a paid run: that `/code-review` works in `-p` mode under
  `--safe-mode`, and the exact layout of `/code-review` and `codex review`
  output. The pilot in step 1 checks both before the main spend.

Run it from the repository root. `run` skips runs that already finished, so it
can be stopped and started again.

```bash
RC=tests/evals/review-compare
python3 $RC/review_compare.py build --out $RC/work/cases
# 1. Pilot: two cases, the three main arms. Read $RC/work/results/runs/*/*/1/stdout.txt.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full,code-review,codex-review --case 'invoice-discounts--clean' --case 'invoice-discounts--02'
# 2. The main comparison on every case.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full,code-review,codex-review --max-cost-usd 450
# 3. The other arms.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-swap,full-no-refuter,standard-contract,standard-adversarial --max-cost-usd 900
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-split --large-only
python3 $RC/review_compare.py score --cases $RC/work/cases --results $RC/work/results \
  --json $RC/work/results/report.json
```

Estimated cost, before any run has measured it. The pilot prints each run's
reported cost; use it to correct these figures.

- `full`: one Claude seat at `opus` and effort `high`, one Codex seat, and the
  refuter on most defect cases: about $1 to $3 of Claude per case. The Codex seat
  counts against the ChatGPT plan's limits and has no metered price.
- `code-review` at `high`: about $1 to $3 per case. `codex-review`: plan limits only.
- Step 1: about $5 to $12.
- Step 2 (83 cases, three arms): about $150 to $450 of Claude.
- Step 3: `full-swap` (two Claude seats and the refuter) about $2 to $5 per case;
  `full-no-refuter` and each Standard arm about $0.50 to $2; `full-split` only on
  the large cases. Together about $400 to $900 more.
- `--max-cost-usd` stops starting new runs once the reported Claude cost reaches
  the figure. Runs go one at a time; step 2 takes most of a day.

`orch-review.py` appends its outcome rows under `XDG_STATE_HOME`; the runner points
that at `work/results/state/`, so eval runs stay out of the real outcome log.
