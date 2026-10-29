#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard — keeps agents from filling the disk.
#
# Why this exists: on 2026-10-28 a review agent ran, as an "evidence" command,
#   cd $TMPDIR && rm -rf pr && mkdir pr && cp -R "$OLDPWD"/. .
# and copied a folder into a folder inside itself without end: 79 GB in 12
# minutes, the startup disk full, every agent on the machine stopped. It had
# improvised a scratch copy in Claude Code's shared temporary folder instead of
# working in the clone it was given. A prompt asked it not to; this hook makes
# the command fail instead.
#
# Two conservative rules, not an exact model of the shell: an exact model
# failed open on ordinary forms (option values, subshells, wrappers such as
# timeout or xargs, `-o/path`), so each rule refuses more rather than less.
#
#   A. A command that names Claude Code's shared temporary folder
#      (/tmp/claude, /tmp/claude-*, their /private forms, $TMPDIR, or the
#      hook's own $TMPDIR) outside the session's own folder
#      (/tmp/claude-<uid>/<project>/<session id>/), and holds a write word
#      anywhere, is refused. Write words: cp mv rsync ditto tar mkdir touch tee
#      dd rm rmdir ln install unzip curl wget truncate mktemp clone worktree
#      -delete, and a `>` redirection to anything but /dev/null. "Anywhere"
#      means in every part of the line: after a cd, inside $(...), backticks,
#      arithmetic, `bash -c '...'`, eval, a heredoc fed to a shell or xargs
#      (`cat <<EOF | bash` too), behind timeout, xargs or find -exec. Every
#      word is a path candidate, and so are `=` values and option-attached
#      paths (`-o/tmp/...`, `--output=/tmp/...`, `D=/tmp/...`); each is
#      normalized (`//`, `/./`, `..`, symlinks) and, when relative, resolved
#      from every folder the line may be in. Known variables ($PWD, $OLDPWD,
#      $HOME, $TMPDIR in any spelling, the line's own) are replaced, and a word
#      with an unknown part (`$TMPDIR/review-$$`) keeps the folder before it.
#   B. A recursive copy (`cp -R`/`-r`/`-a`, rsync, ditto, or a
#      `tar -c ... | tar -x ...` pipeline) whose destination is at or inside a
#      source is refused (`cp -R . ./sub`, `cp -f -R . ./sub`,
#      `timeout 600 cp -R . ./sub`, `find . -exec cp -R {} ./sub \;`). Every
#      non-option word counts as a path, and every folder the line may be in
#      (where it starts, and each cd target) is tried.
#
# It allows ordinary work: copies and writes inside the clone or project and
# anywhere outside the temporary folders (a review's run directory is always
# outside them); a command that only reads the temporary folder (`ls`, `du`,
# `cat`, `grep`); `mktemp -d` with no folder named; text in single quotes,
# which the shell never runs (`printf %s '$(mkdir /tmp/claude-501/x)'`);
# a heredoc that is data (`cat > notes.md <<EOF`) unless it names the shared
# folder.
#
# What it refuses on purpose although nothing is written there (recorded in
# docs/specs/disk-guard.md, Settled): a line that reads the shared folder and
# writes elsewhere (`cat /tmp/claude-501/x.log > out.txt`: run the two apart),
# a write word that is only an argument (`ls /tmp/claude-501 | grep tar`), a
# subshell cd that a later write does not follow (`(cd /tmp/claude-501); mkdir
# x`), a line nested more than four levels (`$(...)`, `bash -c`, eval), and a
# line it cannot read (unbalanced quotes) that copies or writes near the shared
# folder.
#
# Contract: it catches the forms agents write, by accident or in evidence
# scripts, and refuses what it cannot read with confidence. It is not a
# security boundary against a command built on purpose to hide a write; the
# disk watchdog (free-space floor, run-directory cap) and each Codex launch's
# own $TMPDIR are the backstop.
#
# Limits, stated so nobody counts on more: a path the line does not spell
# (a variable set by an earlier command, `D=$(mktemp -d)`, a symlink made
# earlier) is not known; programs that write files themselves (python, node,
# make, tests) are not seen; a path fed on stdin to anything but a shell or
# xargs is checked only as a name of the shared folder.
#
# Reads the event on stdin; exit 0 allows, exit 2 refuses with the reason on
# stderr. The decision is scripts/lib/orch-disk-guard.py, run with `python3 -I`
# so nothing beside it or in the environment is imported. Without python3, or
# when the helper fails, a plain text check refuses any command naming the
# shared temporary folder or $TMPDIR together with a write word.
#
# The only opt-out is ORCH_ALLOW_TEMP_WRITES=1 in the hook's OWN environment,
# set by a person when launching the session. An inline
# `ORCH_ALLOW_TEMP_WRITES=1 cp ...` prefix lands in the child shell, not here,
# so it does not disarm the guard; the review launchers never pass it on.

# NO `set -e`, as in guard-destructive-git.sh: a guard that aborts mid-script
# exits non-zero-but-not-2, which Claude Code treats as a non-blocking error,
# and the command runs. Every path below ends in exit 0 or exit 2.
set -uo pipefail

if [[ "${ORCH_ALLOW_TEMP_WRITES:-0}" == "1" ]]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${HOOK_DIR}/../lib/orch-disk-guard.py"

INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

if command -v python3 >/dev/null 2>&1 && [[ -f "${HELPER}" ]]; then
  python3 -I "${HELPER}" <<< "${INPUT}"
  rc=$?
  [[ ${rc} -eq 0 || ${rc} -eq 2 ]] && exit "${rc}"
fi

FLAT=$(printf '%s' "${INPUT}" | LC_ALL=C tr -c '[:print:]' ' ')
if LC_ALL=C grep -qE '/tmp/claude-|[$][{]?TMPDIR' <<< "${FLAT}" \
   && LC_ALL=C grep -qE '(^|[^[:alnum:]_-])(cp|mv|rsync|ditto|tar|mkdir|touch|tee|dd|rm|rmdir|ln|install|unzip|curl|wget|truncate|clone|mktemp)([^[:alnum:]_-]|$)|>' <<< "${FLAT}"; then
  echo "disk guard: refused: the command could not be checked, and it names a write and the shared temporary folder. Work in the clone or folder you were given, and keep copies and temporary files inside it." >&2
  exit 2
fi
exit 0
