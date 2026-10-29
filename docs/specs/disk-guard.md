# Spec: review agents cannot fill the disk

Status: built 2026-10-28 (release 0.19.0), for review. Maintained alongside
`scripts/hooks/guard-disk-writes.sh`, its decision helper
`scripts/lib/orch-disk-guard.py`, `scripts/lib/orch-review.py`,
`scripts/lib/orch-control.py` and `scripts/lib/orch-task-resources.py`.
Tests: `tests/test-disk-guard.py`, the `test_disk_*` cases in
`tests/test-review.py`, the disk cases in `tests/test-policy.py` and
`tests/test-task-resources.py`, and the guard's two rows in
`tests/test-hook-latency.sh`.

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
allows; exit 2 refuses with the reason on stderr. Like
`guard-destructive-git.sh` it never uses `set -e`, and every path ends in
exit 0 or exit 2. It is timed in `tests/test-hook-latency.sh` on a plain
command, on a long command it reads and refuses, and on a line of 150
`cd dN && echo a b c` steps before a shared write (budget 500 ms each). Every
path is resolved with one lookup per folder not seen before, so a long line
stays far under the 10 s hook timeout, at which Claude Code would run the
command unchecked. Without
`python3`, or when the helper exits with anything but 0 or 2, a plain text
check refuses any command naming `/tmp/claude-` or `$TMPDIR`/`${TMPDIR`
together with a write word.

The first version modelled the shell exactly (option arities per command, the
current folder after each `cd`, the order of substitutions). The Full review
of PR #55 reproduced it failing open thirteen ways on ordinary syntax
(`cp -f -R . ./sub`, `rm -r /tmp/claude-501/pr`, `curl -sSLo /tmp/...`,
`cd $TMPDIR && true $(mkdir pr)`, `timeout 600 cp -R . ./sub`,
`(cd /); mkdir pr`, `echo $((1<<2))` before a line it then skipped). Each was a
gap in the model, and a model of the shell always has another. The rules
below are conservative instead: when unsure, they refuse.

**The contract.** The hook catches the forms agents actually write, by
accident or in evidence scripts. Anything it cannot read with confidence
that copies, or that writes near a shared root, is refused: it fails closed.
It is not a security boundary against a command built on purpose to hide a
write (Settled). The backstop for whatever it misses is the watchdog (G3:
the 2 GiB free-space floor and the 10 GiB run-directory cap, which kill the
run) and the per-launch temporary folder (G2), which keeps a Codex child's
`$TMPDIR` inside the run directory the watchdog measures.

### What it refuses

1. **Rule A, the shared temporary folder.** A command that names a shared
   folder outside the session's own folder and holds a write word anywhere is
   refused. The shared folders are `/tmp/claude`, `/tmp/claude-*` and their
   `/private` forms (any user), `$TMPDIR` in any spelling (`$TMPDIR`,
   `${TMPDIR}`, and `${TMPDIR` with any operator: `:-` `-` `:=` `=` `:?` `?`
   `:+` `+` `#` `%` `/`), and the hook's own `$TMPDIR` unless it is
   `/` or the home folder. Every word, the value after `=` (`D=`, `of=`,
   `--output=`), an absolute path attached to an option (`-o/tmp/...`), and
   an absolute path inside a longer word is a path candidate. Each is
   normalized before it is matched (`//`, `/./`, `..` and symlinks resolved),
   and a relative one is resolved from every folder the line may be in (where
   it starts and each `cd`/`pushd` target), so `cd /tmp && mkdir
   claude-501/pr` and `mkdir pr` started in `/tmp/claude-501` are caught.
   The variables the hook knows are replaced first: the line's own as they
   stand at that word, `$PWD` as each of those folders, `$OLDPWD`, `$HOME`
   and `$TMPDIR` (`cd /tmp && mkdir "$PWD/claude-501/pr"` is caught). A word
   with a part whose value is unknown (`$$`, `$RANDOM`, `$1`, `$(...)`) keeps
   the folder spelled before that part, so `mkdir "$TMPDIR/review-$$"` names
   `$TMPDIR`.
   The write words are `cp mv rsync ditto tar mkdir touch tee dd rm rmdir ln
   install unzip curl wget truncate mktemp clone worktree -delete` as whole
   words, and a `>` redirection to anything but `/dev/null`, `/dev/stdout`,
   `/dev/stderr` or `/dev/tty`. Both are gathered from the whole line and
   every part that runs: `$(...)`, `<(...)`, `>(...)` and backticks (not in
   single quotes), the inside of `$((...))` and `((...))` arithmetic,
   `bash -c`/`sh -c`/`zsh -c` strings, `eval`, and a heredoc whose line,
   read without its `#` comment, feeds `bash`, `sh`, `zsh`, `xargs`, `eval` or
   `source` anywhere on it (`cat <<EOF | bash` included; `cat > notes.md
   <<'EOF'  # for the bash step` is data). Inside arithmetic, `<`, `>`, `<<`
   and `>>` compare and shift, never redirect or open a heredoc
   (`echo $((size >> 10))` writes nothing); a `$(...)` in it keeps its own.
   A `((` whose parentheses do not close as `))` (`((cd x) )`) is two
   subshells, as bash reads it. Because
   the two are gathered, not matched to each other, a `cd` into the shared
   folder, a wrapper (`timeout`, `xargs`, `find -exec`, `nice`, `stdbuf`), an
   option value, or a subshell cannot separate them.
2. **Rule B, a copy into itself.** `cp` with `-R`, `-r` or `-a` (in any
   cluster, anywhere after `cp`), `rsync`, `ditto` (anywhere in the line, so
   behind any wrapper), and a `tar -c ... | tar -x ...` pipeline, when a
   destination resolves at or inside a source: `cp -R . ./sub`,
   `cp -f -R . ./sub`, `cp -r -T . sub`, `rsync -a ./ ./backup/`,
   `ditto . sub`, `tar -cf - . | tar -xf - -C sub`, `cp -R * sub/`,
   `find . -exec cp -R {} ./sub \;` (`{}` reads as `find`'s first folder).
   Every non-option word after the copier is a path; the destination is the
   last one, or cp's `-t`/`--target-directory` value (`-t dir`, `-Rt dir`,
   `-tdir`, `--target-directory=dir`), which is then never also a source;
   rsync's `-t` keeps times, so `rsync -a -t ./ ./backup/` is refused.
   Variables are read as they stand at that copy in the line
   (`D=sub; cp -R . "$D"; D=/x` is refused). A destination with an unknown
   part is inside the folder spelled before it (`cp -R .
   "./snapshot-$(date +%s)"` is refused); a source with one is not read.
   Paths are resolved from
   every folder the line may be in: where it starts, and each `cd`/`pushd`
   target, in every combination with `$OLDPWD`. A `tar` pipeline is read from
   the folder the shell runs each side in, so `tar cf - . | (cd /dest && tar
   xf -)` is allowed.
3. A command nested more than four levels deep (`$(...)`, `bash -c` and
   `eval` each count) is refused as not checkable.
4. A command it cannot tokenize (unbalanced quotes outside a heredoc) is
   refused when it holds a copier or `tar`, or names a shared folder together
   with a write word.

### What it allows

- Everything that does not name a shared folder and copies nothing into
  itself: copies and writes in the clone or project, and in a review's run
  directory, which `run` already keeps outside every temporary folder (R1).
- Inside the shared folders, the session's own folder,
  `/tmp/claude-<uid>/<any folder>/<session_id>/` (and its `/private` form),
  where `<session_id>` is the event's and matches `[A-Za-z0-9._-]+`; and the
  folder the command starts in (the event's `cwd`), only when that folder lies
  inside a shared root, below it: never the root itself, and never a folder
  above one (`/`, `/tmp`, `/private/tmp`).
- A command that only reads a shared folder (`ls`, `du`, `cat`, `grep`,
  `find` without `-delete`), and `mktemp` with no folder named.
- Text in single quotes, which the shell never runs
  (`printf %s '$(mkdir /tmp/claude-501/pr)'`, `grep -rn 'mkdir /tmp/...' .`).
- A heredoc that is data (`cat > notes.md <<'EOF'`, `git commit -F - <<EOF`):
  its body is read only for names of a shared folder, so text with
  apostrophes or the words cp and mkdir in it is fine.

A path the line does not spell (a variable set by an earlier command,
`D=$(mktemp -d)`, a symlink made earlier) is not known, and programs that
write files themselves (python, node, tests) are not seen. These limits are
stated in the hook's header.

### The message

`disk guard: refused: <what>, e.g. "cp copies <src> into <dst>, a folder
inside it, which never ends" / "mkdir in a command that names the shared
temporary folder (/tmp/claude-501/pr)".` then `Work in the clone or folder
you were given at <cwd>: run every command, evidence script and experiment
there, and keep copies and temporary files inside it or in your session
folder <folder>. Never copy, clone or extract it into itself, into $TMPDIR or
/tmp/claude-*, or into a parent folder. A command that only reads the shared
folder runs if it has no write in the same line.`

The person's own override, as with `ORCH_ALLOW_DESTRUCTIVE_GIT`:
`ORCH_ALLOW_TEMP_WRITES=1` in the hook's own environment. An inline prefix
does not disarm it, and the launchers' reduced environment never passes it.

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

- The guard is conservative, not an exact model of the shell (Full review of
  PR #55, 2026-10-29: the exact model failed open thirteen ways). A command
  that names a shared temporary folder and holds a write word anywhere is
  refused even when the write goes elsewhere: `cat /tmp/claude-501/x.log >
  out.txt`, `ls /tmp/claude-501 | grep tar`, `(cd /tmp/claude-501); mkdir pr`.
  Reason: a line that both reads the shared folder and writes elsewhere is
  rare for an agent, the message says to run the read on its own, and every
  narrower rule tried had a form that slipped through.
- Option values are never told apart from paths in rule B (`rsync -e ssh`
  makes `ssh` a source). Reason: telling them apart needs every program's
  option table, and a missing entry hid `-R` (`cp -f -R`); a wrong extra path
  can only refuse more.
- A heredoc fed to anything but a shell or `xargs` is data: only its names of
  a shared folder count. Reason: notes and commit messages hold apostrophes
  and the words cp or mkdir; a heredoc into a file that names the shared
  folder is still refused. Write such a file with the editor tool.
- A line nested more than four levels (`$(...)`, `bash -c`, `eval`), or one
  it cannot tokenize that copies or writes near the shared folder, is refused.
  Reason: no agent writes either in ordinary work, and both fail closed.

- The thresholds: refuse to launch under 5 GiB free; fire under 2 GiB free or
  when the run directory passes 10 GiB; sweep sandboxes over 24 hours idle.
  Set by the owner's brief of 2026-10-28.
- The guard is a hook, not a prompt; the prompt rule is a second layer. Set by
  the owner's brief: the incident came from a model ignoring the clone it was
  given.
