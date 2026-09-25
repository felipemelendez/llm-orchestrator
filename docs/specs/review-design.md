# Spec: one review design for Standard and Full

Status: proposed 2026-09-25 (ticket T4). Not built. T5 builds it only after
Felipe approves this file.

## Goal

One review design for both paths and both harnesses. Standard runs one
reviewer. Full runs two blind reviewers with different briefs on two
providers, then a refuter when a serious finding exists. One Python script,
`scripts/lib/orch-review.py`, runs every step in a fixed order. It runs the
proposed fixes itself and decides the verdict last, from files it wrote or
read itself. The agent starts it once, so no step can be skipped.

Out of scope: the spec review before coding, the fix itself, and the legacy
procedure (T6).

## Why one script

A Workflow script cannot run commands or read files. The checks that decide
whether a review counts would have to run after it returns, so the verdict
would come before them. It also runs only on Claude Code.

`orch-review.py` starts `claude -p` and `codex exec` itself and runs on both
harnesses. `codex review` and Codex custom agents are not used as seats.
`codex review` uses Codex's own review brief, and custom agents cannot run in
a chosen copy. Neither would give the GPT seat the same brief, in the same
kind of copy, as the Claude seat.

## Running it

```
python3 scripts/lib/orch-review.py run --detach --path standard|full
    --writer claude|codex --base <ref> --spec <file> --run-dir <new dir>
    [--brief contract|adversarial] [--adversarial-provider claude|codex]
    [--split] [--no-refuter]
python3 scripts/lib/orch-review.py wait <run-dir> --seconds 540
```

- **R1.** On both harnesses the agent starts `run --detach`, then repeats
  `wait` until it reports that the run finished. `run` refuses an existing
  run directory. A run that crashes leaves no `review.json`: the skill
  reports it as incomplete, and a new run starts from the beginning.
- **R2.** The skill sets `--writer`: `claude` on Claude Code, `codex` on
  Codex. The last four options exist only for T10.

## Steps

1. **Preflight.** Each CLI the path needs is installed and signed in
   (`claude auth status --json`, `codex login status`). Every path needs
   `codex`, because fix experiments run under `codex sandbox` (R10). The
   project has a `LAWS.md` with a harm ranking, or the shipped
   `skills/cadence/references/laws.md` template's ranking is used. No
   submodule, checked recursively with `git submodule foreach --recursive
   git status --porcelain`, has uncommitted changes. Any failure ends the
   run as `INCOMPLETE`, and nothing is substituted.
2. **Fingerprint.** Every tracked and untracked, non-ignored file of the
   real checkout is added to a temporary index (`GIT_INDEX_FILE=<tmp>`,
   `git read-tree HEAD`, `git add -A`), and `git write-tree` is recorded.
   That tree id is the reviewed state.
3. **Copies.** Each copy is a disposable local clone in task-owned scratch,
   registered in `scripts/lib/orch-task-resources.py` as a new resource
   kind, `clone`:
   - It is made with `git clone --local --no-checkout`, then
     `git read-tree -u --reset <tree>`. The copy has its own `.git`, its
     HEAD at the real HEAD, and the uncommitted change.
   - The paths listed in `cadence.json` `review.copy_ignored` are then
     copied in, using copy-on-write where the file system supports it, and
     `review.setup` runs if it is set.
   - The copy's own fingerprint must equal the one from step 2 when it is
     created.
   - Submodules are present only at their recorded commits.
   - Removal: the task helper deletes a `clone` only when it is owned by
     this task, has no `.orch-active` mutex, and its `.git` holds no ref,
     stash or worktree beyond those recorded when the clone was made.
     Otherwise it keeps the clone and reports why. (Today
     `orch-task-resources.py` refuses to remove any copy that contains a
     repository.)

   Each seat launch, each fix experiment and the refuter get a fresh copy.
4. **Parts.** By default each seat reviews the whole change in one launch.
   `--split` (T10 only) groups whole files in diff order into parts of at
   most 150 changed lines; a file over 150 lines is its own part. Each part
   is then reviewed in its own launch, with the list of all changed files
   and their line counts.
5. **Seats.** All seat launches run in parallel (R3 to R7).
6. **Validate, and run the fixes** (R8 to R13).
7. **Refuter.** Full only, under R14.
8. **Fingerprint again.** Recompute step 2 on the real checkout, and repeat
   the recursive submodule check from step 1.
9. **Decide** (R17), write `review.json`, append the review row (R20).

## Seats, providers and models

- **R3.** Standard: one seat, with the contract brief, on the writer's
  provider, and no refuter.
- **R4.** Full: a contract seat and an adversarial seat. Neither sees the
  other's findings or the implementer's report. The adversarial seat runs on
  the provider that did not write the change (GPT on Claude Code, Claude on
  Codex); the contract seat runs on the other. The refuter is always Claude.
- **R5.** Claude launch: `claude -p --output-format stream-json --verbose
  --model opus --effort high --json-schema <schema> --safe-mode --restricted
  --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash
  --permission-mode dontAsk --permission-prompts none --strict-mcp-config
  --mcp-config '{"mcpServers":{}}' --no-session-persistence`. It runs in the
  copy, with the prompt on stdin. It starts with no MCP servers, so the
  person's connectors (for example claude.ai Slack or Gmail) are neither
  visible nor usable. If the stream's `system` `init` event has a non-empty
  `mcp_servers`, the launch is a dropout (R7).
  The served model is the assistant messages' `model` field. It must belong
  to the model family of the requested alias.
- **R6.** GPT launch: `codex exec --json -s workspace-write -C <copy>
  -c model_reasoning_effort="high" --output-schema <schema> -o <file> -`.
  - It never uses `--ephemeral` and never passes `-m`.
  - The requested model is `model` in `$CODEX_HOME/config.toml`
    (`CODEX_HOME` defaults to `~/.codex`), the CLI's default.
  - The served model and effort are the `model` and `effort` fields of
    `$CODEX_HOME/sessions/**/rollout-*-<thread_id>.jsonl`. `thread_id` comes
    from the stream's `thread.started` event.
  - If `config.toml` names no model, the served model is recorded but not
    compared.
- **R7.** A launch is a **dropout** when any of these holds:
  - it exits nonzero;
  - it has no final result;
  - no served model can be read;
  - the served model differs from the requested one.

  A dropout is never replaced by another provider, model or brief.

**Configuration.**

- Models are always the alias (`opus`) or the CLI default, at effort
  `high`; there is no override. The review records requested and served
  values.
- The seat prompt carries `runner.test_cmd`. When that field is empty, the
  prompt says "no test command is configured; find and run the project's
  tests".
- The seat prompt carries the "Harm ranking" section of the project's
  `LAWS.md`, or of the shipped template `skills/cadence/references/laws.md`
  when the project has no `LAWS.md`.

**Why GPT holds the adversarial brief on Claude Code.** The adversarial seat
looks for what the writer missed, and a model approved 31.7% of its own
behavior-changing errors (arXiv:2605.21537). Two results count against this
choice:

- the one cross-model study found that Codex reviewing Claude's code lowered
  the pass rate from 91.4% to 82.8% when the reviewers could not run tests
  (arXiv:2607.21656);
- different models give the same wrong answer about 60% of the time when
  both are wrong (arXiv:2506.07962).

In this design, fixes are run and evidence is checked, which the first study
lacked. T10 tests the swap.

## Findings and evidence

- **R8.** A seat returns `{findings, not_checked}`.
  - A finding has `file`, `line`, `rank` (`catastrophic | serious | mild`),
    `kind` (`defect | spec-gap | scope-creep | test-tampering`),
    `confidence`, `claim` and `evidence`.
  - A `serious` or `catastrophic` finding also has either `repro {command,
    patch}` or `not_runnable` (a reason). `command` shows the failure;
    `patch` is the proposed fix as a unified diff.
  - The script gives each finding the id `<seat>-<part>-<n>` (part `1`
    without `--split`).
- **R9.** Evidence is one of two kinds:
  - `file-line {file, line, quote}` is valid when that line exists in the
    copy and `quote` equals it, ignoring spaces at either end.
  - `test-run {command, output}` is valid when the seat's own event stream
    shows a completed command with exactly that text, and every line of
    `output` appears as a whole line of that command's output. `output` must
    have at least one non-empty line.
- **R10. Fix experiments are run by the script, not by a model.** For each
  `repro`:
  1. The script runs `command` in a fresh copy and records receipt 1.
  2. It applies `patch` with `git apply`.
  3. It runs `command` again and records receipt 2.

  All three run under `codex sandbox -C <copy>` with writes allowed only in
  the copy and the system temporary directory, and no network. This is
  chosen over accepting only commands that start with `runner.test_cmd`,
  because a test command can still write anywhere the person can, and many
  projects have no `test_cmd`; the sandbox limits writes whatever the
  command is. If the sandbox cannot start, the experiment is not run, the
  receipt says so, and the finding is not reproduced.

  A receipt holds the command, exit code, output, duration and the copy's
  fingerprint. The finding is **reproduced** when receipt 1 fails and
  receipt 2 passes. A patch that does not apply, or a run longer than 600
  seconds, is recorded in the receipt.
- **R11.** A `mild` finding becomes a `note` when its evidence is invalid or
  its confidence is below 0.8 or missing. A `serious` or `catastrophic`
  finding never becomes a note:
  - it is `verified` when its evidence is valid and it was either reproduced
    or marked `not_runnable`;
  - otherwise it is `unverified`.

  Both states block, and both go to the refuter.
- **R12.** A `serious` or `catastrophic` finding with neither `repro` nor
  `not_runnable` makes the review `INCOMPLETE`.
- **R13.** Each `not_checked` item is `{category, text}`, with `category`
  one of `tests-not-run`, `files-not-read` or `claim-unverified`. Seats list
  only what they did not check. Every item is returned verbatim and makes
  the review `INCOMPLETE`.
  - When the task does not allow test changes, a `test-tampering` finding is
    raised to `serious`. Test tampering means a test was deleted or skipped,
    an assertion was weakened, a test was changed to match the code, or code
    special-cases test inputs.
  - A rank outside the allowed values becomes `serious`.

  Raised and replaced ranks are counted.

## The refuter

- **R14.** The refuter runs on Full when both seats are complete and at
  least one finding is `serious` or `catastrophic`.
  - It gets every non-note finding from both seats, with their receipts.
  - It returns one verdict per serious or catastrophic finding: `PROMOTED`,
    `DROPPED` or `UNRESOLVED`.
  - A finding with no verdict is `unjudged`. An unjudged finding, or a
    refuter dropout, makes the review `INCOMPLETE`.
  - `--no-refuter` skips the refuter (T10 only), and the review is marked
    `experimental`.
- **R15.** A reproduced finding and a `not_runnable` finding can never be
  dropped. For any other finding, `DROPPED` is valid only when it does one
  of these:
  - cites the seat's own receipt 1, and receipt 1 passed: the claimed
    failure did not happen. A patch that did not apply, or a receipt 2 that
    failed, proves nothing and cannot support a drop;
  - gives a `file-line` quote that is valid under R9, and explains why that
    line contradicts the claim.

  An invalid `DROPPED` counts as `UNRESOLVED`.
- **R16.** The refuter may lower a rank only where R15 would allow a drop,
  with the same evidence. A reproduced or `not_runnable` finding keeps its
  rank. The refuter never raises a rank.

## The decision

- **R17.** One function decides, after steps 1 to 8, from the files in the
  run directory only.
  - The verdict is `INCOMPLETE` if any of these holds:
    - the preflight failed;
    - a seat part or a needed refuter run is missing or a dropout;
    - a finding is unjudged;
    - R12 or R13 applies;
    - the real checkout's fingerprint at step 8 differs from step 2, or a
      seat, refuter or repro copy's fingerprint at creation differs from
      step 2 (seat copies may change while seats work, and repro copies
      change when the patch is applied; receipt 2 records that
      fingerprint);
    - a submodule is dirty at step 8.
  - Otherwise it is `NOT-READY` if any finding is blocking.
  - Otherwise it is `READY-WITH-FIXES` if any finding is `mild`.
  - Otherwise it is `READY`.
- **R18.** Each finding has exactly one status:
  - `note`;
  - `mild`: valid evidence and a confidence of at least 0.8;
  - `verified` or `unverified`: serious or worse, before the refuter or
    without one;
  - `promoted`, `dropped`, `unresolved` or `unjudged`: serious or worse,
    after the refuter.

  The blocking statuses are `verified`, `unverified`, `promoted`,
  `unresolved` and `unjudged`.
- **R19.** `review.json` holds:
  - the verdict and every reason for `INCOMPLETE`;
  - for each launch, the provider, the brief, and the requested and served
    model and effort;
  - every finding with its status, receipts and the refuter's evidence;
  - the `not_checked` items;
  - the counts: raw findings, notes, invalid evidence, below the floor,
    raised or replaced ranks, and patches that did not apply.

  Nothing a seat returned is left out.

## After the review

- **R20.** Every run, including an `INCOMPLETE` one, appends one review row
  to
  `${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/review-outcomes.jsonl`.
  The row holds the run id, date, repository name, path, writer, providers
  and briefs, requested and served models, parts, diff lines, verdict,
  incomplete reasons, counts, duration and reported cost. It holds no claim
  text or code.
- **R21.** The agent handles the findings with `receiving-code-review`, then
  runs `orch-review.py record <run-dir> --dispositions <file>`. The file
  gives every finding one disposition:
  - `fixed`, with the check that failed before and passes after;
  - `refuted`, with evidence under R9;
  - `ignored`, with a reason. A blocking finding may be `ignored` only when
    the person said so.

  `record` appends one row per finding: run id, finding id, seat, provider,
  rank, kind, status and disposition. It rejects a file that leaves any
  finding out.

## What the script cannot do

- Ask the person anything while it runs.
- Fix the change. Fixing stays with the agent.
- Keep Claude's Bash inside the copy. `--restricted` confines only the file
  tools. Step 8 detects writes to tracked and untracked files of the real
  checkout, but not writes to ignored files.
- Cover uncommitted changes inside submodules. A dirty submodule stops the
  review at step 1.
- Make copied ignored dependencies safe. An editable install or an absolute
  path in a virtualenv can make tests in the copy import the real checkout's
  code. Such projects need `review.setup`.
- Decide by a fixed rule whether two findings describe the same defect. The
  refuter judges each finding.

## What T5 builds

**Add**

- `scripts/lib/orch-review.py` (`run`, `wait`, `record`). It takes over the
  model checks in `scripts/providers/claude-review.py`.
- The `clone` resource kind and its removal rule in
  `scripts/lib/orch-task-resources.py` (step 3).
- In `skills/requesting-code-review/references/`:
  - `contract.md`: spec compliance, and "which test would still pass with
    its mechanism removed", from `reviewer-spec.md`;
  - `adversarial.md`: `reviewer-plain.md` plus the test-tampering list;
  - `refuter.md`: the laws from `skills/cadence/references/refuter.md`
    plus R14 to R16;
  - `security-lens.md`: the checklist from `orch-security-reviewer.md`,
    added to both seat briefs when the diff matches
    `ORCH_SIG_SECURITY_DIFF`;
  - the JSON schemas.
- `tests/test-review.py` and its `.sh` shim, using fake `claude` and `codex`
  binaries and fake rollouts, with one case per rule. The cases include:
  - the refuter runs when a serious finding exists and is skipped otherwise;
  - a missing seat gives `INCOMPLETE`, never `READY`;
  - a dropout is never replaced, and a served-model mismatch is a dropout;
  - a serious finding with invalid evidence stays blocking;
  - an invented `DROPPED` leaves the finding blocking;
  - a patch that does not apply leaves the finding unverified;
  - a write to the real checkout gives `INCOMPLETE`;
  - a dirty submodule gives `INCOMPLETE`.

  These tests replace `tests/test-review-diff-behavior.sh`,
  `tests/validate-workflows.sh` and the other workflow tests named in T5's
  "Done when". The coordinator updates that list.

**Change**

- `skills/requesting-code-review/SKILL.md`: R1, R2 and the verdicts.
- `skills/receiving-code-review/SKILL.md`: harm ranks and R21.
- `commands/review.md`: `/llm-orchestrator:review [base] [--full]`, which
  saves no file in the repository.
- `skills/cadence/SKILL.md` and `CADENCE.md`:
  - the proportional Full steps 3 and 4 point to `requesting-code-review`;
  - the "separate workflow" paragraph goes;
  - "The project files" documents `review.copy_ignored` and
    `review.setup`.

  These keys are optional, and `cadence-init.sh` writes none of them. The
  legacy steps 2 and 2b, and `reviewer-spec.md`, `reviewer-plain.md` and
  `refuter.md` (with its `review-diff.js` paragraph), stay for T6.
- `agents/orch-spec-reviewer.md`: kept only for brainstorming's review of a
  spec document. Its description says so, and its `review-diff.js` and
  workflow text goes. It keeps its Issues block, which
  `scripts/hooks/subagent-stop.sh` still expects.
- `scripts/lib/codex-cadence-read-command.py:66` and
  `tests/test-codex-adapter.sh` section A17 (lines 400 to 409): remove the
  `claude-review.py` exemption and its cases. `orch-review.py run` needs no
  exemption, because its command line names no locked path (it finds
  `LAWS.md` and `cadence.json` itself).
- `tests/test-codex-verify-gate.sh:150`: use `python3 tests/test-review.py`
  as the example command.
- Remove the deleted names from `scripts/hooks/subagent-stop.sh`,
  `scripts/install.sh`, `docs/install.md:177`, `templates/dispatch-prompt.md`
  (drop the code-reviewer role), `tests/validate-skills.sh`,
  `tests/test-install.sh`, `tests/smoke.sh` and
  `tests/test-protocol-hooks.sh`.
- Update the description of the old review in `docs/codex.md`,
  `docs/codex-provider.md`, `ARCHITECTURE.md` (Layer 6, the security review,
  the workflows entries), `README.md`, `docs/commands-guide.md`,
  `docs/manual-testing.md`, `docs/anthropic-ecosystem.md`,
  `examples/walkthrough.md`, `AGENTS.md`, `CLAUDE.md`,
  `templates/scaffold-AGENTS.md` and `tests/README.md`.
- Do the same in the skills and commands that name the old stages:
  `dispatching-*`, `executing-plans`, `finishing-a-branch`,
  `using-orchestrator`, and `commands/dispatch.md`, `finish.md`, `verify.md`
  and `skills.md`.
- `tests/evals/cases/reviewer-confidence-anchoring.json`: update the text
  only; do not run it.

**Delete**

- The `workflows/` directory, `skills/using-workflows/`,
  `tests/test-review-diff-behavior.sh`, `tests/validate-workflows.sh`,
  `tests/test-validate-workflows.sh`, `tests/test-workflow-distribution.sh`
  and `tests/lib/check-workflow-script.mjs`.
- `agents/orch-code-reviewer.md` and `agents/orch-security-reviewer.md`.
- `templates/code-reviewer-prompt.md`, `security-reviewer-prompt.md`,
  `spec-reviewer-prompt.md` and `review.md`.
- `scripts/providers/claude-review.py` and `tests/test-claude-provider.*`.

**Proposed ruling.** `LAWS.md` and `cadence.json` are protected, and both
still list `workflows/`. Felipe applies this text:

`Ruling 4 (<date>, Felipe): the plugin ships no Workflow scripts. In LAWS.md section 2, "agents/, commands/, templates/, workflows/ and output-styles/" becomes "agents/, commands/, templates/ and output-styles/". In docs/llm-orchestrator/cadence.json, "workflows" is removed from src_roots and "workflows/**" from prod_globs. LOCK.sha256 is rewritten under ORCH_CADENCE_UNLOCK=1.`


## What T10 measures

Use the same real diffs with about 100 or more planted defects and the same
prompt wording in every arm. Compare paired results with McNemar's test.
Score defects found by rank, false findings, tokens and minutes:

1. Full against the built-in `/code-review` and against `codex review`.
2. The provider swap (`--adversarial-provider`).
3. With and without the refuter (`--no-refuter`).
4. Parts of 150 lines against the whole change (`--split`).
5. Standard with each brief (`--brief`).
6. Serious findings left `unverified`, per provider, and how many of them
   were real.
7. A case where the tests contradict the spec (test tampering, R13).

The outcome log also gives a running measure at no cost: the share of
findings fixed per seat, provider and rank, the refuter's drop rate, and the
dropout rate per provider.

## Verified and not verified

Verified on 2026-09-25:

- `claude --help` (2.1.282) lists every flag in R5.
- `codex exec --help` and `codex login --help` (0.157.0) list every flag and
  command in R6 and step 1.
- A local 0.157.0 `codex exec` rollout contains `"model":"gpt-6-astra"` and
  `"effort":"high"`.
- Run from inside a Claude Code session, `claude -p "<prompt>" --model opus
  --tools Bash --permission-mode dontAsk --output-format json` ran a Bash
  command with no prompt, returned `modelUsage` naming `claude-opus-5-5`,
  and reported no permission denials.
- `claude -p ... --output-format stream-json --verbose` shows each Bash call
  as an assistant `tool_use` block with `input.command`, and its result as a
  user `tool_result` block with the output text and `is_error`. The final
  `result` event carries `modelUsage` with the served model. R9 reads these.
- With `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`, the
  `system` `init` event has `mcp_servers: []` and lists no claude.ai
  connectors. Without these flags, a nested `claude -p` loaded the person's
  connectors.
- `codex exec --json -s read-only --skip-git-repo-check` (0.157.0) emits
  `item.completed` events of type `command_execution` with the fields
  `command`, `aggregated_output`, `exit_code` and `status`. R9 reads these.
- `git clone --local --no-checkout`, followed by `git read-tree -u --reset
  <tree>` with a tree written from a temporary index that held tracked and
  untracked changes, gave the clone the full uncommitted content. A local
  clone brings the loose objects with it.

Not verified:

- the full R5 flag set together (`--safe-mode`, `--restricted`,
  `--json-schema`, `--allowedTools`); the checks above used a smaller set;
- what `workspace-write` allows outside `-C`;
- the `codex sandbox` options that allow writes only in the copy and the
  temporary directory with no network (`codex sandbox --help` in 0.157.0
  lists `-C`, `-c`, `--permission-profile` and
  `--sandbox-state-disable-network`, not a direct write-root flag);
- that the agent's shell on Codex allows a 540-second `wait`.

## Decided (pending Felipe's confirmation)

1. One Python script replaces the Workflow script. `workflows/`,
   `using-workflows` and their tests are deleted, with Ruling 4 above.
2. On Full, the refuter runs whenever a serious finding exists, not only
   when the reviewers disagree.
3. The refuter is always Claude (`opus`, `high`).
4. The GPT seat may write inside its own copy (`workspace-write`).
5. The outcome log lives outside Git, in the user's state folder.
6. Security is a section added to both briefs, and the separate security
   reviewer is removed.

Still open: whether the Claude alias is `opus` or `fable`.

## Sources

- Reddy et al., arXiv:2605.21537: a model approved 31.7% of its own
  behavior-changing errors.
- Xiang et al., arXiv:2607.21656: the pass rate fell from 91.4% to 82.8%
  when Codex reviewed Claude's code without running tests.
- Kim et al., arXiv:2506.07962: different models give the same wrong answer
  about 60% of the time when both are wrong.
- Qiu and Gill, arXiv:2608.18167: reviewer plus critic scored 43/57, against
  34 to 36 for one or two reviewers. On SWE-PRBench, the critic prompt that
  forced evidence-backed disagreement scored best (F1 0.533), and the
  version without it scored worst (0.457).
- Jin and Chen, arXiv:2603.00539: executing the proposed fix filters out
  false findings.
- Kumar et al., arXiv:2606.15689: F1 0.657 on small diffs, and 0.043 on
  diffs over 150 lines.
- OpenAI, "A Practical Approach to Verifying Code at Scale": reviewers need
  the repository and the ability to run code.
- `docs/MEASUREMENTS.md` record two: the plain-language seat found 10 of 21
  catastrophic defects alone (one operator, no control arm).
