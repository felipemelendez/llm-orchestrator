# Spec: the Codex completion check

Status: implemented 2026-09-22; record kinds revised 2026-09-25. Maintained alongside `scripts/lib/codex-completion-check.py`.

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

`transcript_path` is the session rollout (JSONL). The check reads only the
records Codex itself writes when a command it ran has finished. Which records
a rollout holds depends on the build and on the thread's history mode, which
the rollout's `session_meta` names as `history_mode`:

| Build and mode | What a finished command leaves |
|---|---|
| 0.147.0 and later, paginated history (the default for a new thread with a local state database) | A command record for every command, whether a direct `exec_command` call or a command a code-mode `exec` script ran. A direct call also leaves the function-call pair below. |
| Any build, legacy history (for example 0.154.0-alpha.6.2 Desktop threads on this machine, and their subagents) | No command record. A direct `exec_command` call leaves the function-call pair. A command a code-mode `exec` script ran leaves nothing Codex wrote; only the text the script chose to print. |
| 0.146.0 and earlier | No command record in either mode; the function-call pair. |

Sources: `codex-rs/rollout/src/policy.rs` at `rust-v0.157.0`
(`should_persist_event_msg`: `ItemCompleted` is kept only in paginated
history, `ExecCommandEnd` never); `codex-rs/app-server/src/request_processors/thread_processor.rs`
(a new thread is paginated unless the client asks otherwise, the thread is
ephemeral, or there is no state database); `codex-rs/core/src/tools/context.rs`
(`response_header`, the output header); and local session logs, in which
every paginated rollout that ran a command on 0.147.0 or later has command
records, and legacy and 0.146.0 rollouts have none. Why some 0.154 Desktop
threads are legacy is unverified.

| Entry | Shape |
|---|---|
| Command record | `event_msg` whose payload is `item_completed` with `turn_id` and an `item` of type `CommandExecution`, carrying `command` (an argv list, usually `["/bin/zsh","-lc","<the command>"]`), `exit_code` (an integer) and `status` (`completed` for 0, `failed` otherwise). |
| Function-call pair | `response_item` / `function_call` named `exec_command` (no `namespace`), whose `arguments` JSON has `cmd`, and whose `internal_chat_message_metadata_passthrough.turn_id` names the turn; then the `function_call_output` with the same `call_id`, a string that starts with Codex's header: lines `Chunk ID: …`, `Wall time: …`, `Process exited with code N` or `Process running with session ID N`, `Original token count: …`, then `Output:`. A command still running is finished by a later `write_stdin` call with that `session_id`, whose output header carries the exit code. |
| Turn start | `event_msg` / `task_started` with `turn_id`; also `turn_context` with `turn_id`. Used only as a fallback. |

Nothing the agent wrote is read beyond the command it asked for: not the
JavaScript it sent to the exec tool, not the text it chose to print from a
result, not the program's output below the `Output:` line. An earlier version
parsed those, and every one of its false passes came from there.

Rules:

- The records of this turn are those whose `turn_id` is the payload's. When no
  record names that turn (an older log, or a turn id the log spells
  differently), the turn is the slice after the last marker where the
  `turn_id` changed; a marker Codex re-emits for the same turn after a
  compaction is not a new turn.
- When the log has no command record and this turn has a code-mode `exec`
  call, the turn's commands cannot be read (legacy history): print nothing.
  A turn with no `exec` call is still judged by its function-call pairs.
- A check passes when a record in this turn has exit code 0 (and, for a
  command record, status `completed`), and a command that passes
  `ran_a_check`. A function-call pair's command is its `cmd`, judged as a
  shell script. The lists it uses
  (runners, targets, non-run options, prefixes, wrappers, package managers
  and their options) are data in one block of `orch-completion-check.py`;
  both harnesses use them. The command is split into words in one linear
  pass, cut into segments, and each segment is read from the left:
  1. **Words.** Any whitespace (including U+00A0, U+2028, U+3000, `\v` and
     `\f`) separates words. Quoted text and backslash escapes join the word
     they are in. Outside quotes:
     - `;`, `&`, `&&`, `|`, `||`, `(`, `)` and newlines end a segment.
     - A redirection ends the word before it and is dropped together with
       its target word: `<`, `>`, `>>`, `<>`, `>|`, `<&`, `>&`, `&>`,
       `&>>`, `<<<`, each optionally after a descriptor number (`2>`,
       `2>&1`, `0<`). So `2>/dev/null pytest` reads as `pytest`.
     - `<<WORD`, `<<'WORD'` and `<<-WORD` start a heredoc: its body, from
       the next line up to the line that is exactly `WORD` (after leading
       tabs for `<<-`), is skipped. With no such line the rest is skipped.
     - A `#` that starts a word starts a comment, which runs to the end of
       the line.

     A command with a quote left open is not a check.
  2. **Options.** Every list of options below names only the options that
     take a value. Any other word starting with `-` is read as an option
     with no value, and `--` ends the options.
  3. **Prefixes.** Leading `VAR=value` words are skipped, and so are these
     programs (by the last part of their path, so `/usr/bin/env` too) with
     their options and plain arguments: `env` (value options `-u`,
     `--unset`, `-C`, `--chdir`), `time`, `timeout DURATION` (value options
     `-k`, `--kill-after`, `-s`, `--signal`) and `cd DIR`.
  4. **Wrapper.** If the segment then starts with `aws-vault exec`,
     `doppler run`, `op run`, `dotenvx run`, `infisical run` or `mise exec`,
     everything up to and including its first `--` is skipped, and prefixes
     again. With no `--` it is not a check. No other program is a wrapper,
     because after `--` programs such as git, rm and ls take file names. A
     project with another wrapper puts its full command in `runner.test_cmd`.
  5. **Front.** `npx`, `bunx`, `npm exec`, `pnpm exec`, `pnpm dlx`,
     `yarn exec`, `yarn dlx`, `uv run`, `poetry run`, `pipenv run`,
     `hatch run`, `rye run` and `bundle exec` are skipped with their
     options. `npm`, `pnpm`, `yarn` and `bun` are read the same way; after
     their options must come a check script (`test`, `t`, `tests`, `lint`,
     `typecheck`, `check`, or one of them followed by `:` or `-`, such as
     `test:unit`), `run <script>`, `exec`/`dlx` as above,
     `yarn workspace <name>` followed by the same again, or, for `pnpm` and
     `yarn` only, a runner (`pnpm vitest`). Anything else is one of the
     manager's own commands (`add`, `remove`, `update`, `why`, ...), so
     `pnpm -w add -D vitest` and `pnpm --filter jest build` are not checks.
     The value options come from npm 11's and uv's own help; npx's `-p` is
     `--package`, while npm's `-p` is `--parseable` and takes no value. The
     lists for pnpm, yarn and bun come from their published documentation,
     not a local run.
  6. **Runner.** The next word, taken by its last path part so that any
     path works (`.ve/bin/pytest`, `/usr/bin/make`, `$HOME/.ve/bin/pytest`),
     must be a runner: `pytest`, `py.test`, `jest`, `vitest`, `mocha`,
     `rspec`, `tox`, `nox`, `phpunit`, `pest`, `tsc`, `ruff`, `eslint`,
     `biome`, `flake8`, `mypy`, `pyright`, `shellcheck`, `rubocop`,
     `golangci-lint`, `ctest` or `bats`; or `python -m` with `pytest`,
     `unittest`, `tox`, `mypy`, `ruff` or `flake8` (the module is then
     judged as that runner, so step 7 applies to `python -m ruff rule`); or
     a test script run directly or by `bash`, `sh` or `python`
     (`tests/x.sh`, `./tests/x.py`, `./run-tests.sh`). The interpreter's own
     options before `-m` or the script are skipped (`python3 -u -m pytest`,
     `bash -e tests/x.sh`); of those, python's `-X` and `-W`, bash's `-o`
     and `-O`, and sh's `-o` take a value, and in a cluster of short
     options the last letter takes it (`bash -euo pipefail tests/x.sh`).
     `bash -n`, `bash --noexec` and `sh -n`, alone or in a cluster
     (`bash -en`), only parse the script, so they are not checks.

     Two kinds of runner need a target word:
     - Tools whose subcommand comes first: the first word after their own
       options must be the target. `go test`/`vet` (value option `-C`);
       `bazel test` after its value startup options (`--output_base`,
       `--output_user_root`, `--bazelrc`, `--host_jvm_args`);
       `cargo test`/`check`/`clippy`/`nextest` (after an optional
       `+toolchain`; value options `-C`, `-Z`, `--config`); `mix test`;
       `dotnet` and `swift test`; `deno test`/`check`/`lint`. So
       `go build -o test`, `cargo run --bin check`, `bazel build //app:test`
       and `go mod why test` are not checks.
     - Tools that take a list of targets: any later plain word before `--`
       counts, but never the value of one of their value options. `make`,
       `just` and `task` with `test`, `tests`, `check`, `lint`,
       `typecheck`, `ci` or `verify`; `gradle`/`gradlew` with `test` or
       `check`, also as a task path (`:app:test`); `mvn` with `test` or
       `verify`. The value options: make `-C`, `-f`, `-I`, `-o`, `-W` and
       their long forms; gradle `-x`/`--exclude-task`, `-p`, `-b`, `-c`,
       `-g`, `-I` and their long forms; mvn `-pl`, `-f`, `-s`, `-gs`, `-P`,
       `-rf`, `-t` and their long forms; just `-f`/`--justfile`,
       `-d`/`--working-directory`, `--shell`, `--dotenv-filename`,
       `--dotenv-path`; task `-d`/`--dir`, `-t`/`--taskfile`,
       `-o`/`--output`. So `mvn clean test`, `./gradlew clean test` and
       `make -C app test` count, and `gradle build -x test`,
       `make -C test build` and `task -d test build` do not.
     The name must be the whole word, so `tsc-watch`, `ruff-lsp`,
     `pytest.ini` and `scripts/eslint/build-rules.sh` are not runners
     (`tsc-watch` and `ruff-lsp` counted under an earlier rule).
  7. **Not a run.** A segment is not a check when it has an option that
     makes any runner only print (`--version`, `--help`, `-h`, `-V`,
     `--collect-only`, `--dry-run`, `--list-tests`, `--list`,
     `--show-config`, `--co`, `--print-config`, `--why`), or an option that
     makes a runner named earlier in it plan, list or skip:
     `make` `-n`, `--just-print`, `--dry-run`, `--recon`, `-q`, `--question`;
     `just` `-n`, `--dry-run`; `cargo` `--no-run`; `gradle`/`gradlew` `-m`,
     `--dry-run`; `mvn` `-DskipTests`, `-Dmaven.test.skip` (bare or
     `=true`); `pytest` `--markers`, `--fixtures`, `--fixtures-per-test`,
     `--collect-only`, `--co`, `--setup-plan`; `jest` `--clearCache`,
     `--listTests`, `--showConfig`; `ruff` `--show-files`, `--show-settings`.
     `ruff rule`, `ruff config`,
     `ruff format` (without `--check`), `ruff linter`, `ruff version`,
     `ruff clean`, `ruff server` and `ruff analyze` inspect rather than
     check. An option combined with others (`make -kn test`) is not
     recognised.
- When the project's `docs/llm-orchestrator/cadence.json` sets
  `runner.test_cmd`, a command also passes when the words and operators of
  `test_cmd`, read by step 1 and with its own leading prefixes other than
  `cd` removed, appear in the command's starting at one of two places in a
  segment: after the segment's prefixes other than `cd`, or where its
  command proper starts (after all prefixes and a named wrapper's `--`). So
  `cd /repo && cd app && ./check -q` and `FOO=1 cd app && ./check` match
  `cd app && ./check`, and `aws-vault exec p -- bin/suite --fast` matches
  `bin/suite --fast`. Redirections are dropped on both sides, so
  `bin/suite --fast</dev/null` and `bin/suite 2>/dev/null --fast` match
  `bin/suite --fast`, and `bin/suite --fastest` does not. A segment the
  match touches that is not a run by step 7 cancels it, so
  `/usr/bin/make test -n` does not match `/usr/bin/make test`. The
  comparison costs at most the command's length times `test_cmd`'s; the
  command side is linear, and `test_cmd` is the project's own, set in a
  protected file. The project is the payload's `cwd`, else
  `CODEX_PROJECT_DIR`, else the hook's working directory; on Claude Code it
  is `CLAUDE_PROJECT_DIR`, else the working directory. Unverified: that a
  live Codex sends the project root as `cwd` (the recorded payload shape
  has the field; a session started in a subdirectory would not find the
  file), and whether Codex sets `CODEX_PROJECT_DIR` at all. A missing,
  unreadable or malformed `cadence.json` (including one nested too deep to
  read), or an empty `test_cmd`, leaves only the lists.
- A shell argv (`bash`, `sh`, `zsh` or `dash` with `-c`,
  `-lc`, `-ic` or `-lic`) is judged on its script text; any other argv runs
  one program, so it is joined with `shlex.join`, which quotes each
  argument. `["git","commit","-m","Fix gate (pytest)"]` stays one program
  with one message.
- On Claude Code the harness records a launch and a finish differently, and
  the check tells them apart from the record alone: a Bash call made with
  `run_in_background`, or whose result is the launch acknowledgement
  (`Command running in background with ID:`), is a launch, not a finish.
  On Codex a command record is written only when a command finishes, and a
  function-call output that says `Process running with session ID N` is a
  launch; only the exit code in its header, or in the header of the
  `write_stdin` poll that ends it, is a finish.
- A record missing its command or its integer exit code is not a record;
  a function-call output whose header has any other line, or no `Output:`
  line, is not one either. A
  command the agent asked for that has no record (interrupted, still running,
  never started) does not count. A row that is not a JSON object, or whose
  payload is not, is skipped and the rest of the log is still read.
- A payload that is not an object, a null or missing transcript, a null
  message: print nothing.

## Limits, by construction

The check reads what the harness recorded and the command's words the way
above. It catches the careless false claim, not deliberate faking
(ARCHITECTURE.md Layer 7). These shapes get past it, on both harnesses, and
stay out of scope on purpose:

- `pytest &`: the shell reports 0 as soon as the check is launched.
- `pytest || true`, or any other masking of the exit code.
- `false && pytest; true`: the check is named in a segment that never ran;
  the check does not follow which segments the shell runs.
- `pytest() { :; }` then `pytest`: a shell function or alias with a
  runner's name.
- `echo $((pytest))`: text inside `$(( ))`, `$( )` or backticks is not
  told apart from a command.
- A quote left open anywhere in the command: the command is not read as a
  check, so an honest run with a stray quote sends the agent back once.
- `npx -c "vitest run"` and `npm exec --call "..."`: the command an option
  names is not read, so this honest run is not seen.
- `mix do compile + test`: the first word after `mix` is `do`, so this
  run is not seen. A project that runs its tests this way names the
  command in `runner.test_cmd`.
- `just run test`: for make, gradle, mvn, just and task every later plain
  word is read as a target, so `test` given to the `run` recipe as an
  argument reads as the `test` target.
- `bash <<EOF` with a check in the body: heredoc bodies are skipped, so
  this honest run is not seen and the agent is sent back once.
- A line appended to the log by hand; the log is the harness's.

The laws leave honesty to the agent. The word split above only finds which
program a segment runs. Earlier versions also tried to judge what the shell
does with the result (background and exit-code rules), and every rule
mis-judged an honest command somewhere else: `2>&1` read as a background
`&`, a multi-line quoted argument read as an unbalanced line. A note that is
wrong gets ignored, which is worse than no note. Do not add those rules;
`orch-completion-check.py`'s docstring says the same.

In a legacy-history thread that uses code-mode `exec`, the check says
nothing, so a false PASS there is not caught. It also says nothing on a
paginated thread whose only `exec` scripts so far ran no command, since that
log looks the same.

## Not in scope

`SubagentStop` is not registered for Codex: the payload offers
`agent_transcript_path`, but whether it is the child's rollout in this format
is unverified, and judging a child by its parent's log is worse than silence.
The word split and the lists are shared with the Claude check on purpose; see
that file's docstring.

## Verification

`bash tests/test-codex-verify-gate.sh` runs the hook on scrubbed real lines
of each kind of log in the table above (`tests/fixtures/codex-rollouts/`) and
on generated fixtures in the same shapes, including a decoy script and an agent-printed result with no
harness record behind them, runners named by a path, behind a named wrapper or
through `pnpm`/`yarn`/`npx`, a project's `runner.test_cmd`, and the honest shapes (`2>&1`, a quoted `&`, a
here-string, a multi-line quoted argument) that must stay silent, and asserts
the invariants (exit 0, no `systemMessage`, no stderr).
`bash tests/test-install-global.sh` G16 runs the command exactly as
`.codex-plugin/plugin.json` registers it, and G17 (with `CODEX_BIN` set)
lists the hooks through a real Codex app server after a plugin install. Live Codex: unverified in tests; one turn
after `/hooks` trust shows it.
