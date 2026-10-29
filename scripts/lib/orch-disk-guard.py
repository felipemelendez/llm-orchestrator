#!/usr/bin/env python3
"""The disk guard's decision for one Bash command; scripts/hooks/guard-disk-writes.sh runs it.

Reads the PreToolUse event on stdin. Exit 0 allows the command; exit 2 refuses it, with the
reason and what to do instead on stderr. What it refuses, what it allows and its limits are in
the hook's header. Spec: docs/specs/disk-guard.md.
"""
import json
import os
import re
import shlex
import sys

# Claude Code's shared temporary root, for any user, in both spellings (macOS links /tmp).
TEMP_ROOT = re.compile(r"^(?:/private)?/tmp/claude-[^/]+(?=/|$)")
SESSION_ID = re.compile(r"[A-Za-z0-9._-]+")
PUNCTUATION = ";&|()<>"
PLACEHOLDER = "__ORCH_SUBSTITUTION__"  # a $(...) or `...`: its value is unknown
UNKNOWN = "/__orch_unknown_directory__"  # a directory the parser could not resolve
VAR = re.compile(r"\$(?:\{([A-Za-z_]\w*)(?::?[-=]([^}]*))?\}|([A-Za-z_]\w*))")
ASSIGN = re.compile(r"([A-Za-z_]\w*)=(.*)", re.S)
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(?:'([^']*)'|\"([^\"]*)\"|\\?([A-Za-z0-9_]+))")
KEYWORDS = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "!", "{", "}", "time"}
WRAPPERS = {"env", "sudo", "command", "nohup", "exec", "nice", "builtin"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
WRITE_WORDS = re.compile(r"(^|[^\w-])(cp|mv|rsync|ditto|tar|mkdir|touch|tee|dd|rm|rmdir|ln|install|unzip|"
                         r"curl|wget|truncate|clone|mktemp)([^\w-]|$)|>")
TEMP_WORDS = re.compile(r"/tmp/claude-|\$\{?TMPDIR")
MAX_DEPTH = 4


class Refused(Exception):
    pass


def nested(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def strip_heredocs(text):
    """Drop here-document bodies: they are data, not commands."""
    kept, pending = [], []
    for line in text.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        kept.append(line)
        pending = [next(part for part in match if part) for match in HEREDOC.findall(line) if any(match)]
    return "\n".join(kept)


def substitutions(text):
    """The text with each $(...), <(...), >(...) and `...` replaced by a placeholder, and their insides."""
    out, inner, i = [], [], 0
    while i < len(text):
        if text[i:i + 2] in ("$(", "<(", ">("):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            inner.append(text[i + 2:j - 1])
            out.append(PLACEHOLDER)
            i = j
        elif text[i] == "`":
            j = text.find("`", i + 1)
            j = len(text) if j < 0 else j
            inner.append(text[i + 1:j])
            out.append(PLACEHOLDER)
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out), inner


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
            # A pipeline ends at ; & && || outside parentheses; `a | (cd x && b)` is one pipeline.
            joined = token.replace("||", ";").replace("|&", "|").replace("&&", ";")
            if depth == 0 and (";" in joined or "&" in joined):
                pipeline += 1
            depth = max(0, depth + token.count("(") - token.count(")"))
        else:
            words.append(token)
        i += 1
    commands.append((pipeline, words, targets))
    return [command for command in commands if command[1] or command[2]]


def options(args, valued=(), target=("-t", "--target-directory")):
    """(short and long flags, positional arguments, target directory) of a cp-like argument list."""
    flags, positional, chosen, ended, i = [], [], None, False, 0
    while i < len(args):
        arg = args[i]
        if ended or arg == "-" or not arg.startswith("-"):
            positional.append(arg)
        elif arg == "--":
            ended = True
        else:
            name, equals, value = arg.partition("=")
            if name in target:
                chosen = value if equals else (args[i + 1] if i + 1 < len(args) else None)
                i += 0 if equals else 1
            elif name in valued and not equals:
                i += 1
            flags.append(arg)
        i += 1
    return flags, positional, chosen


def recursive(flags):
    return any(flag in ("--recursive", "--archive") or (not flag.startswith("--") and set(flag[1:]) & set("Rra"))
               for flag in flags)


class Walk:
    """One reading of the command, with $TMPDIR bound to one value."""

    def __init__(self, guard, tmpdir, cwd, depth=0):
        self.guard, self.tmpdir, self.cwd, self.depth = guard, tmpdir, cwd, depth
        self.oldpwd, self.vars, self.stack, self.unknown = None, {}, [], 0

    def child(self):
        walk = Walk(self.guard, self.tmpdir, self.cwd, self.depth + 1)
        walk.oldpwd, walk.vars = self.oldpwd, dict(self.vars)
        return walk

    def value(self, name):
        if name in self.vars:
            return self.vars[name]
        return {"PWD": self.cwd, "OLDPWD": self.oldpwd, "HOME": self.guard.home, "TMPDIR": self.tmpdir}.get(name)

    def expand(self, word):
        if word is None or PLACEHOLDER in word:
            return None
        if word == "~" or word.startswith("~/"):
            word = self.guard.home + word[1:]
        missing = []

        def replace(match):
            name = match.group(1) or match.group(3)
            value = self.value(name)
            if value is None and match.group(2) is not None:
                value = self.expand(match.group(2))
            if value is None:
                missing.append(name)
                return ""
            return value
        text = VAR.sub(replace, word)
        return None if missing or "$" in text else text

    def path(self, word):
        """The absolute, symlink-resolved path a word names, or None when it cannot be known."""
        text = self.expand(word)
        if not text or re.match(r"^[^/]*:", text):  # empty, or a remote host:path
            return None
        glob = re.search(r"[*?\[]", text)
        if glob:
            head = text[:glob.start()]
            text = head.rsplit("/", 1)[0] or "/" if "/" in head else "."
        full = os.path.normpath(os.path.join(self.cwd, text))
        return full if full.startswith(UNKNOWN) else os.path.realpath(full)

    def unknown_directory(self):
        self.unknown += 1
        return f"{UNKNOWN}/{self.unknown}"

    def write(self, word, what, path=None):
        target = path or self.path(word)
        root = self.guard.root_of(target) if target else None
        if root and not self.guard.own(target):
            raise Refused(f"{what} {target}, inside the shared temporary folder {root}")

    def copy_into_itself(self, name, sources, destination, base=None):
        target = self.path(destination) if destination is not None else None
        if not target:
            return
        for source in sources:
            origin = (base or self).path(source)
            if origin and nested(target, origin):
                raise Refused(f"{name} copies {origin} into {target}, a folder inside it, which never ends")

    def run(self, text):
        if self.depth > MAX_DEPTH:
            raise Refused("a command nested too deeply to check")
        outer, inner = substitutions(strip_heredocs(text))
        for part in inner:
            self.child().run(part)
        sources = {}
        for pipeline, words, targets in simple_commands(outer):
            self.command(pipeline, words, targets, sources)

    def command(self, pipeline, words, targets, sources):
        saved = dict(self.vars)
        prefix = {}
        while words and (words[0] in KEYWORDS or ASSIGN.fullmatch(words[0])):
            match = ASSIGN.fullmatch(words[0])
            if match:
                prefix[match.group(1)] = self.expand(match.group(2))
            words = words[1:]
        if words and words[0].startswith("#"):
            words = []
        for target in targets:
            self.write(target, "a redirection writes")
        if not words:
            self.vars.update(prefix)  # a plain assignment lasts for the rest of the command
            return
        self.vars.update(prefix)
        try:
            self.dispatch(pipeline, words, sources)
        finally:
            restored = dict(saved)
            if os.path.basename(words[0]) in ("export", "declare", "local", "readonly", "typeset"):
                restored.update({k: v for k, v in self.vars.items() if k not in saved or v != saved.get(k)})
            self.vars = restored

    def dispatch(self, pipeline, words, sources):
        while words and os.path.basename(words[0]) in WRAPPERS:
            words = words[1:]
            while words and (words[0].startswith("-") or ASSIGN.fullmatch(words[0])):
                words = words[2:] if words[0] in ("-n", "-u", "-C") else words[1:]
        if not words:
            return
        name, args = os.path.basename(words[0]), words[1:]
        if name in ("export", "declare", "local", "readonly", "typeset"):
            for arg in args:
                match = ASSIGN.fullmatch(arg)
                if match:
                    self.vars[match.group(1)] = self.expand(match.group(2))
        elif name in ("cd", "pushd", "popd"):
            self.change_directory(name, [arg for arg in args if arg not in ("-L", "-P", "-e", "-@", "-n")])
        elif name in SHELLS:
            flag = next((n for n, arg in enumerate(args) if re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", arg)), None)
            if flag is not None and flag + 1 < len(args):
                self.child().run(args[flag + 1])
        elif name == "eval":
            self.run(" ".join(args))
        elif name in ("cp", "rsync", "ditto"):
            flags, positional, target = options(args, valued=("-e", "--rsh", "--exclude", "--include", "--filter",
                                                              "-f", "--files-from", "--exclude-from", "-T",
                                                              "--temp-dir", "--log-file", "--backup-dir",
                                                              "--link-dest", "--compare-dest", "--copy-dest",
                                                              "--chmod", "--chown", "--rsync-path", "--arch"))
            if target is None and len(positional) >= 2:
                target = positional.pop()
            if target is not None:
                if name != "cp" or recursive(flags):
                    self.copy_into_itself(name, positional, target)
                self.write(target, f"{name} writes")
        elif name in ("mv", "install", "ln"):
            flags, positional, target = options(args, valued=("-m", "-o", "-g", "-S"))
            if name == "install" and any(flag == "-d" for flag in flags):
                for item in positional:
                    self.write(item, "install -d creates")
            elif target is None and len(positional) >= 2:
                target = positional.pop()
            elif target is None and len(positional) == 1 and name == "ln":
                target = os.path.basename(positional[0].rstrip("/")) or "."
            if target is not None:
                self.write(target, f"{name} writes")
        elif name in ("mkdir", "touch", "rm", "rmdir", "truncate", "tee"):
            _, positional, _ = options(args, valued=("-m", "-s", "-t", "-d", "-r", "--size", "--reference"),
                                       target=())
            for item in positional:
                self.write(item, {"mkdir": "mkdir creates", "rm": "rm deletes", "rmdir": "rmdir deletes"}
                           .get(name, f"{name} writes"))
        elif name == "dd":
            for arg in args:
                if arg.startswith("of="):
                    self.write(arg[3:], "dd writes")
        elif name in ("curl", "wget"):
            self.download(name, args)
        elif name == "unzip":
            _, positional, target = options(args, valued=("-x",), target=("-d",))
            self.write(target or ".", "unzip extracts into")
        elif name == "mktemp":
            self.mktemp(args)
        elif name == "tar":
            self.tar(pipeline, args, sources)
        elif name == "git":
            self.git(args)

    def change_directory(self, name, args):
        if name == "popd":
            target = self.stack.pop() if self.stack else self.unknown_directory()
        elif not args:
            target = self.guard.home if name == "cd" else self.unknown_directory()
        elif args[0] == "-":
            target = self.oldpwd or self.unknown_directory()
        else:
            target = self.path(args[0]) or self.unknown_directory()
        if name == "pushd":
            self.stack.append(self.cwd)
        self.oldpwd, self.cwd = self.cwd, target

    def download(self, name, args):
        wrote = False
        for n, arg in enumerate(args):
            key, equals, value = arg.partition("=")
            value = value if equals else (args[n + 1] if n + 1 < len(args) else None)
            if (name == "curl" and key in ("-o", "--output", "--output-dir")) or (
                    name == "wget" and key in ("-O", "--output-document", "-P", "--directory-prefix")):
                wrote = True
                if value != "-":
                    self.write(value, f"{name} writes")
            elif name == "curl" and key in ("-O", "--remote-name", "--remote-name-all"):
                wrote = True
                self.write(".", "curl writes into")
        if name == "wget" and not wrote:
            self.write(".", "wget writes into")

    def mktemp(self, args):
        _, positional, directory = options(args, target=("-p", "--tmpdir"))
        if directory:
            self.write(directory, "mktemp creates in")
        for template in positional:
            if "/" in template:
                self.write(os.path.dirname(template) or "/", "mktemp creates in")

    def tar(self, pipeline, args, sources):
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
                        rest = letters[k + 1:]
                        value = rest if rest and arg.startswith("-") else (args[i + 1] if i + 1 < len(args) else None)
                        i += 0 if rest and arg.startswith("-") else 1
                        archive, directory = (value, directory) if letter == "f" else (archive, value)
                        if rest and arg.startswith("-"):
                            break
            else:
                positional.append(arg)
            i += 1
        into = self.path(directory) if directory else self.cwd
        if "x" in modes:
            self.write(None, "tar extracts into", path=into)
            for origin in sources.get(pipeline, []):
                if into and nested(into, origin):
                    raise Refused(f"tar copies {origin} into {into}, a folder inside it, which never ends")
        if "c" in modes:
            if archive not in (None, "-"):
                self.write(archive, "tar writes")
            else:
                base = self.child()
                base.cwd = into
                sources.setdefault(pipeline, []).extend(
                    path for path in (base.path(item) for item in positional) if path)

    def git(self, args):
        base, i = self, 0
        while i < len(args) and args[i].startswith("-"):
            if args[i] == "-C" and i + 1 < len(args):
                base = self.child()
                base.cwd = self.path(args[i + 1]) or self.unknown_directory()
            i += 2 if args[i] in ("-C", "-c") else 1
        if i >= len(args):
            return
        sub, rest = args[i], args[i + 1:]
        if sub == "clone":
            _, positional, _ = options(rest, valued=("-b", "--branch", "-o", "--origin", "-c", "--config", "--depth",
                                                     "--reference", "--separate-git-dir", "-j", "--jobs",
                                                     "--template", "-u", "--upload-pack", "--filter"), target=())
            if len(positional) >= 2:
                base.write(positional[1], "git clone writes")
            elif positional:
                name = re.sub(r"\.git$", "", positional[0].rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1])
                base.write(name or ".", "git clone writes")
        elif sub == "worktree" and rest[:1] == ["add"]:
            _, positional, _ = options(rest[1:], valued=("-b", "-B", "--reason"), target=())
            if positional:
                base.write(positional[0], "git worktree add writes")


class Guard:
    def __init__(self, event, env):
        self.home = env.get("HOME") or os.path.expanduser("~")
        self.cwd = os.path.realpath(event.get("cwd") or os.getcwd())
        uid_root = f"/tmp/claude-{os.getuid()}"
        own_tmp = env.get("TMPDIR")
        self.tmpdirs = [uid_root] + ([own_tmp] if own_tmp and os.path.realpath(own_tmp) != os.path.realpath(uid_root)
                                     else [])
        root = os.path.realpath(own_tmp) if own_tmp else None
        # The hook's own $TMPDIR is a shared root too, unless it is too wide to mean one ("/" or home).
        self.tmp_root = root if root and root not in ("/", os.path.realpath(self.home)) else None
        session = event.get("session_id")
        self.session = session if isinstance(session, str) and SESSION_ID.fullmatch(session) else None
        transcript = event.get("transcript_path")
        parts = transcript.split("/") if isinstance(transcript, str) else []
        self.project_folder = parts[parts.index("projects") + 1] if "projects" in parts[:-1] else None

    def root_of(self, path):
        match = TEMP_ROOT.match(path)
        if match:
            return match.group(0)
        if self.tmp_root and nested(path, self.tmp_root):
            return self.tmp_root
        return None

    def own(self, path):
        """The session's own folder, and the folder the command starts in unless that is a shared root."""
        if self.session and re.match(r"^(?:/private)?/tmp/claude-[^/]+/[^/]+/" + re.escape(self.session) + r"(?:/|$)",
                                     path):
            return True
        return nested(path, self.cwd) and self.root_of(self.cwd) not in (self.cwd, self.cwd.rstrip("/"))

    def scratch_hint(self):
        if self.session and self.project_folder:
            return f"/tmp/claude-{os.getuid()}/{self.project_folder}/{self.session}/"
        return None

    def decide(self, command):
        for tmpdir in self.tmpdirs:
            Walk(self, tmpdir, self.cwd).run(command)

    def message(self, reason):
        hint = self.scratch_hint()
        return (f"disk guard: refused: {reason}.\n"
                f"Work in the clone or folder you were given at {self.cwd}: run every command, evidence script and "
                "experiment there, and keep copies and temporary files inside it"
                + (f" or in your session folder {hint}" if hint else "") + ". "
                "Never copy, clone or extract it into itself, into $TMPDIR or /tmp/claude-*, or into a parent folder.")


def raw_refusal(text):
    """The fallback when the command cannot be parsed: refuse any write-type word near a temp root."""
    if TEMP_WORDS.search(text) and WRITE_WORDS.search(text):
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
    except Exception:  # an unparsable command (unbalanced quotes) falls back to the raw check
        refusal = raw_refusal(command)
        if refusal:
            print(refusal, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
