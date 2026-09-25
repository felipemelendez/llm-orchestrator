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
installed binary), and grades it with the binary's own rules: the `file_exists`
glob rule (`**` spans directories, `*` and `?` stay within one, and `[` and `]`
are literal), and `input_match` tested against the JSON of each tool call's input.
It stages the workspace as the eval does (`<root>/home/cwd`, with a stub `.git`
and a `.gitconfig` in `home`) and runs the scaffold with the eval's environment.
Then it requires:

- at least one grader to fail on the bare scaffold;
- at least one grader to fail on the reference reply with none of the work done
  (skipped for the four reply-only cases, whose descriptions say so);
- every grader to pass on the reference solution: `reference.sh`,
  `reference-reply.md`, a Write call for each file the reference creates or
  changes, and any other calls in `reference-tools.json`.

Only regex graders on the whole transcript or on MCP mock calls are not
evaluated; no case uses them.

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

Arms (`review-compare/arms.json`) all run on the same cases, with the change
uncommitted. Every arm gets the same spec file. `orch-review.py` receives it
through `--spec` and puts it in its own briefs. The two native arms receive the
same sentence naming the spec: "The change must implement the spec in <spec>.
Read it, and report every place where the change does not meet it, as well as
any other defect." It goes to `/code-review` through `--append-system-prompt`,
and to `codex review` as `-c developer_instructions=...`, because codex 0.157.0
refuses a custom-instructions PROMPT together with `--uncommitted`. Each tool still uses its own
review brief around that sentence, so a difference between arms is a difference
between the whole methods, not only the reviewers.

| arm | command |
|---|---|
| `full` | `orch-review.py run --path full --writer claude --base HEAD --spec <spec>` |
| `code-review` | `claude -p "/code-review high" --model opus --effort high --safe-mode --append-system-prompt <sentence>`, no MCP servers |
| `codex-review` | `codex review --uncommitted -c model_reasoning_effort="high" -c developer_instructions=<sentence>`, with every MCP server in `config.toml`, apps and plugins turned off |
| `full-swap` | `full` with `--adversarial-provider claude` |
| `full-no-refuter` | `full` with `--no-refuter` |
| `full-split` | `full` with `--split` (run with `--large-only`) |
| `standard-contract`, `standard-adversarial` | `--path standard` with each `--brief` |
| `full-effort-unset` | not runnable, by decision: reviewers always run at effort `high`, so `orch-review.py` has no option to leave effort unset |

The two native arms run with a narrowed environment, as `orch-review.py` does for
its seats: the basic variables plus the ones that CLI uses to reach its model, so
other credentials (AWS, GitHub tokens) are not passed. A `codex-review` run whose
log shows an MCP server started is counted as incomplete.

`review_compare.py score` reads `review.json` for the orch-review arms (every
finding except notes and dropped ones) and the reply text for the other two (one
finding per list item or heading that names a file). Every arm is scored by the
same rule:

- A finding points at a planted defect when it names the defect's file and a
  line within 3 lines of the defect's lines, or names the file with no line and
  names the defect's function.
- It counts as a detection only when it also describes the defect: it names the
  defect's function, or shares at least two content words with the defect's
  one-line description in the answer key. A finding that points at a defect but
  describes something else is reported as location-only, and counts neither as
  found nor as false.
- Any other finding is false, so every finding on a clean case is false.

The report gives, per arm: defects found, split by planted rank (serious, mild)
and separately for test tampering; false findings and location-only findings;
clean cases with no finding; for the orch-review arms, serious findings left
unverified by the fix experiments, per provider, and how many of them were real
detections; cost, tokens and minutes. For each pair of arms it gives an exact
McNemar test on the defects both arms saw in their first try, and the same test
on the cases where one arm made more false findings than the other.

Tokens are those not read from a cache. Codex's cached input and reasoning output
are parts of its input and output counts, so they are not added again. For
`codex-review` the count is the "tokens used" line it prints. Codex reports no
dollar cost.

Limits of the comparison:

- A finding counts as false whenever it does not point at a planted defect, so a
  real problem the set did not plant is counted as wrong. Read the false findings
  before concluding.
- The claim match is a word-overlap rule. It can credit a vague finding that
  shares two words with the description, and miss a correct one worded
  differently. Read the location-only findings.
- A finding that names no file is not counted at all.
- Two defects in the same case are not independent, and McNemar treats them as
  if they were. With one try per case there is one sample per defect.
- Not verified without a paid run: that `/code-review` works in `-p` mode under
  `--safe-mode` with the appended sentence, that `codex review` passes
  `developer_instructions` to its reviewer (0.157.0 accepts the key: a signed-out
  `--strict-config` run rejected an unknown key and loaded this one), that it logs
  its MCP servers, and the exact layout of
  both outputs. The pilot in step 1 checks these before the main spend.

The orch-review arms need `scripts/lib/orch-review.py` (ticket T5) merged; `run`
refuses them until it exists. Run from the repository root. `run` skips runs that
already finished, so it can be stopped and started again.

```bash
RC=tests/evals/review-compare
python3 $RC/review_compare.py build --out $RC/work/cases
# 1. Pilot: two cases, the three main arms. Read $RC/work/results/runs/*/*/1/stdout.txt.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full,code-review,codex-review --case 'invoice-discounts--clean' --case 'invoice-discounts--02'
# 2. The smallest run that answers "does Full find more than /code-review": both arms, all 83 cases.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full,code-review --max-cost-usd 250
# 3. codex review on the same cases (plan limits only).
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results --arms codex-review
# 4. The other arms.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-swap,full-no-refuter,standard-contract,standard-adversarial --max-cost-usd 270
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-split --large-only
python3 $RC/review_compare.py score --cases $RC/work/cases --results $RC/work/results \
  --json $RC/work/results/report.json
```

Estimated cost. Only one real review has been measured, so treat these as ranges
to correct with the pilot, which prints each run's reported cost.

- Measured: the one Full review in the outcome log (2026-09-25, a 15-line diff,
  Claude contract seat, Codex adversarial seat and the Claude refuter) cost
  $0.24 of Claude and took 79 seconds. The old runner's plain `claude -p` sessions
  on Opus cost $0.24 to $0.38 each.
- `full`: these diffs are 60 to 205 lines, so about $0.25 to $1 of Claude per case.
  The Codex seat counts against the ChatGPT plan's limits and has no metered price.
- `code-review` at `high`: not measured. It is at least one Opus session ($0.24 to
  $0.38), and at `high` it may start several subagents, so about $0.40 to $2 per
  case.
- Step 1 (2 cases × 3 arms): about $1.50 to $6.
- Step 2 (83 cases × `full` and `code-review`): 83 × ($0.25 to $1 plus $0.40 to $2),
  about $55 to $250. This is the smallest run that answers the main question.
- Step 3: no metered cost.
- Step 4: `full-swap` (two Claude seats and the refuter) about $0.40 to $1.50 per
  case, `full-no-refuter` about $0.15 to $0.70, each Standard arm about $0.10 to
  $0.50, so 83 × $0.75 to $3.20, about $60 to $270, plus `full-split` on the 24
  cases from the four large templates, about $6 to $24.
- `--max-cost-usd` stops starting new runs once the reported Claude cost reaches
  the figure. Runs go one at a time, a minute or more each, so step 2 takes about
  three to six hours.

`orch-review.py` appends its outcome rows under `XDG_STATE_HOME`; the runner points
that at `work/results/state/`, so eval runs stay out of the real outcome log.
