# Codex execution evidence and completion checks

`scripts/hooks/codex-evidence.py` and `scripts/verification/codex-verify.py` add
opt-in execution receipts to the existing cadence. The hook never reads the
unstable transcript format or treats an agent's report as executed evidence.
Claude hooks are separate and unchanged.

Codex 0.154's unified-exec hooks omit the requested tool working directory and
deliver raw, possibly truncated command output without an exit status. The
session `cwd` is not proof of execution directory. Consequently, ordinary direct
commands cannot earn trusted green receipts: run verifiers through the explicit
wrapper below. Text resembling `Process exited with code 0` is just output.

## Activation contract

In a project's `docs/llm-orchestrator/cadence.json`, enable both the cadence and
the Codex policy:

```json
{
  "enabled": true,
  "codex_verification": {
    "mode": "blocking",
    "include_globs": [".githooks/**"],
    "exclude_globs": [],
    "commands": []
  }
}
```

`mode` is `blocking` or `warn`; absent/other values leave the project inert.
The lists are optional. Include globs augment source/config suffix defaults and
the cadence runner's production/test globs. Exclude globs remove generated
evidence or other explicitly irrelevant paths. Review policy changes as changes
to verification, not as a way to make a failed check disappear.

The Codex installer registers this synchronous command:

```text
python3 /absolute/framework/scripts/hooks/codex-evidence.py
```

Register it for `UserPromptSubmit`, `PreToolUse` (`Bash|apply_patch`),
`PostToolUse` (`Bash|apply_patch`), `Stop`, `SubagentStart`, and
`SubagentStop`. `SessionStart` is supported as an optional fallback baseline.
Keep the hooks synchronous so a final answer does not race the ledger write.
Codex's `/hooks` trust step still belongs to the user; installation does not
bypass it. These fields follow the [official Codex hook contract](https://learn.chatgpt.com/docs/hooks).

## What the hook records

Run a verifier with an absolute working directory and new private artifact
paths for every invocation, keeping the shown flag order:

```sh
python3 /absolute/framework/scripts/verification/codex-verify.py --cwd /absolute/project --receipt /absolute/private-artifacts/run-001.json --output /absolute/private-artifacts/run-001.log -- npm run typecheck
```

The command after `--` is an argument vector, never a shell snippet. Store the
artifacts outside the source tree or in its excluded notes/artifacts directory.
The runner refuses to overwrite either artifact. Receipt/log files use mode
`0600`. It creates an exclusive reservation, executes the verifier with the
explicit `cwd`, and atomically finishes the receipt with the subprocess's real
exit status, before/after source fingerprints, and full-output hash. It returns
the verifier's exit status and prints its output. A timeout is optional through
`codex_verification.timeout_seconds`; none is imposed by default. Cancellation
terminates its owned process group and records an interrupted outcome when the
runtime permits cleanup.

Before the wrapper runs, the hook accepts only the exact installed sibling
runner path. It records the new artifact paths, invocation/runner hashes,
canonical target worktree, HEAD, source manifest, session/turn, and tool-call ID.
It also exclusively reserves a private `<receipt>.request.json` with a random
nonce. The runner echoes that nonce, preventing two concurrent sessions from
attributing the same new artifact to different invocations. Keep all three
artifacts with the run; use new paths for a retry.
After completion it validates only that observed invocation's exact receipt and
output: paths, privacy, command identity, invocation hash, runner hash, timing,
request nonce, source snapshots, and output hash must match. Missing, reused, altered,
unfinished, or unobserved artifacts cannot establish a passing check.
Merely observing `PostToolUse` or a hook's own zero exit status proves nothing.
If the turn-start baseline is missing, the hook cannot classify the task as
unchanged: it requires a fresh recognized check or an explicit pending handoff.

Inside the wrapper, the default recognizer accepts direct non-build verifiers:
`npm test`, `npm run test:*`, `npm run lint[:*]`, `npm run typecheck[:*]`, their
pnpm/yarn forms, `npm --prefix functions run test:unit`, jest/vitest/pytest,
eslint, `ruff check`, `tsc --noEmit`,
`python3 -m unittest`, `python3 -m pytest`, and repository-local
`python3 tests/test-*.py` / `bash tests/test-*.sh` scripts. Non-test commands,
help/version/list invocations, shell composition, `echo`, arbitrary Python
snippets, and build commands do not earn receipts. Use direct commands with the
wrapper's explicit absolute `--cwd`, not `cd ... && ...` or `... | tee ...`.
`npx` additionally requires `--no-install`. Selecting a script still requires
checking that its implementation/lifecycle follows the project's build and
dependency rules; a script name is not a sandbox. The hook never launches a
verifier on its own. Invoking the runner is an explicit execution request.
Default recognizers reject source/config routing outside the canonical
repository, including an external npm prefix, Jest root, pytest target, and
symlinks resolving outside the tree. An in-repository `--prefix functions`
remains supported. No-check modes such as Ruff `--exit-zero`, ESLint
`--print-config`, and TypeScript `--showConfig`/`--noCheck` do not earn receipts.

Custom direct commands can be added through `commands` entries containing a
full-match regular expression `pattern` and `kind` (`test`, `lint`, or
`typecheck`). This is trusted project policy and should name a real verifier.
It is not a general mechanism for importing handwritten receipt JSON.

Test success requires the runner's explicit exit code zero and a positive
test/check count. Empty selections, missing summaries, failures in output,
interrupted runs, and incomplete receipts remain unverified. Typecheck and lint
may legitimately succeed silently. The hook never extracts an exit code from
stdout, even if it looks exactly like Codex's rendered metadata. For a yielded
command, current unified exec emits the final Post hook only on completion;
the original pre-command snapshot remains associated with its tool-call ID.
Ordinary recognized commands are recorded as `unbound`, because actual cwd and
status are unavailable. Rerun the same verifier through the wrapper to replace
that unresolved result. Verifier identity is the canonical target cwd plus
inner argv, so fresh receipt paths do not prevent a successful retry from
superseding a failure. Unrelated passing commands cannot erase it.

The source fingerprint includes tracked and unignored source/config/test files,
file modes, and symlink targets. It excludes dependency/build trees, git metadata,
report and artifact trees, configured notes directories, `.env*`, `credentials`,
PEM/key files, and ignored output. It does not follow symlinks outside the tree.
Ordinary Markdown edits are out of scope unless explicitly included by policy.
Changing source or HEAD after a green check invalidates that check. A check from
another worktree cannot verify this worktree.

## Completion behavior

`UserPromptSubmit` establishes the baseline. Additional prompts during the
active task preserve it, including stop continuations and parallel-agent
activity sharing a session. At `Stop`, source changes require fresh verification
when this session observed a potentially mutating tool call, verification
activity, or an explicit full-verification claim. A plain question or recognized
read-only tools are not forced to test another editor's concurrent changes or
branch checkout. Unknown shell scripts are conservatively potentially mutating;
ordinary direct read commands are recognized. Missing turn baselines still
require an honest pending handoff or fresh evidence.

For an active verification obligation, at least one fresh recognized passing
check and no unresolved failed/unknown/running check are required. External
changes after this session's check still invalidate it. The latest invocation
of each command counts: an unrelated green lint
cannot erase a failed test. Successful checks must see the same source before,
after, and at completion. A claim of full verification also triggers the check.

This is a minimum evidence check. One passing command does not prove all
affected subsystems were tested, prove useful test coverage, or substitute for
the independent reviewers and mutation gate. The controller still selects and
checks the appropriate suite and final changes.

When necessary validation cannot run, the final response must state the
limitation plainly and include one of these lines outside a code block:

```text
Verification: PENDING — Felipe needs to build the updated binary before the device journey.
Verification: BLOCKED — The required test service is unavailable; the affected checks did not run.
```

These are truthful unverified outcomes, not green receipts. Do not combine them
with an unsupported assertion that all checks passed. Never start a build or
install dependencies merely to satisfy the completion hook.

Blocking mode requests at most one continuation, preserving the original
baseline even when Codex assigns the continuation a new turn ID. If still
unresolved, the hook emits an `UNVERIFIED` warning and records that outcome;
it does not force an infinite retry cycle. Warn mode immediately emits the
warning. Thus “blocking” means one corrective continuation, not a promise that
the runtime can never deliver an unverified answer. Read-only work and ordinary
documentation without verification claims need no test run.

## Native agent receipts and storage

`SubagentStart` / `SubagentStop` record native provider, observed model when
provided, agent ID/type, source fingerprint/HEAD, time, and an output hash.
Reasoning effort remains unknown because the hook schema does not report it.
A stopped agent is recorded as `stopped`, never assumed successful or graded as
an independent reviewer solely from its existence. Native review receipts and
external-provider reports are distinct from executed test evidence.

The ledger is a private `state.json` under:

```text
~/.llm-orchestrator/codex/<project-hash>/<session-hash>/state.json
```

Hashes use SHA-256 of JSON-encoded canonical root/session strings. Tests can
override the base with `ORCH_CODEX_STATE_DIR`. Each file update holds a process
lock and uses an atomic replacement with mode `0600`; directory names never
use raw session IDs. `evidence` contains executed check records, `agents`
contains native receipts, and `outcome` records the latest completion decision.

The global ledger stores hashes plus the command runner, status, and tool-call
ID. It does not duplicate full prompts, final replies, source contents, command
arguments, or test output. The explicitly requested private receipt contains
the actual argv and the private log contains complete stdout/stderr; treat
these artifacts as potentially sensitive and do not publish them blindly.
Reference those artifacts and the matching tool-call ID in review evidence;
the hash alone is not a readable substitute.

Hooks and runner receipts are local guardrails, not tamper-resistant attestation.
Someone able to rewrite the configuration, trusted runner, artifacts, or local
state can change the result. This protects against stale/accidental evidence,
not a malicious actor with the same filesystem permissions. Some
runtime tools can bypass normal hook coverage; unavailable/corrupt state yields
an explicit warning rather than a fabricated receipt. Excluded/ignored files
and sources outside the canonical repository are outside this fingerprint.
