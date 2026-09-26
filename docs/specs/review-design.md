# Spec: one review design for Standard and Full

Status: T5's design (approved 2026-09-25, ticket T4, built in T5), revised by
ticket T22 on 2026-09-26 after two blind reviews and live checks of both
built-in reviewers. Felipe's decisions of 2026-09-26 are listed under
"Decided"; the revision awaits his approval of the whole.

**What T22 changes.** The reviewers are now the built-in ones: Claude Code's
`/code-review` and `codex review`. Our seats, their briefs, their schema,
parts and the T10-only options go. A new "prover" ranks each finding under
fixed floors and writes its repro. The sandboxed fix experiments, the refuter,
the decision, the outcome log and the safety rules stay, with a stricter drop
rule. A person with only one of the two CLIs can run Standard and Full.

## Goal

The 2026-09-25/26 comparison (`docs/MEASUREMENTS.md`) found that our two seats
detect no more planted defects than `/code-review` or `codex review`, and take
three to five times as long. What ours added was proof (89% of its findings
reproduced by a failing command and a patch) and a blocking decision. So the
built-ins find, and `scripts/lib/orch-review.py` proves, decides and records.
It runs every step in a fixed order and decides last, from files it wrote.
The agent starts it once. Out of scope: the spec review, and the fix.

## Running it

```
python3 scripts/lib/orch-review.py run --detach --path standard|full
    --writer claude|codex --base <ref> --spec <file> --run-dir <new dir>
    [--allow-test-changes]
python3 scripts/lib/orch-review.py wait <run-dir> --seconds 540
```

- **R1.** Unchanged: `run --detach`, then `wait` until finished. `run`
  refuses an existing run directory, and one inside the repository or any
  temporary directory. A crashed run leaves no `review.json`: incomplete.
- **R2.** The skill sets `--writer`: `claude` on Claude Code, `codex` on
  Codex. `--brief`, `--adversarial-provider`, `--split` and `--no-refuter`
  are removed.

## Steps

1. **Preflight.** T5's checks (harm ranking, submodules, `review.setup`), plus
   `git merge-base <base> HEAD` must exist, plus the providers of R3 must be
   installed and signed in (`claude auth status --json`, `codex login
   status`). Any failure: `INCOMPLETE`.
2. **Fingerprint.** Unchanged: the tree id of every tracked and untracked,
   non-ignored file, written from a temporary index.
3. **Copies.** T5's `clone` resource, with one change: the copy's HEAD is set
   to the merge-base (`git update-ref --no-deref HEAD <merge-base>`) before
   `git read-tree -u --reset <tree>`, so the whole change, committed or not, is
   the copy's uncommitted change, which both built-ins review with no target.
   The spec is copied to `<copy>/.git/orch-review/spec.md` (in no diff and no
   fingerprint). Every launch and experiment gets a fresh copy.
4. **Reviewers** in parallel (R3 to R6). 5. **Parse** (R7).
6. **Prove**: prover launches, then experiments (R8 to R13).
7. **Refuter**, Full only (R14 to R16). 8. **Fingerprint again**, submodules.
9. **Decide** (R17), write `review.json`, append the outcome row (R20).

## Providers

- **R3.** Decided by Felipe on 2026-09-26:
  - **Standard** runs one reviewer, from the provider that did not write the
    change when it is installed: `codex review` on Claude Code,
    `/code-review` on Codex. Otherwise it runs the writer's own and records
    `same_provider: true`, which `wait` prints. Reasons: a model approved
    31.7% of its own behavior-changing errors (arXiv:2605.21537); and
    `codex review` was the stronger measured reviewer (130/134 found, 1.3
    false findings per run, 6 of 14 clean cases with no finding by R7's
    parser; `/code-review`: 125/134, 5.8, 0 of 14).
  - **Full** runs two independent reviews. With both CLIs: one
    `/code-review` and one `codex review`. With one CLI: that provider's
    built-in twice, each in its own fresh copy and its own session, neither
    seeing the other's reply; `same_provider: true` is recorded, and the
    verdict line and `wait`'s summary say plainly that both reviews came
    from one provider.
  - The **prover and refuter** run on Claude when it is installed, else on
    Codex (T5's `codex exec` launch, R6 of T5: `-s workspace-write`, schema,
    MCP off, served model from the rollout).
  - **Experiments** run in `codex sandbox` when Codex is installed, else in a
    Claude runner launch (R10).
  - Lost with one CLI: the second provider's view (Standard reviews its
    own provider's work, and Full's two reviews share one provider's blind
    spots), a Claude prover and refuter on Codex-only, and on Claude-only an
    experiment runner that costs a model call.
- **R4.** Both reviewers get the comparison's instruction: "The change must
  implement the spec in `<copy>/.git/orch-review/spec.md`. Read it, and
  report every place where the change does not meet it, as well as any other
  defect." When the diff matches `ORCH_SIG_SECURITY_DIFF`, the text of
  `references/security-lens.md` follows. Each built-in keeps its own brief.
  It goes to `/code-review` as `-p` text (R5) and to `codex review` as
  `developer_instructions` (R6).

## The reviewers

- **R5. Claude reviewer.** In the copy, stdin closed, reduced environment:

  ```
  claude -p "/code-review high <probe instruction> <R4 instruction>"
    --model opus --effort high --safe-mode --restricted
    --tools Read,Grep,Glob,Bash,Agent --allowedTools Read,Grep,Glob,Bash,Agent
    --permission-mode dontAsk --output-format stream-json --verbose
    --strict-mcp-config --mcp-config '{"mcpServers":{}}'
    --session-id <new uuid> --settings <T5's Bash sandbox>
  ```

  - **The instruction goes in the `-p` text, after the level.**
    `/code-review` reviews in a subagent, and `--append-system-prompt` does
    not reach it (live: a required marker line, the probe and the
    `.git/orch-review/spec.md` path were all ignored), so the comparison's
    `code-review` arm never got its spec sentence. Text after the level
    reaches the subagent's prompt as "Review target: `...`"; it was obeyed,
    and the uncommitted change was still reviewed.
  - `--safe-mode` keeps the person's CLAUDE.md, plugins and hooks out of the
    context, but not out of reach: 33 of 83 recorded replies cite
    `~/.claude/CLAUDE.md`. `--restricted` confines file tools to the working
    directory (live: a Read of `~/.claude/CLAUDE.md` was refused and listed in
    `permission_denials`); the sandbox's `denyRead` covers `~/.claude` for Bash.
  - **Where the calls are.** The subagent's tool calls are not in the stream
    (it holds `task_started`, `init`, `task_notification` and `result`).
    They are in its transcript,
    `$CLAUDE_CONFIG_DIR/projects/*/<session-id>/subagents/agent-*.jsonl`
    (`~/.claude` by default), so the run keeps session persistence and names
    its session. No transcript: dropout.
  - **Deleting the kept session.** After reading it, the script deletes
    only that session's files: under `projects/`, it lists the directories
    one level down and needs exactly one to hold an entry named exactly
    `<session-id>`; it then removes `<that dir>/<session-id>.jsonl` and
    `<that dir>/<session-id>/`, and the same `<session-id>/` under the
    session's temporary folder (`$TMPDIR/claude-<uid>/<that dir name>/`,
    seen live). It uses no wildcard beyond that listing, removes a parent
    directory only when it is left empty, and never touches another
    session. A failure to delete, or a match count other than one, is
    recorded in `review.json` `cleanup` and printed by `wait` as a warning;
    it does not change the verdict.
  - **Sandbox proof.** In `-p` mode, settings that fail validation are
    silently ignored, so the sandbox must be shown. The transcript must hold a
    `sandbox_instructions` attachment whose configuration lists the run
    directory under read deny and the copy under write allow; and its first
    Bash call must be T5's probe, answered `ORCH-SANDBOX-ON` with no
    `ORCH-SANDBOX-OFF`, the probe file absent afterwards. A Bash call with
    `dangerouslyDisableSandbox` also fails it. Failure: dropout. The `init`
    event must show `mcp_servers: []`.
  - **Served model:** every key of the final result's `modelUsage` must be in
    the `opus` family; any other key is a substitution and a dropout. Claude
    reports no served effort; `review.json` records the requested one.
- **R6. Codex reviewer.** In the copy, stdin closed, reduced environment
  plus `RUST_LOG=warn,codex_otel=info`:

  ```
  codex review --uncommitted -c model_reasoning_effort="high"
    -c sandbox_mode="read-only" -c developer_instructions=<instruction, TOML string>
    -c mcp_servers.<name>.enabled=false ... --disable apps --disable plugins
  ```

  `codex review` has no `-m`, `-s`, `-C`, `--json` or `--output-schema`, and
  refuses a prompt with `--uncommitted`. The stderr log names several
  `conversation.id=` values (live: the `exec` parent, a `codex-auto-review`
  helper at effort `low`, and the review). The review's rollout is the one
  of them, under `$CODEX_HOME/sessions/**/rollout-*-<id>.jsonl`, whose
  `session_meta.source` is `{"subagent": "review"}`; exactly one must
  exist. Its `turn_context` gives the served `model`, `effort` and
  `sandbox_policy`. Dropout unless: model equals `config.toml`'s `model`
  (not compared when absent), effort is `high`, sandbox is `read-only`, a
  developer message carries the instruction, no `codex.tool_result` log line
  has `mcp_tool=true`, and each `codex.conversation_starts` line, when
  present, has `mcp_servers=""` (none in the 83 recorded runs; six in the
  live run). Helper models are recorded, not compared.
- **R7. Dropouts and parsing.** A reviewer is a dropout when it exits
  nonzero, runs over 3600 seconds, fails a check in R5 or R6, or its reply is
  not positively parsed:
  - `/code-review`: the final result's `result` text, not `is_error`. The
    findings are the union of every fenced JSON array whose items are all
    objects with a string `file`. A fenced array of any other shape, or no
    such array at all, is a dropout. Arrays that are all empty: zero
    findings. `line` is kept when it is an integer; `summary` and
    `failure_scenario` are the reviewer's words.
  - `codex review`: the rollout's `task_complete` `last_agent_message`, a
    JSON object with `findings`, `overall_correctness`,
    `overall_explanation` and `overall_confidence_score`. Each finding has
    `title` (`[P<n>] ...`), `body`, `confidence_score`, `priority` and
    `code_location` (`absolute_file_path`, `line_range.start`); the path is
    made relative to the copy after resolving symlinks. Zero findings only
    when `findings` is `[]` and `overall_correctness` is `"patch is
    correct"`. Dropout when the message is not that JSON, when the two
    disagree (no findings but "incorrect", findings but "correct"), or when
    the count of `- [P<n>]` lines in stdout differs from `findings`.

  A dropout makes the review `INCOMPLETE` and is never replaced; its parsed
  findings are kept, marked `from_dropout`, and not proved. Ids are
  `code-review-<n>` and `codex-review-<n>`; when one built-in runs twice,
  `code-review-1-<n>` and `code-review-2-<n>` (or `codex-review-...`). Both parsers live in
  `orch-review.py`; `review_compare.py` loads it with
  `importlib.util.spec_from_file_location` (as `orch-review.py` loads
  `orch-task-resources.py`), and counts a run whose reply a parser rejects as
  an incomplete run of that arm, left out of detection and listed with its
  reason.

## Rank and proof

- **R8. The prover.** Findings go in batches of at most 10 to prover
  launches, at most 4 running at once per review. A launch is T5's model
  launch on the R3 provider (Claude: sandbox, probe, schema, no MCP; Codex:
  `codex exec` as in T5). Its brief (`references/prover.md`) carries the
  spec, the harm ranking, `runner.test_cmd` (or "find and run the project's
  tests"), the diff, and each finding's id, file, line, priority and the
  reviewer's words. One result per id: `rank`, `kind` (`defect | spec-gap |
  scope-creep | test-tampering | test-gap | style`), `confidence`, `claim`,
  `evidence`, `mild_reason` when mild, and for serious or catastrophic
  `repro {command, patch}` or `not_runnable`. The prover ranks the
  consequence if the claim is true; truth is for the experiment and refuter.
  It cannot drop or add findings; an extra id is ignored and counted. A
  prover dropout, or a missing result for any id: `INCOMPLETE`.
- **Rank floors**, set by the script, not the prover, in this order:
  1. `defect` and `spec-gap` are at least `serious`; so is `test-tampering`
     unless `--allow-test-changes`. Only `test-gap`, `scope-creep` and
     `style` (wording, naming, maintainability) may be `mild`, and only with
     a `mild_reason`; without one they become `serious`.
  2. A `test-gap` claims only missing coverage, which a passing run cannot
     disprove: without a failing receipt 1 on the unpatched copy it is
     `mild` (`rank_lowered`); with one it keeps its serious rank.
  3. A `codex review` finding with priority 0 or 1 is at least `serious`,
     whatever step 1 or 2 gave: the floor wins over the test-gap lowering.

  Every raise and lowering is recorded with the prover's rank and reason, and
  `wait` prints each mild finding with its `mild_reason`.
- **R9. Evidence.** Unchanged: `file-line` must match the reviewed line;
  `test-run` must match a completed command in the launch's own stream.
- **R10. Fix experiments.** Receipt 1 runs `command` on the unpatched copy,
  `git apply` applies `patch`, receipt 2 runs `command` again; 600 seconds
  each, process group killed. With Codex: T5's `codex sandbox -P :workspace
  -C <copy>`. Claude-only: a runner launch (Claude, sandbox and probe, no
  other task) gets the exact command lines, the patch as
  `<copy>/.git/orch-review/patch.diff`, and each command wrapped as
  `sh -c '<cmd>'; echo ORCH-EXIT=$?`; the script takes each receipt from the
  stream's tool result, and the receipt fails when the call text differs,
  the order differs, or the marker is missing. **Reproduced** means receipt
  1 failed and receipt 2 passed. A passing receipt 1 proves only that the
  command did not target the claim: it never drops a finding, and never
  lowers a `defect`, `spec-gap` or `test-tampering` finding. (A `test-gap`
  without a failing receipt is mild by R8 step 2; the priority 0/1 floor of
  step 3 still wins over that.)
- **R11.** A finding from a built-in reviewer never becomes a note and
  never disappears; only a valid refuter `DROPPED` (R15) removes it from the
  verdict, and it stays listed in `review.json`. T5's `note` status and
  confidence floor are removed: every finding here is a reviewer finding.
  A `mild` finding is `mild` whatever its evidence or confidence (both are
  recorded) and makes the verdict `READY-WITH-FIXES` at most. A serious or
  catastrophic one is `verified` (valid evidence, and reproduced or
  `not_runnable`) or `unverified`. Both block. `READY` needs zero surviving
  findings.
- **R12.** A serious or catastrophic result the prover itself ranked, with
  neither `repro` nor `not_runnable`: `INCOMPLETE`. A rank the script raised
  (the floors) without a repro stays `unverified` and blocking. An unknown
  rank or kind becomes `serious`/`defect`.
- **R13.** T5's `not_checked` list is removed; the built-ins report none.
  Tampering is a test deleted or skipped, an assertion weakened, a test
  changed to match the code, or code that special-cases test inputs. A test
  that was never there is a gap. Raised, floored, lowered and replaced ranks
  are counted.

## The refuter

- **R14.** Full only. It runs when every reviewer and prover launch is
  complete and a serious or catastrophic finding exists, on the R3 provider
  in a fresh copy. It sees every finding with the reviewer's words,
  the prover's result and the receipts. It returns `PROMOTED`, `DROPPED` or
  `UNRESOLVED` per serious or catastrophic id, and may return `RAISE` for a
  mild one (a raise only makes the review stricter). A missing verdict or a
  refuter dropout: `INCOMPLETE`. Standard has no refuter.
- **R15.** A reproduced or `not_runnable` finding can never be dropped. For
  any other, a `DROPPED` verdict carries `scenario` (the reviewer's stated
  failure scenario, quoted) and `drop_check {command, expected_output}`. The
  refuter's own runs count for nothing, since its copy is writable. The
  script runs `command` itself, in the experiment sandbox of R10, on a fresh
  unpatched copy of the reviewed tree whose fingerprint must equal step 2's,
  600 seconds, process group killed. The drop is valid only when that run
  exits 0 and every line of `expected_output` (at least one non-empty line)
  appears as a whole line of its output; its receipt is kept as
  `drop_receipt`. A passing receipt 1, a quote, or a patch that did not apply
  is not enough. An invalid `DROPPED` counts as `UNRESOLVED`.
- **R16.** The refuter lowers a rank only with a valid `drop_check` as R15
  requires, and never below a floor of R8.

## The decision

- **R17.** One function decides from the run directory's files only.
  `INCOMPLETE` when: a needed run file is missing or unreadable, or
  `errors.json` exists; the preflight failed; a reviewer, prover, runner or
  needed refuter launch is missing or a dropout; a finding is unjudged; R12
  applies; the real checkout's fingerprint changed, or a copy's fingerprint
  at creation differs; a submodule is dirty or present. Otherwise `NOT-READY`
  if any finding blocks, `READY-WITH-FIXES` if any is `mild`, else `READY`.
  A missing reviewer is never agreement.
- **R18.** Statuses: `mild`, `verified`, `unverified`, `promoted`,
  `dropped`, `unresolved`, `unjudged` (T5's `note` is removed). Blocking:
  `verified`, `unverified`, `promoted`, `unresolved`, `unjudged`.
- **R19.** `review.json` holds the verdict and every `INCOMPLETE` reason;
  per launch the role, provider, requested and served model and effort,
  `same_provider`, and the served sandbox (`codex review`) or probe result
  (Claude); every finding with the reviewer's words, priority, the prover's
  result, floors applied, status and receipts; and the counts. Nothing a
  reviewer returned is left out.

## After the review

- **R20.** Unchanged: one row per run in
  `${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/review-outcomes.jsonl`,
  naming reviewers instead of briefs, with no claim text or code.
- **R21.** Unchanged: `record <run-dir> --dispositions <file>`, one per
  finding id: `fixed` with the check; `refuted`, with a `file-line` quote
  that `record` checks; `ignored` with a reason, for a blocking finding only
  when the person said so. It rejects omissions.

## What stays, what goes

**Stays:** `run`, `wait`, `record`; preflight, fingerprints, clones,
`review.copy_ignored`, `review.setup`, the reduced environment, the Claude
launch with sandbox and probe, `run_codex` and `codex_mcp_servers` (now only
for a Codex prover or refuter, R3), evidence checks, experiments, refuter, decision, outcome log;
`references/refuter.md`, `refuter-schema.json`, `security-lens.md`.

**Add:** `references/prover.md`, `prover-schema.json`, the two parsers, the
reviewer launches, the prover step, the Claude experiment runner.

**Remove** (nothing unused stays):

- `references/contract.md`, `adversarial.md`, `seat-schema.json`.
- In `orch-review.py`: `SEAT_RULES`, `seat_prompt`, parts, `PART_LINES` and
  `parts.json` (and `decide()`'s need for it), `not_checked` handling, the
  seat branch of `answer_shape_valid`, `SEAT_TIMEOUT` (renamed
  `LAUNCH_TIMEOUT`), and `--brief`, `--adversarial-provider`, `--split`,
  `--no-refuter` with the `experimental` marker.
- In `tests/test-review.py`: the cases for seats, briefs, parts,
  `not_checked` and the four options.
- In `review_compare.py`: its own `json_findings`, `text_findings`,
  `reply_findings`, `FILE`, `FENCED_ARRAY` and `TEXT_FIELDS`; `--large-only`;
  the `unavailable` arm handling. In `tests/test-review-compare.py:373`, the
  `full-effort-unset` part of the refused-arms case.
- In `arms.json`: `full` (its command would run the new design under the old
  name, and `run` would skip it as done), `full-swap`, `full-no-refuter`,
  `full-split`, `standard-contract`, `standard-adversarial`,
  `full-effort-unset`. Their results stay in `docs/MEASUREMENTS.md`.
- In `tests/evals/README.md`: the run examples for those arms (step 4)
  and the `full` arm in step 2.

**Change:** `skills/requesting-code-review/SKILL.md` (reviewers, providers,
removed options; the section "The native `/code-review`" goes);
`skills/receiving-code-review/SKILL.md` (ids `code-review-1`,
`codex-review-2`); `references/refuter.md` (R14 to R16);
`references/refuter-schema.json` migrates: `verdict` adds `RAISE`; each
verdict gains `scenario` (string, required for `DROPPED`) and `drop_check`
(`{command, expected_output}`, required for `DROPPED` and for a lowered
`rank`); the old `receipt-1` evidence type is removed;
`skills/cadence/CADENCE.md` lines 40 to 43 and `tests/test-cadence-docs.sh:121`
(prover, refuter, security lens); `scripts/install.sh:271`
(`prover-schema.json`); `scripts/lib/orch-signals.sh:103` (the lens goes to
the reviewers' instruction); `ARCHITECTURE.md:209`, `AGENTS.md`,
`README.md`, `docs/codex.md`, `docs/codex-provider.md`,
`docs/commands-guide.md`, `tests/README.md`, `tests/evals/README.md`.
`commands/review.md` is unchanged in use. `docs/MEASUREMENTS.md` and
`tests/evals/README.md` say the `code-review` arm never received its spec
sentence (R5); that arm in `arms.json` moves the sentence into its `-p` text.

**Claude Code path:** the skill runs the script with `--writer claude`.
**Codex path:** skill only, as in T5, `--writer codex`. The script, not the
agent, starts the built-ins.

## How we will know it works

- **Tests, free.** `tests/test-review.py` rewritten around fake `claude` and
  `codex` on `PATH`: `/code-review` streams and subagent transcripts (with
  and without the probe or the `sandbox_instructions` attachment), prover, refuter and runner
  streams, `codex review` stdout, stderr log and rollout in a fake
  `CODEX_HOME`, `codex sandbox` run directly. One case per rule, including:
  provider choice with one or both CLIs and `same_provider`; Full with one
  CLI runs that built-in twice in separate copies and sessions, neither
  given the other's reply, and says so in the verdict line; the kept
  session is deleted by its exact id only, another session's files are
  untouched, and a failed delete is reported; the exact flags;
  both parsers on the recorded shapes; an empty array before a full one;
  prose-only, conflicting or count-mismatched Codex replies; a missing or
  failed probe; an extra `modelUsage` key; every floor and their order; a
  passing receipt 1 that cannot drop; a drop without `scenario` or with a
  `drop_check` that fails on the script's fresh copy; a low-confidence mild
  test-gap that stays visible and gives `READY-WITH-FIXES`, never `READY`; the
  runner's receipts; the merge-base copy; plus T5's kept cases.
- **Scorer, free.** `tests/test-review-compare.py` covers the shared parsers;
  re-score the recorded comparison and note any count change in
  `docs/MEASUREMENTS.md`.
- **Live checks** (run 2026-09-26 with Felipe's approval; see Verified).
- **Comparison, paid, only when Felipe asks.** Arms `full-builtin` (`--path
  full --writer claude`) and `standard-builtin` (`--path standard --writer
  claude`); listed, not run: `standard-builtin-codex` (`--writer codex`) and
  `full-builtin-single` (`--path full --writer claude` with a `PATH` that
  holds `claude` but not `codex`).
  Also scored: planted serious defects that end blocking, prover rank
  against planted rank, floors applied, share reproduced, clean-case
  verdicts (old `full`: 0 of 13 passed), `INCOMPLETE` rate and reasons,
  minutes and cost.

## Limits

- The Codex read-only sandbox limits writes, not reads.
- MCP servers in `codex review` are turned off by flags; its start log line
  is not always written, so sometimes only use is seen.
- The `/code-review` probe rests on the reviewer obeying the `-p` text; one
  that skips it is a dropout. How often that happens is measured by the arm.
- `/code-review` treats the `-p` text as its "review target"; a future
  release could read it differently. The transcript check would then fail
  (no probe), giving `INCOMPLETE`.
- Parsers follow the shapes seen on 2026-09-25/26; a new shape gives
  `INCOMPLETE`, never `READY`.
- A mild `style`, `scope-creep` or `test-gap` label is the prover's
  judgment; on Standard nothing re-checks it (Full's refuter can `RAISE`).
  Such a finding still stays listed, needs a disposition (R21), and keeps
  the verdict at `READY-WITH-FIXES` at most; it can never produce `READY`.
- Whether a refuter's drop command targets the claim is judged, not checked.
- With one CLI, Full's two reviews come from one provider and may share its
  blind spots; the review says so, it does not hide it.
- Two reviewers reporting one defect give two findings, proved separately.
- Linux sandboxes, nested runs from a Codex session, and T5's other open
  items are still not verified.

## Decided (Felipe, 2026-09-26)

1. **One CLI is enough (R3).** Standard: the other provider's reviewer when
   installed, else the writer's own, with `same_provider`. Full: both
   built-ins, or with one CLI that provider's built-in twice as independent
   reviews, with `same_provider` stated in the verdict.
2. **The kept `/code-review` session** is written, read and then deleted by
   its exact id (R5); a failed delete is reported.
3. **The Claude alias stays `opus`** (decided in T4).
4. **No refuter on Standard** for now.
5. **Refuter drops need its own scenario test-run** (R15).
6. **The prover is measured on replayed replies first**, then a small live
   pilot.
7. **The `code-review` arm is re-run** with its spec sentence in the `-p`
   text; the coordinator runs it.

No open questions remain.

## Verified on 2026-09-26

Live runs, with Felipe's approval, on a copy of the comparison case
`role-permissions--01`, with the run directory under
`~/.local/state/llm-orchestrator/t22-checks/`:

- `/code-review` with R5's flags (first with `--append-system-prompt`, then
  with the instruction in the `-p` text): exit 0 in about 37 s, one fenced
  array (10 and 9 findings), `modelUsage` only `claude-opus-5-5`, `init` with
  `mcp_servers: []` and tools `Task, Bash, Glob, Grep, Read`, no permission
  denials. The stream showed no tool call. With the instruction appended to
  the system prompt, the transcript showed no probe and no read of
  `.git/orch-review/spec.md`, and a marker line was not written; given in
  the `-p` text, the marker was written, and the transcript's first Bash call
  was the probe: `touch: .../sandbox-probe: Operation not permitted` then
  `ORCH-SANDBOX-ON`; the reviewer then ran `cat .git/orch-review/spec.md`.
  The transcript's `sandbox_instructions` attachment listed the run
  directory and `~/.claude` under read `denyOnly`, and the copy under write
  `allowOnly`. The reviewer did not try to read `~/.claude/CLAUDE.md`; its
  reply said the sandbox blocks it.
- `claude -p` with `--restricted --tools Read`, asked to Read
  `~/.claude/CLAUDE.md`: refused, "is outside <copy>; --restricted confines
  the file tools to the working directory", and listed in
  `permission_denials`.
- `codex review` with R6's flags: exit 0 in 56 s; the review rollout
  (`source` `{"subagent": "review"}`) has `turn_context` model
  `gpt-6-astra`, effort `high`, sandbox `read-only`, approval `never`; a
  developer message carries the instruction; its final message has
  `findings`, `overall_confidence_score`, `overall_correctness` ("patch is
  incorrect") and `overall_explanation`, with 2 findings of keys `body`,
  `code_location`, `confidence_score`, `priority`, `title`; stdout had 2
  `[P1]` lines. Stderr named three conversations, the first the `exec`
  parent, one `codex-auto-review` at effort `low`; six
  `codex.conversation_starts` lines, all `mcp_servers=""`; all tool results
  `mcp_tool=false`.
- The Claude experiment runner (R10), `--restricted --tools Bash` and the
  sandbox: the stream showed the three calls verbatim, with results
  `...Operation not permitted` / `ORCH-SANDBOX-ON`, `ORCH-EXIT=3` and
  `ORCH-EXIT=0`; exit 0 in 12 s.

Without calling a model:

- `claude --help` (2.1.283) lists every flag in R5; `--restricted` confines
  file tools to the working directories and drops Bash unless `--tools`
  names it; `-p` says settings files that fail validation are silently
  ignored; `--safe-mode` keeps "built-in tools and plugins".
- `codex review --help` (0.156.1; T5 checked 0.157.0): `-c`,
  `--strict-config`, `--enable`, `--disable`, `--uncommitted`, `--base`,
  `--commit`, `--title`, PROMPT; no `-m`, `-s`, `-C`, `--json`,
  `--output-schema`. `codex sandbox --help` lists `-P`, `-C`.
- Signed-out `CODEX_HOME` (refused as unauthorized, no model answered): a
  prompt with `--uncommitted` is a usage error; `--strict-config` accepts
  `sandbox_mode` and rejects an unknown key; a failed review exits 1 with
  empty stdout.
- Recorded comparison, 83 runs per arm: each `/code-review` reply has
  exactly one fenced array, all parse, all `modelUsage` keys are
  `claude-opus-5-5`, 33 cite `~/.claude/CLAUDE.md`. Every `codex review`
  rollout ends in the R7 JSON object; 6 have `[]` with "patch is correct"
  (all clean cases), 77 have findings with "patch is incorrect"; stdout's
  `[P<n>]` count equals `findings` in all 83; every stderr has
  `conversation.id=`, none a `conversation_starts` line; all 295 tool results
  have `mcp_tool=false`.
- A copy made as in step 3 shows a committed change, a modified file and an
  untracked file as its uncommitted change; its tree equals the fingerprint.

Not verified: whether `-c sandbox_mode` changes anything (`codex review`
served `read-only` with and without it); a Bash `cat ~/.claude/CLAUDE.md`
inside `/code-review` (the sandbox configuration denies it; nothing tried
it); the runner with a real repro and patch; Linux; nested runs from a
Codex session.

Sources: T5's (arXiv:2605.21537, 2607.21656, 2506.07962, 2608.18167,
2603.00539, 2606.15689) and `docs/MEASUREMENTS.md`, 2026-09-25/26.
