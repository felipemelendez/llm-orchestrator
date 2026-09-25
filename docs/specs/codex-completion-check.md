# Spec: the Codex completion check

Status: implemented 2026-09-22. Maintained alongside `scripts/lib/codex-completion-check.py`.

## Goal

Codex gets the same completion check Claude Code has, from the same source of
truth, without any of the removed machinery: no per-command watcher, no
repository hashing, no receipts, no verification runner.

## The contract

At Codex's `Stop` event the hook receives `last_assistant_message`,
`transcript_path`, `turn_id` and `stop_hook_active`. It answers one question:

> The reply's last `Verification:` label, outside code fences, is `PASS`. Did a
> command matching `ORCH_SIG_VERIFY_CMD`, or starting with the project's
> `runner.test_cmd` (and not matching `ORCH_SIG_VERIFY_NONRUN`), run in this
> turn and finish with exit code 0?

- Yes, or the label is anything but PASS, or there is no label: print nothing.
- No: print `{"decision":"block","reason":<NOTE>}` once. NOTE is
  `orch-completion-check.py`'s note, byte for byte.
- `stop_hook_active` true: print nothing. This is the continuation the hook
  itself requested; it fires at most once per turn.
- Always exit 0. Never print `systemMessage`. Never write to stderr outside
  `ORCH_HOOK_DRY_RUN=1`.

## Why the agent, not the person

Codex's `StopCommandOutputWire` (codex-rs/hooks/src/schema.rs, read
2026-09-22) is `continue`, `stopReason`, `suppressOutput`, `systemMessage`,
`decision`, `reason`. There is no `hookSpecificOutput.additionalContext` on
Stop. `systemMessage` is a warning in the person's UI. `decision: block` on
Stop does not reject the turn; Codex continues and gives the agent `reason` as
the next prompt. The person is never the audience for an agent's missing
check, so the note goes to the agent through the continuation.

## Reading the log

`transcript_path` is the session rollout (JSONL). The check reads exactly one
kind of entry: the record Codex itself writes when a command it ran has
finished.

| Entry | Shape |
|---|---|
| Command record | `event_msg` whose payload is `item_completed` with `turn_id` and an `item` of type `CommandExecution`, carrying `command` (an argv list, usually `["/bin/zsh","-lc","<the command>"]`), `exit_code` (an integer) and `status` (`completed` for 0, `failed` otherwise). Present in every rollout since Codex started writing them (August 2026; every command in the 300 such rollouts on this machine has one). |
| Turn start | `event_msg` / `task_started` with `turn_id`; also `turn_context` with `turn_id`. Used only as a fallback. |

Nothing the agent wrote is read: not the JavaScript it sent to the exec tool,
not the text it chose to print from a result. An earlier version parsed those,
and every one of its false passes came from there.

Rules:

- The records of this turn are those whose `turn_id` is the payload's. When no
  record names that turn (an older log, or a turn id the log spells
  differently), the turn is the slice after the last marker where the
  `turn_id` changed; a marker Codex re-emits for the same turn after a
  compaction is not a new turn.
- A check passes when a record in this turn has exit code 0, status
  `completed`, and a command that passes `ran_a_check`: the text split at
  `;`, `&`, `|` and newlines, the plain forms of the known prefixes stripped
  (`cd x &&`, `env`, `time`, `timeout N`, `VAR=value` with no space in the
  value; a prefix with its own options, such as `timeout -k 5 300`, is not
  stripped), one segment matching the shared pattern and not the non-run
  pattern. That is the whole reading of the text; the check does not parse
  shell. The pattern is anchored at the segment's start. Before the runner
  only these may come, in this order:
  1. One of these wrappers, its own arguments, then `--`: `aws-vault exec`,
     `doppler run`, `op run`, `dotenvx run`, `infisical run`, `mise exec`.
     No other program counts as a wrapper, because after `--` git, rm and
     ls take file names (`git diff -- tests/x.sh`). A project with another
     wrapper puts its full command in `runner.test_cmd`.
  2. A program that runs the project's copy of a tool, with options and
     their values: `npx`, `bunx`, `pnpm`, `pnpm exec`, `pnpm dlx`, `yarn`,
     `yarn dlx`, `yarn workspace <name>`, `poetry run`, `pipenv run`,
     `uv run`, `hatch run`, `rye run`, `bundle exec`, `dotnet run --`,
     `deno task` (`pnpm --filter web vitest run`, `npx --yes jest`).
  3. A path to the runner: `.ve/bin/`, `./node_modules/.bin/`, `/usr/bin/`,
     `~/.cargo/bin/`, `$HOME/.ve/bin/`. Every runner may be named by a path
     (`/usr/bin/make test`), and so may `bash`, `sh` and `python` before a
     test script.

  A tool's name (`pytest`, `jest`, `eslint`, `tsc` and the rest of the list
  in `orch-signals.sh`) must be the whole last part of the path and must end
  at whitespace, the end of the segment or a shell operator (`;`, `&`, `|`,
  `(`, `)`, `<`, `>`). It never ends at `/`, `.` or `-`, so
  `config/jest/setup.js`, `scripts/eslint/build-rules.sh` and `pytest.ini`
  are not runs. This also means `tsc-watch` and `ruff-lsp` no longer count,
  where the earlier word-boundary rule counted them. A runner with options
  before its target (`make -j4 test`) is not recognised and the agent is
  sent back once.
- When the project's `docs/llm-orchestrator/cadence.json` sets
  `runner.test_cmd`, a command also passes when it starts with that text
  followed by the end of the command, a space or an operator. It is tried
  on the whole command and again after each leading prefix is removed
  (`cd /repo &&`, `FOO=1`, `env`, `time`, `timeout N`), so a `test_cmd`
  holding `&&` still matches; it is also tried on each segment. The project
  is the payload's `cwd`, else `CODEX_PROJECT_DIR`, else the hook's working
  directory; on Claude Code it is `CLAUDE_PROJECT_DIR`, else the working
  directory. Unverified: that a live Codex sends the project root as `cwd`
  (the recorded payload shape has the field; a session started in a
  subdirectory would not find the file), and whether Codex sets
  `CODEX_PROJECT_DIR` at all. A missing, unreadable or malformed
  `cadence.json` (including one nested too deep to read), or an empty
  `test_cmd`, leaves only the pattern. A shell argv (`bash`, `sh`, `zsh` or `dash` with `-c`,
  `-lc`, `-ic` or `-lic`) is judged on its script text; any other argv runs
  one program, so it is joined with spaces only when no argument holds shell
  punctuation.
- On Claude Code the harness records a launch and a finish differently, and
  the check tells them apart from the record alone: a Bash call made with
  `run_in_background`, or whose result is the launch acknowledgement
  (`Command running in background with ID:`), is a launch, not a finish.
  Codex writes one record per finished command, so there is nothing to tell
  apart.
- A record missing its command or its integer exit code is not a record. A
  command the agent asked for that has no record (interrupted, still running,
  never started) does not count. A row that is not a JSON object, or whose
  payload is not, is skipped and the rest of the log is still read.
- A payload that is not an object, a null or missing transcript, a null
  message: print nothing.

## Limits, by construction

The check reads what the harness recorded and the command's text the plain
way above. These shapes get past it, on both harnesses, and stay that way on
purpose:

- `npm test &`: the shell reports 0 as soon as the check is launched.
- A check named only inside a heredoc body or a quoted string
  (`printf 'npm test'`).
- `npm test || true`, or any other masking of the exit code.
- A line appended to the log by hand; the log is the harness's.

Each is a disguise, and the laws leave honesty to the agent: the check
catches the careless false claim, not the deliberate one. Earlier versions
tried to close these with text rules (a tokenizer, heredoc and background
parsing), and every rule mis-judged an honest command somewhere else: `2>&1`
read as a background `&`, a multi-line quoted argument read as an unbalanced
line, a here-string read as a heredoc. Shell syntax has no bottom, and a note
that is wrong gets ignored, which is worse than no note. Do not add them
back; `orch-completion-check.py`'s docstring says the same.

A Codex build from before these records existed (July 2026 and earlier)
writes none, so on such a build every PASS is sent back once.

## Not in scope

`SubagentStop` is not registered for Codex: the payload offers
`agent_transcript_path`, but whether it is the child's rollout in this format
is unverified, and judging a child by its parent's log is worse than silence.
The pattern's known coarseness (a `|` inside a quoted argument splits a
segment) is shared with the Claude check on purpose; see that file's docstring.

## Verification

`bash tests/test-codex-verify-gate.sh` drives the hook with fixtures in the
shape above, including a decoy script and an agent-printed result with no
harness record behind them, runners named by a path, behind a named wrapper or
through `pnpm`/`yarn`/`npx`, a project's `runner.test_cmd`, and the honest shapes (`2>&1`, a quoted `&`, a
here-string, a multi-line quoted argument) that must stay silent, and asserts
the invariants (exit 0, no `systemMessage`, no stderr).
`bash tests/test-install-global.sh` G16 runs the command exactly as
`~/.codex/hooks.json` registers it. Live Codex: unverified in tests; one turn
after `/hooks` trust shows it.
