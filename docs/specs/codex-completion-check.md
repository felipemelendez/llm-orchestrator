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
> command that runs a check (by the rules below), or that starts with the
> project's `runner.test_cmd`, run in this turn and finish with exit code 0?

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
  `completed`, and a command that passes `ran_a_check`. The lists it uses
  (runners, wrappers, package managers and their options) are data in one
  block of `orch-completion-check.py`; both harnesses use them. The command
  is read in linear passes, never with a backtracking pattern:
  1. **Words.** Quoted text and backslash escapes join the word they are
     in. Outside quotes, `;`, `&`, `&&`, `|`, `||`, `(`, `)` and newlines
     end a segment, and `<`, `>` (with `>&`, `&>`) are redirections that end
     the word before them. A redirection and its target are not words. If a
     quote is left open, every quote is read as an ordinary character.
  2. **Prefixes.** Leading `VAR=value`, `env`, `time`, `timeout N` and
     `cd dir` are skipped. A prefix with its own options, such as
     `timeout -k 5 300`, is not.
  3. **Wrapper.** If the segment starts with `aws-vault exec`, `doppler run`,
     `op run`, `dotenvx run`, `infisical run` or `mise exec`, everything up
     to and including its first `--` is skipped, and prefixes again. With no
     `--` it is not a check. No other program is a wrapper, because after
     `--` programs such as git, rm and ls take file names. A project with
     another wrapper puts its full command in `runner.test_cmd`.
  4. **Front.** `npx`, `bunx`, `npm exec`, `pnpm exec`, `pnpm dlx`,
     `yarn exec`, `yarn dlx`, `uv run`, `poetry run`, `pipenv run`,
     `hatch run`, `rye run` and `bundle exec` are skipped with the options
     listed for each (and the value of each option that takes one), then an
     optional `--`. An option not on the list means the segment is not a
     check. `npm`, `pnpm`, `yarn` and `bun` are read the same way; after
     their options must come a check script (`test`, `t`, `tests`, `lint`,
     `typecheck`, `check`, or one of them followed by `:` or `-`, such as
     `test:unit`), `run <script>`, `exec`/`dlx` as above,
     `yarn workspace <name>` followed by the same again, or, for `pnpm` and
     `yarn` only, a runner (`pnpm vitest`). Anything else is one of the
     manager's own commands (`add`, `remove`, `update`, `why`, ...), so
     `pnpm -w add -D vitest` and `pnpm --filter jest build` are not checks.
  5. **Runner.** The next word, taken by its last path part so that any
     path works (`.ve/bin/pytest`, `/usr/bin/make`, `$HOME/.ve/bin/pytest`),
     must be a runner: `pytest`, `py.test`, `jest`, `vitest`, `mocha`,
     `rspec`, `tox`, `nox`, `phpunit`, `pest`, `tsc`, `ruff`, `eslint`,
     `biome`, `flake8`, `mypy`, `pyright`, `shellcheck`, `rubocop`,
     `golangci-lint`, `ctest` or `bats`; or one that needs a second word
     (`go test`/`vet`; `cargo test`/`check`/`clippy`/`nextest`; `mix test`;
     `gradle` or `gradlew test`/`check`; `mvn test`/`verify` after its
     options; `make`, `just` or `task` with `test`, `tests`, `check`,
     `lint`, `typecheck`, `ci` or `verify`; `dotnet`, `swift` and
     `bazel test`; `deno test`/`check`/`lint`); or `python -m` with
     `pytest`, `unittest`, `tox`, `mypy`, `ruff` or `flake8`; or a test
     script run directly or by `bash`, `sh` or `python`
     (`tests/x.sh`, `./tests/x.py`, `./run-tests.sh`). The name must be the
     whole word, so `tsc-watch`, `ruff-lsp`, `pytest.ini` and
     `scripts/eslint/build-rules.sh` are not runners (`tsc-watch` and
     `ruff-lsp` counted under an earlier rule). A runner with options before
     its target (`make -j4 test`) is not recognised.
  6. **Printing only.** A segment with `--version`, `--help`, `-h`, `-V`,
     `--collect-only`, `--dry-run`, `--list-tests`, `--list`,
     `--show-config`, `--co`, `--print-config` or `--why` is not a check.
- When the project's `docs/llm-orchestrator/cadence.json` sets
  `runner.test_cmd`, a command also passes when its words start with the
  words of `test_cmd`. It is tried on the whole command and again after each
  leading prefix (`cd /repo &&`, `FOO=1`, `env`, `time`, `timeout N`), so a
  `test_cmd` holding `&&` still matches, and on each segment after its
  prefixes. Because it compares words, `bin/suite --fast</dev/null` starts
  with `bin/suite --fast` and `bin/suite --fastest` does not. The project
  is the payload's `cwd`, else `CODEX_PROJECT_DIR`, else the hook's working
  directory; on Claude Code it is `CLAUDE_PROJECT_DIR`, else the working
  directory. Unverified: that a live Codex sends the project root as `cwd`
  (the recorded payload shape has the field; a session started in a
  subdirectory would not find the file), and whether Codex sets
  `CODEX_PROJECT_DIR` at all. A missing, unreadable or malformed
  `cadence.json` (including one nested too deep to read), or an empty
  `test_cmd`, leaves only the lists.
- A shell argv (`bash`, `sh`, `zsh` or `dash` with `-c`,
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
- A check named only inside a heredoc body: each body line is read as a
  command.
- `npm test || true`, or any other masking of the exit code.
- A line appended to the log by hand; the log is the harness's.

Each is a disguise, and the laws leave honesty to the agent: the check
catches the careless false claim, not the deliberate one. The word split
above only finds which program a segment runs. Earlier versions also tried to
judge these shapes (heredoc and background rules), and every rule mis-judged
an honest command somewhere else: `2>&1` read as a background `&`, a
multi-line quoted argument read as an unbalanced line, a here-string read as
a heredoc. A note that is wrong gets ignored, which is worse than no note. Do
not add them back; `orch-completion-check.py`'s docstring says the same.

A Codex build from before these records existed (July 2026 and earlier)
writes none, so on such a build every PASS is sent back once.

## Not in scope

`SubagentStop` is not registered for Codex: the payload offers
`agent_transcript_path`, but whether it is the child's rollout in this format
is unverified, and judging a child by its parent's log is worse than silence.
The word split and the lists are shared with the Claude check on purpose; see
that file's docstring.

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
