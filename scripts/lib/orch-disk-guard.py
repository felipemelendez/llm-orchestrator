#!/usr/bin/env python3
"""The disk guard's decision for one Bash command; scripts/hooks/guard-disk-writes.sh runs it.

Reads the PreToolUse event on stdin. Exit 0 allows the command; exit 2 refuses it, with the
reason and what to do instead on stderr. What it refuses, what it allows and its limits are in
the hook's header. Spec: docs/specs/disk-guard.md.

Two rules, both conservative rather than an exact model of the shell (an exact model failed open
on ordinary forms: option values, subshells, wrappers, attached option values):
  A. a command that names a shared temporary folder (outside the session's own folder) and holds
     a write word anywhere, in any nested part, is refused;
  B. a recursive copy whose destination is at or inside a source is refused, reading every
     non-option word as a path and trying every folder the command may be in.
"""
import json
import os
import re
import shlex
import sys

UID = os.getuid()
PUNCTUATION = ";&|()<>"
PLACEHOLDER = "__ORCH_SUBSTITUTION__"  # a $(...) or `...`: its value is unknown
# Claude Code's shared temporary roots, any user, with and without the dash (/tmp/claude is writable too).
ROOT = re.compile(r"^(?:/private)?/tmp/claude(?:-[^/]+)?(?=/|$)")
TMPVAR = re.compile(r"\$\{TMPDIR(?:[:#%/][^}]*)?\}|\$TMPDIR(?![A-Za-z0-9_])")
SLASHES = re.compile(r"/(?:\.?/)+")  # `//` and `/./` mean `/`
# An absolute path inside a longer word: at its start, or after a separator or a quote.
ABSOLUTE = re.compile(r"(?:^|(?<=[\s=:@,'\"]))/[^\s'\"`;|&()<>,]*")
VAR = re.compile(r"\$(?:\{([A-Za-z_]\w*)(?::?[-=]([^}]*))?\}|([A-Za-z_]\w*))")
ASSIGN = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S)
HEREDOC = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]+)'|\"([^\"\n]+)\"|\\?([A-Za-z0-9_.-]+))")
SESSION_ID = re.compile(r"[A-Za-z0-9._-]+")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
CODE_FEEDERS = SHELLS | {"xargs", "eval", "source"}  # a heredoc fed to these is code, not data
WRITE_WORDS = {"cp", "mv", "rsync", "ditto", "tar", "mkdir", "touch", "tee", "dd", "rm", "rmdir", "ln", "install",
               "unzip", "curl", "wget", "truncate", "mktemp", "clone", "worktree", "-delete"}
COPIERS = {"cp", "rsync", "ditto"}
NOT_WRITTEN = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}
MAX_DEPTH = 4


class Refused(Exception):
    pass


def nested(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def scan(text):
    """Split a command into (outer text, code texts, heredoc data words), aware of quotes.

    $(...), <(...), >(...) and backticks outside single quotes become code and a placeholder;
    the inside of $((...)) and ((...)) arithmetic is code too, its shifts no heredoc; `#` comments
    are dropped; a heredoc's body (only for a real `<<` outside quotes and arithmetic) is code when
    its line feeds a shell or xargs anywhere, else data."""
    out, code, data, pending, quote, i, n, line_start = [], [], [], [], None, 0, len(text), 0

    def closing(start):
        depth, j = 1, start
        while j < n and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        return j

    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c)
            quote = None if c == "'" else quote
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if quote is None:
            if c in "'\"":
                quote = c
                out.append(c)
                i += 1
                continue
            if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
                end = text.find("\n", i)
                i = n if end < 0 else end
                continue
            match = HEREDOC.match(text, i) if text.startswith("<<", i) and not text.startswith("<<<", i) else None
            if match:
                delimiter = next(part for part in match.groups()[1:] if part)
                end = text.find("\n", i)
                line = text[line_start:n if end < 0 else end]  # the whole line: `cat <<EOF | bash` feeds a shell
                feeds = bool(set(re.findall(r"[A-Za-z0-9_.-]+", line)) & CODE_FEEDERS)
                pending.append((delimiter, match.group(1) == "-", feeds))
                out.append(" ")
                i = match.end()
                continue
            if c == "\n" and pending:
                i += 1
                for delimiter, dash, feeds in pending:
                    body = []
                    while i < n:
                        end = text.find("\n", i)
                        line = text[i:n if end < 0 else end]
                        i = n if end < 0 else end + 1
                        if (line.lstrip("\t") if dash else line) == delimiter:
                            break
                        body.append(line)
                    if feeds:
                        code.append("\n".join(body))
                    else:
                        data.extend(" ".join(body).split())
                pending = []
                out.append("\n")
                line_start = i
                continue
        elif c == '"':
            quote = None
            out.append(c)
            i += 1
            continue
        if text.startswith("$((", i) or (quote is None and text.startswith("((", i)):
            # Arithmetic: a `<<` in it is a shift, never a heredoc, and a $(...) in it still runs.
            start = i + (3 if text[i] == "$" else 2)
            end = closing(start)
            code.append(text[start:end - 1].replace("<<", "  "))
            i = end + (1 if end < n and text[end] == ")" else 0)
            out.append(PLACEHOLDER)
            continue
        if text[i:i + 2] in ("$(", "<(", ">("):
            end = closing(i + 2)
            code.append(text[i + 2:end - 1])
            out.append(PLACEHOLDER)
            i = end
            continue
        if c == "`":
            end = text.find("`", i + 1)
            end = n if end < 0 else end
            code.append(text[i + 1:end])
            out.append(PLACEHOLDER)
            i = end + 1
            continue
        if c == "\n":
            line_start = i + 1
        out.append(c)
        i += 1
    return "".join(out), code, data


def simple_commands(text):
    """(pipeline number, words, redirection targets) for each simple command, in order."""
    text = text.replace("\\\n", " ").replace("\n", " ; ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    commands, words, targets, pipeline, depth, i = [], [], [], 0, 0, 0
    while i < len(tokens):
        token = tokens[i]
        if token and set(token) <= set(PUNCTUATION):
            if "<" in token or ">" in token:
                if words and words[-1].isdigit():
                    words.pop()  # the 2 of 2>
                target = tokens[i + 1] if i + 1 < len(tokens) else ""
                if ">" in token and not (token.endswith("&") and (target.isdigit() or target == "-")):
                    targets.append(target)
                i += 2
                continue
            commands.append((pipeline, words, targets))
            words, targets = [], []
            joined = token.replace("||", ";").replace("|&", "|").replace("&&", ";")
            if depth == 0 and (";" in joined or "&" in joined):
                pipeline += 1  # `a | (cd x && b)` stays one pipeline
            depth = max(0, depth + token.count("(") - token.count(")"))
        else:
            words.append(token)
        i += 1
    commands.append((pipeline, words, targets))
    return [command for command in commands if command[1] or command[2]]


class Check:
    def __init__(self, guard):
        self.guard = guard
        self.noted, self.writes, self.copies = [], [], []
        self.bases, self.cwd, self.vars, self.scopes = [guard.cwd], guard.cwd, {}, 0

    def note(self, word):
        """Remember a word; the paths it may name are checked once every folder of the line is known."""
        self.noted.append(TMPVAR.sub(f"/tmp/claude-{UID}", word))

    def shared_paths(self):
        """Every shared-folder path outside the session's own folder that a noted word may name. Each
        spelling is normalized first (`//`, `/./`, `..`, symlinks), and a relative word is resolved from
        every folder the line may be in."""
        found = []
        for text in self.noted:
            parts = [text, *ABSOLUTE.findall(SLASHES.sub("/", text))]
            if "=" in text:
                parts.append(text.split("=", 1)[1])  # D=/tmp/..., --output=/tmp/..., of=/tmp/...
            if text.startswith("-") and "/" in text:
                parts.append(text[text.index("/"):])  # -o/tmp/... and other attached values
            for part in parts:
                if not part or PLACEHOLDER in part or "$" in part or (part.startswith("-") and part is text):
                    continue
                part = self.guard.home + part[1:] if part == "~" or part.startswith("~/") else part
                for path in [part] if part.startswith("/") else [os.path.join(base, part) for base in self.bases]:
                    real = os.path.realpath(SLASHES.sub("/", path))
                    if self.guard.root_of(real) and not self.guard.own(real):
                        found.append(real)
        return found

    def run(self, text, depth=0):
        if depth > MAX_DEPTH:
            raise Refused("a command nested too deeply to check")
        outer, codes, data = scan(text)
        for word in data:
            self.note(word)
        self.scopes += 1
        scope = self.scopes
        for pipeline, words, targets in simple_commands(outer):
            for target in targets:
                self.note(target)
                if target not in NOT_WRITTEN:
                    self.writes.append(f"a redirection into {target}")
            for n, word in enumerate(words):
                self.note(word)
                name = os.path.basename(word)
                if name in WRITE_WORDS:
                    self.writes.append(name)
                match = ASSIGN.fullmatch(word)
                if match:
                    self.vars[match.group(1)] = match.group(2)
                if name in ("cd", "pushd"):
                    self.change_directory([arg for arg in words[n + 1:n + 3] if arg not in ("-L", "-P")][:1])
                if name in SHELLS:
                    flag = next((k for k in range(n + 1, len(words))
                                 if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", words[k])), None)
                    if flag is not None and flag + 1 < len(words):
                        self.run(words[flag + 1], depth + 1)
                if name == "eval":
                    self.run(" ".join(words[n + 1:]), depth + 1)
            self.copies.append((scope, pipeline, words, self.cwd, dict(self.vars)))  # as they stand here
        for part in codes:
            self.run(part, depth + 1)

    def change_directory(self, args):
        target = self.guard.home if not args else (None if args[0] == "-" else self.path(args[0], self.cwd))
        if target:
            self.cwd = target
            if target not in self.bases:
                self.bases.append(target)

    def path(self, word, base, oldpwd=None, values=None):
        """The absolute path a word names from `base`, or None when it cannot be known."""
        values = self.vars if values is None else values
        if word is None or PLACEHOLDER in word:
            return None
        if word == "~" or word.startswith("~/"):
            word = self.guard.home + word[1:]
        missing = []

        def replace(match):
            name = match.group(1) or match.group(3)
            value = values[name] if name in values else {
                "PWD": base, "OLDPWD": oldpwd, "HOME": self.guard.home, "TMPDIR": f"/tmp/claude-{UID}"}.get(name)
            if value is None and match.group(2) is not None:
                value = match.group(2)
            if value is None or "$" in value:
                missing.append(name)
                return ""
            return value
        text = VAR.sub(replace, word)
        if missing or "$" in text or not text or re.match(r"^[^/]*:", text):
            return None
        glob = re.search(r"[*?\[]", text)
        if glob:
            head = text[:glob.start()]
            text = (head.rsplit("/", 1)[0] or "/") if "/" in head else "."
        return os.path.realpath(os.path.join(base, text))

    def copy_into_itself(self):
        """Rule B, once every folder the command may be in is known."""
        streams = {}
        for scope, pipeline, words, cwd, values in self.copies:
            roots = []
            if "find" in words:
                after = words[words.index("find") + 1:]
                roots = [w for w in after if not w.startswith("-") and w not in ("(", "!")][:1] or ["."]
            for n, word in enumerate(words):
                name = os.path.basename(word)
                args = words[n + 1:]
                if name in COPIERS and (name != "cp" or any(
                        arg in ("--recursive", "--archive")
                        or (re.fullmatch(r"-[A-Za-z]+", arg) and set(arg[1:]) & set("Rra")) for arg in args)):
                    self.check_copy(name, cwd, values, *self.operands(args, roots))
                elif name == "tar":
                    self.tar(streams.setdefault((scope, pipeline), []), args, cwd, values)

    @staticmethod
    def operands(args, roots):
        """(sources, destinations) of a cp-like argument list, reading every non-option word as a path."""
        positional, targets, ended, value_of = [], [], False, None
        for k, arg in enumerate(args):
            if k == value_of:
                continue  # the -t value is the target, never also a source
            if ended or arg == "-" or not arg.startswith("-"):
                positional.extend(roots if arg == "{}" else [arg])
            elif arg == "--":
                ended = True
            elif arg in ("-t", "--target-directory") and k + 1 < len(args):
                targets.append(args[k + 1])
                value_of = k + 1
            elif arg.startswith("--target-directory="):
                targets.append(arg.split("=", 1)[1])
        if not targets and len(positional) >= 2:
            targets, positional = [positional[-1]], positional[:-1]
        return positional, targets

    def check_copy(self, name, cwd, values, sources, targets):
        bases = [cwd] + [base for base in self.bases if base != cwd]
        for base in bases:
            for oldpwd in bases:
                for target in targets:
                    into = self.path(target, base, oldpwd, values)
                    for source in sources:
                        origin = self.path(source, base, oldpwd, values)
                        if into and origin and nested(into, origin):
                            raise Refused(f"{name} copies {origin} into {into}, a folder inside it, "
                                          "which never ends")

    def tar(self, stream, args, cwd, values):
        """A `tar -c ... | tar -x ...` pipeline, each side read from the folder the shell runs it in."""
        modes, archive, directory, positional, i = set(), None, None, [], 0
        while i < len(args):
            arg = args[i]
            if arg.startswith("--"):
                key, equals, value = arg.partition("=")
                if key in ("--file", "--directory"):
                    value = value if equals else (args[i + 1] if i + 1 < len(args) else None)
                    i += 0 if equals else 1
                    archive, directory = (value, directory) if key == "--file" else (archive, value)
                modes |= {"--create": {"c"}, "--extract": {"x"}, "--get": {"x"}}.get(key, set())
            elif (arg.startswith("-") and len(arg) > 1) or (i == 0 and re.fullmatch(r"[A-Za-z]+", arg)):
                letters = arg.lstrip("-")
                for k, letter in enumerate(letters):
                    modes.add(letter)
                    if letter in "fC":
                        attached = letters[k + 1:] if arg.startswith("-") else ""
                        value = attached or (args[i + 1] if i + 1 < len(args) else None)
                        i += 0 if attached else 1
                        archive, directory = (value, directory) if letter == "f" else (archive, value)
                        if attached:
                            break
            else:
                positional.append(arg)
            i += 1
        here = self.path(directory, cwd, values=values) if directory else cwd
        if "x" in modes and here:
            for origin in (origin for origins in stream for origin in origins):
                if nested(here, origin):
                    raise Refused(f"tar copies {origin} into {here}, a folder inside it, which never ends")
        if "c" in modes and archive in (None, "-") and here:
            stream.append([path for path in (self.path(item, here, values=values) for item in positional) if path])


class Guard:
    def __init__(self, event, env):
        self.home = env.get("HOME") or os.path.expanduser("~")
        self.cwd = os.path.realpath(event.get("cwd") or os.getcwd())
        own_tmp = env.get("TMPDIR")
        root = os.path.realpath(own_tmp) if own_tmp else None
        # The hook's own $TMPDIR is a shared root too, unless it is too wide to mean one ("/" or home).
        self.tmp_root = root if root and root not in ("/", os.path.realpath(self.home)) else None
        self.tmp_forms = sorted({form.rstrip("/") for form in (own_tmp, root) if form}) if self.tmp_root else []
        session = event.get("session_id")
        self.session = session if isinstance(session, str) and SESSION_ID.fullmatch(session) else None
        transcript = event.get("transcript_path")
        parts = transcript.split("/") if isinstance(transcript, str) else []
        self.project_folder = parts[parts.index("projects") + 1] if "projects" in parts[:-1] else None

    def root_of(self, path):
        match = ROOT.match(path)
        if match:
            return match.group(0)
        return next((root for root in self.tmp_forms if nested(path, root)), None)

    def own(self, path):
        """The session's own folder, and the folder the command starts in unless that is a shared root."""
        if self.session and re.match(r"^(?:/private)?/tmp/claude(?:-[^/]+)?/[^/]+/" + re.escape(self.session)
                                     + r"(?:/|$)", path):
            return True
        # The folder the command starts in counts only when it lies inside a shared root, below the root:
        # never the root itself, and never a folder above one (/, /tmp, /private/tmp).
        root = self.root_of(self.cwd)
        return bool(root) and root != self.cwd and nested(path, self.cwd)

    def scratch_hint(self):
        if self.session and self.project_folder:
            return f"/tmp/claude-{UID}/{self.project_folder}/{self.session}/"
        return None

    def decide(self, command):
        check = Check(self)
        try:
            check.run(command)
        except ValueError:  # unbalanced quotes: fall back to the words, refusing what could be either rule
            words = [word for word in re.split(r"[\s;&|()<>'\"`]+", command) if word]
            for word in words:
                check.note(word)
            check.shared = check.shared_paths()
            copying = sorted(set(words) & (COPIERS | {"tar"}))
            writing = sorted(set(words) & WRITE_WORDS) or ([">"] if ">" in command else [])
            if (check.shared and writing) or copying:
                raise Refused("a command that could not be read and that copies, or writes while naming the "
                              f"shared temporary folder ({', '.join(copying or writing)})")
            return
        check.copy_into_itself()
        shared = check.shared_paths()
        if shared and check.writes:
            raise Refused(f"{check.writes[0]} in a command that names the shared temporary folder ({shared[0]})")

    def message(self, reason):
        hint = self.scratch_hint()
        return (f"disk guard: refused: {reason}.\n"
                f"Work in the clone or folder you were given at {self.cwd}: run every command, evidence script and "
                "experiment there, and keep copies and temporary files inside it"
                + (f" or in your session folder {hint}" if hint else "") + ". "
                "Never copy, clone or extract it into itself, into $TMPDIR or /tmp/claude-*, or into a parent folder. "
                "A command that only reads the shared folder runs if it has no write in the same line.")


def raw_refusal(text):
    """The fallback when the event cannot be decoded: refuse any write-type word near a temp root."""
    if re.search(r"/tmp/claude-|\$\{?TMPDIR", text) and re.search(
            r"(^|[^\w-])(" + "|".join(sorted(WRITE_WORDS - {"-delete"})) + r")([^\w-]|$)|>", text):
        return ("disk guard: refused: the command could not be checked, and it names a write and the shared "
                "temporary folder. Work in the clone or folder you were given, and keep copies and temporary "
                "files inside it.")
    return None


def main():
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
        command = (event.get("tool_input") or {}).get("command")
    except (ValueError, AttributeError):
        refusal = raw_refusal(raw)
        if refusal:
            print(refusal, file=sys.stderr)
            return 2
        return 0
    if not isinstance(command, str) or not command.strip():
        return 0
    try:
        guard = Guard(event, os.environ)
        guard.decide(command)
    except Refused as refused:
        print(guard.message(str(refused)), file=sys.stderr)
        return 2
    except Exception:  # any other failure of the reading falls back to the plain text check
        refusal = raw_refusal(command)
        if refusal:
            print(refusal, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
