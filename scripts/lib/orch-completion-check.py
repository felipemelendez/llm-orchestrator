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
# describes them. A command is read in linear passes and never with a
# backtracking pattern: split into words and operators, cut into segments at
# the operators, then read each segment's words from the left.

# Runners that are a check by name alone, however they are reached by path.
TOOLS = frozenset((
    "pytest", "py.test", "jest", "vitest", "mocha", "rspec", "tox", "nox", "phpunit",
    "pest", "tsc", "ruff", "eslint", "biome", "flake8", "mypy", "pyright", "shellcheck",
    "rubocop", "golangci-lint", "ctest", "bats"))
# Runners that are a check only with one of these next words: `go test`.
SUBCOMMANDS = {
    "go": ("test", "vet"), "cargo": ("test", "check", "clippy", "nextest"),
    "mix": ("test",), "gradle": ("test", "check"), "gradlew": ("test", "check"),
    "mvn": ("test", "verify"), "make": ("test", "tests", "check", "lint", "typecheck", "ci", "verify"),
    "just": ("test", "tests", "check", "lint", "typecheck", "ci", "verify"),
    "task": ("test", "tests", "check", "lint", "typecheck", "ci", "verify"),
    "dotnet": ("test",), "swift": ("test",), "bazel": ("test",), "deno": ("test", "check", "lint"),
}
# Options that make one of those runners plan or skip the check instead of
# running it: `make -n test`, `cargo test --no-run`, `mvn -DskipTests test`.
DRY_RUNS = {
    "make": ("-n", "--just-print", "--dry-run", "--recon", "-q", "--question"),
    "just": ("-n", "--dry-run"),
    "cargo": ("--no-run",),
    "gradle": ("-m", "--dry-run"), "gradlew": ("-m", "--dry-run"),
    "mvn": ("-DskipTests", "-Dmaven.test.skip"),
}
# `python -m <module>` runs a check for these modules.
PY_MODULES = ("pytest", "unittest", "tox", "mypy", "ruff", "flake8")
# package.json scripts that are checks: `npm test`, `pnpm run lint`, `yarn test:unit`.
SCRIPTS = ("t", "test", "tests", "lint", "typecheck", "check")
# Test scripts named by path, run directly or by bash/sh/python.
TEST_SCRIPT = re.compile(r"(?:\./)?tests?/[A-Za-z0-9._/-]*\.(?:sh|py)|\./[A-Za-z0-9._-]*(?:test|check)[A-Za-z0-9._-]*\.sh")
PYTHON = re.compile(r"python[0-9.]*")

# Words skipped before the command proper: the options each takes that have a
# value, those that do not, and how many plain words follow (`timeout 300`,
# `cd dir`). `VAR=value` words are skipped too.
PREFIXES = {
    "env": ({"-u", "--unset", "-C", "--chdir"}, {"-i", "--ignore-environment", "-0", "--null", "-v", "--debug"}, 0),
    "time": (set(), {"-p"}, 0),
    "timeout": ({"-k", "--kill-after", "-s", "--signal"}, {"--preserve-status", "--foreground", "-v", "--verbose"}, 1),
    "cd": (set(), {"-L", "-P"}, 1),
}
# Programs that end their own options with `--` and run what follows the
# first `--`. A project with another wrapper names its command in test_cmd.
WRAPPERS = (("aws-vault", "exec"), ("doppler", "run"), ("op", "run"),
            ("dotenvx", "run"), ("infisical", "run"), ("mise", "exec"))

# Programs that run a project's copy of a runner: the words that name them,
# their options that take a value, those that do not, and those whose value
# is itself a command to judge (`npx -c "vitest run"`). Any other option
# means the command is not read as a check. From npm 11 and uv's own help;
# pnpm, yarn and bun from their documentation.
NPM_PLAIN = {"-y", "--yes", "--no", "-q", "--quiet", "-s", "--silent", "--ws", "--workspaces",
             "--include-workspace-root"}
FRONTS = {
    # npx's -p is --package; npm's own -p is --parseable.
    ("npx",): ({"-p", "--package", "-w", "--workspace"}, NPM_PLAIN, {"-c", "--call"}),
    ("npm", "exec"): ({"--package", "-w", "--workspace"}, NPM_PLAIN, {"-c", "--call"}),
    ("bunx",): ({"-p", "--package"}, {"--bun"}, set()),
    ("pnpm", "exec"): ({"--filter", "-F", "-C", "--dir", "--resume-from"}, {"-r", "--recursive", "--parallel"}, set()),
    ("pnpm", "dlx"): ({"--package"}, {"-s", "--silent"}, set()),
    ("yarn", "exec"): (set(), set(), set()),
    ("yarn", "dlx"): ({"-p", "--package"}, {"-q", "--quiet"}, set()),
    ("uv", "run"): ({"--with", "-w", "--with-editable", "--with-requirements", "--python", "-p", "--project",
                     "--directory", "--package", "--extra", "--group"},
                    {"--frozen", "--locked", "--no-sync", "--isolated", "--all-extras", "-q", "--quiet"}, set()),
    ("poetry", "run"): (set(), set(), set()),
    ("pipenv", "run"): (set(), set(), set()),
    ("hatch", "run"): (set(), set(), set()),
    ("rye", "run"): (set(), set(), set()),
    ("bundle", "exec"): (set(), set(), set()),
}
FRONT_KEYS = {}
for _key in FRONTS:
    FRONT_KEYS.setdefault(_key[0], []).append(_key)
# Package managers: their options, and whether a runner may follow directly
# (`pnpm vitest`). After the options comes a check script, `run <script>`,
# one of the FRONTS above, `yarn workspace <name> ...`, or (where allowed) a
# runner. Anything else is one of its own subcommands (`add`, `why`, ...).
MANAGERS = {
    "npm": ({"--prefix", "-C", "-w", "--workspace"}, NPM_PLAIN | {"--if-present"}, False),
    "pnpm": ({"--filter", "-F", "-C", "--dir", "--reporter", "--loglevel"},
             {"-r", "--recursive", "-w", "--workspace-root", "-s", "--silent", "--parallel", "--stream"}, True),
    "yarn": ({"--cwd"}, {"--silent"}, True),
    "bun": (set(), set(), False),
}

# An option that makes any runner only print (`pytest --version`), not run.
PRINTS_ONLY = re.compile(r"--version|--help|-h|-V|--collect-only|--collectOnly|--dry-?[Rr]un|"
                         r"--list-?[Tt]ests?|--list|--show-?config|--co|--print-?config|--why")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)
# How deep `npx -c "npx -c '...'"` is followed.
MAX_DEPTH = 3

# The pieces of a command. Quoted text and escapes join the word they are in;
# `;` `&` `&&` `|` `||` `(` `)` and newlines outside quotes are operators; a
# redirection (`>`, `2>`, `2>&1`, `&>`, `<<EOF`) is dropped with its target.
_REDIRECT = r"&>>?|[0-9]*(?:<<<|<<-|<<|>>|<>|<&|>&|>\||<|>)"
PIECE = re.compile(r"""'[^']*'|"(?:[^"\\]|\\[\s\S])*"|\\[\s\S]|[ \t\r]+|&&|\|\||""" + _REDIRECT
                   + r"""|[;&|()\n]|[^\s'"\\;&|()<>]+|['"\\]""")
# The same with quotes read as ordinary characters, for a quote left open.
PLAIN = re.compile(r"[ \t\r]+|&&|\|\||" + _REDIRECT + r"|[;&|()\n]|[^\s;&|()<>]+")
OPERATORS = frozenset(("&&", "||", ";", "&", "|", "(", ")", "\n"))


def _unquote(piece):
    first = piece[0]
    if first == "'":
        return piece[1:-1]
    if first == '"':
        return re.sub(r'\\([\\"$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), piece[1:-1])
    if first == "\\":
        return "" if piece[1] == "\n" else piece[1]
    return piece


def _read(text, pattern):
    """Words and operators as a list: a word is a str, an operator a 1-tuple.
    None when a quote is left open."""
    out, word, pos, end = [], None, 0, len(text)
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

    while pos < end:
        match = pattern.match(text, pos)
        piece, pos = match.group(), match.end()
        first = piece[0]
        if pattern is PIECE and piece in ("'", '"', "\\"):
            return None
        if first in " \t\r":
            flush()
        elif piece in OPERATORS:
            flush()
            drop, heredoc = False, None
            out.append((piece,))
            if piece == "\n" and pending:
                pos = _after_heredocs(text, pos, pending)
                pending = []
        elif first in "<>&" or (first.isdigit() and piece.lstrip("0123456789")[:1] in ("<", ">")):
            if first.isdigit() and word is not None:
                word += piece[:len(piece) - len(piece.lstrip("0123456789"))]
            flush()
            bare = piece.lstrip("0123456789")
            drop = True
            if bare in ("<<", "<<-"):
                heredoc = bare == "<<-"
        elif first == "#" and word is None:
            newline = text.find("\n", pos)
            pos = end if newline < 0 else newline
        else:
            word = (word or "") + (_unquote(piece) if pattern is PIECE else piece)
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


SPECIAL = re.compile(r"""['"\\#<>]""")
SPLIT = re.compile(r"(&&|\|\||[;&|()\n])")


def tokens(text):
    """Words and operators of a command (see _read). Text with no quote,
    escape, comment or redirection is split directly, which is faster."""
    if not SPECIAL.search(text):
        out = []
        for index, part in enumerate(SPLIT.split(text)):
            if index % 2:
                out.append((part,))
            else:
                out.extend(part.split())
        return out
    read = _read(text, PIECE)
    return read if read is not None else _read(text, PLAIN)


def segments(toks):
    """The words between operators, with the index of each segment's first
    token in toks."""
    start, current = 0, []
    for index, token in enumerate(toks):
        if isinstance(token, tuple):
            yield start, current
            start, current = index + 1, []
        else:
            current.append(token)
    yield start, current


def skip_options(words, i, valued, plain):
    """Index past known options; None at an option the program does not know."""
    while i < len(words):
        w = words[i]
        if w in valued:
            i += 2
        elif w in plain or w.split("=", 1)[0] in valued:
            i += 1
        elif w.startswith("-") and w != "--":
            return None
        else:
            break
    return i


def base(word):
    return word.rsplit("/", 1)[-1]


def starts(words):
    """Where the command proper may start: 0, then after each leading prefix,
    then after a named wrapper's first `--` and the prefixes after it. None
    when a wrapper has no `--`."""
    out, i, wrapped = [0], 0, False
    while i < len(words):
        w = words[i]
        if "=" in w and ASSIGNMENT.match(w):
            i += 1
        elif w in PREFIXES:
            valued, plain, positional = PREFIXES[w]
            j = skip_options(words, i + 1, valued, plain)
            if j is None:
                break
            i = j + positional
        elif not wrapped and tuple(words[i:i + 2]) in WRAPPERS:
            try:
                i = words.index("--", i + 2) + 1
            except ValueError:
                return None
            wrapped = True
        else:
            break
        out.append(min(i, len(words)))
    return out


def is_script(word):
    return word in SCRIPTS or any(word.startswith(s + ":") or word.startswith(s + "-")
                                  for s in SCRIPTS if s != "t")


def is_runner(words, i):
    """words[i:] starts with a runner that runs a check."""
    if i >= len(words):
        return False
    name, rest = base(words[i]), words[i + 1:i + 3]
    if name in TOOLS or TEST_SCRIPT.fullmatch(words[i]):
        return True
    if name in SUBCOMMANDS:
        dry = DRY_RUNS.get(name, ())
        if any(w in dry or w.split("=", 1)[0] in dry and w.split("=", 1)[1] in ("", "true")
               for w in words[i + 1:]):
            return False
        j = i + 1
        if name == "mvn":
            while j < len(words) and words[j].startswith("-"):
                j += 1
        return j < len(words) and words[j] in SUBCOMMANDS[name]
    if PYTHON.fullmatch(name):
        return bool(rest) and (rest[0] == "-m" and rest[1:2] and rest[1] in PY_MODULES
                               or bool(TEST_SCRIPT.fullmatch(rest[0])))
    if name in ("bash", "sh"):
        return bool(rest) and bool(TEST_SCRIPT.fullmatch(rest[0]))
    return False


def after_front(words, j, key, depth):
    """words[j:] follow the FRONTS entry `key`: skip its options, then a
    runner must come next, or the command an option names must run a check."""
    valued, plain, command = FRONTS[key]
    while j < len(words):
        w = words[j]
        name, equals, value = w.partition("=")
        if w in command:
            return j + 1 < len(words) and runs_a_check(words[j + 1], depth + 1)
        if name in command and equals:
            return runs_a_check(value, depth + 1)
        if w in valued:
            j += 2
        elif w in plain or (name in valued and equals):
            j += 1
        elif w == "--":
            j += 1
            break
        elif w.startswith("-"):
            return False
        else:
            break
    return is_runner(words, j)


def manager(words, i, depth):
    """words[i:] starts with a package manager: judge what it runs."""
    name = base(words[i])
    valued, plain, direct = MANAGERS[name]
    while True:
        j = skip_options(words, i + 1, valued, plain)
        if j is None or j >= len(words):
            return False
        w = words[j]
        if is_script(w):
            return True
        if w in ("run", "run-script"):
            return j + 1 < len(words) and is_script(words[j + 1])
        if (name, w) in FRONTS:
            return after_front(words, j + 1, (name, w), depth)
        if name == "yarn" and w == "workspace":
            i = j + 1           # `yarn workspace web jest`: read on after the name
            continue
        return direct and is_runner(words, j)


def prints_only(words):
    return any(PRINTS_ONLY.fullmatch(w) for w in words if w[:1] == "-")


def segment_is_check(words, depth=0, positions=None, printing=None):
    """One segment's words run a check, and not only to print. positions and
    printing, when given, are starts(words) and prints_only(words)."""
    if prints_only(words) if printing is None else printing:
        return False
    if positions is None:
        positions = starts(words)
    if positions is None or positions[-1] >= len(words):
        return False
    i = positions[-1]
    first = base(words[i])
    for key in FRONT_KEYS.get(first, ()):
        if (first,) + tuple(words[i + 1:i + len(key)]) == key:
            return after_front(words, i + len(key), key, depth)
    if first in MANAGERS:
        return manager(words, i, depth)
    return is_runner(words, i)


def runs_a_check(text, depth=0):
    """Some segment of text runs a check."""
    return depth <= MAX_DEPTH and any(segment_is_check(words, depth) for _, words in segments(tokens(text)))


def _occurrences(toks, want):
    """Start indexes of want inside toks, by Knuth-Morris-Pratt: linear."""
    fail, k = [0] * len(want), 0
    for i in range(1, len(want)):
        while k and want[i] != want[k]:
            k = fail[k - 1]
        if want[i] == want[k]:
            k += 1
        fail[i] = k
    k = 0
    for i, token in enumerate(toks):
        while k and token != want[k]:
            k = fail[k - 1]
        if token == want[k]:
            k += 1
        if k == len(want):
            yield i - k + 1
            k = fail[k - 1]


def ran_a_check(command, test_cmd=""):
    """Some segment of the command runs a check, or test_cmd's words and
    operators appear in it starting where a segment's command proper may
    start (after its prefixes or a named wrapper). A segment that asks only
    to print does not count either way."""
    toks = tokens(command)
    candidates, printing = set(), []
    for start, words in segments(toks):
        positions, prints = starts(words), prints_only(words)
        if segment_is_check(words, 0, positions, prints):
            return True
        printing.append(prints)
        candidates.update(start + p for p in (positions or ()))
    want = tokens(test_cmd) if test_cmd else []
    if not want:
        return False
    # Which segment each token is in, and how many of the segments before it
    # ask only to print, so a match is checked in constant time.
    segment_of, segment = [], 0
    for token in toks:
        segment_of.append(segment)
        segment += isinstance(token, tuple)
    printed = [0]
    for prints in printing:
        printed.append(printed[-1] + prints)
    for at in _occurrences(toks, want):
        first, last = segment_of[at], segment_of[at + len(want) - 1]
        if at in candidates and printed[last + 1] == printed[first]:
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
