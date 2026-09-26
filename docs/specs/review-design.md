# Spec: one review design for Standard and Full

Status: T5's design (approved 2026-09-25, ticket T4, built in T5), revised by
ticket T22 on 2026-09-26. The revision awaits Felipe's approval.

**What T22 changes.** The reviewers are now the built-in ones: Claude Code's
`/code-review` and `codex review`. Our own seats, their briefs, their schema,
parts and the T10-only options go. A new Claude "prover" ranks each finding
and writes its repro. Everything after that stays: the sandboxed fix
experiments, the refuter, the decision, the outcome log and the safety rules.

## Goal

The 2026-09-25/26 comparison (`docs/MEASUREMENTS.md`) found that our two
seats detect no more planted defects than `/code-review` or `codex review`,
and take three to five times as long. What ours added was proof (89% of its
findings reproduced by a failing command and a patch) and a blocking
decision. So the built-ins find, and `scripts/lib/orch-review.py` proves,
decides and records. It still runs every step in a fixed order and decides
last, from files it wrote. The agent starts it once.

Out of scope: the spec review before coding, and the fix itself.

## Running it

```
python3 scripts/lib/orch-review.py run --detach --path standard|full
    --writer claude|codex --base <ref> --spec <file> --run-dir <new dir>
    [--allow-test-changes]
python3 scripts/lib/orch-review.py wait <run-dir> --seconds 540
```

- **R1.** Unchanged: `run --detach`, then `wait` until finished. `run`
  refuses an existing run directory, and one inside the repository or any
  temporary directory. A run that crashes leaves no `review.json` and is
  reported as incomplete. `--allow-test-changes` as in R13.
- **R2.** The skill sets `--writer`: `claude` on Claude Code, `codex` on
  Codex. `--brief`, `--adversarial-provider`, `--split` and `--no-refuter`
  are removed.

## Steps

1. **Preflight.** As in T5, except that every path now needs both CLIs
   installed and signed in (`claude auth status --json`, `codex login
   status`): the prover and refuter are Claude, experiments run in `codex
   sandbox`, and one reviewer is always the other provider (R3). The harm
   ranking, submodule and `review.setup` checks are unchanged. `git
   merge-base <base> HEAD` must exist. Any failure: `INCOMPLETE`.
2. **Fingerprint.** Unchanged: the tree id of every tracked and untracked,
   non-ignored file, written from a temporary index.
3. **Copies.** Unchanged (`clone` resource kind, `--no-hardlinks`, copy
   fingerprint must match), with one change: the copy's HEAD is set to the
   merge-base (`git update-ref --no-deref HEAD <merge-base>`) before `git
   read-tree -u --reset <tree>`. The whole change, committed and not, is then
   the copy's uncommitted change, which is what both built-ins review with no
   target. The spec file is copied to `<copy>/.git/orch-review/spec.md`,
   which is in no diff and no fingerprint. Every reviewer, prover, refuter and
   experiment gets a fresh copy.
4. **Reviewers** run in parallel (R3 to R6).
5. **Parse** each reply into findings (R7).
6. **Prove.** Prover launches, then the fix experiments (R8 to R13).
7. **Refuter.** Full only (R14 to R16).
8. **Fingerprint again**, and the submodule check.
9. **Decide** (R17), write `review.json`, append the outcome row (R20).

## The reviewers

- **R3.** Standard runs one reviewer: the provider that did not write the
  change. On Claude Code that is `codex review`; on Codex it is
  `/code-review`. Reasons: a model approved 31.7% of its own
  behavior-changing errors (arXiv:2605.21537), and on Claude Code this also
  picks the stronger measured reviewer (`codex review`: 130/134 found, 1.3
  false findings per run, 3 of 14 clean cases silent; `/code-review`:
  125/134, 5.8, 0 of 14). Full runs both. There is no `--brief`: a built-in
  uses its own review brief.
- **R4.** Both reviewers get the same extra instruction, as in the
  comparison: "The change must implement the spec in
  `<copy>/.git/orch-review/spec.md`. Read it, and report every place where
  the change does not meet it, as well as any other defect." When the diff
  matches `ORCH_SIG_SECURITY_DIFF`, the text of `references/security-lens.md`
  follows it.
- **R5. Claude reviewer.** In the copy, stdin closed:

  ```
  claude -p "/code-review high" --model opus --effort high --safe-mode
    --append-system-prompt <instruction> --output-format json
    --permission-mode dontAsk --allowedTools Read,Grep,Glob,Bash,Agent
    --strict-mcp-config --mcp-config '{"mcpServers":{}}'
    --no-session-persistence --settings <T5's Bash sandbox>
  ```

  These are the comparison's flags, which ran 83 times, plus T5's
  `--settings` Bash sandbox (writes only in the copy, no network,
  `failIfUnavailable`, `denyRead` of the run directory and credential
  folders). `--safe-mode` turns off the person's plugins, hooks, CLAUDE.md
  and MCP servers but keeps built-in skills, so `/code-review` runs.
  - Served model: the keys of the final result's `modelUsage`. At least one
    must be in the `opus` family; all are recorded. Claude reports no served
    effort, so `review.json` records effort as requested only.
  - It cannot run T5's sandbox probe: `/code-review` takes no prompt of ours
    (see Limits).
- **R6. Codex reviewer.** In the copy, stdin closed, with
  `RUST_LOG=warn,codex_otel=info`:

  ```
  codex review --uncommitted -c model_reasoning_effort="high"
    -c sandbox_mode="read-only" -c developer_instructions=<instruction as TOML string>
    <MCP off: -c mcp_servers.<name>.enabled=false for each configured server,
     --disable apps --disable plugins>
  ```

  `codex review` has no `-m`, `-s`, `-C`, `--json` or `--output-schema`, and
  refuses a prompt together with `--uncommitted`, so the instruction goes in
  `developer_instructions` and the sandbox in `sandbox_mode`. Its reviewer
  only reads and runs commands, so read-only fits (it ran the tests
  read-only in the comparison).
  - The thread id is `conversation.id=` in the stderr log. The rollout
    `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl` gives, from its
    `turn_context`, the served `model`, `effort` and `sandbox_policy`. The
    requested model is `model` in `config.toml` (not compared when absent);
    effort must be `high`; `sandbox_policy.type` must be `read-only`; and a
    developer message must carry the instruction.
  - `codex review` logs no `codex.conversation_starts` line (none in 83
    runs), so T5's "MCP servers started" check cannot be used. Instead, a
    `codex.tool_result` log line with `mcp_tool=true` makes it a dropout.
- **Environment.** T5's reduced environment for every launch, unchanged.
- **R7. Dropouts and parsing.** A reviewer is a dropout when it exits
  nonzero, runs over 3600 seconds, has no served model, or fails a check in
  R5 or R6, or when its reply cannot be parsed:
  - `/code-review`: the reply is the result's `result` text, which must not
    be `is_error`. Its findings are the items of the first fenced JSON array
    whose items are all objects with a string `file` (the scorer's
    `json_findings`; 83 of 83 comparison replies had one). `line` is kept when
    it is an integer; `summary` and `failure_scenario` are the claim. An empty
    array is zero findings. No such array: dropout.
  - `codex review`: stdout. A finding is a line
    `- [P<n>] <title> — <path>:<start>-<end>` and the indented lines under
    it (249 of 249 such lines in the comparison matched). The path is made
    relative to the copy (compared after resolving symlinks, since macOS
    reports `/private/var/...`); the line is `<start>`; `P<n>` is kept as
    `priority`. Empty stdout, or any `[P<n>]` that is not on such a line, is
    a dropout. A reply with no `[P<n>]` line is zero findings only when no
    line that starts with a list marker or heading names a path with a line
    number; otherwise it is a dropout.

  A dropout makes the review `INCOMPLETE`, is never replaced by another
  provider or model, and its parsed findings are kept, marked
  `from_dropout`, and not proved. Finding ids are `code-review-<n>` and
  `codex-review-<n>`. The two parsers live in `orch-review.py`, and
  `review_compare.py` imports them, so the scorer and the review read replies
  the same way.

## Rank and proof

- **R8. The prover.** Built-ins give no rank, kind or repro. For each
  reviewer, its findings go in batches of at most 10 to Claude prover
  launches, up to 4 at a time. A launch is T5's Claude launch unchanged:
  `claude -p --output-format stream-json --verbose --model opus --effort high
  --json-schema <prover schema> --safe-mode --restricted --tools
  Read,Grep,Glob,Bash ...`, the Bash sandbox, no MCP, and the sandbox probe
  as its first Bash call. Its brief (`references/prover.md`) carries the
  spec, the harm ranking, `runner.test_cmd` (or "find and run the project's
  tests"), the diff, and each finding's id, file, line, priority and the
  reviewer's words. It returns one result per id: `rank`, `kind` (`defect |
  spec-gap | scope-creep | test-tampering | test-gap`), `confidence`,
  `claim`, `evidence`, and for serious or catastrophic either `repro
  {command, patch}` or `not_runnable`.
  - The prover ranks the consequence **if the claim is true**, by the harm
    ranking. Whether it is true is settled by the experiment and the
    refuter, not by the prover. It cannot drop a finding or add one; an id it
    did not receive is ignored and counted.
  - A `codex review` finding marked `[P0]` or `[P1]` is at least `serious`.
    The brief says so, and a lower rank is raised and counted (`rank_floor`).
  - A prover dropout (T5's rules for Claude launches: exit, timeout, no
    result of the schema's shape, served model, failed probe, MCP loaded), or
    a result missing for any id, makes the review `INCOMPLETE`.
- **R9. Evidence.** Unchanged: `file-line` must match the reviewed line;
  `test-run` must match a completed command in the prover's own stream.
- **R10. Fix experiments.** Unchanged: receipt 1, `git apply`, receipt 2,
  each under `codex sandbox -P :workspace -C <copy>`, 600 seconds, process
  group killed. Reproduced means receipt 1 failed and receipt 2 passed.
- **R11.** Unchanged. A `mild` finding with invalid evidence or confidence
  below 0.8 is a `note`. A serious or catastrophic one is `verified` (valid
  evidence, and reproduced or `not_runnable`) or `unverified`. Both block.
- **R12.** A serious or catastrophic prover result with neither `repro` nor
  `not_runnable` makes the review `INCOMPLETE`. Exceptions: a rank the script
  raised (test tampering under R13, or the `[P0]`/`[P1]` floor) stays
  `unverified` and blocking. An unknown rank becomes `serious`, with no
  exception.
- **R13.** T5's `not_checked` list is removed: the built-ins report none.
  The test rules stay, applied to the prover's `kind`:
  - When the task does not allow test changes, `test-tampering` is raised to
    `serious`. Tampering: a test deleted or skipped, an assertion weakened, a
    test changed to match the code, or code that special-cases test inputs.
  - A `test-gap` without `repro` is lowered to `mild` (`rank_lowered`). With
    a `repro` it keeps its rank (`gap_with_repro`) and is run and judged like
    a `defect`. A test that was never there is a gap; one the change weakened
    or rewrote is tampering.

  Raised, floored, lowered and replaced ranks are counted.

## The refuter

- **R14 to R16.** Unchanged, with "both seats" read as "every reviewer and
  prover launch". Full only; it runs when every reviewer and prover launch is
  complete and a serious or catastrophic finding exists. It is Claude
  (`opus`, `high`) in a fresh copy, and sees each non-note finding with the
  reviewer's words, the prover's result and the receipts. A reproduced or
  `not_runnable` finding can never be dropped; `DROPPED` needs the finding's
  own passing receipt 1; rank goes down only on the same evidence; an
  unjudged finding or a refuter dropout gives `INCOMPLETE`. Standard has no
  refuter, as in T5.

## The decision

- **R17.** One function decides from the run directory's files only.
  `INCOMPLETE` when: a needed run file is missing or unreadable, or
  `errors.json` exists; the preflight failed; a reviewer, prover or needed
  refuter launch is missing or a dropout; a finding is unjudged; R12
  applies; the real checkout's fingerprint changed, or a copy's fingerprint
  at creation differs; a submodule is dirty or present. Otherwise
  `NOT-READY` if any finding blocks, `READY-WITH-FIXES` if any is `mild`,
  else `READY`. A missing reviewer is never agreement.
- **R18.** Statuses unchanged; blocking: `verified`, `unverified`,
  `promoted`, `unresolved`, `unjudged`.
- **R19.** `review.json` holds the verdict and every reason for
  `INCOMPLETE`; per launch the role (reviewer, prover, refuter), provider,
  requested and served model and effort, and for `codex review` its served
  sandbox policy; every finding with the reviewer's own words, its
  `priority`, the prover's result, its status and receipts; the counts (raw,
  notes, invalid evidence, below the floor, raised, floored, lowered or
  replaced ranks, patches that did not apply, ids the prover added). Nothing
  a reviewer returned is left out.

## After the review

- **R20.** Unchanged: every run appends one row to
  `${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/review-outcomes.jsonl`,
  now naming reviewers instead of briefs, with no claim text or code.
- **R21.** Unchanged: `record <run-dir> --dispositions <file>`, one
  disposition per finding id: `fixed` with the check; `refuted`, with a
  `file-line` quote that `record` checks; `ignored` with a reason, and for a
  blocking finding only when the person said so. It rejects omissions.

## What stays, what goes

**Stays:** `orch-review.py` `run`, `wait` and `record`; preflight,
fingerprints, clones, `review.copy_ignored` and `review.setup`, the reduced
environment, the Claude launch with sandbox and probe (now used by the
prover and refuter), evidence checks, fix experiments, refuter, decision,
outcome log; `references/refuter.md`, `refuter-schema.json`,
`security-lens.md`.

**Add:** `references/prover.md` and `prover-schema.json`; the two reply
parsers; the reviewer launches (R5, R6); the prover step.

**Remove** (nothing unused stays):

- `references/contract.md`, `adversarial.md`, `seat-schema.json`.
- In `orch-review.py`: `SEAT_RULES`, `seat_prompt`, parts and `PART_LINES`,
  the `codex exec` seat launch (`run_codex`) and its MCP-start check,
  `not_checked` handling, and the options `--brief`,
  `--adversarial-provider`, `--split`, `--no-refuter` with their
  `experimental` marker.
- In `tests/test-review.py`: the cases for seats, briefs, parts, `codex
  exec`, `not_checked`, and the four removed options.
- In `tests/evals/review-compare/arms.json`: `full` (its command would now
  run the new design under the old name, and `run` would skip it as already
  done), `full-swap`, `full-no-refuter`, `full-split`, `standard-contract`,
  `standard-adversarial`, `full-effort-unset`. Their results stay in
  `docs/MEASUREMENTS.md`; the raw results stay in the ignored `work/`.

**Change:**

- `skills/requesting-code-review/SKILL.md`: which reviewers run, that every
  path needs both CLIs, the removed options. Its section "The native
  `/code-review`" goes: it is now a reviewer.
- `skills/receiving-code-review/SKILL.md`: the example ids become
  `code-review-1`, `codex-review-2`.
- `references/refuter.md`: "two reviewers" becomes the reviewers and the
  prover; it sees the reviewer's words and the prover's result.
- `skills/cadence/CADENCE.md` lines 40 to 43 link the prover, refuter and
  security lens; `tests/test-cadence-docs.sh:121` checks those names.
- `scripts/install.sh:271`: `seat-schema.json` becomes `prover-schema.json`.
- `scripts/lib/orch-signals.sh:103`: the comment says the lens is appended to
  the reviewers' instruction.
- `ARCHITECTURE.md:209`, `AGENTS.md`, `README.md`, `docs/codex.md`,
  `docs/codex-provider.md`, `docs/commands-guide.md`, `tests/README.md`,
  `tests/evals/README.md` ("The review comparison"): the new shape.
- `commands/review.md`: unchanged in use (`[base] [--full]`).

**Claude Code path:** the agent runs the skill, which runs the script with
`--writer claude`. **Codex path:** skill only, as in T5; the agent runs the
same script with `--writer codex`. On both, the script, not the agent, starts
the built-ins.

## How we will know it works

- **Tests, free.** `tests/test-review.py` rewritten around fake programs on
  `PATH`. Fake `claude` answers `-p "/code-review high"` with a scripted
  `--output-format json` result, and prover or refuter launches with a
  scripted stream. Fake `codex` answers `review` with scripted stdout, a
  stderr log line with `conversation.id=` and a rollout in a fake
  `CODEX_HOME`, and runs `sandbox` commands directly. One case per rule,
  including: Standard on Claude Code runs only `codex review`, on Codex only
  `/code-review`; Full runs both; the exact flags of R5 and R6; both parsers
  on the comparison's reply shapes; an unparseable reply, an `is_error`
  result, a stray `[P1]`, and a bare list with no `[P<n>]` each give
  `INCOMPLETE`; served model, effort or sandbox mismatch is a dropout; an
  `mcp_tool=true` line is a dropout; a missing instruction in the rollout is
  a dropout; a prover that skips an id gives `INCOMPLETE`; the `[P1]` floor;
  the copy's HEAD is the merge-base and its uncommitted change is the whole
  change; plus T5's kept cases (evidence, experiments, refuter, fingerprints,
  submodules, `record`).
- **Scorer, free.** `tests/test-review-compare.py` covers the shared
  parsers; re-score the recorded comparison with them and note in
  `docs/MEASUREMENTS.md` any change to the `codex-review` counts.
- **Comparison, paid, only when Felipe asks.** Two new arms, `full-builtin`
  (`--path full --writer claude`) and `standard-builtin` (`--path standard
  --writer claude`, so `codex review` plus proof). Scored as before, and
  also: planted serious defects that end blocking, the prover's rank against
  the planted rank, the share reproduced, verdicts on clean cases (the old
  `full` passed 0 of 13), `INCOMPLETE` rate and reasons, minutes and cost.
  Detection should match the built-ins' own arms; the question is whether
  proof keeps real defects blocking and stops blocking clean changes.

## Limits

- `/code-review`'s Bash runs under the `--settings` sandbox, but that cannot
  be probed from inside it, and whether `/code-review`'s own steps obey it is
  not yet tried. The prover and refuter keep the probe.
- The `codex review` read-only sandbox limits writes, not reads: it can read
  the run directory, including the other reviewer's reply.
- No MCP start log for `codex review`: MCP servers are turned off by flags,
  and only their use (`mcp_tool=true`) is detected.
- The parsers follow the reply shapes seen on 2026-09-25/26 (claude 2.1.28x,
  codex 0.156/0.157). A shape change gives `INCOMPLETE`, never `READY`, until
  the parser is updated.
- Two reviewers reporting one defect give two findings, each proved on its
  own; no fixed rule merges them.
- Linux sandboxes, nested runs from a Codex session, and T5's other open
  items are still not verified.

## Open questions for Felipe

1. **Standard with only one CLI installed.** Every path now needs both
   `claude` and `codex`. Recommend: keep it; without both, preflight gives
   `INCOMPLETE` and names the missing CLI. No quiet fallback to the writer's
   own provider.
2. **Refuter on Standard.** `/code-review` averaged 5.8 findings per run
   that were not planted defects (most were true, per the audit), so on Codex
   Standard more serious findings may stay `unverified` and block.
   Recommend: no refuter on Standard for now; decide from the
   `standard-builtin` numbers.
3. **The `[P0]`/`[P1]` floor.** Recommend: keep it; it stops the prover
   ranking a finding Codex called urgent as mild, and costs one rule.
4. **Measure proof on replayed replies first.** A test-only replay (fake
   reviewers that print the recorded 2026-09-25/26 replies, a real prover)
   would measure the proof step on the exact findings already scored, for
   about half the cost. Recommend: yes, then a small live pilot of both
   new arms.
5. **Still open from T5:** whether the Claude alias is `opus` or `fable`.

## Verified on 2026-09-26 (no model called)

- `claude --help` (2.1.283) lists every flag in R5 and R8; `--safe-mode`
  keeps "built-in tools and plugins".
- `codex review --help` (codex-cli 0.156.1; T5 verified 0.157.0) lists
  `-c`, `--strict-config`, `--enable`, `--disable`, `--uncommitted`,
  `--base`, `--commit`, `--title` and a PROMPT, and no `-m`, `-s`, `-C`,
  `--json` or `--output-schema`. `codex sandbox --help` still lists `-P`, `-C`.
- With a signed-out `CODEX_HOME`: `codex review --uncommitted "<prompt>"` is
  refused with a usage error; under `--strict-config`, `-c
  sandbox_mode="read-only"` and `"workspace-write"` are accepted and an
  unknown key is rejected; the run then fails with exit 1, empty stdout and
  the error on stderr (the request was refused as unauthorized; no model
  answered).
- From the comparison's recorded outputs (83 runs each): every
  `/code-review` reply parses with `json_findings`, every `modelUsage` names
  only `claude-opus-5-5`, no subagent was spawned; 249 of 249 `[P<n>]` lines
  match the R7 header (P1 54, P2 190, P3 5), and the silent clean replies
  have no `[P<n>]`; every stderr has `conversation.id=`, none has
  `codex.conversation_starts`, and all 295 tool results have
  `mcp_tool=false`.
- One recorded `codex review` rollout: `turn_context` has model
  `gpt-6-astra`, effort `high` (config default `xhigh`, so the override
  applies), sandbox `read-only` with no `sandbox_mode` in `config.toml`,
  approval `never`; a developer message carries the spec sentence.
- A clone made as in step 3, with HEAD moved to the merge-base, shows a
  committed change, a modified file and an untracked file together as its
  uncommitted change, and its index tree equals the fingerprint.

Not verified: `/code-review` under the `--settings` sandbox; that `-c
sandbox_mode` changes what `codex review` serves (R6 checks the rollout
anyway); an empty-array `/code-review` reply (no clean case was silent).

Sources: T5's (arXiv:2605.21537, 2607.21656, 2506.07962, 2608.18167,
2603.00539, 2606.15689) and `docs/MEASUREMENTS.md`, 2026-09-25/26.
