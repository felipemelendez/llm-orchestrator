#!/usr/bin/env python3
"""Did a check actually run and pass this turn?

Reads a Stop / SubagentStop payload on stdin. Prints one note, or nothing.
Always exits 0: this warns, it never blocks. See orch-verify-gate.sh for why.

A command counts when the harness wrote a finished, non-error result for it
(on Codex: its own record, exit code 0) and one of its segments runs a check
by the lists below, or the command starts with the project's
`runner.test_cmd` (from docs/llm-orchestrator/cadence.json). On
Claude Code a Bash call made with run_in_background, or whose result is the
harness's launch acknowledgement ("Command running in background with ID:"),
is a launch, not a finish.

The command is split into words only to find which program a segment runs:
quotes and escapes join a word, operators outside quotes end a segment,
redirections, comments and heredoc bodies are dropped. It does not judge what
the shell would do with the result. Limits, by construction, the same on both
harnesses: `npm test &` (the shell reports 0 before the check has finished),
`npm test || true`, `false && npm test`, a shell function named like a
runner, and text inside `$(( ))` are all accepted; the spec lists them. Those
are disguises. The laws leave honesty to the agent: this check catches the
careless false claim, not the deliberate one. Earlier versions tried to judge
them (background and exit-code rules) and every rule mis-judged an honest
command somewhere else: `2>&1`, a multi-line quoted argument. Do not add
those rules back; a note that is wrong gets ignored, which is worse than no
note.

What it does NOT catch, on purpose: a green run that tested nothing, a suite
that does not cover the change, and anything deliberately dressed up to look
like a pass. Watching commands cannot catch those.
"""
import json
import os
import re
import sys

LABEL = re.compile(r"(?im)^[ \t]*(?:[-*+][ \t]*)?(?:#{1,6}[ \t]*)?[*_]{0,3}Verification[*_]{0,3}:"
                   r"[ \t]*[*_]{0,3}[ \t]*(PASS|PENDING|BLOCKED|NOT APPLICABLE)")
# [ \t]*, not \s*: with \s* a run of blank lines is re-scanned from every
# line start, and a reply padded with them takes the hook past its time limit.
FENCE = re.compile(r"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[^\n]*")
# A user entry the person did not type: an agent returning, a slash command, a
# compaction summary. Counting one as the turn start throws away real checks.
MACHINE = ("<task-notification>", "<local-command-", "<bash-", "<command-name>", "<system-reminder>")
# What Claude Code writes as the result of a command it decided to background
# itself. The command was started; nothing says it finished.
LAUNCH = "Command running in background with ID:"

NOTE = ("Cadence: this reply says Verification: PASS, but no check ran and passed in this turn. "
        "Run the project's test command as one plain foreground command, or say PENDING instead.")


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    return content if isinstance(content, list) else []


def is_person(entry):
    if entry.get("type") != "user" or entry.get("isSidechain") or entry.get("isMeta"):
        return False
    if entry.get("isCompactSummary"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip()) and not content.lstrip().startswith(MACHINE)
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def result_text(block):
    """The text of a tool_result: a string, or text blocks."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
    return ""


def finished_ok(block):
    """A tool_result the harness wrote for a command that ran to the end
    without error. A launch acknowledgement is not that."""
    if not isinstance(block, dict) or block.get("type") != "tool_result" or block.get("is_error"):
        return False
    return not result_text(block).lstrip().startswith(LAUNCH)


def configured_test_cmd(project):
    """The project's runner.test_cmd from its cadence.json, or "" when it has none."""
    try:
        with open(os.path.join(project, "docs", "llm-orchestrator", "cadence.json"),
                  encoding="utf-8") as stream:
            runner = json.load(stream).get("runner")
        command = runner.get("test_cmd")
    except Exception:       # unreadable, not JSON, too deep, wrong shape: use the lists alone
        return ""
    return command.strip() if isinstance(command, str) else ""


# --- Which commands count as a check -------------------------------------
#
# The lists below are the whole definition; docs/specs/codex-completion-check.md
# describes them. A command is split into words and operators in one linear
# pass, cut into segments at the operators, and each segment's words are read
# from the left.

# Runners that are a check by name alone, however they are reached by path.
TOOLS = frozenset((
    "pytest", "py.test", "jest", "vitest", "mocha", "rspec", "tox", "nox", "phpunit",
    "pest", "tsc", "ruff", "eslint", "biome", "flake8", "mypy", "pyright", "shellcheck",
    "rubocop", "golangci-lint", "ctest", "bats"))
# Runners whose subcommand is the first word after their own options: a
# check only when that word is one of these (`go test`, not `go build -o test`).
# With each: its options that take a value before the subcommand.
SUBCOMMANDS = {
    "go": (("test", "vet"), {"-C"}),
    "cargo": (("test", "check", "clippy", "nextest"), {"-C", "-Z", "--config"}),
    "mix": (("test",), set()), "dotnet": (("test",), set()), "swift": (("test",), set()),
    "bazel": (("test",), {"--output_base", "--output_user_root", "--bazelrc", "--host_jvm_args"}),
    "deno": (("test", "check", "lint"), set()),
}
# Runners that take a list of targets: a check when any later plain word
# before `--` is one of these (`mvn clean test`, `./gradlew :app:test`). The
# value of one of their options is never a target (`gradle build -x test`).
_MAKE_TARGETS = ("test", "tests", "check", "lint", "typecheck", "ci", "verify")
_GRADLE_VALUES = {"-x", "--exclude-task", "-p", "--project-dir", "-b", "--build-file", "-c",
                  "--settings-file", "-g", "--gradle-user-home", "-I", "--init-script"}
TARGETS = {
    "make": (_MAKE_TARGETS, {"-C", "-f", "-I", "-o", "-W", "--directory", "--file", "--makefile",
                             "--include-dir", "--old-file", "--assume-old", "--what-if", "--new-file",
                             "--assume-new"}),
    "gradle": (("test", "check"), _GRADLE_VALUES), "gradlew": (("test", "check"), _GRADLE_VALUES),
    "mvn": (("test", "verify"), {"-pl", "--projects", "-f", "--file", "-s", "--settings", "-gs",
                                 "--global-settings", "-P", "--activate-profiles", "-rf", "--resume-from",
                                 "-t", "--toolchains"}),
    "just": (_MAKE_TARGETS, {"-f", "--justfile", "-d", "--working-directory", "--shell",
                             "--dotenv-filename", "--dotenv-path"}),
    "task": (_MAKE_TARGETS, {"-d", "--dir", "-t", "--taskfile", "-o", "--output"}),
}
# Interpreter options that come before `-m` or the script: the letters of
# short options that take a value (in a cluster, the last letter takes the
# next word: `bash -euo pipefail`), and the options that only parse the
# script instead of running it (`bash -n`).
INTERPRETERS = {
    "python": ({"X", "W"}, set()),
    "bash": ({"o", "O"}, {"-n", "--noexec"}),
    "sh": ({"o"}, {"-n"}),
}
# Options that make a runner plan, list or skip instead of running:
# `make -n test`, `cargo test --no-run`, `pytest --markers`. For the `-D`
# options a value of `true` counts the same as none.
NON_RUNS = {
    "make": ("-n", "--just-print", "--dry-run", "--recon", "-q", "--question"),
    "just": ("-n", "--dry-run"),
    "cargo": ("--no-run",),
    "gradle": ("-m", "--dry-run"), "gradlew": ("-m", "--dry-run"),
    "mvn": ("-DskipTests", "-Dmaven.test.skip"),
    "pytest": ("--markers", "--fixtures", "--fixtures-per-test", "--collect-only", "--co", "--setup-plan"),
    "py.test": ("--markers", "--fixtures", "--fixtures-per-test", "--collect-only", "--co", "--setup-plan"),
    "jest": ("--clearCache", "--listTests", "--showConfig"),
    "ruff": ("--show-files", "--show-settings"),
}
# Subcommands that inspect instead of checking: `ruff rule F401`. `ruff format`
# is a check only with `--check`.
NON_RUN_SUBCOMMANDS = {"ruff": ("rule", "config", "format", "linter", "version", "clean", "server", "analyze")}
# An option that makes any runner only print (`pytest --version`), not run.
PRINTS_ONLY = re.compile(r"--version|--help|-h|-V|--collect-only|--collectOnly|--dry-?[Rr]un|"
                         r"--list-?[Tt]ests?|--list|--show-?config|--co|--print-?config|--why")
# `python -m <module>` runs a check for these modules.
PY_MODULES = ("pytest", "unittest", "tox", "mypy", "ruff", "flake8")
# package.json scripts that are checks: `npm test`, `pnpm run lint`, `yarn test:unit`.
SCRIPTS = ("t", "test", "tests", "lint", "typecheck", "check")
# Test scripts named by path, run directly or by bash/sh/python.
TEST_SCRIPT = re.compile(r"(?:\./)?tests?/[A-Za-z0-9._/-]*\.(?:sh|py)|\./[A-Za-z0-9._-]*(?:test|check)[A-Za-z0-9._-]*\.sh")
PYTHON = re.compile(r"python[0-9.]*")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)

# Every list of options below names only the options that take a value; any
# other option is read as taking none, and `--` ends the options.
#
# Words skipped before the command proper, with the number of plain words
# each takes after its options (`timeout 300`, `cd dir`). `VAR=value` words
# are skipped too.
PREFIXES = {
    "env": ({"-u", "--unset", "-C", "--chdir"}, 0),
    "time": (set(), 0),
    "timeout": ({"-k", "--kill-after", "-s", "--signal"}, 1),
    "cd": (set(), 1),
}
# Programs that end their own options with `--` and run what follows the
# first `--`. A project with another wrapper names its command in test_cmd.
WRAPPERS = (("aws-vault", "exec"), ("doppler", "run"), ("op", "run"),
            ("dotenvx", "run"), ("infisical", "run"), ("mise", "exec"))
# Programs that run a project's copy of a runner. From npm 11's and uv's own
# help; pnpm, yarn and bun from their documentation. npx's -p is --package;
# npm's own -p is --parseable, which takes no value.
FRONTS = {
    ("npx",): {"-p", "--package", "-w", "--workspace", "-c", "--call"},
    ("npm", "exec"): {"--package", "-w", "--workspace", "-c", "--call"},
    ("bunx",): {"-p", "--package"},
    ("pnpm", "exec"): {"--filter", "-F", "-C", "--dir", "--resume-from"},
    ("pnpm", "dlx"): {"--package"},
    ("yarn", "exec"): set(),
    ("yarn", "dlx"): {"-p", "--package"},
    ("uv", "run"): {"--with", "-w", "--with-editable", "--with-requirements", "--python", "-p", "--project",
                    "--directory", "--package", "--extra", "--group"},
    ("poetry", "run"): set(),
    ("pipenv", "run"): set(),
    ("hatch", "run"): set(),
    ("rye", "run"): set(),
    ("bundle", "exec"): set(),
}
# Package managers, and whether a runner may follow them directly
# (`pnpm vitest`). After the options comes a check script, `run <script>`,
# one of the FRONTS above, `yarn workspace <name> ...`, or (where allowed) a
# runner. Anything else is one of its own subcommands (`add`, `why`, ...).
MANAGERS = {
    "npm": ({"--prefix", "-C", "-w", "--workspace"}, False),
    "pnpm": ({"--filter", "-F", "-C", "--dir", "--reporter", "--loglevel"}, True),
    "yarn": ({"--cwd"}, True),
    "bun": (set(), False),
}

# The pieces of a command, each after any spaces. Quoted text and escapes
# join the word they are in; `;` `&` `&&` `|` `||` `(` `)` and newlines are
# operators; a redirection (`>`, `2>`, `2>&1`, `&>`, `<<EOF`) is dropped with
# its target. A lone quote or trailing backslash means a quote is left open.
PIECE = re.compile(r"""([^\S\n]*)('[^']*'|"(?:[^"\\]|\\[\s\S])*"|\\[\s\S]|&&|\|\||&>>?|"""
                   r"""[0-9]*(?:<<<|<<-|<<|>>|<>|<&|>&|>\||<|>)|[;&|()\n]|[^\s'"\\;&|()<>]+|['"\\]|$)""")
OPERATORS = frozenset(("&&", "||", ";", "&", "|", "(", ")", "\n"))
SPECIAL = frozenset("'\"\\&|;()\n<>#0123456789")


def _unquote(piece):
    first = piece[0]
    if first == "'":
        return piece[1:-1]
    if first == '"':
        return re.sub(r'\\([\\"$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), piece[1:-1])
    if first == "\\":
        return "" if piece[1] == "\n" else piece[1]
    return piece


def tokens(text):
    """The command as a list: a word is a str, an operator a 1-tuple. None
    when a quote is left open: such a command is not read as a check."""
    out, word = [], None
    drop = False            # the next word is a redirection's target
    heredoc = None          # a `<<` redirection's tab rule, until its word ends
    pending = []            # heredoc (terminator, strip tabs) whose body is next

    def flush():
        nonlocal word, drop, heredoc
        if word is not None:
            if heredoc is not None:
                pending.append((word, heredoc))
                heredoc = None
            if not drop:
                out.append(word)
            drop, word = False, None

    pieces = PIECE.finditer(text)
    while True:
        match = next(pieces, None)
        if match is None:
            break
        space, piece = match.groups()
        if space:
            flush()
        if not piece:
            continue
        first = piece[0]
        if first not in SPECIAL or (first.isdigit() and "<" not in piece and ">" not in piece):
            word = piece if word is None else word + piece      # a plain word: the usual case
        elif first in "'\"\\":
            if len(piece) == 1:
                return None     # a quote left open
            word = (word or "") + _unquote(piece)
        elif piece in OPERATORS:
            flush()
            drop, heredoc = False, None
            out.append((piece,))
            if piece == "\n" and pending:
                pieces = PIECE.finditer(text, _after_heredocs(text, match.end(), pending))
                pending = []
        elif first == "#":
            if word is not None:
                word += piece
                continue
            newline = text.find("\n", match.end())
            if newline < 0:
                break
            pieces = PIECE.finditer(text, newline)
        else:                   # a redirection, perhaps after a descriptor number
            digits = len(piece) - len(piece.lstrip("0123456789"))
            if digits and word is not None:
                word += piece[:digits]
            flush()
            drop = True
            if piece[digits:] in ("<<", "<<-"):
                heredoc = piece[digits:] == "<<-"
    flush()
    return out


def _after_heredocs(text, pos, pending):
    """Position after the bodies of the heredocs started on the line just read."""
    end = len(text)
    for terminator, strip_tabs in pending:
        while pos < end:
            newline = text.find("\n", pos)
            stop = end if newline < 0 else newline
            line = text[pos:stop]
            pos = stop + 1 if newline >= 0 else end
            if (line.lstrip("\t") if strip_tabs else line) == terminator:
                break
    return pos


def segments(toks):
    """(index of the first token, words) for each run of words between operators."""
    start, current = 0, []
    for index, token in enumerate(toks):
        if isinstance(token, tuple):
            yield start, current
            start, current = index + 1, []
        else:
            current.append(token)
    yield start, current


def skip_options(words, i, valued):
    """Index past the options at words[i:], and past a `--` that ends them."""
    while i < len(words) and words[i].startswith("-"):
        if words[i] == "--":
            return i + 1
        i += 2 if words[i] in valued else 1
    return i


def base(word):
    return word.rsplit("/", 1)[-1]


def starts(words):
    """(where a test_cmd starting with `cd` may start, where the command
    proper starts): past the leading prefixes other than `cd`, then past all
    prefixes and a named wrapper's first `--`. None for a wrapper with no `--`."""
    i, before_cd, wrapped = 0, None, False
    while i < len(words):
        w = words[i]
        if "=" in w and ASSIGNMENT.match(w):
            i += 1
            continue
        name = base(w)
        if name in PREFIXES:
            if name == "cd" and before_cd is None:
                before_cd = i
            valued, positional = PREFIXES[name]
            i = skip_options(words, i + 1, valued) + positional
        elif not wrapped and tuple(words[i:i + 2]) in WRAPPERS:
            try:
                i = words.index("--", i + 2) + 1
            except ValueError:
                return None
            wrapped = True
        else:
            break
    i = min(i, len(words))
    return (i if before_cd is None else before_cd), i


def asks_not_to_run(words):
    """The segment asks a runner only to print, plan, list or skip."""
    seen = set()
    for w in words:
        if w[:1] == "-":
            name, equals, value = w.partition("=")
            if PRINTS_ONLY.fullmatch(w) or any(
                    w in NON_RUNS[r] or (equals and name in NON_RUNS[r] and value == "true") for r in seen):
                return True
        elif base(w) in NON_RUNS:
            seen.add(base(w))
    return False


def is_script(word):
    return word in SCRIPTS or any(word.startswith(s + ":") or word.startswith(s + "-")
                                  for s in SCRIPTS if s != "t")


def is_runner(words, i):
    """words[i:] starts with a runner that runs a check."""
    if i >= len(words):
        return False
    name, rest = base(words[i]), words[i + 1:]
    if name in NON_RUN_SUBCOMMANDS:
        sub = next((w for w in rest if not w.startswith("-")), None)
        if sub in NON_RUN_SUBCOMMANDS[name] and not (sub == "format" and "--check" in rest):
            return False
    if name in TOOLS or TEST_SCRIPT.fullmatch(words[i]):
        return True
    if name in SUBCOMMANDS:
        targets, valued = SUBCOMMANDS[name]
        j = 1 if name == "cargo" and rest[:1] and rest[0][:1] == "+" else 0     # `cargo +nightly test`
        j = skip_options(rest, j, valued)
        return j < len(rest) and rest[j] in targets
    if name in TARGETS:
        targets, valued = TARGETS[name]
        j = 0
        while j < len(rest) and rest[j] != "--":
            w = rest[j]
            if w[:1] == "-":
                j += 2 if w in valued else 1
                continue
            if (w.rsplit(":", 1)[-1] if name in ("gradle", "gradlew") else w) in targets:
                return True
            j += 1
        return False
    interpreter = "python" if PYTHON.fullmatch(name) else name
    if interpreter in INTERPRETERS:
        valued, parse_only = INTERPRETERS[interpreter]
        j = 0           # the interpreter's own options, up to -m, -c or the script
        while j < len(rest) and rest[j][:1] == "-" and rest[j] not in ("-m", "-c", "--"):
            w = rest[j]
            if w in parse_only or (w[1:2] != "-" and any("-" + c in parse_only for c in w[1:])):
                return False
            j += 2 if w[1:2] != "-" and w[-1] in valued else 1
        if j < len(rest) and rest[j] == "--":
            j += 1
        if interpreter == "python" and rest[j:j + 1] == ["-m"]:
            module = rest[j + 1:j + 2]
            # The module is judged as the runner it names, inspection modes included.
            return bool(module) and module[0] in PY_MODULES and (
                module[0] == "unittest" or is_runner(rest, j + 1))
        return j < len(rest) and bool(TEST_SCRIPT.fullmatch(rest[j]))
    return False


def manager(words, i):
    """words[i:] starts with a package manager: judge what it runs."""
    name = base(words[i])
    valued, direct = MANAGERS[name]
    while True:
        j = skip_options(words, i + 1, valued)
        if j >= len(words):
            return False
        w = words[j]
        if is_script(w):
            return True
        if w in ("run", "run-script"):
            return j + 1 < len(words) and is_script(words[j + 1])
        if (name, w) in FRONTS:
            return is_runner(words, skip_options(words, j + 1, FRONTS[(name, w)]))
        if name == "yarn" and w == "workspace":
            i = j + 1           # `yarn workspace web jest`: read on after the name
            continue
        return direct and is_runner(words, j)


def segment_is_check(words):
    """One segment's words run a check, and not only to print or plan."""
    positions = starts(words)
    if positions is None or asks_not_to_run(words):
        return False
    i = positions[1]
    if i >= len(words):
        return False
    first = base(words[i])
    for key in ((first,), (first, words[i + 1] if i + 1 < len(words) else None)):
        if key in FRONTS:
            return is_runner(words, skip_options(words, i + len(key), FRONTS[key]))
    if first in MANAGERS:
        return manager(words, i)
    return is_runner(words, i)


def ran_a_check(command, test_cmd=""):
    """Some segment of the command runs a check, or the words and operators
    of test_cmd (its leading prefixes other than `cd` removed) appear in the
    command where a segment's command may start. A segment the match touches
    that asks only to print or plan cancels it. The comparison costs at most
    the command's length times test_cmd's; test_cmd is the project's own."""
    toks = tokens(command)
    if toks is None:
        return False
    found = []
    for start, words in segments(toks):
        if segment_is_check(words):
            return True
        found.append((start, words))
    want = tokens(test_cmd) if test_cmd else None
    if not want:
        return False
    head = starts(next(segments(want))[1])
    want = want[head[0] if head else 0:]
    if not want:
        return False
    vetoed = [asks_not_to_run(words) for _, words in found]
    for k, (start, words) in enumerate(found):
        for p in set(starts(words) or ()):
            at = start + p
            if toks[at:at + len(want)] != want:
                continue
            j = k               # every segment the match touches must run
            while j < len(found) and found[j][0] < at + len(want) and not vetoed[j]:
                j += 1
            if j == len(found) or found[j][0] >= at + len(want):
                return True
    return False


def active(payload):
    """stop_hook_active as Codex and Claude Code send it: a boolean. A string
    "false" is not true."""
    value = payload.get("stop_hook_active")
    return value is True or (isinstance(value, str) and value.strip().lower() == "true")


def main():
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        return 0
    if active(payload):
        return 0            # already spoke this turn; do not nag on every re-entry

    # A label inside a code fence is being quoted, not claimed. The last verdict
    # in the reply is the verdict.
    found = LABEL.findall(FENCE.sub("", payload.get("last_assistant_message") or ""))
    if not found or found[-1].strip().upper() != "PASS":
        return 0

    # On SubagentStop the harness names the child's own file; judging a child by
    # its parent's commands is worse than silence.
    transcript = payload.get("transcript_path")
    if payload.get("hook_event_name") == "SubagentStop":
        transcript = payload.get("agent_transcript_path") or child_file(transcript, payload)
    if not isinstance(transcript, str) or not os.path.isfile(transcript):
        return 0

    entries = []
    with open(transcript, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)

    start = 0
    for index, entry in enumerate(entries):
        if is_person(entry):
            start = index
    recent = entries[start:]

    # A call counts only when the harness wrote a finished, non-error result
    # for it. A call with no result was interrupted or is still running, and a
    # launch acknowledgement is a start, not a finish.
    finished = {b.get("tool_use_id") for e in recent for b in blocks(e) if finished_ok(b)}
    test_cmd = configured_test_cmd(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    for entry in recent:
        for b in blocks(entry):
            if (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"
                    and isinstance(b.get("input"), dict)
                    and isinstance(b["input"].get("command"), str)
                    and not b["input"].get("run_in_background")   # a launch is not a finish
                    and isinstance(b.get("id"), str) and b["id"] in finished
                    and ran_a_check(b["input"]["command"], test_cmd)):
                return 0

    if os.environ.get("ORCH_HOOK_DRY_RUN") == "1":
        print("orch-dry-run[orch-verify-gate]: would report - " + NOTE, file=sys.stderr)
        return 0
    # additionalContext is the one route to the model on this harness; stderr
    # would only reach the person's transcript view, and the person is not the
    # audience for an agent's missing check.
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": payload.get("hook_event_name") or "Stop", "additionalContext": NOTE}}))
    return 0


def child_file(transcript, payload):
    """Fallback for harness versions without agent_transcript_path."""
    agent = payload.get("agent_id")
    if not agent or not isinstance(transcript, str):
        return None
    stem = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
    for name in ("agent-%s.jsonl" % agent, "%s.jsonl" % agent):
        candidate = os.path.join(stem, "subagents", name)
        if os.path.isfile(candidate):
            return candidate
    return None


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)     # a malformed transcript must never cost the turn
