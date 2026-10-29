#!/usr/bin/env python3
"""The disk guard's decision for one Bash command; scripts/hooks/guard-disk-writes.sh runs it.

Reads the PreToolUse event on stdin. Exit 0 lets the command run; exit 2 refuses it, with the reason and
what to do instead on stderr. Any other exit (an event it cannot read, a bug) makes the hook fall back to
its plain text check. Spec: docs/specs/disk-guard.md, G1.

It reads the command as flat text and has no model of the shell. What it refuses is a closed list:
  0. `//` and `/./` become `/`, and the session's own folder is set aside;
  1. any mention of the shared temporary area: $TMPDIR, /tmp, mktemp, claude-<digits>;
  2. a recursive copy whose paths are not spelled out, or whose destination is at or inside a source,
     and a `tar ... | ... tar` pipeline;
  3. a command over 100,000 characters that holds a copier or a rule-1 word.
Everything else runs; the watchdog (G3) bounds what this list does not name.
"""
import json
import os
import re
import shlex
import sys

MAX_LENGTH = 100_000
LONG_WORDS = ("cp", "rsync", "ditto", "tar", "tmpdir", "/tmp", "mktemp", "claude-")  # rule 3, lower case
SLASHES = re.compile(r"/(?:\.?/)+")
OWN = "/session-folder"  # what the session's own folder becomes: absolute, and no rule-1 word
SESSION_ID = re.compile(r"[A-Za-z0-9._-]+")
# Rule 1. Names and paths ignore case, as macOS's disk does; a variable's name does not.
SHARED = re.compile(r"\$TMPDIR(?![A-Za-z0-9_])|\$\{[#!]?TMPDIR(?![A-Za-z0-9_])"
                    r"|(?i:/tmp)(?![A-Za-z0-9_.-])"
                    r"|(?<![A-Za-z0-9_])(?i:mktemp)(?![A-Za-z0-9_])"
                    r"|(?<![A-Za-z0-9_.-])(?i:claude-[0-9]+)(?![A-Za-z0-9_.-])")
COPIER = re.compile(r"(?i)(?<![A-Za-z0-9_])(?:cp|rsync|ditto)(?![A-Za-z0-9_])")
TAR = re.compile(r"(?i)(?<![A-Za-z0-9_.-])tar(?![A-Za-z0-9_.-])")
CHANGES_FOLDER = re.compile(r"(?i)(?<![A-Za-z0-9_.-])(?:cd|pushd|popd)(?![A-Za-z0-9_.-])")
SPELLED_OUT = re.compile(r"[A-Za-z0-9._/+-]+")
TARGET = re.compile(r"--target-directory(?:=(.*))?|-[A-Za-z]*?t(.*)")  # cp's -t value
SEPARATORS = ";&|()<>`"


def set_aside(text, session):
    """Rule 0: each spelling of the session's own folder becomes OWN, unless the path after it holds `..`."""
    if not session:
        return text
    folder = re.compile(r"(?:/private)?/tmp/claude(?:-[0-9]+)?/[A-Za-z0-9._-]+/" + re.escape(session)
                        + r"(?![A-Za-z0-9._-])([^\s;&|()<>`]*)")
    return folder.sub(lambda match: match.group(0) if ".." in match.group(1) else OWN + match.group(1), text)


def copies(words):
    """(name, arguments) for each cp, rsync or ditto word; its arguments run to the next separator or copier."""
    found, current = [], None
    for word in words:
        name = os.path.basename(word).lower()
        if word and set(word) <= set(SEPARATORS):
            if current and current[1] and current[1][-1].isdigit() and set(word) & set("<>"):
                current[1].pop()  # the 2 of 2>
            current = None
        elif name in ("cp", "rsync", "ditto"):
            current = (name, [])
            found.append(current)
        elif current:
            current[1].append(word)
    return found


def copy_reason(name, args, cwd, changes_folder):
    """Rule 2 for one copy: why it is refused, or None."""
    if name == "cp" and not any(arg in ("--recursive", "--archive") or (
            arg.startswith("-") and not arg.startswith("--") and set(arg[1:]) & set("rRa")) for arg in args):
        return None
    operands, target, value_next = [], None, False
    for arg in args:
        option = TARGET.fullmatch(arg) if name == "cp" else None
        if value_next:
            target, value_next = arg, False
        elif not arg.startswith("-") or arg == "-":
            operands.append(arg)
        elif option:
            target = option.group(1) or option.group(2) or None
            value_next = target is None
    destination = target if target is not None else (operands.pop() if operands else None)
    if destination is None:
        return None
    for operand in operands + [destination]:
        if not SPELLED_OUT.fullmatch(operand):
            return (f"{name} copies with a path that is not spelled out ({operand}). In a recursive copy, write "
                    "each path with letters, digits and . _ / + - only: no variable, ~, glob, brace, quote, "
                    "space or colon")
        if changes_folder and not operand.startswith("/"):
            return (f"{name} copies a relative path ({operand}) in a command that changes folder. Run the cd "
                    "as its own command, or write the paths from /")
    if not operands:
        return (f"{name} copies into {destination} from sources that are not on the line (xargs or stdin). "
                "Write each source out")
    into = os.path.normpath(os.path.join(cwd, destination))
    for source in operands:
        origin = os.path.normpath(os.path.join(cwd, source))
        if into == origin or into.startswith(origin.rstrip("/") + "/"):
            return f"{name} copies {origin} into {into}, a folder inside it, which never ends"
    return None


def decide(command, cwd, session, hint):
    """The refusal for `command`, run from folder `cwd` by `session`, or None to let it run."""
    if len(command) > MAX_LENGTH:
        lowered = command.lower()
        if any(word in lowered for word in LONG_WORDS):
            return ("a command over 100,000 characters that copies or names the shared temporary area. "
                    "Split it into shorter commands")
        return None
    text = set_aside(SLASHES.sub("/", command), session)
    shared = SHARED.search(text)
    if shared:
        return (f"the command names the shared temporary area ({shared.group(0)}). Read a file there with "
                f"the Read tool; work in the clone or folder you were given, {cwd}; and put temporary files "
                + (f"in your session's own folder, {hint}" if hint else "inside that folder"))
    first = TAR.search(text)
    bar = text.find("|", first.end()) if first else -1
    if bar >= 0 and TAR.search(text, bar + 1):
        return "a tar pipeline (tar ... | ... tar). Extract with -C into a folder you spell out, as two commands"
    if not COPIER.search(text):
        return None
    lexer = shlex.shlex(text.replace("\\\n", " ").replace("\n", " ; "), posix=True, punctuation_chars=SEPARATORS)
    lexer.whitespace_split, lexer.commenters = True, ""
    try:
        words = list(lexer)
    except ValueError as error:
        return (f"a command with a copier that the guard cannot read ({error}). Close its quotes, or write "
                "text that holds cp, rsync or ditto with the Write tool")
    start = set_aside(os.path.normpath(cwd), session)
    changes_folder = bool(CHANGES_FOLDER.search(text))
    return next(filter(None, (copy_reason(name, args, start, changes_folder) for name, args in copies(words))), None)


def main():
    event = json.loads(sys.stdin.read())
    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0
    session = event.get("session_id")
    session = session if isinstance(session, str) and SESSION_ID.fullmatch(session) else None
    cwd = event.get("cwd") if isinstance(event.get("cwd"), str) else os.getcwd()
    transcript = event.get("transcript_path")
    parts = transcript.split("/") if isinstance(transcript, str) else []
    project = parts[parts.index("projects") + 1] if "projects" in parts[:-1] else None
    hint = f"/tmp/claude-{os.getuid()}/{project}/{session}/" if session and project else None
    reason = decide(command, cwd, session, hint)
    if reason:
        print(f"disk guard: refused: {reason.replace(OWN, (hint or '<session folder>/').rstrip('/'))}.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
