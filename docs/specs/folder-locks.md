# Folder locks: one winner on every system

Date: 2026-10-29. Status: implemented (0.18.1); spec reviewed before coding.

## Problem

The plugin uses "create a folder" as a one-at-a-time ticket: whoever creates
the folder goes first, everyone else waits or refuses. That only works if the
folder command tells exactly one caller "done".

Ubuntu 26.04 replaced the `mkdir` program with the Rust rewrite
(rust-coreutils 0.8.0 in the release, 0.10.0 in updates). Its `mkdir`, without
`-p`, first checks whether the folder exists, then creates it, and when the
create fails it returns success if the path is now a folder
(`Err(_) if path.is_dir() => Ok(())`, not limited to `-p`). Two programs that
pass the check before either creates the folder are both told "done". Newer
upstream versions limit that branch to `-p`; Ubuntu 26.04 still ships the old
ones.

GitHub's `ubuntu-latest` moved to 26.04 around 2026-10-16. Since then three
tests fail at random there and never on 24.04 or macOS: `tests/smoke.sh`'s two
concurrent lock tests (8 or 9 lines of 10, 3 or 4 entries of 5) and
`tests/test-worktree-materialize.sh`'s mutex race (2 and 4 winners of one
folder). Users on Ubuntu 26.04 have the same bug: two memory saves at once can
lose one, two agents can both believe they own a worktree, two integrations
can run against one base.

## Where the plugin relies on it

1. `scripts/lib/orch-lock.sh` `with_lock`: memory writes (`/remember`,
   `/forget`, `/onboard`), the detection and architecture caches
   (`orch-detect.sh`, `orch-arch.sh`) and the researcher validator.
2. `scripts/orch-worktree-integrate.sh` `acquire_int_lock`: one integration
   per base.
3. `scripts/orch-worktree-materialize.sh` `registry_claim`: one owner per
   worktree name. A false win here is worse than a wait: on a failed meta
   write the loser `rm -rf`s the winner's claim.
4. The implementer's writer marker `<worktree>/.orch-active`, which the agent
   creates itself by following `agents/orch-implementer.md` and
   `templates/implementer-prompt.md`.

## Requirement

Each of the four creates its folder through a call that fails when the folder
already exists, whatever `mkdir` program the system has: on any system with
perl, exactly one of any number of simultaneous creators succeeds. This is
about the create step only; `with_lock`'s stale-lock reclaim keeps its own,
documented behaviour.

## Design

- One helper, `orch_mkdir_once <dir>`, in `scripts/lib/orch-lock.sh`. It calls
  the operating system's mkdir directly, `perl -e 'mkdir shift or exit 1' --
  "<dir>"`, with stderr silenced; without perl, the `mkdir` program. The
  branch is chosen by `command -v perl`, never by `perl ... || mkdir`, which
  would hand perl's "already exists" to the faulty program. Perl ships with
  macOS, every Ubuntu (perl-base is essential) and Git for Windows, so the
  fallback only runs where the faulty program is not installed. A python3
  branch was dropped in review: no system the bug reaches lacks perl.
- `with_lock`, `acquire_int_lock` and `registry_claim` call the helper instead
  of `mkdir`. The two worktree scripts source `orch-lock.sh` from
  `scripts/lib/`, as `orch-worktree-materialize.sh` already sources
  `orch-project.sh`.
- The implementer takes its marker with
  `perl -e 'mkdir shift or exit 1' -- "<worktree>/.orch-active"`, run exactly
  as written and on its own; the instructions say why plain `mkdir` is not
  used. If that command cannot run at all (permission denied, or no perl), the
  implementer reads the path like any failed claim (finding nothing there, it
  runs the claim once more first, in case the holder just released it): a folder means another
  writer holds it; nothing there means the claim could not be made (denied,
  no perl, or the worktree missing or not writable), and it stops with
  `Status: BLOCKED` and a Need that names the allow rule and the worktree
  check; anything else is protocol corruption, as before. It never falls back
  to the `mkdir` program: on Ubuntu 26.04 that fallback let two writers in
  (found in review, after a first version had it). Everything else about the marker (a folder, released
  with `rmdir`, a regular file there is corruption) stays, and the reaper and
  task-resource checks, which look only at its shape, need no change.
- Permissions. Claude Code's starter settings (`templates/settings.json`,
  seeded by `install.sh --copy`) allowed `Bash(mkdir:*)`; they now also allow
  `Bash(perl -e 'mkdir shift or exit 1' --:*)`. Claude Code matches the rule
  as a prefix and perl joins every `-e` into one program, so the prefix ends
  with `--`: without it, `<prefix> -e '<any code>'` matched and ran (found in
  review); after `--` every word is a path argument. Checked live with
  `claude -p --permission-mode dontAsk`: the exact command runs, and the same
  prefix followed by `-e 'mkdir ...'` is denied. A project that already has
  its own settings keeps them, and the CHANGELOG says how to add the rule.
  Where the rule is absent and a mode denies the command, the implementer
  stops as above; the person adds the rule once.
- Shipped text that called plain `mkdir` the guarantee now names the system
  call: `skills/using-git-worktrees/SKILL.md`, `skills/managing-memory/SKILL.md`
  (it still said `flock`), and the comments in `orch-lock.sh`,
  `orch-worktree-materialize.sh` and `orch-worktree-reaper.sh`. Text that only
  describes the marker's shape ("a directory", "fails against a file") stays.
- Nothing else changes: the pid file, both reclaims of a dead holder's lock,
  timeouts and release checks keep their current behaviour.

## Tests

The bug cannot be reproduced on macOS, and on Linux only by chance. So the
regression tests put a fake `mkdir` first on `PATH` that behaves like the
26.04 one (runs the real `mkdir`; if that fails and the path is a folder,
exits 0). Under it:

- `orch_mkdir_once` refuses a folder that exists.
- `with_lock` waits for and times out on a lock held by a live process.
- `registry_claim` refuses a name another session holds, and leaves that
  claim intact.
- `acquire_int_lock` refuses while a live integration holds the lock.
- Without perl on `PATH`, `orch_mkdir_once` falls back to the `mkdir` program:
  it creates a new folder once and refuses it after.
- The implementer's marker command refuses a second writer; the test reads
  the command from `agents/orch-implementer.md`, so the instructions and the
  test cannot drift, and checks the template carries the same command.

- The implementer's instructions and the template never offer the `mkdir`
  program for the marker, and carry the BLOCKED Need for an empty path; the
  starter settings allow the claim command by a prefix that ends with `--`.
Each fails on the code before its fix (observed: the marker race gave 4
winners of 4, a second claimer overwrote another session's claim). `tests/smoke.sh`'s two concurrent lock tests stay
as they are; on 26.04 they become the live check. The materialize suite's
marker race used to race plain `mkdir`, which tested the operating system's
tool rather than the plugin; it now races the implementer's claim command,
read from its instructions, under the fake.

## Release

0.18.1: version in the three plugin manifests, a CHANGELOG entry, and the
installed plugin copies refreshed to byte parity after merge.

## Out of scope: the merge lock's dead-holder reclaim

Review found that `acquire_int_lock` reclaims a dead holder's lock by deleting
the folder (`rm -rf`) and creating it again. Two runs that judge the same dead
pid at the same moment can then both hold it. That code is older than this
change and does not depend on the `mkdir` program. Two attempts to fix it here
(move the folder aside and verify; then a review proposal to swap only the pid
file) each opened new races in review, because reclaiming a lock that does not
release itself on death has no simple correct form. It goes to its own ticket,
where the choice (a kernel lock that releases itself, or an in-place takeover)
can be designed and reviewed on its own.

## Settled

- A perl that is on PATH but cannot run (a broken version-manager shim, a bad
  PERL5OPT) makes the create fail; it never hands the create to the `mkdir`
  program (Felipe's session, 2026-10-29). Review asked both ways in turn:
  falling back lets Ubuntu 26.04's program say "done" twice, failing blocks
  locks until perl is fixed. A lock that fails loudly loses nothing; a false
  win can lose a note or let two writers in. Reopen only with a new argument.

## Alternatives considered

- Delete or loosen the failing tests: hides a real data-loss bug.
- Pin CI to `ubuntu-24.04`: hides it on CI and leaves users on 26.04 exposed.
- A kernel file lock (`flock`): not on macOS by default, and would replace the
  lock and its reclaim logic wholesale, which this bug does not need.
- Bash's noclobber (`set -C; : > file`) as the exclusive step: no new
  dependency, but it turns folder locks into file locks and changes the
  reclaim, release and reaper logic in four places.
- Wait for Ubuntu to update rust-coreutils: not in our control, and older
  installs stay broken.
