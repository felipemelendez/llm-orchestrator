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
# It refuses a Bash command that
#   1. copies a folder into itself: `cp -R`/`-r`/`-a`, `rsync`, `ditto`, or a
#      `tar -c ... | tar -x ...` pipeline whose destination is the source or
#      inside it (`cp -R . ./sub`, `rsync -a ./ ./backup/`);
#   2. writes, creates or deletes anything inside Claude Code's shared
#      temporary folder (/tmp/claude-*, /private/tmp/claude-*) or the hook's
#      own $TMPDIR, outside the session's own folder
#      (/tmp/claude-<uid>/<project>/<session id>/) and outside the folder the
#      command starts in. Write-type means: a `>`/`>>` redirection or heredoc
#      into a file, the destination of cp, mv, rsync, ditto, install or ln,
#      mkdir, touch, rm, rmdir, truncate, tee, `dd of=`, `curl -o`/`-O`, wget,
#      `tar -x` and `tar -cf <file>`, unzip, `git clone`, `git worktree add`,
#      and `mktemp` given an explicit folder.
# A literal $TMPDIR is read twice: as /tmp/claude-<uid>, what Claude Code's
# Bash sandbox gives every command whatever the process was started with, and
# as the hook's own $TMPDIR. Either one landing in a shared folder refuses.
#
# It allows ordinary work: copies and writes inside the clone or project, and
# anywhere outside the temporary folders (a review's run directory is always
# outside them); reads of the temporary folder (`ls`, `du`, `cat`, `grep`);
# `mktemp -d` with no folder named.
#
# Limits, stated so nobody counts on more: the parser follows cd/pushd/popd,
# OLDPWD, PWD, HOME, TMPDIR, `NAME=value` assignments, `export`, `bash -c`,
# `eval` and the inside of $(...) and backticks; a path built from anything
# else (another variable, the output of a command, `D=$(mktemp -d)`) is not
# known and does not by itself refuse. Programs that write files themselves
# (python, node, make, tests) are not seen. Quoted text that is only
# punctuation (`">"`) reads as an operator. Subshells share one directory.
#
# Reads the event on stdin; exit 0 allows, exit 2 refuses with the reason on
# stderr. The decision is scripts/lib/orch-disk-guard.py. Without python3, or
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
  python3 "${HELPER}" <<< "${INPUT}"
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
