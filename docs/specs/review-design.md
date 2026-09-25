# Spec: one review design for Standard and Full

Status: proposed 2026-09-25 (ticket T4). Not built. T5 builds it only after
Felipe approves this file.

## Goal

The plugin has one review design. Standard runs one reviewer. Full runs two
blind reviewers with different briefs, on two providers, and a refuter only
when a fixed rule says so. The same finding format, evidence rule and
accounting apply on both paths, on Claude Code and on Codex, with or without
the Workflow tool. `workflows/review-diff.js` and the cadence's separate
blind-pair steps are replaced, not kept beside it.

Out of scope: the spec review before coding (cadence Full step 1), the fix
itself, and the legacy procedure (T6 deletes it).

## Terms

- **Seat**: one reviewer role. Full has two: the **contract seat** and the
  **adversarial seat**. The **refuter** is not a seat; it judges findings and
  originates none.
- **Brief**: the text that tells a seat what to do. Each brief is one file
  (see "What T5 builds") and is sent verbatim to whichever provider runs it.
- **Writer provider**: the provider whose agent wrote the change. On Claude
  Code it is `claude`; on Codex it is `codex`.
- **Part**: a slice of the diff of at most about 150 changed lines (R10).
- **Review copy**: a disposable copy of the reviewed tree that one seat, for
  one part, may read, build and run tests in.
- **Controller**: the main agent. It prepares inputs, runs the review, fixes,
  and records outcomes.

## The rules

Each rule is written so a test can check it. "The script" means the
Workflow script; the written fallback must give the same result for the same
inputs (R28).

### Paths

- **R1.** Standard runs exactly one seat, the contract seat, on the writer
  provider, and never runs the refuter.
- **R2.** Full runs the contract seat and the adversarial seat. They never
  see each other's findings, the implementer's report or its conclusions.
  Each re-derives the change from its review copy.
- **R3.** Full never runs a third seat. The refuter runs only under R16.

### Findings and evidence

- **R4.** Every seat returns one object per part, in this shape (JSON
  Schema, kept in one file and embedded in the script):

  ```json
  {
    "verdict": "READY | READY-WITH-FIXES | NOT-READY",
    "not_checked": ["what the seat could not check, and why"],
    "findings": [{
      "id": "string, unique within this seat and part",
      "file": "repo-relative path",
      "line": "42 or 42-50",
      "rank": "catastrophic | serious | mild",
      "kind": "defect | spec-gap | scope-creep | test-tampering",
      "confidence": 0.0,
      "claim": "state -> wrong output",
      "scene": "given <state>; when <action>; expect <observable>",
      "fix": "the smallest concrete change, with file:line",
      "evidence": {"kind": "file-line | test-run | fix-run", "detail": "..."}
    }]
  }
  ```

  Ranks are the project's harm ranking (`LAWS.md`), not
  critical/important/minor. A project without a harm ranking uses the three
  classes in this repository's `LAWS.md` section 1.
- **R5. The evidence rule.** A finding has evidence only when:
  - `file-line`: `detail` contains `<path>:<line>` (a path, a colon, digits);
  - `test-run` or `fix-run`: `detail` has a line starting `$ ` (the command
    run in the review copy) and a line starting `=> ` (the observed result).
    `fix-run` means the proposed fix was applied in the review copy and the
    check was run before and after it.

  A finding without evidence is a **note**: it is returned, never blocks,
  never triggers the refuter, and is counted in `unsupported`. The rule is
  the same for every provider, so every GPT finding on Claude-written code
  must pass it (and the reverse).
- **R6.** A finding with `confidence` below 0.8 is a note, counted in
  `below_floor`. A missing or non-numeric confidence counts as below the
  floor and is also counted in `bad_confidence`. Reviewers are told to report
  everything; the script filters.
- **R7.** A `rank` outside the enum is lower-cased; if still invalid it
  becomes `serious` and is counted in `coerced`. Coercion always moves toward
  more scrutiny.
- **R8.** A `test-tampering` finding below `serious` is raised to `serious`
  when the controller's `tests_may_change` input is false, and counted in
  `coerced`. Test tampering means: a test deleted or skipped, an assertion
  weakened, a test changed to match the code, or production code that
  special-cases test inputs.
- **R9.** A `serious` or `catastrophic` finding with an empty `scene` keeps
  its rank and is counted in `no_scene`.

### Input size

- **R10.** The controller splits the diff into parts before the review:
  whole files in diff order until the next file would pass 150 changed lines;
  a file over 150 lines is split at hunk boundaries; a single hunk over 150
  lines is its own part and is listed in `oversize`. Each seat reviews each
  part in a separate agent. Every part agent also gets the list of all
  changed files with their line counts, so it knows what else changed.

### Accounting: a missing review is never a pass

- **R11.** A part result that is null, not an object, or has no `findings`
  array is **missing**. A seat with any missing part makes the review
  incomplete.
- **R12.** A non-object element inside `findings` is dropped and counted in
  `malformed`; its part counts as missing (R11).
- **R13.** A provider dropout (not installed, not signed in, refused, rate
  limited, timed out, wrong or unrecorded served model) is a missing part.
  Nothing replaces it: the script never runs the other provider, another
  model or another brief in its place.
- **R14.** When the review is incomplete the refuter does not run, the
  verdict is `INCOMPLETE`, and every finding the present seats returned is
  still in the return, marked `unverified`.
- **R15.** An empty diff dispatches no agent and returns `INCOMPLETE` with
  `missing: [{"reason": "no-diff"}]`.

### When the refuter runs

- **R16. The fixed rule.** After both seats are complete, the script
  matches findings across seats: a contract finding and an adversarial
  finding match when they name the same file and their line ranges, each
  widened by 5 lines, overlap. Each finding matches at most one, the closest
  first, ties by order. Notes (R5, R6) take no part. Then:
  - a matched pair with the same rank is **agreed**; it needs no refuter;
  - a matched pair with different ranks is **disputed**;
  - an unmatched `serious` or `catastrophic` finding is **one-sided serious**;
  - an unmatched `mild` finding is **one-sided mild**; it needs no refuter;
  - if one seat's verdict is `NOT-READY` and the other's is `READY`, every
    unmatched finding of the `NOT-READY` seat is also disputed.

  The refuter runs if and only if the review is complete and the disputed
  plus one-sided serious set is not empty. It is sent only that set.
- **R17.** The refuter returns one verdict per assigned finding:
  `PROMOTED`, `DROPPED` or `UNRESOLVED`, with a rank and evidence under R5.
  A `PROMOTED` or `DROPPED` verdict without valid evidence counts as
  `UNRESOLVED` and is counted in `malformed_verdicts`. The burden is on the
  refuter to drop: `UNRESOLVED` keeps the finding at its higher rank.
- **R18.** The refuter may lower a rank only with evidence and never raises
  one; a raise is ignored and counted in `malformed_verdicts`. For a disputed
  pair with no usable verdict, the higher rank stands.
- **R19.** A verdict with an unknown or duplicated finding id is discarded
  and counted; the finding it failed to address is **unjudged**. An unjudged
  finding, or a refuter agent that returns null, makes the review incomplete
  and leaves those findings `unverified`, never dropped.
- **R20.** At most 4 refuter agents run; findings are split into that many
  contiguous batches. The script logs the batch count.

### Seats, providers and models

- **R21.** The two Full seats run on different providers: one Claude seat,
  one GPT seat run through the Codex CLI. The **adversarial seat runs on the
  provider that did not write the change**: GPT on Claude Code, Claude on
  Codex. The `adversarial_provider` input can override this for T10's swap
  test; the return records which provider held which brief.

  Why: the adversarial seat's job is to find what the writer did not think
  of. Errors of the same model are correlated (arXiv:2506.07962) and a model
  approves 31.7% of its own behavior-changing errors (arXiv:2605.21537), so
  the seat that hunts blind spots should not share the writer's. The contract
  seat checks the change against written requirements, where a shared model
  matters less. The one cross-model study found GPT reviewing Claude's code
  lowered the pass rate when reviewers could not run tests
  (arXiv:2607.21656); here the GPT seat can run tests in its copy (R26) and
  every finding must pass R5, and T10 tests the swap.
- **R22.** Models are named by alias or CLI default so they stay current:
  Claude seats and the refuter use `opus` at effort `high`; the GPT seat
  passes no `-m`, so it gets the Codex CLI's configured default, at
  `model_reasoning_effort="high"`. A project may name other values in
  `cadence.json` `codex_providers`; the requested value is recorded either
  way.
- **R23.** The return records, per seat and part, the requested model and
  effort and the model actually served. For the GPT seat and for a Claude
  seat run through `claude-review.py`, the served model comes from the
  runner's receipt; a receipt without served-model evidence is a dropout
  (R13), as `claude-review.py` already treats `unverified_model`. For Claude
  agents inside the Workflow script, the controller reads the served model
  from the agents' transcripts after the run (unconfirmed; see "Not yet
  confirmed").
- **R24.** Before a Full review starts, the controller runs both providers'
  `doctor` commands. If either is not ready, the review is not started and is
  reported as incomplete with the reason. It is never run with one provider.

### Review copies and the real checkout

- **R25.** Each (seat, part) and each refuter batch gets its own review copy,
  made with `skills/cadence/scripts/orch-task-resources.py` and containing
  exactly the reviewed tree, including uncommitted and untracked files. The
  controller records the digest of `git diff` in each copy and in the real
  checkout; they must match before the review starts.
- **R26.** Seats and the refuter may read the whole repository, build and
  run tests, but only in their review copy. The GPT seat runs with
  `codex exec -s workspace-write -C <copy>`. Claude agents are told to start
  every command with `cd <copy> &&`; nothing enforces this (no `cwd`).
- **R27.** The controller records `git status --porcelain` and the `git
  diff` digest of the real checkout before and after the review. Any change
  makes the review incomplete and is reported to the person as a write to
  the real checkout.

### One rule, two implementations

- **R28.** The matching, accounting and refuter decision exist twice: inside
  the Workflow script (which cannot import files) and in
  `scripts/lib/orch-review.py` for the written fallback. A test runs the same
  fixture cases through both and requires identical returns.

### The return value

- **R29.** The script and `orch-review.py finalize` return:

  ```json
  {
    "path": "standard | full",
    "verdict": "READY | READY-WITH-FIXES | NOT-READY | INCOMPLETE",
    "complete": true,
    "missing": [{"seat": "...", "part": "...", "reason": "..."}],
    "seats": [{"seat": "contract | adversarial", "provider": "claude | codex",
               "brief": "contract | adversarial",
               "parts": [{"part": "...", "model_requested": "...",
                          "effort": "high", "model_served": "... | null",
                          "receipt": "path | null"}]}],
    "refuter": {"ran": false, "reason": "agreed | disputed | incomplete | standard",
                "assigned": 0, "batches": 0},
    "findings": [{"...R4 fields": "", "seats": ["contract"],
                  "status": "agreed | promoted | unresolved | one-sided-mild | dropped | note | unverified",
                  "blocking": true}],
    "counts": {"raw": 0, "malformed": 0, "below_floor": 0, "bad_confidence": 0,
               "unsupported": 0, "coerced": 0, "no_scene": 0,
               "malformed_verdicts": 0, "unjudged": 0, "oversize": 0}
  }
  ```

  - `verdict` is `INCOMPLETE` whenever `complete` is false, however clean the
    present findings are.
  - A finding is `blocking` when its rank is `serious` or `catastrophic` and
    its status is `agreed`, `promoted`, `unresolved` or `unverified`.
  - Otherwise `NOT-READY` if any finding is blocking; `READY-WITH-FIXES` if
    only `mild` findings with status other than `note` or `dropped` remain;
    else `READY`.
  - On Standard, the single seat's findings that pass R5 and R6 get status
    `unverified` and `refuter.reason` is `standard`.
  - Dropped findings and notes stay in `findings`; nothing a seat returned is
    silently removed.

## The Workflow script (Claude Code)

`workflows/review-change.js`, run as `/llm-orchestrator:review-change`. Only
the main agent can start it (the Workflow tool is not given to subagents).

**Inputs** (`args`), all prepared by the controller in shell, because the
script has no file or shell access:

| Input | Content |
|---|---|
| `path` | `standard` or `full` |
| `spec` | The spec text, or for Standard the acceptance criteria |
| `summary` | A short plain description of what the change should do, written by the controller from the spec, never from the implementer's report |
| `harm_ranking` | The project's harm ranking text |
| `briefs` | `{contract, adversarial, refuter, security_lens}` texts, read from the brief files |
| `pressure_areas` | `file:symbol` list for the contract seat only |
| `security_sensitive` | Boolean from `ORCH_SIG_SECURITY_DIFF`; `true` appends the security lens to both briefs |
| `tests_may_change`, `changed_tests` | Whether the task allows test changes; the changed test files with their git status |
| `parts`, `file_summary` | From `orch-review.py split` (R10) |
| `copies` | Review copy path per seat and part, and per refuter batch (R25) |
| `adversarial_provider` | Optional; defaults to `codex` on Claude Code (R21) |
| `codex` | `{runner, schema_path, out_dir, model, effort}` for the GPT seat |

**Agent calls.** Every call names `model` and `effort` (LAWS section 3).

| Call | agentType | model | effort | schema | Count |
|---|---|---|---|---|---|
| Contract seat (Claude) | `llm-orchestrator:orch-spec-reviewer` | `opus` | `high` | seat (R4) | one per part |
| Adversarial seat (GPT) | `llm-orchestrator:orch-codex-runner` | `sonnet` | `low` | runner result | one per part |
| Refuter (Claude) | `llm-orchestrator:orch-refuter` | `opus` | `high` | verdicts (R17) | 0, or 1 to 4 |

With `adversarial_provider: "claude"` the seats swap: the adversarial seat is
`llm-orchestrator:orch-adversarial-reviewer` (`opus`, `high`) and the
contract brief goes to the Codex runner. The seats run with `pipeline()` over
parts; the refuter decision needs every part of both seats, so it follows a
barrier. Standard runs only the contract row.

**Return:** R29. `log()` is display only; the controller builds its report
from the return value.

## Running the GPT seat from the script

The script cannot run commands, so the GPT seat is an `agent()` whose only
job is to run the runner and hand back its result:

1. `python3 <runner> start --role <brief> --cwd <copy> --prompt-file <file>
   --schema <schema_path> --output <file> --receipt <file>` starts
   `codex exec --json -s workspace-write -C <copy>
   -c model_reasoning_effort="high" --output-schema <schema> -o <last>` in
   the background and returns at once. The prompt goes on stdin.
2. `python3 <runner> wait --receipt <file> --seconds 540` blocks for up to
   9 minutes (under the Bash tool's 10-minute limit) and prints the status;
   the agent repeats it until the status is final.
3. `python3 <runner> show --receipt <file>` prints `{status, reason,
   receipt, output_sha256, model_served, result}`; the agent returns that
   object through the runner schema, unchanged.

The runner (`scripts/providers/codex-review.py`) follows
`scripts/providers/claude-review.py`: `doctor`, a mode-0600 receipt with
requested and served model, input digests, exit status and output digest,
no model substitution, and a nonzero status for every dropout kind.

**Risks, and how the design handles each:**

- The runner agent could change the findings it copies. After the run the
  controller runs `orch-review.py check-runner`, which recomputes the output
  file's digest and requires it to equal both the receipt's and the digest of
  the result the script received. A mismatch makes the review incomplete.
- A permission prompt or an auto-mode refusal can stop the runner's Bash
  command inside a workflow. The agent then returns null or a dropout, which
  is a missing part (R13). The plugin cannot ship an allow rule; the docs
  name the rule a person can add.
- Claude Code's sandbox can block the Codex binary's network or credential
  store. The `doctor` preflight (R24) runs in the same environment and stops
  the review before it starts.
- The person's Codex hooks, including this plugin's Codex completion check,
  run inside the seat's `codex exec` and may add one continuation turn. This
  costs time, not correctness; T5 checks it.
- The configured Codex default may not be OpenAI's most capable model. The
  served model is recorded (R23) and shown in the report; the person decides.

## The written fallback

Used on Codex (which has no Workflow tool) and on Claude Code when the
Workflow tool is missing or errors. It lives in the `requesting-code-review`
skill and calls the same scripts, so its return matches R29 (R28).

1. Prepare the same inputs as the script's table, run both `doctor` commands
   (Full), and record the real checkout's state (R27).
2. For each part, start the two seats as separate background processes or
   agents, each with its own review copy and its brief, and save each result
   as a file:
   - On Codex: the contract seat is `codex-review.py run` (writer provider)
     and the adversarial seat is `claude-review.py run`.
   - On Claude Code without Workflow: the contract seat is an `Agent`
     dispatch of `orch-spec-reviewer` with `model: opus`, told to end with
     the R4 JSON; the adversarial seat is `codex-review.py run`, run directly
     by the controller.
3. `orch-review.py compare <results>` validates, counts and applies R16. It
   prints the refuter decision and the assigned findings.
4. If the refuter runs: on Codex, `codex-review.py run --role refuter`; on
   Claude Code, an `Agent` dispatch of `orch-refuter` with `model: opus`.
5. `orch-review.py finalize` writes the R29 return. The controller reports
   from that file only.

**Codex's own review tools.** `codex review` and `codex exec review` use
Codex's built-in review brief with custom instructions added, so the brief
would not be the same text on both providers; they stay out of the seats and
are a baseline arm in T10. Read-only custom agents (`.codex/agents/*.toml`,
`sandbox_mode = "read-only"`) cannot run tests or a proposed fix and inherit
the parent's working directory, so they cannot use a review copy; they are
not used. A separate `codex exec` process per seat gives a fresh context, a
chosen directory and a receipt.

On Codex, `claude-review.py` exposes only Read, Grep and Glob, so the Claude
seat there cannot run code; its findings carry `file-line` evidence, and
executed evidence comes from the refuter. (Decision 6 below.)

## What the script cannot do

- Ask the person anything mid-run.
- Run a writing agent in a chosen directory: `agent()` has no `cwd`, and
  `isolation: 'worktree'` branches from the default branch, not the reviewed
  tree. Review copies are made by the controller before the run, and staying
  inside them is a prompt rule (R26), checked afterwards (R27).
- Read files, run commands or check receipts; the controller does that
  before and after.
- Fix anything. Fixing stays with the main agent.

## After the review

- **R30.** The controller handles each finding with `receiving-code-review`:
  it checks a finding before acting on it, and refutes one only with evidence
  under R5.
- **R31.** The controller records one disposition per finding: `fixed` (with
  the check that failed before and passes after), `refuted` (with evidence),
  or `ignored` (with a reason). A blocking finding may be `ignored` only when
  the person says so in the conversation; the record names that.
- **R32.** `orch-review.py record` appends one line per finding to
  `${XDG_STATE_HOME:-$HOME/.local/state}/llm-orchestrator/review-outcomes.jsonl`,
  outside Git: date, repository name, path, part count, diff lines, seat,
  provider, brief, model requested and served, rank, kind, evidence kind,
  status, refuter verdict and disposition. It stores no claim text or code.
  A review without dispositions for every finding is reported as not
  recorded.

## What T5 builds

**Add**

- `workflows/review-change.js`: the script above.
- `scripts/providers/codex-review.py`: the Codex runner (`doctor`, `start`,
  `wait`, `show`, `run`), with offline tests using a fake `codex` binary
  (`tests/test-codex-provider.py` and its `.sh` shim).
- `scripts/lib/orch-review.py`: `split`, `compare`, `finalize`,
  `check-runner`, `record`.
- `skills/requesting-code-review/references/`: `contract.md`,
  `adversarial.md`, `refuter.md`, `security-lens.md` and
  `finding-schema.json`. The contract brief takes the spec-compliance and
  "which test would still pass with its mechanism removed" parts of
  `reviewer-spec.md` and `orch-spec-reviewer.md`. The adversarial brief takes
  `reviewer-plain.md` and adds the test-tampering list (R8). The refuter
  brief takes `refuter.md`'s laws and R17 to R19. The security lens takes the
  checklist from `orch-security-reviewer.md`. No legacy report rules
  (templates, stamps, ledger rows, seat-rules packets) move over.
- `agents/orch-adversarial-reviewer.md` and `agents/orch-refuter.md`
  (`model: opus`, `effort: high`, tools Read, Grep, Glob, Bash), and
  `agents/orch-codex-runner.md` (`model: sonnet`, `effort: low`, tools Bash,
  Read). Reviewer agent files hold only standing rules; the brief comes in
  the prompt.
- `tests/test-review-change-behavior.sh`: runs the script against stubbed
  workflow globals, one case per rule R1 to R29 that the script implements,
  including: refuter runs on disagreement; skipped on agreement; a missing
  review returns `INCOMPLETE`, never `READY`; a dropout is never replaced.
- `tests/test-review-rule-parity.sh`: R28, on shared fixtures under
  `tests/fixtures/review/`.

**Change**

- `skills/requesting-code-review/SKILL.md`: the one procedure for Standard
  and Full, the script path and the written fallback for both harnesses.
- `skills/receiving-code-review/SKILL.md`: harm ranks instead of
  Critical/Important/Minor, the evidence rule for refuting, R31 and R32.
- `commands/review.md`: `/llm-orchestrator:review [base] [--full]` runs
  `requesting-code-review` on Standard, or Full with `--full`. It no longer
  saves a review file in the repository.
- `agents/orch-spec-reviewer.md`: becomes the contract seat. It may run code
  in its review copy, and loses "do not re-run what the implementer ran" and
  the Issues-block output.
- `scripts/providers/claude-review.py`: default effort `high` (today `max`);
  roles `contract`, `adversarial`, `refuter`.
- `skills/cadence/CADENCE.md` proportional Full steps 3 and 4, and
  `skills/cadence/SKILL.md`: point to `requesting-code-review` and drop the
  statement that `review-diff.js` is separate. T6 removes the legacy steps.
- `skills/using-workflows/SKILL.md`, `ARCHITECTURE.md` (Layer 6, the
  security review section, the workflows entries), `README.md`,
  `docs/codex-provider.md` (both runners; the Claude runner is required for
  Full on Codex), `docs/commands-guide.md`, `docs/manual-testing.md`,
  `docs/anthropic-ecosystem.md`, `examples/walkthrough.md`, `AGENTS.md`,
  `CLAUDE.md`, `templates/scaffold-AGENTS.md`, `tests/README.md`, and every
  skill and command that names the old stages or files (`dispatching-*`,
  `executing-plans`, `finishing-a-branch`, `using-orchestrator`,
  `commands/dispatch.md`, `finish.md`, `verify.md`, `skills.md`).
- `scripts/hooks/subagent-stop.sh` and `scripts/install.sh`: agent and
  workflow file names.
- `tests/validate-skills.sh` (model and effort policy for the new agents),
  `tests/validate-workflows.sh`, `tests/test-workflow-distribution.sh`,
  `tests/test-install.sh`, `tests/smoke.sh`, `tests/test-protocol-hooks.sh`:
  new names. `tests/evals/cases/reviewer-confidence-anchoring.json`: update
  the text only; do not run it.

**Delete**

- `workflows/review-diff.js` and `tests/test-review-diff-behavior.sh`.
- `agents/orch-code-reviewer.md` and `agents/orch-security-reviewer.md`
  (security becomes a lens in both briefs).
- `templates/spec-reviewer-prompt.md`, `templates/code-reviewer-prompt.md`,
  `templates/security-reviewer-prompt.md`, `templates/review.md`.
- `skills/cadence/references/reviewer-spec.md`, `reviewer-plain.md`,
  `refuter.md` (their content moves into the new briefs).

**Stop if**: no source for the served model of Claude agents inside a
workflow exists (R23), or a Workflow subagent cannot run the runner's `wait`
loop. Report it to Felipe instead of shipping a review that cannot record a
model or run the GPT seat.

No protected file must change. If Felipe wants this repository's own
sessions to run the GPT seat without a prompt, the allow rule goes in
`.claude/settings.json` under a ruling; T5 proposes the exact line.

## What T10 measures

On the same changes with planted defects (about 100 or more, in real diffs,
the same prompt wording in every arm), paired, with McNemar's test:

1. Full (this design) against the built-in `/code-review` and against
   `codex review`: defects found by rank, false findings, cost in tokens and
   minutes.
2. The swap: adversarial brief on GPT against on Claude
   (`adversarial_provider`).
3. With and without the refuter (still unmeasured, per `docs/MEASUREMENTS.md`).
4. Parts of 150 lines against the whole diff in one part.
5. Standard with the contract brief against the adversarial brief.
6. How many findings R5 turned into notes, per provider, and how many of
   those were real planted defects.
7. At least one case where the tests contradict the spec, to measure test
   tampering and whether R8 catches it.

The outcome log (R32) gives an online measure without paid runs: the share
of findings fixed, per seat, provider and rank; the refuter's drop rate; and
the dropout rate per provider.

## Not yet confirmed

- The `agent()` options (`label`, `phase`, `schema`, `model`, `effort`,
  `isolation`, `agentType`; no `cwd`) and "returns null when the agent dies"
  come from the bundled `workflow-authoring` skill text read on 2026-09-25;
  the public docs do not list them, and no script has exercised `effort`.
- Whether a Workflow subagent's Bash commands can raise a permission prompt
  for the person, and whether the runner's repeated 9-minute `wait` works
  inside one agent.
- Where a workflow agent's served model can be read after the run (R23).
- That `codex exec --json` events name the served model. The Codex 0.157.0
  help confirms `--json`, `--output-schema`, `-o`, `-s`, `-C`, `-m`, `-c`
  and `--ephemeral`; it does not show the event contents.
- What `-s workspace-write` allows outside `-C` (temporary directories,
  network) and which `model_reasoning_effort` values the default model
  accepts; this machine's config uses `medium`.
- Whether `claude -p` can force a JSON schema for the Claude seat on Codex;
  if not, `orch-review.py` validates the text and counts a failure as
  malformed (R12).

## Decisions for Felipe

1. Approve this design.
2. The adversarial seat runs on the provider that did not write the change
   (GPT on Claude Code) (R21).
3. The Claude alias: `opus` (the repository's policy) or `fable`, whichever
   you count as most capable.
4. The GPT seat sandbox: `workspace-write` in a disposable copy, so it can
   run tests, against `read-only`, which blocks tests that write files.
5. A new `orch-codex-runner` agent on `sonnet` at effort `low`, which changes
   the model policy in `tests/validate-skills.sh`.
6. On Codex, the Claude seat stays read-only through `claude-review.py`, or
   the runner gains Bash inside its review copy.
7. The outcome log location (R32), outside Git.
8. Removing the separate security reviewer in favor of a lens in both briefs.

## Sources

- Qiu and Gill, Adversarial Review, arXiv:2608.18167: reviewer plus a critic
  held to evidence found 43 of 57, against 34 to 36 for one or two reviewers.
- Jin and Chen, arXiv:2603.00539: executing the proposed fix filters false
  findings.
- Kim et al., arXiv:2506.07962: different models make correlated errors.
- Xiang et al., arXiv:2607.21656: cross-model review, 91.4% to 82.8% when
  Codex reviewed Claude's code without running tests.
- Reddy et al., arXiv:2605.21537: self-approval of wrong code.
- Kumar et al., arXiv:2606.15689: F1 0.657 on small diffs, 0.043 over 150
  lines.
- OpenAI, "A Practical Approach to Verifying Code at Scale": reviewers need
  the repository and code execution, not only the diff.
- Zhong et al., ImpossibleBench, arXiv:2510.20270: agents edit tests to pass.
- `docs/MEASUREMENTS.md` record two: the plain-language seat found 10 of 21
  catastrophic defects alone (one operator, no control arm).
