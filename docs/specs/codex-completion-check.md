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
     in. Outside quotes:
     - `;`, `&`, `&&`, `|`, `||`, `(`, `)` and newlines end a segment.
     - A redirection ends the word before it and is dropped together with
       its target word: `<`, `>`, `>>`, `<>`, `>|`, `<&`, `>&`, `&>`,
       `&>>`, `<<<`, each optionally after a descriptor number (`2>`,
       `2>&1`, `0<`). So `2>/dev/null pytest` reads as `pytest`.
     - `<<WORD`, `<<'WORD'` and `<<-WORD` start a heredoc: its body, from
       the next line up to the line that is exactly `WORD` (after leading
       tabs for `<<-`), is skipped, so a body line is never read as a
       command. With no such line the rest of the command is skipped.
     - A `#` that starts a word starts a comment, which runs to the end of
       the line.
     If a quote is left open, every quote is read as an ordinary character.
  2. **Prefixes.** Leading `VAR=value` words are skipped, and so are these
     programs with the options listed for each and their plain arguments:
     `env` (`-i`, `-u NAME`, `-C DIR`, `-0`, `-v`), `time` (`-p`),
     `timeout DURATION` (`-k N`, `-s SIG`, `--signal=SIG`,
     `--preserve-status`, `--foreground`, `-v`) and `cd DIR` (`-L`, `-P`).
     An option not listed stops the skipping, so the segment is not read as
     a check.
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
     check. For `npx` and `npm exec`, `-c CMD` / `--call CMD` names a
     command, and that command is judged by these same rules (nested up to
     three deep). The option lists come from npm 11's and uv's own help;
     npx's `-p` is `--package`, while npm's `-p` is `--parseable` and is not
     accepted after `npm exec`. The lists for pnpm, yarn and bun come from
     their published documentation, not a local run. `npm`, `pnpm`, `yarn` and `bun` are read the same way; after
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
     Nor is a runner given one of its own dry-run or skip options:
     `make` with `-n`, `--just-print`, `--recon`, `-q` or `--question`;
     `just -n`; `cargo --no-run`; `gradle`/`gradlew -m`; `mvn -DskipTests`
     or `-Dmaven.test.skip` (bare or `=true`). An option combined with
     others (`make -kn test`) is not recognised.
- When the project's `docs/llm-orchestrator/cadence.json` sets
  `runner.test_cmd`, a command also passes when the words and operators of
  `test_cmd`, read by step 1, appear in the command's, starting where a
  segment's command may start: at the segment's first word or after any of
  its prefixes or a named wrapper's `--` (steps 2 and 3). So `cd /repo &&
  cd app && ./check -q` matches `cd app && ./check`, and
  `aws-vault exec p -- bin/suite --fast` matches `bin/suite --fast`.
  Redirections are dropped on both sides, so `bin/suite --fast</dev/null`
  and `bin/suite 2>/dev/null --fast` match `bin/suite --fast`, and
  `bin/suite --fastest` does not. A segment the match touches that asks
  only to print (step 6) cancels it. The search is Knuth-Morris-Pratt over
  the words, so it is linear however long both commands are. The project
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
  one program, so it is joined with `shlex.join`, which quotes each
  argument. `["git","commit","-m","Fix gate (pytest)"]` stays one program
  with one message.
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
- A quote left open anywhere in the command: every quote is then read as
  an ordinary character, so quoted text can be read as words.
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
