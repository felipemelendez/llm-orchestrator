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
bash entry that hands the event to `scripts/lib/orch-disk-guard.py` (shlex
tokenizing, path resolution). Exit 0 allows; exit 2 refuses with the reason on
stderr. Like `guard-destructive-git.sh` it never uses `set -e`, and every path
ends in exit 0 or exit 2. It is timed in `tests/test-hook-latency.sh` on a
plain command and on a long command it parses and refuses (about 45 ms each,
budget 500 ms). Without `python3`, or when the helper exits with anything but
0 or 2, a plain text check refuses any command naming `/tmp/claude-` or
`$TMPDIR`/`${TMPDIR` together with a write word; the helper does the same for
a command it cannot tokenize (unbalanced quotes).

### What it refuses

1. **A copy into itself.** `cp` with `-R`, `-r` or `-a`, `rsync`, `ditto`, and
   a `tar -c ... | tar -x ...` pipeline (a subshell such as
   `| (cd x && tar xf -)` is part of the pipeline), when the destination
   resolves at or inside a source: `cp -R . ./sub`, `rsync -a ./ ./backup/`,
   `ditto . sub`, `tar -cf - . | tar -xf - -C sub`, `cp -R * sub/`.
2. **A write into a shared temporary folder.** The shared folders are
   `/tmp/claude-*` and `/private/tmp/claude-*` (any user), and the hook's own
   `$TMPDIR` unless it is `/` or the home folder. Write-type means: a `>`,
   `>>`, `>|`, `&>` redirection or a heredoc into a file; the destination of
   `cp`, `mv`, `rsync`, `ditto`, `install` or `ln`; `mkdir`, `touch`, `rm`,
   `rmdir`, `truncate`, `tee`; `dd of=`; `curl -o`/`-O`/`--output-dir`;
   `wget` (its `-O`/`-P` or the current folder); `tar -x` (its `-C` or the
   current folder) and `tar -cf <file>`; `unzip` (its `-d` or the current
   folder); `git clone` (its destination, or the repository name in the
   current folder); `git worktree add <path>`; `mktemp` given an explicit
   folder (`-p`, `--tmpdir=`, or a template with a `/`). A new folder under
   the shared root (the incident began with `mkdir pr`) is covered here.
3. A command nested more than four levels deep (`bash -c` inside `$(...)`
   inside ...) is refused as not checkable.

A literal `$TMPDIR` is read twice, once as `/tmp/claude-<uid>` (what Claude
Code's sandbox gives every command, F3) and once as the hook's own `$TMPDIR`;
either landing in a shared folder refuses.

### What it allows

- Everything outside the shared folders: copies and writes in the clone or
  project, and in a review's run directory, which `run` already keeps outside
  every temporary folder (R1).
- Inside them, the session's own folder,
  `/tmp/claude-<uid>/<any folder>/<session_id>/` (and its `/private` form),
  where `<session_id>` is the event's and matches `[A-Za-z0-9._-]+`; and the
  folder the command starts in (the event's `cwd`), unless that folder is a
  shared root itself.
- Reads (`ls`, `du`, `cat`, `grep`, `find` without `-delete`), and `mktemp`
  with no folder named, and temporary files programs make on their own: the
  hook cannot see them, they are bounded, and refusing `mktemp -d` would break
  ordinary scripts in every session.

### How paths are resolved

Absolute paths; paths relative to the tracked current folder (the event's
`cwd`, then each `cd`/`pushd`/`popd`, which also track `OLDPWD`); `.`, `..`,
trailing `/.`, `~`, `$HOME`, `$PWD`, `$OLDPWD`, `$TMPDIR`, `${NAME:-default}`;
`NAME=value` assignments and `export` earlier in the same command; a glob
resolves to its folder part (`src/*` is `src`). Paths go through `realpath`.
`bash -c`/`sh -c`/`zsh -c` strings, `eval`, `$(...)`, `<(...)` and backticks
are parsed as commands; heredoc bodies are dropped as data. A destination
built from anything else (another variable, a command's output such as
`D=$(mktemp -d)`) is not known and does not by itself refuse. These limits,
and that programs writing files themselves (python, node, tests) are not seen,
are stated in the hook's header.

### The message

`disk guard: refused: <what>, e.g. "cp copies <src> into <dst>, a folder
inside it, which never ends" / "mkdir creates /private/tmp/claude-501/pr,
inside the shared temporary folder /private/tmp/claude-501".` then `Work in
the clone or folder you were given at <cwd>: run every command, evidence
script and experiment there, and keep copies and temporary files inside it or
in your session folder <folder>. Never copy, clone or extract it into itself,
into $TMPDIR or /tmp/claude-*, or into a parent folder.`

The person's own override, as with `ORCH_ALLOW_DESTRUCTIVE_GIT`:
`ORCH_ALLOW_TEMP_WRITES=1` in the hook's own environment. An inline prefix
does not disarm it, and the launchers' reduced environment never passes it.

### Where it is wired

- `hooks/hooks.json`, `PreToolUse` `Bash`, after the two existing guards:
  every Claude Code session that has the plugin, and its subagents.
- Every `claude -p` the plugin launches (`run_claude`, `run_runner`,
  `run_code_review` in `orch-review.py`; `orch-control.py launch` uses
  `run_claude`): the hook goes into the `--settings` JSON next to the sandbox,
  as `bash <absolute path of the plugin's own guard-disk-writes.sh>`, outside
  the clone, so a reviewer cannot change it. These launches drop
  `--safe-mode` (F1) and keep `--restricted` and `--strict-mcp-config`, which
  keep the person's settings files, CLAUDE.md, plugins and MCP servers out
  (F2). The launch is checked from its init event: every plugin's `source`
  must end in `@builtin`, or the launch is a dropout, so the guarantee
  `--safe-mode` gave is observed, not assumed. `docs/specs/review-design.md`
  R5 records the flags.
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
  accumulate), each measured with one `du -sk` bounded to 30 seconds ("not
  measured in time" otherwise).
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
- **When it fires.** It kills every process group the run started (every
  launch and experiment is started through one registry), and nothing new
  starts: no launch, no experiment, no copy. It writes `watchdog.json` in the
  run directory with the reason and the path that grew (for the cap, the
  largest entry inside the run directory, descending while one child holds
  more than half; for the free-space floor, the culprits' sizes) and prints
  the same to stderr. `decide()` reads it: the run is `INCOMPLETE` with that
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
    launch` first sweep, bounded to 120 seconds, the tasks the two launchers
    make (task `review <run>` whose only lease, if any, is `orch-review`, and
    `configured-<role>` whose only lease is `configured-cli`), when the task's
    record was last written over 24 hours ago, the task is not `done`, its
    scratch folder still exists (a record whose folder was removed by hand has
    nothing to reclaim and is left as it is), and nobody holds its scratch
    lock. A task from before this change has no
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

- The thresholds: refuse to launch under 5 GiB free; fire under 2 GiB free or
  when the run directory passes 10 GiB; sweep sandboxes over 24 hours idle.
  Set by the owner's brief of 2026-10-28.
- The guard is a hook, not a prompt; the prompt rule is a second layer. Set by
  the owner's brief: the incident came from a model ignoring the clone it was
  given.
