# Spec: one review design for Standard and Full

Status: proposed 2026-09-25 (ticket T4). Not built. T5 builds it only after
Felipe approves this file.

## Goal

One review design for both paths and both harnesses. Standard runs one
reviewer. Full runs two blind reviewers with different briefs on two
providers, then a refuter when a serious finding exists. One Python script,
`scripts/lib/orch-review.py`, runs every step in a fixed order and decides
the verdict last, from files it reads itself. The agent runs it once, so no
step can be skipped.

Out of scope: the spec review before coding, the fix itself, and the legacy
procedure (T6).

## Why one script and no Workflow script

A Workflow script cannot run commands or read files. The checks that decide
whether a review counts (served model, evidence in tool logs, the real
checkout unchanged) would have to run after it returns, so the verdict would
be decided before them. It also runs only on Claude Code, so Codex would need
a second copy of the same rules.

`orch-review.py` launches `claude -p` and `codex exec` itself, reads their
event streams, and runs on both harnesses. The Workflow tool would add a
progress display and per-agent resume; the script resumes by reusing valid
seat results in its run directory (R4). Nothing else is lost.

## Running it

```
python3 scripts/lib/orch-review.py run --path standard|full --writer claude|codex
    --base <ref> --spec <file> --run-dir <dir>
    [--brief contract|adversarial] [--adversarial-provider claude|codex]
    [--no-split] [--no-refuter]
```

The last four options exist for T10; normal use sets none of them.

- **R1.** `run` performs the steps below in order and exits 0 after it
  writes `<run-dir>/review.json`, whatever the verdict. A crash exits nonzero
  and leaves no `review.json`; the skill reports that as incomplete.
- **R2.** On Claude Code the agent starts `run` with the Bash tool's
  background option and reads `review.json` when it exits. On Codex,
  `run --detach` returns at once, and `orch-review.py wait <run-dir>
  --seconds 540` returns when the run ends or the time is up; the agent
  repeats `wait`.
- **R3.** The skill sets `--writer`: `claude` on Claude Code, `codex` on
  Codex.
- **R4.** Running `run` again with the same `--run-dir` reuses a seat's
  result only if its inputs digest (prompt, copy tree, model and effort
  requested) matches and the result passed validation. It relaunches the
  rest.

## Steps

1. **Preflight.** Check that each needed CLI is installed and signed in
   (`claude auth status --json`, `codex login status`). Full needs both. A
   failure ends the run as `INCOMPLETE`, with no seat launched and nothing
   substituted.
2. **Fingerprint.** Add every tracked and untracked, non-ignored file of the
   real checkout to a temporary index (`GIT_INDEX_FILE=<tmp>`,
   `git read-tree HEAD`, `git add -A`) and record `git write-tree`. This tree
   id is the reviewed state.
3. **Copies.** For each seat launch and for the refuter, create a git
   worktree at `HEAD` and check out the fingerprint tree into it
   (`git read-tree -u --reset <tree>`). The copy then has `.git`, the base
   commit and the uncommitted change. Copy the ignored paths listed in
   `cadence.json` `review.copy_ignored` (for example `.ve`, `node_modules`)
   with a copy-on-write clone where the file system supports it, then run
   `review.setup` if set. The copy's own fingerprint must equal step 2's.
   T5 adds this to `skills/cadence/scripts/orch-task-resources.py`, so copies
   are leased and cleaned up like other task resources.
4. **Parts.** Only when the diff has more than 150 changed lines, split it:
   whole files in diff order until the next file would pass 150 lines, and a
   larger file at hunk boundaries. `--no-split` keeps one part. Each seat
   reviews each part in a separate launch and its own copy, with the part's
   diff and the list of all changed files with line counts.
5. **Seats.** Launch all seat runs in parallel (R8 to R10).
6. **Validate.** Parse each result, assign ids and check evidence against
   the seat's own event stream (R11 to R16).
7. **Refuter.** Full only, when R17 says so.
8. **Fingerprint again.** Recompute step 2 on the real checkout.
9. **Decide** (R22), write `review.json` and append the review row to the
   outcome log (R25).

## Seats, providers and models

- **R5.** Standard: one seat with the contract brief, on the writer's
  provider, and no refuter. `--brief adversarial` changes the brief (T10
  only).
- **R6.** Full: a contract seat and an adversarial seat. Neither sees the
  other's findings or the implementer's report. The adversarial seat runs on
  the provider that did not write the change (GPT on Claude Code, Claude on
  Codex), and the contract seat on the other. `--adversarial-provider`
  overrides this for T10's swap test.
- **R7.** The refuter runs on Claude, `opus`, effort `high`, on both
  harnesses.
- **R8.** A Claude launch is `claude -p --output-format stream-json
  --verbose --model opus --effort high --json-schema <schema> --safe-mode
  --restricted --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash
  --permission-mode dontAsk --permission-prompts none --strict-mcp-config
  --no-session-persistence`, with the copy as working directory and the
  prompt on stdin. `--safe-mode` skips CLAUDE.md, so the prompt carries the
  project's test command (`runner.test_cmd`) and any rule the brief needs.
- **R9.** A GPT launch is `codex exec --json -s workspace-write -C <copy>
  -c model_reasoning_effort="high" --output-schema <schema> -o <file> -`,
  with no `-m`, so it gets the Codex CLI's configured default model. A
  project may name a model or effort in `cadence.json` `codex_providers`.
- **R10.** Each launch records in `<run-dir>` the command, the requested
  model and effort, start and end times, exit status, the full event stream,
  and the served model read from that stream (Claude: the assistant
  messages' `model`; Codex: the event that names the model, unverified). A
  launch is a **dropout** when it exits nonzero, has no final result, names
  no served model, or its served model does not match the request (for
  Claude, the alias's model family).

Why GPT holds the adversarial brief on Claude Code (Felipe's choice): the
adversarial seat looks for what the writer missed, and a model approved 31.7%
of its own behavior-changing errors (arXiv:2605.21537). Against it: the one
cross-model study found that Codex reviewing Claude's code lowered the pass
rate from 91.4% to 82.8% when reviewers could not run tests
(arXiv:2607.21656). Here seats run tests and evidence is checked. Different
models also give the same wrong answer about 60% of the time when both are
wrong (arXiv:2506.07962), so two providers are less independent than they
look. T10 tests the swap.

## Findings and evidence

- **R11.** Each seat returns `{findings: [...], not_checked: [...]}`. A
  finding has `file`, `line`, `rank` (`catastrophic | serious | mild`, from
  the project's harm ranking), `kind` (`defect | spec-gap | scope-creep |
  test-tampering`), `confidence` (0 to 1), `claim`, `fix` and `evidence`.
  A `serious` or `catastrophic` finding also has either `fix-run` evidence or
  `not_runnable` (a reason). The script gives each finding the id
  `<seat>-<part>-<n>`, unique across seats and parts, and ignores any id the
  seat sent.
- **R12.** Evidence is one of:
  - `file-line {file, line, quote}`: valid when the file exists in the
    copy, the line exists, and `quote` equals that line with outer
    whitespace removed.
  - `test-run {command, output}`: valid when the reviewer's own event stream
    shows a completed command with exactly that text whose output contains
    `output` (non-empty, verbatim).
  - `fix-run {command, before, after}`: valid when the stream shows that
    command completed twice, with a change to the copy between the two runs,
    the first run's output containing `before` and the second's containing
    `after`. The script records whether each run passed or failed. A
    `fix-run` supports a finding only when the first run failed and the
    second passed.
- **R13.** A finding with no valid evidence, or with a `confidence` below
  0.8 or missing, is a **note**. It is kept in `review.json` and counted, but
  it never blocks and is never sent to the refuter. This applies to every
  provider, so every GPT finding on Claude-written code must pass it.
- **R14.** A `serious` or `catastrophic` finding with neither a `fix-run`
  that supports it nor `not_runnable` makes the review `INCOMPLETE`, because
  a required step was skipped.
- **R15.** A non-empty `not_checked` makes the review `INCOMPLETE`, and its
  text is returned verbatim.
- **R16.** Test tampering means a test deleted or skipped, an assertion
  weakened, a test changed to match the code, or code that special-cases
  test inputs. When the task does not allow test changes, a `test-tampering`
  finding ranked below `serious` is raised to `serious` and counted. A rank
  outside the enum becomes `serious` and is counted.

## The refuter

- **R17.** The refuter runs only on Full, only when both seats are complete,
  and only when at least one `serious` or `catastrophic` finding is not a
  note. It gets every non-note finding from both seats and judges the
  serious and catastrophic ones. `--no-refuter` skips it (T10 only; the
  review is then marked `experimental`).
- **R18.** The refuter returns groups `{ids, verdict, rank, evidence}`; one
  group is one defect. Every serious or catastrophic id must be in exactly
  one group. A missing id is **unjudged** and makes the review `INCOMPLETE`,
  and so does a refuter dropout.
- **R19.** `AGREED` is valid only for a group holding ids from both seats at
  the same rank, and needs no new evidence. Any other `AGREED` counts as
  `UNRESOLVED`.
- **R20.** `PROMOTED` and `DROPPED` need evidence that is valid under R12
  against the refuter's own event stream. A `DROPPED` on a finding without
  `not_runnable` also needs a `fix-run` in which both runs passed, showing
  that the proposed fix changes nothing observable. A verdict that fails
  this counts as `UNRESOLVED`, which keeps the finding at its highest rank.
- **R21.** A group's rank may be lower than the highest rank of its findings
  only with valid evidence, and it is never higher.

## The decision

- **R22.** One function in `orch-review.py` decides, after steps 1 to 8,
  from the files in `<run-dir>` only:
  - `INCOMPLETE` if the preflight failed; if any seat part or a needed
    refuter run is missing, a dropout or unjudged; if R14 or R15 applies; or
    if a copy's or the real checkout's fingerprint differs from step 2;
  - otherwise `NOT-READY` if any serious or catastrophic finding is neither a
    note nor `DROPPED` (on Standard, every such finding counts);
  - otherwise `READY-WITH-FIXES` if any `mild` finding is not a note;
  - otherwise `READY`.
- **R23.** `review.json` holds the verdict and every reason for
  `INCOMPLETE`. For each launch it holds the provider, the brief, and the
  requested and served model and effort. It lists every finding with its
  status (`note`, `agreed`, `promoted`, `dropped`, `unresolved`, `mild`) and
  the refuter's evidence, plus the counts (raw, notes, invalid evidence,
  below floor, coerced ranks). Nothing a seat returned is left out.
- **R24.** A dropout is never replaced by another provider, model or brief.

## After the review

- **R25.** Every run appends one review row to
  `${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/review-outcomes.jsonl`,
  including `INCOMPLETE` runs and preflight failures. The row holds: run id,
  date, repository name, path, writer, providers and briefs, models
  requested and served, parts, diff lines, verdict, incomplete reasons,
  counts, duration and reported cost. It stores no claim text or code.
- **R26.** The agent handles findings with `receiving-code-review`, then
  runs `orch-review.py record <run-dir> --dispositions <file>` with one line
  per finding. Each line is one of:
  - `fixed`, with the check that failed before and passes after;
  - `refuted`, with evidence under R12;
  - `ignored`, with a reason. A blocking finding may be ignored only when
    the person said so.

  `record` appends one row per finding (run id, finding id, seat, provider,
  rank, kind, evidence kind, status, disposition). It rejects a file that
  leaves out any finding.
- Fixing stays with the agent. The script never edits the real checkout.

## What T5 builds

**Add**

- `scripts/lib/orch-review.py` (`run`, `wait`, `record`). It takes over the
  receipt and model checks from `scripts/providers/claude-review.py`.
- `skills/requesting-code-review/references/`: `contract.md`,
  `adversarial.md`, `refuter.md`, `security-lens.md` and the JSON schemas.
  The security lens is added to both seat briefs when the diff matches
  `ORCH_SIG_SECURITY_DIFF`. Where each brief's text comes from:
  - the contract brief: spec compliance and "which test would still pass
    with its mechanism removed", from `reviewer-spec.md`;
  - the adversarial brief: `reviewer-plain.md`, plus the test-tampering
    list;
  - the refuter brief: `refuter.md`'s laws, plus R18 to R21;
  - the security lens: the checklist in `orch-security-reviewer.md`.
- `tests/test-review.py` and its `.sh` shim. They use fake `claude` and
  `codex` binaries that replay recorded event streams, with one case per
  rule, including:
  - the refuter runs when a serious finding exists and is skipped when none
    does;
  - a missing seat gives `INCOMPLETE`, never `READY`;
  - a dropout is never replaced;
  - evidence whose command or quote is not in the stream becomes a note;
  - a `DROPPED` with invented output leaves the finding blocking;
  - a change to the real checkout gives `INCOMPLETE`.

  These tests replace `tests/test-review-diff-behavior.sh`,
  `tests/validate-workflows.sh` and the other workflow tests named in T5's
  "Done when". The coordinator updates that list.

**Change**

- `skills/requesting-code-review/SKILL.md`: how to run Standard and Full on
  both harnesses (R1 to R3), and what each verdict means.
- `skills/receiving-code-review/SKILL.md`: harm ranks, the evidence rule
  for refuting, and R26.
- `commands/review.md`: `/llm-orchestrator:review [base] [--full]` runs the
  skill and saves no review file in the repository.
- `skills/cadence/SKILL.md`, and proportional Full steps 3 and 4 in
  `CADENCE.md`: point to `requesting-code-review` and drop the "separate
  workflow" paragraph. The legacy steps 2 and 2b and the briefs they link to
  stay for T6 to delete.
- `agents/orch-spec-reviewer.md`: kept only for brainstorming's review of a
  spec document (`skills/brainstorming/SKILL.md`,
  `spec-document-reviewer-prompt.md`). Its description says so. It keeps its
  Issues block, so `scripts/hooks/subagent-stop.sh` keeps expecting that
  block.
- Remove the deleted names from `scripts/hooks/subagent-stop.sh`,
  `scripts/install.sh`, `templates/dispatch-prompt.md` (drop the
  code-reviewer role), `tests/validate-skills.sh`, `tests/test-install.sh`,
  `tests/smoke.sh` and `tests/test-protocol-hooks.sh`.
- `docs/codex.md` and `docs/codex-provider.md`: the Claude seat is part of
  Full on Codex, launched by `orch-review.py`.
- Update the text that describes the old review in `ARCHITECTURE.md`
  (Layer 6, the security review, the workflows entries), `README.md`,
  `docs/commands-guide.md`, `docs/manual-testing.md`,
  `docs/anthropic-ecosystem.md`, `examples/walkthrough.md`, `AGENTS.md`,
  `CLAUDE.md`, `templates/scaffold-AGENTS.md` and `tests/README.md`. Do the
  same in the skills and commands that name the old stages
  (`dispatching-*`, `executing-plans`, `finishing-a-branch`,
  `using-orchestrator`, `commands/dispatch.md`, `finish.md`, `verify.md`,
  `skills.md`).
- `tests/evals/cases/reviewer-confidence-anchoring.json`: update the text
  only; do not run it.

**Delete**

- `workflows/review-diff.js` and the `workflows/` directory,
  `skills/using-workflows/`, `tests/test-review-diff-behavior.sh`,
  `tests/validate-workflows.sh`, `tests/test-validate-workflows.sh`,
  `tests/test-workflow-distribution.sh` and
  `tests/lib/check-workflow-script.mjs`.
- `agents/orch-code-reviewer.md` and `agents/orch-security-reviewer.md`.
- `templates/code-reviewer-prompt.md`, `security-reviewer-prompt.md`,
  `spec-reviewer-prompt.md` and `review.md`.
- `scripts/providers/claude-review.py` and `tests/test-claude-provider.*`,
  once their checks live in `orch-review.py` and `tests/test-review.py`.

**Stop if** any of these is true, and report it instead of shipping a review
that cannot check its own evidence:

- nested `claude -p` cannot run inside a Claude Code session;
- `codex exec --json` does not name the served model;
- the event streams do not show command text and output (R12).

No protected file needs to change.

## What T10 measures

Use the same real diffs with about 100 or more planted defects, the same
prompt wording in every arm, and paired results tested with McNemar's test.
Score defects found by rank, false findings, tokens and minutes:

1. Full against the built-in `/code-review` and against `codex review`.
2. The provider swap (`--adversarial-provider`).
3. With and without the refuter (`--no-refuter`).
4. Split against whole diff (`--no-split`).
5. Standard with each brief (`--brief`).
6. How many findings R13 turned into notes, per provider, and how many of
   those were real defects.
7. A case where the tests contradict the spec, to measure test tampering
   and whether R16 catches it.

The outcome log also gives a running measure at no cost: the share of
findings fixed per seat, provider and rank, the refuter's drop rate, and the
dropout rate per provider.

## Not verified

- `claude --help` (2.1.282) lists every flag in R8. Not tried:
  - whether `--permission-mode dontAsk` with `--allowedTools Bash` runs Bash
    without a prompt;
  - whether nested `claude -p` works inside a Claude Code session;
  - whether Claude's Bash can write outside the copy. The help says
    `--restricted` confines the file tools. The step 8 fingerprint catches
    writes to tracked and untracked files, but not to ignored ones.
- `codex exec --help` and `codex login --help` (0.157.0) list every flag and
  command used. Not seen:
  - which `--json` event names the served model;
  - which record holds command text, output and exit code (T15 found Codex
    sessions without command records);
  - what `workspace-write` allows outside `-C`;
  - which effort values the default model accepts.
- Whether the agent's shell on Codex allows a 540-second `wait`.
- Ignored dependencies copied into a review copy may point back at the real
  checkout (editable installs, absolute paths in virtualenvs). Tests in the
  copy may then import the real checkout's code. Projects set up that way
  need `review.setup`.

## Decisions for Felipe

1. Approve the design.
2. Replace the Workflow script with one Python script, and delete
   `workflows/`, `using-workflows` and their tests.
3. On Full, the refuter runs whenever a serious finding exists, not only
   when the reviewers disagree. No fixed rule can tell whether two findings
   describe the same defect, so the refuter decides that. The cost is one
   refuter run on every Full review that has a serious finding.
4. The refuter is Claude (`opus`, `high`) on both harnesses.
5. `opus` or `fable` as the most capable Claude alias.
6. The GPT seat may write inside its copy (`workspace-write`), so it can run
   tests and try fixes. `read-only` would block both.
7. The outcome log lives outside Git, in the user's state folder.
8. Security becomes an added section in both briefs, and the separate
   security reviewer is removed.

## Sources

- Reddy et al., arXiv:2605.21537: a model approved 31.7% of its own
  behavior-changing errors.
- Xiang et al., arXiv:2607.21656: Codex reviewing Claude's code lowered the
  pass rate from 91.4% to 82.8% when reviewers could not run tests.
- Kim et al., arXiv:2506.07962: different models give the same wrong answer
  about 60% of the time when both are wrong.
- Qiu and Gill, arXiv:2608.18167: reviewer plus critic scored 43/57, against
  34 to 36 for one or two reviewers. On SWE-PRBench, the critic prompt that
  forced evidence-backed disagreement scored best (F1 0.533) and the version
  without it scored worst (0.457).
- Jin and Chen, arXiv:2603.00539: executing the proposed fix filters out
  false findings.
- Kumar et al., arXiv:2606.15689: F1 0.657 on small diffs and 0.043 on diffs
  over 150 lines.
- OpenAI, "A Practical Approach to Verifying Code at Scale": reviewers need
  the repository and the ability to run code.
- `docs/MEASUREMENTS.md` record two: the plain-language seat found 10 of 21
  catastrophic defects alone (one operator, no control arm).
