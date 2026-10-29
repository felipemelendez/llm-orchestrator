# Spec: review agents cannot fill the disk

Status: built 2026-10-28 (release 0.19.0); G1 rebuilt as a closed list on
2026-10-29; for review. Maintained alongside
`scripts/hooks/guard-disk-writes.sh`, its decision helper
`scripts/lib/orch-disk-guard.py`, `scripts/lib/orch-review.py`,
`scripts/lib/orch-control.py` and `scripts/lib/orch-task-resources.py`.
Tests: `tests/test-disk-guard.py`, the `test_disk_*` cases in
`tests/test-review.py`, the disk cases in `tests/test-policy.py` and
`tests/test-task-resources.py`, the guard's four rows in
`tests/test-hook-latency.sh`, and its install probe in `tests/test-install.sh`.

## What happened

On 2026-10-28, in the Mia project, a Claude reviewer launched by
`orch-review.py` (`claude -p`, Bash sandboxed, `TMPDIR=/tmp/claude-501` inside
the sandbox) ran as an "evidence" command
`cd $TMPDIR && rm -rf pr && mkdir pr && cp -R "$OLDPWD"/. .`, copying a
directory into a folder inside itself without end: 79 GB in 12 minutes, the
startup disk full, every agent on the machine stopped with ENOSPC. Round 4 of
the same review did the same with `bash "$TMPDIR/c1.sh"` evidence scripts.
The reviewer improvised a scratch copy of the repository instead of working in
the clone the script gave it. Separately, review sandboxes under
`~/.cache/llm-orchestrator/task-resources/scratch/` (full clones with
`node_modules`, about 1 GB each) accumulated to 17-24 GB and were never removed.

## Live facts (claude 2.1.312, macOS, 2026-10-28)

Measured by the previous writer of this spec with `--model haiku` probes; not
re-measured by the writer who built it (no model calls were made while
building). They decide the shape of G1 and G2.

- **F1.** Under `--safe-mode`, a `PreToolUse` hook passed in `--settings` does
  not fire: the command ran and the hook's log stayed empty. With
  `--restricted` and without `--safe-mode`, the same hook fires and its deny
  reaches the model (`PreToolUse:Bash hook error: <reason>`).
- **F2.** With `--restricted` and without `--safe-mode`, the init event lists
  the same plugins (only the three `@builtin` ones), the same 19 skills and no
  MCP servers, and the request has the same input token count as with
  `--safe-mode`. A `CLAUDE.md` holding a marker word in the working directory
  was not loaded in either mode. `claude --help` says `--restricted` "ignores
  user, project and local settings files (managed settings and --settings
  still apply)".
- **F3.** Inside Claude Code's Bash sandbox, commands see
  `TMPDIR=/tmp/claude-<uid>` whatever `TMPDIR` or `CLAUDE_CODE_TMPDIR` the
  `claude` process was given, and the sandbox lets them write files and create
  directories anywhere under `/tmp/claude-<uid>` even when
  `filesystem.allowWrite` names only the copy. `/tmp` itself is refused.
- **F4.** The `claude` process puts the sandbox's Unix socket in its own
  `TMPDIR` (`$TMPDIR/srt-mux-<pid>-<n>.sock`). A `TMPDIR` long enough to push
  that path past macOS's 104-byte socket limit fails the sandbox
  (`ENAMETOOLONG ... listen`), and the launch cannot run Bash at all.
- **F5.** `CLAUDE_CODE_TMPDIR=<dir>` moves Claude Code's own temporary files
  (session folders, `bash-edit-diff`) to `<dir>/claude-<uid>/`; the sandboxed
  `TMPDIR` stays `/tmp/claude-<uid>`.
- **F6.** Adding `/tmp/claude-<uid>` and `/private/tmp/claude-<uid>` to the
  sandbox's `filesystem.denyWrite` refuses those writes, but Claude Code's own
  working-directory tracking file (`/tmp/claude-<uid>/cwd-<n>`, written by the
  sandboxed shell) then fails and every command reports exit 1. The sandbox
  therefore cannot close the temp root; the hook is the guard.

## G1. The guard hook

A `PreToolUse` hook on `Bash`: `scripts/hooks/guard-disk-writes.sh`, a thin
bash entry that hands the event to `scripts/lib/orch-disk-guard.py`, run as
`python3 -I` so nothing beside it or in the environment is imported. Exit 0
lets the command run; exit 2 refuses it, with the reason on stderr. Like
`guard-destructive-git.sh` it never uses `set -e`, and every path ends in
exit 0 or exit 2. When `python3` is missing, or the helper exits with anything
but 0 or 2 (an event it cannot read, a bug; its own output is then dropped),
a plain text check runs instead: `grep -E` refuses rule 1's words and any
copier word (`cp`, `rsync`, `ditto`, `tar`), because it cannot read rule 2.

**The contract.** The hook reads the command as flat text. It has no model
of the shell: no variable values, no `cd` tracking, no difference between
code and data, no list of write words. What it refuses is the closed list
below, and every step of it is linear in the command's length, so the
harness's 10 s hook timeout, at which Claude Code would run the command
unchecked, cannot be reached. `tests/test-hook-latency.sh` times it on a
plain command, the incident, a 96,000-character line of copies and a 1.5 MB
line (budget 500 ms each).

A form outside the list runs. That is the specified behaviour, not a
defect. Its bound is G3 (the 2 GiB free-space floor, which kills the run, and
the 10 GiB run-directory cap for Codex children, whose `$TMPDIR` is inside
the run directory) and G2's prompt rule. The hook is not a security boundary
(Settled).

### What it refuses

0. **First, two normalizations.** `//` and `/./` become `/`. Then each
   occurrence of the session's own folder,
   `(/private)?/tmp/claude(-<digits>)?/<project>/<session id>` followed by
   the rest of its path (up to a space or one of ``;&|()<>` ``), is set aside:
   rule 1 does not see it, and rule 2 reads it as one fixed folder. The
   session id is the event's `session_id`, when it matches
   `[A-Za-z0-9._-]+`; the project folder matches `[A-Za-z0-9._-]+`. An
   occurrence whose rest holds `..` is not set aside
   (`mkdir <session folder>/../../pr` is refused by rule 1).
1. **The shared temporary area.** A command whose remaining text, anywhere
   (quotes, heredoc bodies and arithmetic included), holds any of these is
   refused, whether it reads or writes:
   - a reference to `$TMPDIR`: `$TMPDIR`, and `${TMPDIR` with any operator
     or none (`${TMPDIR}`, `${TMPDIR-/tmp}`, `${TMPDIR:?}`, `${#TMPDIR}`,
     `${!TMPDIR}`);
   - `/tmp` as a path component (not followed by a letter, digit, `_`, `.`
     or `-`), which covers `/private/tmp`, `//tmp`, `/tmp/claude*`,
     `/tmp/claude` and `/tmp/{claude-501,x}`;
   - the word `mktemp`;
   - `claude-<digits>` as a path component or a bare word
     (`cd /tmp && mkdir claude-501/pr`, `cd /; cd tmp; mkdir claude-501/pr`).

   Paths and names are matched without regard to case, as macOS's disk
   ignores it; the variable name `TMPDIR` is matched as written. A plain
   assignment `TMPDIR=<path>` is not a reference, so an orchestrator can
   launch a child with its own temporary folder; its value is checked like
   any other text (`TMPDIR=/tmp/x codex exec` is refused for `/tmp`).
2. **A recursive copy into itself.** A `tar … | … tar` pipeline on one line
   (a `tar` word, then a `|`, then another `tar` word) is refused: extract
   with `-C` into a spelled-out folder, as two commands. When the text holds
   `cp`, `rsync` or `ditto` as a word, it is tokenized once with `shlex`
   (POSIX rules; `;&|()<>` and the backtick are separators; a
   backslash-newline joins lines and a newline separates commands). A
   tokenizer error (quotes that do not close) refuses. A copy is a token
   whose name after the last `/`, in any case, is `cp`, `rsync` or `ditto`;
   its arguments are the tokens after it, up to the next separator or copier
   (a digit just before a redirection, the `2` of `2>`, is dropped). It is
   recursive when it is a `cp` with `r`, `R` or `a` in any short-option
   cluster, or with `--recursive` or `--archive`, and every `rsync` or
   `ditto`. Its operands are the arguments that do not start with `-`; the
   destination is cp's `-t` value (`-t dir`, `-tdir`, `-Rt dir`,
   `--target-directory[=]dir`) or else the last operand, and the others are
   the sources. A separate option value counts as an operand
   (`rsync -e ssh` makes `ssh` a source): it can only refuse more. A
   recursive copy is refused when:
   - an operand is not made only of `A-Z a-z 0-9 . _ / + -`: a `$`, `~`, `{`,
     backtick, `:`, `*`, `?`, `[`, `=`, `\`, space or any other character
     refuses;
   - an operand is relative and the text also holds `cd`, `pushd` or `popd`
     as a word;
   - it has a destination and no source on the line (`ls | xargs cp -R -t
     sub`);
   - the destination, resolved with `normpath(join(cwd, op))` from the
     event's `cwd`, equals or lies inside a source (`cp -R . ./sub`,
     `cp -r .. sub`, `rsync -a ./ ./backup/`, `ditto . sub`).
3. **Too long.** A command longer than 100,000 characters is refused when
   it holds, as a plain substring in any case, `cp`, `rsync`, `ditto`, `tar`,
   `tmpdir`, `/tmp`, `mktemp` or `claude-`, and runs otherwise. This test
   comes before anything else.

The person's own override, as with `ORCH_ALLOW_DESTRUCTIVE_GIT`:
`ORCH_ALLOW_TEMP_WRITES=1` in the hook's own environment. An inline prefix
does not disarm it, and the launchers' reduced environment never passes it.

### What it allows

Everything else: copies and writes in the clone or project and in a review's
run directory, which `run` keeps outside every temporary folder (R1)
(`cp -R src dist`, absolute-path copies, `mkdir -p build && cp -r scripts
build/`, `tar -czf out.tgz src`, `cat README.md > notes.md`, `rm -rf build`);
reads and writes under the session's own folder; `claude --model
claude-opus-4-1 -p hi`; `TMPDIR=<session folder>/t codex exec …`; a notes
heredoc that mentions cp or mkdir without a recursive copy in it.

**Over-refusals, on purpose.** The list refuses some commands that write
nothing to the shared area or into themselves: `cat /tmp/x.log`,
`ls $TMPDIR`, `du -sk /tmp/claude-501`, `ls -d /tmp/claude*`, a bare
`mktemp -d`, single-quoted text such as `printf %s '$(mkdir /tmp/x)'`, a
relative path ending in a `tmp` folder (`rm -rf build/tmp`),
`cp -R "$SRC" dest`, `cp -R src/* dist/`, `cp -R ~/repo .`,
`cd sub && cp -R ../x y`, `rsync -a src/ host:dst/`,
`rsync -a --exclude '*.log' src/ build/` (write `--exclude='*.log'`),
`tar cf - src | (cd /dest && tar xf -)`, and a heredoc with an unclosed
apostrophe on a line that holds a copier word
(`cat > notes.md <<'EOF'` … `don't cp -R . sub`; write such a file with
the Write tool). Each refusal says what to do instead.

**Residual gaps, by design.** A variable or symlink made by an earlier
command (`D=/tmp/claude-501` in one call, `mkdir "$D/pr"` in the next); a
path built by another program (`cd "$(printenv TMPDIR)"`); programs that
write files themselves (python, node, make, tests); a copy inside a quoted
string that another program runs (`bash -c 'cp -R . ./sub'`,
`echo "$(cp -R . ./sub)"`); a relative path in a command that starts in the
shared area, or after a `cd` into the session's own folder followed by
`cd ..`; and option spellings outside the list (`cp --rec`). These run, and
G3 bounds them.

### The message

`disk guard: refused: <what>. <what to do instead>.` For rule 1: `the
command names the shared temporary area (<the word>). Read a file there
with the Read tool; work in the clone or folder you were given, <cwd>; and
put temporary files in your session's own folder, <folder>` (or `inside
that folder` when the session's folder is not known). For rule 2, for
example: `cp copies <src> into <dst>, a folder inside it, which never ends`;
`cp copies with a path that is not spelled out ($D). In a recursive copy,
write each path with letters, digits and . _ / + - only: no variable, ~,
glob, brace, quote, space or colon`; `a tar pipeline (tar ... | ... tar).
Extract with -C into a folder you spell out, as two commands`. For rule 3:
`a command over 100,000 characters that copies or names the shared
temporary area. Split it into shorter commands`.

### Where it is wired

- `hooks/hooks.json`, `PreToolUse` `Bash`, after the two existing guards:
  every Claude Code session that has the plugin, and its subagents.
- Every `claude -p` the plugin launches (`run_claude`, `run_runner`,
  `run_code_review` in `orch-review.py`; `orch-control.py launch` uses
  `run_claude`): the hook goes into the `--settings` JSON next to the sandbox.
  It runs outside the sandbox, so it runs from a copy of the hook and its
  helper made once in `<run dir>/guard/`, which the launch can neither read
  (`denyRead`) nor write; the plugin's own files can sit inside the folder a
  launch may write (a `--copy` install under `<project>/.claude`, or
  `orch-control.py launch` on the plugin's own repository), where a model
  could otherwise rewrite the hook it runs under. A run directory inside the
  folder the launch may write is refused. These launches drop `--safe-mode`
  (F1) and keep `--restricted` and `--strict-mcp-config`, which keep the
  person's settings files, CLAUDE.md, plugins and MCP servers out (F2). The
  launch is checked from its init event: every plugin's `source` must end in
  `@builtin`, or the launch is a dropout, so the guarantee `--safe-mode` gave
  is observed, not assumed. `docs/specs/review-design.md` R5 records the flags.
- Not wired: the Codex plugin, and Codex children (`codex review`,
  `codex exec`, `codex sandbox`), which launch with plugins disabled. They get
  the per-launch `TMPDIR` (G2) and the watchdog (G3). The existing guards are
  not wired for Codex either.

## G2. The prompt rule and the per-launch temporary folder

- Every prompt the plugin gives a model process carries one text,
  `WORKSPACE_RULE`, formatted with the folder it runs in: "Work only in
  <path>, the folder you were given: run every command, evidence script and
  experiment inside it, and keep any temporary file inside it. Never copy,
  clone or extract the repository, or any part of it, into $TMPDIR, /tmp or
  any parent folder of <path>; a guard refuses those commands." It is added
  in the five launch functions, so `/code-review`, `codex review`, the prover,
  the refuter, the Claude runner and `orch-control.py launch` (where the path
  is the project) all get it.
- Each Codex child gets `TMPDIR=<its launch or experiment folder>/tmp`, a
  folder inside the run directory, created before the launch and removed when
  it ends: `codex review`, `codex exec`, every `codex sandbox` experiment and
  drop check, and the preflight's sandbox probe. A runaway write through
  `$TMPDIR` then lands where the watchdog measures it.
- Claude children keep the launcher's `TMPDIR`, and get no
  `CLAUDE_CODE_TMPDIR`. Their sandboxed commands see `/tmp/claude-<uid>`
  whatever the process gets (F3), a long `TMPDIR` breaks the sandbox (F4), and
  `CLAUDE_CODE_TMPDIR` moves only Claude Code's own files (F5); a folder for
  them inside the run directory, which the sandbox may not read, was never
  verified live. The guard in `--settings` is their protection.

## G3. Free-space refusal and watchdog

- **Refusal at launch.** `orch-review.py run` (before it creates the run
  directory, so also before `--detach`) and `orch-control.py launch` refuse
  when the volume holding the run directory (its nearest existing folder) has
  less than 5 GiB free: exit 2, printing the free space, the `df -h` line of
  that volume and the size of the likely culprits (the task-resource
  `scratch/`, `/tmp/claude-<uid>`, and the run directory's parent, where runs
  accumulate, both at launch and when the watchdog fires), each with its own
  `du -sk`, all started together under one 30-second deadline; every one
  that finished by then counts, so a slow one leaves the others measured
  ("not measured in time" otherwise).
- **While a run is live.** A watchdog thread, in the process that runs the
  review (the foreground run or the `--child` of `--detach`) and in
  `orch-control.py launch`, reads free space and the run directory's size
  every 10 seconds. The brief said every 60 seconds; at the incident's
  6.6 GB a minute, 60 seconds could pass from the 5 GiB launch floor to a full
  disk between two readings. It fires below 2 GiB free or when the run
  directory (which holds every Codex `TMPDIR`) passes 10 GiB. The review
  copies under `scratch/` are not counted: their size is the repository's
  times the number of copies, known before launch, and a runaway inside one is
  refused by G1 or caught by the free-space floor.
- **When it fires.** It kills every process group the run started, and
  nothing new starts: no launch, no experiment, no copy, no copy step. Every
  launch, experiment and preparation step (the `copy_ignored` copies and
  `review.setup`) is started through one registry, `spawn()`, and a copy
  checks for the stop between its steps; only the `git clone` of a copy runs
  inside the task manager, bounded by the repository's size. For the cap, the
  path that grew (the largest entry inside the run directory, descending while
  one child holds more than half) is measured before the kill, because a
  killed Codex launch removes its tmp folder right after; a file vanishing
  while it is measured gives "not measured", never a dead watchdog. For the
  free-space floor the culprits are measured after the kill. The reason is
  then written to `watchdog.json` whatever the measuring did, and printed to
  stderr. `decide()` reads it: the run is `INCOMPLETE` with that
  reason, and the outcome row carries it. The killed launches are ordinary
  dropouts, so the copies are removed at the end (G4). For
  `orch-control.py launch` the attempt is a dropout with the reason.
- Thresholds and the interval are module constants (`FREE_TO_LAUNCH`,
  `FREE_FLOOR`, `RUN_DIR_CAP`, `WATCH_INTERVAL`) read when used, and the
  free-space reading is one function (`free_bytes`), so tests set a 1 MiB cap
  and a 0.2 s interval, or a replaced reading, without an environment switch.

## G4. Sandbox cleanup

- **Why they were left (read from the live records under
  `~/.cache/llm-orchestrator/task-resources/tasks/` on 2026-10-28 at 20:29,
  never modified).** Of the review tasks whose scratch was still present:
  - Three `open` with the `orch-review` lease never released and no process
    alive (`a6-r2-20261028-182114` with nine clones, `mia-125-r2`,
    `review-2`), and two `configured-writer` launches the same way. Their
    runs died without running their cleanup: the `a6-r2` run directory stops
    at 18:32, during the disk-full incident, with an empty `run.log` (a full
    disk cannot take the traceback). Nothing ever visits an open task again:
    the Stop hook retries only closed tasks, and only empty ones.
  - One `closed` with no reasons and its clone present
    (`mia116-fix-20261028-183109`): its cleanup was interrupted. Its run
    directory holds a zero-byte `.cleanup.json.<uuid>`: writing the record hit
    ENOSPC while the manager was cleaning. A closed task is retried only by
    the Stop hook, which never removes a non-empty tree.
  - One `closed` with "resource missing, replaced or uncertain"
    (`e1-a5-20261028-184438`): its prover's `git clone` failed with "No space
    left on device", git removed its partial clone, and the resource the
    manager had registered, with no identity, made cleanup call the task
    uncertain for good; the task root stayed.
  - Older tasks also kept clones in which a reviewer had made a commit or a
    nested repository ("clone holds a ref ... it did not have when made",
    "clone contains another repository"); those scratch folders are already
    gone, removed by hand. The ownership checks keep such clones on purpose,
    and this change does not loosen them; it is listed as an open question.
- **Fixes at the source.**
  - `Manager.create` records a resource whose creation failed and left
    nothing at its new, unique path as removed; anything left at the path
    stays uncertain and is kept, as before.
  - A run holds an exclusive `flock` on its task's scratch folder from the
    moment the task exists until its cleanup; the descriptor is not inherited,
    so the lock ends when the run's process does, however it ends.
  - **Sweep at each launch.** `orch-review.py run` and `orch-control.py
    launch` first sweep. The sweep runs in its own process
    (`orch-review.py sweep --state-dir <base>`); the launch waits for it at
    most 120 seconds, and a sweep still running finishes in the background
    (the manager's cleanup is safe to interrupt and resume), so one large or
    locked task never holds a launch. The sweep writes to
    `<state dir>/sweep.log`, never to the launcher's stdout or stderr, so a
    caller reading those does not wait for it; a sweep done in time has its
    lines copied to the launcher's stderr. A task whose lifecycle lock another
    process holds is skipped as busy. It sweeps the tasks the two launchers
    make (task `review <run>` whose only lease, if any, is `orch-review`, and
    `configured-<role>` whose only lease is `configured-cli`), when the task's
    record was last written over 24 hours ago, the task is not `done`, its
    scratch folder still exists (a record whose folder was removed by hand has
    nothing to reclaim and is left as it is), and nobody holds its scratch
    lock. A run or launch whose managed-process shutdown is unconfirmed keeps
    its lease on purpose and adds a second consumer (`orch-review-pending`,
    `configured-cli-pending`), so the sweep never releases it as dead. A task from before this change has no
    lock and is judged by age alone. The sweep releases the dead lease and
    finishes the task through the manager, so every ownership check (owned
    folder and uid, no symlink followed, a clone's refs, a nested repository)
    still applies; any other task (a coordinator's worktree, `PHOEBE-115`) is
    never touched. It prints what it removed and kept.
- **End of run.** A run removes its copies, including ignored content such as
  `node_modules` copied in by `copy_ignored` or made by `review.setup`,
  whatever its verdict. Only a run whose own steps raised (`errors.json`)
  keeps them for inspection (`cleanup.json` says `kept` and where), and the
  sweep removes them a day later. The brief said "keep on failure"; keeping
  every `INCOMPLETE` run's copies was measured against the outcome log: 44 of
  110 runs since 2026-10-27 were `INCOMPLETE`, mostly model dropouts, which
  at about 1 GB a copy would hold tens of GB for a day, the problem this
  change removes. A dropout's record (stream, stderr, `launch.json`) is in the
  run directory; its copy holds nothing more than the reviewed tree.
- `orch-control.py capacity status` adds `scratch`: the folder, total bytes
  and task count under `scratch/`, the bytes and count of review and
  configured-launch sandboxes, and whether `du` finished in time.

## G5. Documentation and release

README, `ARCHITECTURE.md`, `docs/install.md` (the hook table and its
override), a `CHANGELOG.md` entry, `docs/specs/review-design.md` (R1, R5, R6),
and the prover and refuter briefs (`skills/requesting-code-review/references/`),
which describe where commands run. The change ships as release 0.19.0 (the
three version fields, as in 0.18.0), so an installed copy updates with
`claude plugin update` and `codex plugin add`.

## Settled

- The guard is not a security boundary against deliberately obfuscated
  commands (decided by the lead, the Claude opus coordinator, 2026-10-28). A
  bypass that needs a command built on purpose to hide a write (a path
  assembled from the output of another command, a variable set by an earlier
  call, a program that writes files itself) is a follow-up, not a blocker.
  Reason: the incident was an accident in an evidence command, and the forms
  agents write are caught; a full shell model would never be complete. What
  bounds such a bypass: the watchdog kills the run under 2 GiB free or past a
  10 GiB run directory (G3), and each Codex child's `$TMPDIR` is inside the
  run directory it measures (G2).

- The hook is a closed list (round 5 of PR #55, 2026-10-29). Decided by
  the coordinator from a read-only root-cause investigation (Claude Fable).
  Reason: five review rounds (21, 13, 11, 9 and 10 findings, nearly all
  reproduced) did not converge. The earlier contract promised that anything
  the hook could not read with confidence was refused, over all of bash, and
  the code decided "can read" with a negative list of unknown markers and a
  code-versus-data split over an open grammar. That is fail-open by
  construction: each round found the next missing marker, several fixes
  regressed forms that were refused before, and the guard grew from 471 to
  589 lines. A negative list over bash cannot converge. A finding that a form
  outside the list in G1 runs is recorded `settled` against this entry,
  unless it shows a form inside the list behaving otherwise; G3 and G2 bound
  what runs.

- The thresholds: refuse to launch under 5 GiB free; fire under 2 GiB free or
  when the run directory passes 10 GiB; sweep sandboxes over 24 hours idle.
  Set by the owner's brief of 2026-10-28.
- The guard is a hook, not a prompt; the prompt rule is a second layer. Set by
  the owner's brief: the incident came from a model ignoring the clone it was
  given.
