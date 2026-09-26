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
lines.

The set has 134 planted defects in 83 cases (69 with defects,
14 clean). The literature research estimates 100 to 170 defects to detect a
rise in detection from 50% to 65% with a paired test.

Arms (`review-compare/arms.json`) all run on the same cases, with the change
uncommitted. Every arm gets the same spec file. `orch-review.py` receives it
through `--spec` and gives its reviewers the same sentence the native arms get:
"The change must implement the spec in <spec>. Read it, and report every place
where the change does not meet it, as well as any other defect." It goes to
`/code-review` in the `-p` text after the level, and to `codex review` as
`-c developer_instructions=...`, because codex refuses a custom-instructions
PROMPT together with `--uncommitted`. Each tool still uses its own review brief
around that sentence.

**The 2026-09-25/26 `code-review` arm never received its sentence.** It was given
through `--append-system-prompt`, which does not reach the subagent
`/code-review` reviews in (checked live on 2026-09-26: a required marker line
and the spec path were ignored). Its numbers in `docs/MEASUREMENTS.md` are
`/code-review` without the spec. The arm now carries the sentence in its `-p`
text, and is to be re-run.

| arm | command |
|---|---|
| `full-builtin` | `orch-review.py run --path full --writer claude --base HEAD --spec <spec>` |
| `standard-builtin` | `orch-review.py run --path standard --writer claude ...` (runs `codex review`) |
| `standard-builtin-codex` | `--path standard --writer codex` (runs `/code-review`); listed, not yet run |
| `full-builtin-single` | `--path full --writer claude` with a `PATH` that holds `claude` but not `codex` (`/code-review` twice); listed, not yet run |
| `code-review` | `claude -p "/code-review high <sentence>" --model opus --effort high --safe-mode`, no MCP servers |
| `codex-review` | `codex review --uncommitted -c model_reasoning_effort="high" -c developer_instructions=<sentence>`, with every MCP server in `config.toml`, apps and plugins turned off |

An arm with `"without": ["codex"]` runs with every `PATH` folder that holds
`codex` replaced by a folder of links to everything else in it. The runs of the
old seat arms (`full`, `full-swap`, `full-no-refuter`, `full-split`,
`standard-contract`, `standard-adversarial`) stay recorded in
`docs/MEASUREMENTS.md`; those arms are gone with the seats.

The two native arms run with a narrowed environment, as `orch-review.py` does for
its launches: the basic variables plus the ones that CLI uses to reach its model,
so other credentials (AWS, GitHub tokens) are not passed. A `codex-review` run whose
log shows an MCP server started is counted as incomplete.

`review_compare.py score` reads `review.json` for the orch-review arms (every
finding except dropped ones). For the native arms it uses the review script's own
parsers (R7 of `docs/specs/review-design.md`), loaded from
`scripts/lib/orch-review.py`: for `/code-review`, one finding per item of every
fenced JSON array of findings that name a file; for `codex review`, the findings
of the JSON final message in the review's rollout under `$CODEX_HOME/sessions`
(`run` keeps a copy as `rollout.jsonl` beside the run). A reply the parser
rejects (prose only, a wrongly shaped array, conflicting or miscounted codex
findings) is an incomplete run of that arm: it is left out of detection and
listed with its reason. Every arm is scored by the same rule:

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
clean cases with no finding; incomplete runs with their reasons; for the
orch-review arms, serious findings left unverified by the fix experiments, per
provider, and how many of them were real detections; cost, tokens and minutes.
For each pair of arms it gives an exact McNemar test on the defects both arms saw
in their first try, and the same test on the cases where one arm made more false
findings than the other. For the built-in arms, also read from `review.json`:
planted serious defects that end blocking, the prover's rank against the planted
rank, floors applied, the share reproduced, clean-case verdicts, and the
`INCOMPLETE` rate and reasons.

Tokens are those not read from a cache. Codex's cached input and reasoning output
are parts of its input and output counts, so they are not added again. For
`codex-review` the count is the "tokens used" line it prints. Codex reports no
dollar cost.

Limits of the comparison:

- A finding counts as false whenever it does not point at a planted defect, so a
  real problem the set did not plant is counted as wrong. Read the false findings
  before concluding. The 2026-09-25/26 run showed this matters: the clean cases
  hold real bugs the set did not plant, and an audit of 80 sampled false
  findings found almost all of them true (unplanted bugs, spec gaps, and minor
  notes on missing tests), none wrong. The FALSE counts overstate noise.
- The claim match is a word-overlap rule. It can credit a vague finding that
  shares two words with the description, and miss a correct one worded
  differently. Read the location-only findings.
- A finding that names no file is not counted at all.
- Two defects in the same case are not independent, and McNemar treats them as
  if they were. With one try per case there is one sample per defect.
- Checked by the 2026-09-25/26 run: `/code-review` answers in `-p` mode under
  `--safe-mode`, and the layout of both outputs (see the scoring paragraph
  above). The first scoring missed the `/code-review` JSON array and read each
  reply as one finding; the scorer now reads the array. Checked live on
  2026-09-26: `codex review` gives `developer_instructions` to its reviewer as a
  developer message, and an appended system prompt does not reach
  `/code-review`'s subagent (so that arm ran without its sentence).

The orch-review arms need `scripts/lib/orch-review.py`; `run` refuses them when
it is missing. Run from the repository root. `run` skips runs that
already finished, so it can be stopped and started again.

```bash
RC=tests/evals/review-compare
python3 $RC/review_compare.py build --out $RC/work/cases
# 1. Pilot: two cases, the three main arms. Read $RC/work/results/runs/*/*/1/stdout.txt.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-builtin,code-review,codex-review --case 'invoice-discounts--clean' --case 'invoice-discounts--02'
# 2. Full with the built-ins, and /code-review again now that it gets its sentence, on all 83 cases.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms full-builtin,code-review --max-cost-usd 250
# 3. Standard with the built-ins.
python3 $RC/review_compare.py run --cases $RC/work/cases --out $RC/work/results \
  --arms standard-builtin --max-cost-usd 150
# 4. Listed, not yet run: standard-builtin-codex and full-builtin-single.
python3 $RC/review_compare.py score --cases $RC/work/cases --results $RC/work/results \
  --json $RC/work/results/report.json
```

Estimated cost. Only one real review has been measured, so treat these as ranges
to correct with the pilot, which prints each run's reported cost.

- Measured, on the old seat design: the one Full review in the outcome log (2026-09-25, a 15-line diff,
  Claude contract seat, Codex adversarial seat and the Claude refuter) cost
  $0.24 of Claude and took 79 seconds. The old runner's plain `claude -p` sessions
  on Opus cost $0.24 to $0.38 each.
- `full-builtin`: one `/code-review`, one `codex review`, prover launches (one
  per 10 findings) and, when a finding is serious, the refuter; not measured yet,
  so about $0.60 to $3 of Claude per case. `codex review` counts against the
  ChatGPT plan's limits and has no metered price.
- `code-review` at `high`: about $0.17 to $0.60 per case (a live run cost $0.17).
- `standard-builtin`: `codex review` plus prover launches, about $0.20 to $1.
- Step 1 (2 cases × 3 arms): about $2 to $8.
- Step 2 (83 cases × `full-builtin` and `code-review`): about $65 to $300.
- `--max-cost-usd` stops starting new runs once the reported Claude cost reaches
  the figure. Runs go one at a time, a minute or more each, so step 2 takes several
  hours.

Each orch-review run keeps its run directory in `review/` beside that run's results, because `orch-review.py` refuses one inside a temp dir; keep `--out` outside temp dirs.
`orch-review.py` appends its outcome rows under `XDG_STATE_HOME`; the runner points
that at `work/results/state/`, so eval runs stay out of the real outcome log.
