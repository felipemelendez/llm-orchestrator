#!/usr/bin/env python3
"""The disk guard's decision for one Bash command; scripts/hooks/guard-disk-writes.sh runs it.

Reads the PreToolUse event on stdin. Exit 0 lets the command run; exit 2 refuses it, with the reason and
what to do instead on stderr. Any other exit (an event it cannot read, a bug) makes the hook fall back to
its plain text check. Spec: docs/specs/disk-guard.md, G1.

It reads the command as flat text and has no model of the shell. What it refuses is a closed list:
  3. first, on the command as given: one over 100,000 characters that holds a copier or a rule-1 word;
  then rules 0 to 2 on two readings, a backslash-newline removed and read as a newline, refusing if either does:
  0. `//` and `/./` become `/`, and the session's own folder is set aside with the plain run after it, bare or
     in a pair of the same quote, with a boundary on each side, when no `..` component follows it;
  1. any mention of the shared temporary area: $TMPDIR, /tmp, mktemp, claude-<digits>;
  2. a recursive copy whose paths are not spelled out, or whose destination is at or inside a source,
     and a `tar ... | ... tar` pipeline.
A real timer bounds the whole decision. Everything else runs; the watchdog (G3) bounds what this list does
not name.
"""
import json
import os
import re
import shlex
import signal
import sys

MAX_LENGTH = 100_000
DEADLINE_SECONDS = 1.0  # far under the harness's 10 s hook timeout, at which the command would run unchecked
LONG_WORDS = ("cp", "rsync", "ditto", "tar", "tmpdir", "/tmp", "mktemp", "claude-")  # rule 3, lower case
SLASHES = re.compile(r"/(?:\.?/)+")
OWN = "/session-folder"  # what the session's own folder becomes: absolute, and no rule-1 word
SESSION_ID = re.compile(r"(?!\.+$)[A-Za-z0-9._-]+")
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
FD_DIGITS = re.compile(r"(?<![^\s;&|()<>`])[0-9]+(?=[<>])")  # the 2 of 2>, never a separate 9 before >
# Rule 0's two shapes: a bare occurrence, or one inside a pair of the same quote, each with a boundary (the start,
# whitespace, `=` or a separator) before it and one (the end, whitespace or a separator) after it.
BOUND_BEFORE = r"(?<![^\s=;&|()<>`])"
BOUND_AFTER = r"(?=$|[\s;&|()<>`])"
DOTS = re.compile(r"(?<![^/\s=;&|()<>`])\.\.(?![^/\s;&|()<>`])")  # a `..` path component
UNQUOTE = str.maketrans("", "", "'\"\\")


class TimeUp(Exception):
    pass


def set_aside(text, session):
    """Rule 0 (spec G1): (the text rule 1 reads, the text rule 2 reads), the session's own folder set aside."""
    if not session or "tmp/claude" not in text.lower():
        return text, text
    folder = re.compile(r"(?i)" + BOUND_BEFORE + r"(['\"]?)(?:/private)?/tmp/claude(?:-[0-9]+)?/(?!\.\.?/)[A-Za-z0-9._-]+/"
                        + re.escape(session) + r"(?![A-Za-z0-9._+-])([A-Za-z0-9._/+-]*)\1" + BOUND_AFTER)
    kept_at = [i for i, c in enumerate(text) if c not in "'\"\\"]  # where each unquoted character came from
    dots = max((kept_at[match.start()] for match in DOTS.finditer(text.translate(UNQUOTE))), default=-1)
    hidden, kept, last = [], [], 0
    for match in folder.finditer(text):  # one pass, left to right; each occurrence on its own
        if match.start() > dots:
            hidden += [text[last:match.start()], " "]
            kept += [text[last:match.start()], OWN, match.group(2)]
            last = match.end()
    return "".join(hidden) + text[last:], "".join(kept) + text[last:]


def canonical(path):
    """A path as macOS's disk reads it: case ignored, and /private/var, /private/tmp, /private/etc as /var, /tmp, /etc."""
    return re.sub(r"^/private(?=/(?:var|tmp|etc)(?:/|$))", "", path.lower())


def holds_words(command):
    """Rule 3's plain substring test: a copier or a rule-1 word, in any case."""
    lowered = command.lower()
    return any(word in lowered for word in LONG_WORDS)


def copies(words):
    """(name, arguments) for each cp, rsync or ditto word; its arguments run to the next separator or copier,
    and a redirection takes only its own target."""
    found, current, target_next = [], None, False
    for word in words:
        name = os.path.basename(word).lower()
        if target_next:
            target_next = False  # a redirection's own target, never an argument
        elif word and set(word) <= set(SEPARATORS):
            target_next = bool(set(word) & set("<>")) and not set(word) & set(";|()`")
            current = current if target_next else None
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
    if destination is None or not operands:
        return (f"{name} copies with its source or destination not on the line (from xargs or stdin). Write "
                "each source and the destination out")
    for operand in operands + [destination]:
        if not SPELLED_OUT.fullmatch(operand):
            return (f"{name} copies with a path that is not spelled out ({operand}). In a recursive copy, write "
                    "each path with letters, digits and . _ / + - only: no variable, ~, glob, brace, quote, "
                    "space or colon")
        if changes_folder and not operand.startswith("/"):
            return (f"{name} copies a relative path ({operand}) in a command that changes folder. Run the cd "
                    "as its own command, or write the paths from /")
    into = os.path.normpath(os.path.join(cwd, destination))
    for source in operands:
        origin = os.path.normpath(os.path.join(cwd, source))
        if canonical(into) == canonical(origin) or canonical(into).startswith(canonical(origin).rstrip("/") + "/"):
            return f"{name} copies {origin} into {into}, a folder inside it, which never ends"
    return None


def decide(command, cwd, session, hint):
    """The refusal for `command`, run from folder `cwd` by `session`, or None to let it run. Rule 3 reads the
    command as given; rules 0 to 2 read it twice, since a backslash-newline joins two halves unless a comment
    ends at it, and the guard does not decide which: either reading refusing refuses."""
    if len(command) > MAX_LENGTH:
        return ("a command over 100,000 characters that copies or names the shared temporary area. "
                "Split it into shorter commands") if holds_words(command) else None
    split = re.sub(r"(?m)^([^#\n]*)\\\n", r"\1", command).replace("\\\n", "\n")  # only a line with a # splits
    readings = dict.fromkeys((command.replace("\\\n", ""), split))
    return next(filter(None, (check(reading, cwd, session, hint) for reading in readings)), None)


def check(command, cwd, session, hint):
    """Rules 0 to 2 on one reading of the command."""
    seen, text = set_aside(SLASHES.sub("/", command), session)
    shared = SHARED.search(seen)
    if shared:
        return (f"the command names the shared temporary area ({shared.group(0)}). Read a file there with "
                f"the Read tool; work in the clone or folder you were given, {cwd}; and put temporary files "
                + (f"in your session's own folder, {hint}" if hint else "inside that folder"))
    for line in text.split("\n"):
        first = TAR.search(line)
        bar = line.find("|", first.end()) if first else -1
        if bar >= 0 and TAR.search(line, bar + 1):
            return "a tar pipeline (tar ... | ... tar). Extract with -C into a folder you spell out, as two commands"
    if not COPIER.search(text):
        return None
    lexer = shlex.shlex(FD_DIGITS.sub(" ", text).replace("\n", " ; "), posix=True, punctuation_chars=SEPARATORS)
    lexer.whitespace_split, lexer.commenters = True, ""
    try:
        words = list(lexer)
    except ValueError as error:
        return (f"a command with a copier that the guard cannot read ({error}). Close its quotes, or write "
                "text that holds cp, rsync or ditto with the Write tool")
    start = set_aside(os.path.normpath(cwd), session)[1]
    changes_folder = bool(CHANGES_FOLDER.search(text))
    return next(filter(None, (copy_reason(name, args, start, changes_folder) for name, args in copies(words))), None)


def decide_in_time(command, cwd, session, hint):
    """decide() under a real timer: past DEADLINE_SECONDS, a command holding a copier or a rule-1 word is refused
    and any other runs, whatever step was slow."""
    def expire(signum, frame):
        raise TimeUp()
    signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, DEADLINE_SECONDS)
    try:
        try:
            return decide(command, cwd, session, hint)
        finally:  # ignored before it is disarmed, so a late alarm can never escape
            signal.signal(signal.SIGALRM, signal.SIG_IGN)
            signal.setitimer(signal.ITIMER_REAL, 0)
    except TimeUp:
        return (f"a command the guard could not finish checking in {DEADLINE_SECONDS:g} s, and it copies or names "
                "the shared temporary area. Split it into shorter commands") if holds_words(command) else None


def main():
    event = json.loads(sys.stdin.read())
    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0
    session = event.get("session_id")
    session = session if isinstance(session, str) and SESSION_ID.fullmatch(session) else None
    cwd = event.get("cwd") if isinstance(event.get("cwd"), str) else os.getcwd()
    transcript = event.get("transcript_path")
    folder, name = os.path.split(transcript) if isinstance(transcript, str) else ("", "")
    project = os.path.basename(folder) if session and name == f"{session}.jsonl" else None  # <project>/<session>.jsonl
    hint = f"/tmp/claude-{os.getuid()}/{project}/{session}/" if session and project else None
    reason = decide_in_time(command, cwd, session, hint)
    if reason:
        print(f"disk guard: refused: {reason.replace(OWN, (hint or '<session folder>/').rstrip('/'))}.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
