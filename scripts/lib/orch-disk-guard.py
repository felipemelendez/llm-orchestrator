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
     non-option word as a path and trying every folder the command may be in; a copy with a path it
     cannot read for certain is refused too.
A part whose value depends on running the shell (a variable the line sets, $OLDPWD, $$, a substitution)
is never computed: it fails closed. Only $HOME, $TMPDIR and $PWD/$(pwd) are known.
"""
import functools
import json
import os
import re
import shlex
import stat
import sys
import time

UID = os.getuid()
PUNCTUATION = ";&|()<>"
PLACEHOLDER = "__ORCH_SUBSTITUTION__"  # a $(...) or `...`: its value is unknown
# Claude Code's shared temporary roots, any user, with and without the dash (/tmp/claude is writable too),
# and a glob right after `claude` (`claude*`, `claude?`, `claude[...]`), which may match any of them.
ROOT = re.compile(r"^(?:/private)?/tmp/claude(?:[-*?\[][^/]*)?(?=/|$)")
# $TMPDIR, ${TMPDIR} and ${TMPDIR<any operator>...}: `:-` `-` `:=` `=` `:?` `?` `:+` `+` `#` `%` `/`.
TMPVAR = re.compile(r"\$\{TMPDIR(?:[^A-Za-z0-9_}][^}]*)?\}|\$TMPDIR(?![A-Za-z0-9_])")
SLASHES = re.compile(r"/(?:\.?/)+")  # `//` and `/./` mean `/`
# An absolute path inside a longer word: at its start, or after a separator or a quote.
ABSOLUTE = re.compile(r"(?:^|(?<=[\s=:@,'\"]))/[^\s'\"`;|&()<>,]*")
# The variables whose value the hook knows for certain, besides $TMPDIR: every other one is unknown.
KNOWN = re.compile(r"\$(?:\{(HOME|PWD)\}|(HOME|PWD)(?![A-Za-z0-9_]))")
PWD_COMMAND = re.compile(r"\$\(\s*pwd(?:\s+-[LP])?\s*\)|`\s*pwd(?:\s+-[LP])?\s*`")  # $(pwd) is $PWD
ASSIGN = re.compile(r"[A-Za-z_]\w*=.*", re.S)
CLAUDE_NAME = re.compile(r"claude(?:[-*?\[][^/]*)?")  # a shared root's own folder name
HEREDOC = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]+)'|\"([^\"\n]+)\"|\\?([A-Za-z0-9_.-]+))")
SESSION_ID = re.compile(r"[A-Za-z0-9._-]+")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
CODE_FEEDERS = SHELLS | {"xargs", "eval", "source"}  # a heredoc fed to these is code, not data
WRITE_WORDS = {"cp", "mv", "rsync", "ditto", "tar", "mkdir", "touch", "tee", "dd", "rm", "rmdir", "ln", "install",
               "unzip", "curl", "wget", "truncate", "mktemp", "clone", "worktree", "-delete"}
COPIERS = {"cp", "rsync", "ditto"}
NOT_WRITTEN = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"}
MAX_DEPTH = 4
DEADLINE_SECONDS = 2.0


class Refused(Exception):
    pass


def nested(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


@functools.lru_cache(maxsize=None)
def resolve(path):
    """os.path.realpath of an absolute path, with one lstat per folder not seen before: the folders a line
    may be in share their prefixes, so a line of many `cd`s costs one lookup per new folder, not per word."""
    path = SLASHES.sub("/", path).rstrip("/") or "/"
    parent, name = os.path.split(path)
    if not name:
        return path
    head = resolve(parent)
    if name in (".", ".."):
        return head if name == "." else os.path.dirname(head)
    full = os.path.join(head, name)
    try:
        return os.path.realpath(full) if stat.S_ISLNK(os.lstat(full).st_mode) else full
    except OSError:
        return full


def closing(text, start):
    """The index just past the `)` that closes the `(` before `start`."""
    depth, j = 1, start
    while j < len(text) and depth:
        depth += {"(": 1, ")": -1}.get(text[j], 0)
        j += 1
    return j


def arithmetic(body):
    """An arithmetic body as code: its `<` and `>` compare and shift, never redirect; a $(...) or backticks in
    it keep their own."""
    out, i = [], 0
    while i < len(body):
        if body.startswith("$(", i) or body[i] == "`":
            j = closing(body, i + 2) if body[i] == "$" else (body.find("`", i + 1) + 1 or len(body))
            out.append(body[i:j])
            i = j
            continue
        out.append(" " if body[i] in "<>" else body[i])
        i += 1
    return "".join(out)


def scan(text):
    """Split a command into (outer text, code texts, heredoc data words), aware of quotes.

    $(...), <(...), >(...) and backticks outside single quotes become code and a placeholder;
    the inside of $((...)) and ((...)) arithmetic is code too, its `<` and `>` operators, never a
    redirection or heredoc; `#` comments are dropped; a heredoc's body (only for a real `<<` outside
    quotes and arithmetic) is code when its line, as read without its comment, feeds a shell or xargs
    anywhere, else data."""
    text = PWD_COMMAND.sub("$PWD", text)
    out, code, data, pending, quote, i, n, line_start = [], [], [], [], None, 0, len(text), 0

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
                pending.append((match.group(2) or match.group(3) or match.group(4), match.group(1) == "-"))
                out.append(" ")
                i = match.end()
                continue
            if c == "\n" and pending:
                feeds = feeds_code("".join(out[line_start:]))  # the line as read, its comment dropped
                i += 1
                for delimiter, dash in pending:
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
                line_start = len(out)
                continue
        elif c == '"':
            quote = None
            out.append(c)
            i += 1
            continue
        if text.startswith("$((", i) or (quote is None and text.startswith("((", i)):
            start = i + (3 if text[i] == "$" else 2)
            end = closing(text, start)
            if end < n and text[end] == ")":  # `))` closes arithmetic; `((a) )` is two subshells, as bash reads it
                code.append(arithmetic(text[start:end - 1]))
                i = end + 1
                out.append(PLACEHOLDER)
                continue
        if text[i:i + 2] in ("$(", "<(", ">("):
            end = closing(text, i + 2)
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
        out.append(c)
        i += 1
        if c == "\n":
            line_start = len(out)
    return "".join(out), code, data


def feeds_code(line):
    """Whether a heredoc's line, as scanned, runs its body as code: it names a shell or xargs anywhere, or
    runs a command whose name is not literal text (`| $(command -v bash)`, `| "$SHELL"`)."""
    if set(re.findall(r"[A-Za-z0-9_.-]+", line)) & CODE_FEEDERS:
        return True
    try:
        commands = simple_commands(line)
    except ValueError:
        return True
    names = [next((word for word in words if not ASSIGN.fullmatch(word)), "") for _, words, _ in commands]
    return any("$" in name or PLACEHOLDER in name for name in names)


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


class TimeUp(Exception):
    pass


UNKNOWN = object()  # an operand with a part whose value the hook cannot know


class Check:
    def __init__(self, guard):
        self.guard = guard
        self.noted, self.writes, self.copies = {}, [], []
        # The folders the line may be in, and whether every `cd` so far has had a literal target ($PWD known).
        self.bases, self.cwd, self.cd_known, self.scopes = [guard.cwd], guard.cwd, True, 0

    def tick(self):
        if time.monotonic() > self.guard.deadline:
            raise TimeUp()

    def note(self, word):
        """Remember a word; the paths it may name are checked once every folder of the line is known."""
        self.noted[word] = None

    def shared_paths(self):
        """Every shared-folder name outside the session's own folder that a noted word may hold. Each spelling
        is normalized first (`//`, `/./`, `..`, symlinks), and a relative one is read from every folder the line
        may be in. A word with a part the hook cannot know names one when the literal text before that part
        lies in, or could begin, a shared root (`$TMPDIR/review-$$`, `/tmp/claude-$UID`, `/tmp/$X`), or when a
        later part is a shared root's own name (`$R/claude-501`)."""
        found = []
        for text in self.noted:
            self.tick()
            parts = [text, *ABSOLUTE.findall(SLASHES.sub("/", text))]
            if "=" in text:
                parts.append(text.split("=", 1)[1])  # D=/tmp/..., --output=/tmp/..., of=/tmp/...
            if text.startswith("-") and "/" in text:
                parts.append(text[text.index("/"):])  # -o/tmp/... and other attached values
            for part in parts:
                if not part or (part.startswith("-") and part is text):
                    continue
                literal = part.startswith("/") and "$" not in part and PLACEHOLDER not in part
                for base in [self.cwd] if literal else self.bases:
                    spelled, cut = self.expand(part, base)
                    if cut is None:
                        real = resolve(os.path.join(base, spelled))
                        if self.guard.root_of(real) and not self.guard.own(real):
                            found.append(real)
                    elif self.could_be_shared(os.path.join(base, spelled[:cut]), spelled[cut:]):
                        found.append(part)
        return found

    def could_be_shared(self, head, rest):
        """Whether a word whose literal text, read from a folder, is `head`, followed by an unknown part and
        `rest`, may name a shared folder outside the session's own."""
        folder, _, partial = head.rpartition("/")
        folder = resolve(folder or "/")
        prefix = folder.rstrip("/") + "/" + partial
        return bool((self.guard.root_of(prefix) and not self.guard.own(folder))
                    or any(form.startswith(prefix) for form in self.guard.root_forms)
                    or any(CLAUDE_NAME.fullmatch(name) for name in rest.split("/")))

    def run(self, text, depth=0):
        if depth > MAX_DEPTH:
            raise Refused("a command nested too deeply to check")
        outer, codes, data = scan(text)
        for word in data:
            self.note(word)
        self.scopes += 1
        scope = self.scopes
        for pipeline, words, targets in simple_commands(outer):
            self.tick()
            for target in targets:
                self.note(target)
                if target not in NOT_WRITTEN:
                    self.writes.append(f"a redirection into {target}")
            for n, word in enumerate(words):
                self.note(word)
                name = os.path.basename(word)
                if name in WRITE_WORDS:
                    self.writes.append(name)
                if name in ("cd", "pushd"):
                    self.change_directory([arg for arg in words[n + 1:n + 3] if arg not in ("-L", "-P")][:1])
                if name == "popd":
                    self.cd_known = False  # back to a folder the guard does not track
                if name in SHELLS:
                    flag = next((k for k in range(n + 1, len(words))
                                 if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", words[k])), None)
                    if flag is not None and flag + 1 < len(words):
                        self.run(words[flag + 1], depth + 1)
                if name == "eval":
                    self.run(" ".join(words[n + 1:]), depth + 1)
            self.copies.append((scope, pipeline, words, self.cwd, self.cd_known))  # as they stand here
        for part in codes:
            self.run(part, depth + 1)

    def change_directory(self, args):
        target = self.guard.home if not args else (
            UNKNOWN if args[0] == "-" else self.certain(args[0], self.cwd if self.cd_known else None))
        if target is UNKNOWN or target is None:
            self.cd_known = False  # `cd "$D"`, `cd -`: from here on $PWD and relative paths are unknown
            return
        self.cwd = target
        if target not in self.bases:
            self.bases.append(target)

    def expand(self, word, base):
        """(text, cut): the word with ~, $HOME, $TMPDIR in any spelling and $PWD (as `base`; unknown when None)
        filled in, and where its first part the hook cannot know begins, or None. Every other variable is
        unknown, the line's own included: their values depend on running the shell."""
        word = TMPVAR.sub(f"/tmp/claude-{UID}", word)
        if word == "~" or word.startswith("~/"):
            word = self.guard.home + word[1:]
        text = KNOWN.sub(lambda match: self.guard.home if "HOME" in match.group(0)
                         else match.group(0) if base is None else base, word)
        return text, min((k for k in (text.find("$"), text.find(PLACEHOLDER)) if k >= 0), default=None)

    def certain(self, word, base):
        """The path a copy operand or `cd` target names from folder `base` (None when that folder is not
        known): UNKNOWN when any part of it is, None when it is remote (`host:path`)."""
        text, cut = self.expand(word, base)
        host = re.match(r"([^/]*):", text)
        if host and "$" not in host.group(1) and PLACEHOLDER not in host.group(1):
            return None
        if cut is not None or not text or (base is None and not text.startswith("/")):
            return UNKNOWN
        glob = re.search(r"[*?\[]", text)
        if glob:
            head = text[:glob.start()]
            text = (head.rsplit("/", 1)[0] or "/") if "/" in head else "."
        return resolve(os.path.join(base or "/", text))

    def copy_into_itself(self):
        """Rule B, once every folder the command may be in is known."""
        streams = {}
        for scope, pipeline, words, cwd, cd_known in self.copies:
            self.tick()
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
                    self.check_copy(name, cwd if cd_known else None, *self.operands(name, args, roots))
                elif name == "tar":
                    self.tar(streams.setdefault((scope, pipeline), []), args, cwd if cd_known else None)

    @staticmethod
    def operands(name, args, roots):
        """(sources, destinations) of a cp-like argument list, reading every non-option word as a path.
        Only cp has a target-directory option (`-t dir`, `-Rt dir`, `-tdir`, `--target-directory[=]dir`);
        rsync's -t keeps times and ditto has none."""
        positional, targets, ended, value_of = [], [], False, None
        for k, arg in enumerate(args):
            if k == value_of:
                continue  # the -t value is the target, never also a source
            target = re.fullmatch(r"--target-directory(?:=(.*))?|-[A-Za-z]*?t(.*)", arg) if name == "cp" else None
            if ended or arg == "-" or not arg.startswith("-"):
                positional.extend(roots if arg == "{}" else [arg])
            elif arg == "--":
                ended = True
            elif target and (target.group(1) or target.group(2)):
                targets.append(target.group(1) or target.group(2))
            elif target and k + 1 < len(args):
                targets.append(args[k + 1])
                value_of = k + 1
        if not targets and len(positional) >= 2:
            targets, positional = [positional[-1]], positional[:-1]
        return positional, targets

    @staticmethod
    def unreadable(name, word):
        word = word.replace(PLACEHOLDER, "$(...)")  # as the person wrote it, not the scanner's marker
        return (f"{name} with a path the guard cannot read ({word}). Spell each source and destination out: "
                "a literal path, $HOME, $TMPDIR, or $PWD and relative paths after cd targets that are spelled "
                "out; a variable the line sets, $OLDPWD, $$ or a substitution cannot be checked")

    def check_copy(self, name, cwd, sources, targets):
        """Rule B for one copy run in `cwd` (None when a `cd` before it had a target that is not literal)."""
        for base in [cwd] + [base for base in self.bases if base != cwd] if cwd else [None]:
            self.tick()
            into = [self.certain(word, base) for word in targets]
            origins = [self.certain(word, base) for word in sources]
            unknown = next((word for word, path in zip(targets + sources, into + origins) if path is UNKNOWN), None)
            if unknown is not None:
                raise Refused(self.unreadable(name, unknown))
            for target in (path for path in into if path):
                for origin in (path for path in origins if path):
                    if nested(target, origin):
                        raise Refused(f"{name} copies {origin} into {target}, a folder inside it, which never ends")

    def tar(self, stream, args, cwd):
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
        here = self.certain(directory, cwd) if directory else (cwd or UNKNOWN)
        if "x" in modes and stream:
            origins = [origin for origins in stream for origin in origins]
            if here is UNKNOWN or UNKNOWN in origins:
                raise Refused(self.unreadable("tar", directory or "the folder it runs in"))
            for origin in (origin for origin in origins if origin and here):
                if nested(here, origin):
                    raise Refused(f"tar copies {origin} into {here}, a folder inside it, which never ends")
        if "c" in modes and archive in (None, "-"):
            stream.append([UNKNOWN] if here in (UNKNOWN, None) else [self.certain(item, here) for item in positional])


class Guard:
    def __init__(self, event, env):
        self.home = env.get("HOME") or os.path.expanduser("~")
        self.cwd = os.path.realpath(event.get("cwd") or os.getcwd())
        own_tmp = env.get("TMPDIR")
        root = os.path.realpath(own_tmp) if own_tmp else None
        # The hook's own $TMPDIR is a shared root too, unless it is too wide to mean one ("/" or home).
        self.tmp_root = root if root and root not in ("/", os.path.realpath(self.home)) else None
        self.tmp_forms = sorted({form.rstrip("/") for form in (own_tmp, root) if form}) if self.tmp_root else []
        self.root_forms = ["/tmp/claude", "/private/tmp/claude", *self.tmp_forms]
        # The helper's own deadline, under the harness's 10 s hook timeout (at which the command would run
        # unchecked). The hook's own environment may lower it, never raise it.
        try:
            self.seconds = min(DEADLINE_SECONDS, float(env.get("ORCH_DISK_GUARD_SECONDS", DEADLINE_SECONDS)))
        except ValueError:
            self.seconds = DEADLINE_SECONDS
        self.deadline = time.monotonic() + self.seconds
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
        words = [word for word in re.split(r"[\s;&|()<>'\"`]+", command) if word]
        try:
            try:
                check.run(command)
            except ValueError:  # unbalanced quotes: fall back to the words, refusing what could be either rule
                for word in words:
                    check.note(word)
                shared = check.shared_paths()
                copying = sorted(set(words) & (COPIERS | {"tar"}))
                writing = sorted(set(words) & WRITE_WORDS) or ([">"] if ">" in command else [])
                if (shared and writing) or copying:
                    raise Refused("a command that could not be read and that copies, or writes while naming the "
                                  f"shared temporary folder ({', '.join(copying or writing)})")
                return
            check.copy_into_itself()
            shared = check.shared_paths()
            if shared and check.writes:
                raise Refused(f"{check.writes[0]} in a command that names the shared temporary folder ({shared[0]})")
        except TimeUp:  # past the deadline: refuse anything that copies or writes, allow the rest
            if {os.path.basename(word) for word in words} & (WRITE_WORDS | COPIERS) or ">" in command:
                raise Refused(f"a command too long to check within {self.seconds:g} s, and it copies or writes; "
                              "split it into shorter commands") from None

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
