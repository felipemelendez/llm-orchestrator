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
# It reads the command as flat text, with no model of the shell, and refuses a
# closed list (docs/specs/disk-guard.md, G1):
#   3. First, on the command as given: over 100,000 characters and holding a
#      copier or a rule-1 word. Then rules 0 to 2 run on two readings, each
#      backslash-newline removed and read as a newline; either refusing refuses.
#   0. `//` and `/./` become `/`; the session's own folder
#      (/tmp/claude-<uid>/<project>/<session id>) is set aside with the plain
#      run of [A-Za-z0-9._/+-] after it, when it starts a word, its run ends at
#      whitespace, a separator, the end or the quote that opened it, and no
#      `..` component follows it. Anything else is not set aside.
#   1. Any mention of the shared temporary area, anywhere in the text, read or
#      write: $TMPDIR or ${TMPDIR...}, /tmp as a path component (/private/tmp
#      too), the word mktemp, and claude-<digits> as a path component or word.
#      A plain TMPDIR=<path> assignment is not a mention.
#   2. A recursive copy (cp -r/-R/-a/--recursive/--archive, rsync, ditto) with
#      a path outside [A-Za-z0-9._/+-], a relative path in a command that also
#      holds cd, pushd or popd, no source on the line, or a destination at or
#      inside a source; and any `tar ... | ... tar` pipeline.
# A real 1 s timer bounds the decision. Everything else runs. That is the
# specified behaviour, not a gap: the disk watchdog (free-space floor,
# run-directory cap) and each Codex launch's own $TMPDIR bound what the list
# does not name. It is not a security boundary.
#
# Reads the event on stdin; exit 0 allows, exit 2 refuses with the reason on
# stderr. The decision is scripts/lib/orch-disk-guard.py, run with `python3 -I`
# so nothing beside it or in the environment is imported. Without python3, or
# when the helper exits with anything but 0 or 2, a plain text check of the
# command alone refuses any rule-1 word and any copier word (cp, rsync, ditto,
# tar), since it cannot read rule 2.
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
  REASON=$(python3 -I "${HELPER}" 2>&1 >/dev/null <<< "${INPUT}")
  rc=$?
  if [[ ${rc} -eq 0 || ${rc} -eq 2 ]]; then
    [[ -n "${REASON}" ]] && printf '%s\n' "${REASON}" >&2
    exit "${rc}"
  fi
fi

# Only the command is checked: the JSON string after the "command" key, up to its closing unescaped quote
# (in valid JSON, "command" followed by : can only be a key). The sed marks a match with a leading C, so an
# empty command is still a command; an event with no such string, cut off or malformed, is checked whole.
# A newline in the text is the two characters \n.
FLAT=$(printf '%s' "${INPUT}" | LC_ALL=C tr -c '[:print:]' ' ')
COMMAND=$(printf '%s' "${FLAT}" | LC_ALL=C sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/C\1/p')
[[ -n "${COMMAND}" ]] && FLAT="${COMMAND#C}"
FLAT=$(printf '%s' "${FLAT}" | sed 's/\\[nrt]/ /g')
if LC_ALL=C grep -qiE '[$][{]?[#!]?TMPDIR([^A-Za-z0-9_]|$)|/tmp([^A-Za-z0-9_.-]|$)|(^|[^A-Za-z0-9_])mktemp([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.-])claude-[0-9]+([^A-Za-z0-9_.-]|$)|(^|[^A-Za-z0-9_])(cp|rsync|ditto|tar)([^A-Za-z0-9_]|$)' <<< "${FLAT}"; then
  echo "disk guard: refused: the guard's helper could not run, and the command copies or names the shared temporary area. Work in the clone or folder you were given, and keep copies and temporary files inside it." >&2
  exit 2
fi
exit 0
