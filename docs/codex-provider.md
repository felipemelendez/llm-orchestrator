# External Claude reviews from Codex

Native Codex agents remain the default. They inherit the parent session's model
and reasoning effort. The optional Claude runner adds a separate provider when
the controller explicitly chooses an external read-only review. If Claude is
unavailable, that is recorded as an incomplete review,
never a successful review and never an automatic model substitution.

Use the two independent reviews and the project's conditional-refuter rule.
The provider runner does not add a third reviewer or replace the review policy.
External provider receipts prove dispatch and reported results; they do not
prove that tests passed, that an app journey worked, or that a review is correct.

## Requirements and authentication

The runner uses Python 3.9+ and an installed Claude Code CLI supporting the flags
shown below. Integration was developed against Claude Code 2.1.273. No Python
packages or additional provider installations are needed. Run this read-only
preflight:

```sh
python3 /path/to/LLM-Orchestrator/scripts/providers/claude-review.py doctor
```

It checks `claude --version` and `claude auth status --json`, emitting only the
version, availability and authentication boolean. It never prints authentication
responses, email addresses or tokens. Existing normal Claude login is used:
the runner does not set an API key, rewrite authentication, or use `--bare`.

A Codex sandbox can prevent Claude from reading the operating system credential
store even when a normal terminal reports a valid login. In that case use the
normal Codex approval path for the doctor or review command; do not infer that
the user needs a new subscription or ask for a secret. An unavailable account
returns a nonzero status and a dropout receipt when invoking `run`.

## Selecting a provider model

The runner reads `docs/llm-orchestrator/cadence.json` beneath `--cwd`, or a file
selected with `--config`. This is the optional portion of the configuration:

```json
{
  "codex_providers": {
    "native": {"provider": "codex", "model": "inherit-parent", "effort": "inherit-parent"},
    "claude": {"enabled": true, "model": "opus", "effort": "max"}
  }
}
```

For Claude, precedence is explicit `--model`/`--effort`, then project values,
then `opus`/`max`. Those aliases avoid pinning an obsolete version. The literal
value `default` or JSON `null` omits the corresponding CLI flag; its receipt
field is null, and no model or effort inheritance is claimed. An exact model
name requests that exact name. Disabled Claude produces a `disabled` receipt
and does not start the CLI. No fallback model flag is passed.

Claude's configured model from a `system/init` event is recorded separately
from the response models reported in assistant messages. The runner requires
assistant response-model evidence; init and usage counters alone are insufficient.
For a model alias it checks every assistant response model's family and labels
that weaker assurance `alias-family`; an exact model request must match exactly.
A response-model mismatch is a nonzero failure. Claude may also use auxiliary
models for internal work: every model from final `modelUsage` remains recorded
in `usage_models` and `model_usage`, with usage-only names listed separately as
`auxiliary_usage_models`. Auxiliary usage neither invalidates a correctly
selected response model nor excuses a mismatching assistant response model.
Requested effort is recorded as a request, not falsely described as verified
served effort.

## Running one review

Prepare a narrowly scoped prompt file and a trusted, isolated working copy.
Include the task requirements, the permitted files, the no-build rule, owned
files, and the relevant source or diff. Claude customizations and automatic
CLAUDE.md discovery are disabled, so the controller must include the needed
project rules explicitly. Do not expose the whole home directory as the cwd.

Choose a new output and receipt path for every attempt. Their parent directory
must already exist. Existing files or symlinks are rejected, not overwritten.

```sh
python3 /path/to/LLM-Orchestrator/scripts/providers/claude-review.py run \
  --cwd /path/to/isolated-review-copy \
  --config /path/to/project/docs/llm-orchestrator/cadence.json \
  --prompt-file /path/to/review-prompt.txt \
  --context-file path/inside/review-copy/change.diff \
  --output /path/to/evidence/claude-review-1.jsonl \
  --receipt /path/to/evidence/claude-review-1.receipt.json
```

`--context-file` can be repeated and is optional. Each such file must be inside
the working copy. `--prompt-stdin` can replace `--prompt-file`. Prompts go to
standard input and are never interpolated into a shell command. Paths containing
spaces work when quoted normally. `--claude-bin` can select a specific installed
executable. Reviews have no execution deadline by default. Set `--timeout` only
when the task explicitly calls for a deadline; a healthy long review is not
terminated merely because a fixed amount of time has passed. The short doctor
checks remain bounded. No build, installation, or service start is performed by
the runner.

The invocation uses `--print --verbose --output-format stream-json`,
`--safe-mode --restricted`, `--permission-mode plan --permission-prompts none`,
`--tools Read,Grep,Glob --allowedTools Read,Grep,Glob`,
`--strict-mcp-config --mcp-config '{"mcpServers":{}}'`,
`--disable-slash-commands --no-session-persistence --no-chrome`.
This keeps normal authentication while disabling ambient hooks, skills, plugins,
MCP tools, and browser integration. Only the three read tools are exposed;
Bash, Write, Edit, Agent and Skill are absent. Managed administrator policies
still apply. The runner never enables permission bypasses.

## Receipts and failure handling

The stdout artifact preserves the JSON event stream. The separate mode-0600
receipt records UTC start/finish times, provider, role, requested model/effort,
reported model evidence, canonical cwd, Git HEAD and tracked-diff digest,
configuration/prompt/explicit-context hashes, process exit status, final-result
status, usage/cost when present, and the output digest. Stderr is represented
by its digest and length, without copying potentially private diagnostics.

The Git digest covers tracked changes only; it is not a hash of all untracked
source files. Use explicit context artifacts or put the reviewed diff in the
prompt to bind those inputs. The receipt describes inputs at dispatch time;
review an isolated copy and invalidate the review if the reviewed change moves.

Exit zero requires a successful process, exactly one successful final result,
nonempty review text, valid event JSON, and acceptable reported model evidence.
`unavailable`, `unauthenticated`, `disabled`, `model_mismatch`,
`unverified_model`, `provider_error`, `invalid_output`, `timeout`, `cancelled`
and runner/preflight errors return nonzero. Timeout, SIGTERM and SIGINT terminate
the child process group and preserve a receipt plus partial output. SIGKILL or
machine failure cannot guarantee finalization; an empty or unfinished receipt
is not evidence of success. Artifact collisions fail before dispatch and leave
the existing evidence untouched.

When Claude drops out, report why and decide explicitly whether to use an
independent native reviewer or stop if external-provider diversity was required.
Never label a substituted native review as Claude. A successful runner receipt
does not mean the reviewer approved the change: read and adjudicate the report.

## Offline regression tests

```sh
python3 tests/test-claude-provider.py
```

The tests use a fake executable and cover authorization dropouts, result/model
validation, artifact exclusivity, prompt transport, configuration precedence,
timeout and cancellation. They make no model calls and execute no builds.
