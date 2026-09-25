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
quotes and escapes join a word, operators outside quotes end a segment. It
does not judge what the shell would do with the result. Limits, by
construction, the same on both harnesses: `npm test &` (the shell reports 0
before the check has finished), a check named only inside a heredoc body, and
`npm test || true` are all accepted. Those are disguises. The laws leave
honesty to the agent: this check catches the careless false claim, not the
deliberate one. Earlier versions tried to judge them (heredoc and background
rules) and every rule mis-judged an honest command somewhere else: `2>&1`, a
multi-line quoted argument, a here-string. Do not add those rules back; a
note that is wrong gets ignored, which is worse than no note.

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
# describes them. A command is read in three linear passes and never with a
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
# `python -m <module>` runs a check for these modules.
PY_MODULES = ("pytest", "unittest", "tox", "mypy", "ruff", "flake8")
# package.json scripts that are checks: `npm test`, `pnpm run lint`, `yarn test:unit`.
SCRIPTS = ("t", "test", "tests", "lint", "typecheck", "check")
# Test scripts named by path, run directly or by bash/sh/python.
TEST_SCRIPT = re.compile(r"(?:\./)?tests?/[A-Za-z0-9._/-]*\.(?:sh|py)|\./[A-Za-z0-9._-]*(?:test|check)[A-Za-z0-9._-]*\.sh")
PYTHON = re.compile(r"python[0-9.]*")

# Programs that end their own options with `--` and run what follows the
# first `--`. A project with another wrapper names its command in test_cmd.
WRAPPERS = (("aws-vault", "exec"), ("doppler", "run"), ("op", "run"),
            ("dotenvx", "run"), ("infisical", "run"), ("mise", "exec"))

# Programs that run a project's copy of a runner: the words that name them,
# the options they accept that take a value, and those that do not. Any
# other option means the command is not read as a check.
FRONTS = {
    ("npx",): ({"-p", "--package", "-c", "--call"}, {"-y", "--yes", "--no", "--no-install", "-q", "--quiet"}),
    ("bunx",): (set(), {"--bun"}),
    ("npm", "exec"): ({"-p", "--package", "-w", "--workspace"}, {"-y", "--yes", "--no", "-ws", "--workspaces"}),
    ("pnpm", "exec"): ({"--filter", "-F", "-C", "--dir"}, {"-r", "--recursive", "--parallel"}),
    ("pnpm", "dlx"): (set(), set()),
    ("yarn", "exec"): (set(), set()),
    ("yarn", "dlx"): (set(), set()),
    ("uv", "run"): ({"--with", "--python", "-p", "--project", "--directory", "--package", "--extra", "--group"},
                    {"--frozen", "--locked", "--no-sync", "--isolated", "--all-extras", "-q", "--quiet"}),
    ("poetry", "run"): (set(), set()),
    ("pipenv", "run"): (set(), set()),
    ("hatch", "run"): (set(), set()),
    ("rye", "run"): (set(), set()),
    ("bundle", "exec"): (set(), set()),
}
# Package managers: their options, and whether a runner may follow directly
# (`pnpm vitest`). After the options comes a check script, `run <script>`,
# one of the FRONTS above, `yarn workspace <name> ...`, or (where allowed) a
# runner. Anything else is one of its own subcommands (`add`, `why`, ...).
MANAGERS = {
    "npm": ({"--prefix", "-w", "--workspace"}, {"-s", "--silent", "-ws", "--workspaces", "--if-present"}, False),
    "pnpm": ({"--filter", "-F", "-C", "--dir", "--reporter", "--loglevel"},
             {"-r", "--recursive", "-w", "--workspace-root", "-s", "--silent", "--parallel", "--stream"}, True),
    "yarn": ({"--cwd"}, {"-W", "--ignore-workspace-root-check", "-s", "--silent"}, True),
    "bun": (set(), set(), False),
}

# An option that makes a runner only print (`pytest --version`), not run.
PRINTS_ONLY = re.compile(r"--version|--help|-h|-V|--collect-only|--collectOnly|--dry-?[Rr]un|"
                         r"--list-?[Tt]ests?|--list|--show-?config|--co|--print-?config|--why")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)

# One pass over the text. Quoted text and escapes join the word they are in;
# `;` `&` `|` `(` `)` and newlines outside quotes end a segment; `<` and `>`
# outside quotes are redirections and end the word before them.
PIECE = re.compile(r"""'[^']*'|"(?:[^"\\]|\\[\s\S])*"|\\[\s\S]|[ \t\r]+|&&|\|\||&>+|[<>]+&?|[;&|()\n]|[^\s'"\\;&|()<>]+|['"\\]""")
PLAIN = re.compile(r"""[ \t\r]+|&&|\|\||&>+|[<>]+&?|[;&|()\n]|[^\s;&|()<>]+""")
OPERATORS = frozenset(("&&", "||", ";", "&", "|", "(", ")", "\n"))


def tokens(text):
    """(kind, text) pairs: kind "w" a word, "r" a redirection, "o" an operator.
    An unbalanced quote makes every quote an ordinary character."""
    out = []
    for pattern in (PIECE, PLAIN):
        out, word, broken = [], None, False
        for match in pattern.finditer(text):
            piece = match.group()
            first = piece[0]
            if first in " \t\r":
                kind = "space"
            elif piece in OPERATORS:
                kind = "o"
            elif first in "<>" or piece.startswith("&>"):
                kind = "r"
            elif pattern is PIECE and piece in ("'", '"', "\\"):
                broken = True
                break
            else:
                if pattern is PIECE:
                    if first == "'":
                        piece = piece[1:-1]
                    elif first == '"':
                        piece = re.sub(r'\\([\\"$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), piece[1:-1])
                    elif first == "\\":
                        piece = "" if piece[1] == "\n" else piece[1]
                word = (word or "") + piece
                continue
            if word is not None:
                out.append(("w", word))
                word = None
            if kind != "space":
                out.append((kind, piece))
        if not broken:
            if word is not None:
                out.append(("w", word))
            return out
    return out


def segments(toks):
    """The tokens between operators."""
    current = []
    for token in toks:
        if token[0] == "o":
            yield current
            current = []
        else:
            current.append(token)
    yield current


def words_of(segment):
    """A segment's words, without redirections and their targets."""
    out, skip = [], False
    for kind, text in segment:
        if kind == "r":
            skip = True
        elif skip:
            skip = False
        else:
            out.append(text)
    return out


def skip_lead(items, word=lambda item: item):
    """Index past the leading `VAR=value`, `env`, `time`, `timeout N`, `cd dir`."""
    i = 0
    while i < len(items):
        w = word(items[i])
        if w is None:
            break
        if ASSIGNMENT.match(w) or w in ("env", "time"):
            i += 1
        elif w in ("timeout", "cd"):
            i += 2
        else:
            break
    return i


def skip_options(words, i, valued, plain):
    """Index past known options; None at an option the front does not know."""
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


def after_front(words, j, key):
    """words[j:] follow the FRONTS entry `key`: skip its options, then a
    runner must come next."""
    j = skip_options(words, j, *FRONTS[key])
    if j is not None and j < len(words) and words[j] == "--":
        j += 1
    return j is not None and is_runner(words, j)


def manager(words, i):
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
            return after_front(words, j + 1, (name, w))
        if name == "yarn" and w == "workspace":
            i = j + 1           # `yarn workspace web jest`: read on after the name
            continue
        return direct and is_runner(words, j)


def segment_is_check(words):
    """One segment's words run a check, and not only to print."""
    if any(PRINTS_ONLY.fullmatch(w) for w in words):
        return False
    i = skip_lead(words)
    for wrapper in WRAPPERS:
        if i < len(words) and tuple(words[i:i + 2]) == wrapper:
            try:
                i = words.index("--", i + 2) + 1
            except ValueError:
                return False
            i += skip_lead(words[i:])
            break
    if i >= len(words):
        return False
    first = base(words[i])
    for key in FRONTS:
        if (first,) + tuple(words[i + 1:i + len(key)]) == key:
            return after_front(words, i + len(key), key)
    if first in MANAGERS:
        return manager(words, i)
    return is_runner(words, i)


def lead_step(toks, i):
    """Index past one leading prefix of a whole command (`cd x &&` included),
    or None when there is none."""
    kind, word = toks[i] if i < len(toks) else ("", "")
    if kind != "w":
        return None
    if ASSIGNMENT.match(word) or word in ("env", "time"):
        return i + 1
    if word in ("timeout", "cd"):
        i += 2
        return i + 1 if i < len(toks) and toks[i][1] in ("&&", ";") else i
    return None


def ran_a_check(command, test_cmd=""):
    """Any segment of the command runs a check and not only to print, or the
    command, or one of its segments, starts with test_cmd word for word. The
    whole command is tried after each leading prefix, so a test_cmd holding
    `&&` still matches."""
    toks = tokens(command)
    want = tokens(test_cmd) if test_cmd else []
    if want and not any(k == "w" and PRINTS_ONLY.fullmatch(t) for k, t in toks):
        i = 0
        while i is not None:
            if toks[i:i + len(want)] == want:
                return True
            i = lead_step(toks, i)
    for segment in segments(toks):
        words = words_of(segment)
        if segment_is_check(words):
            return True
        if want and not any(PRINTS_ONLY.fullmatch(w) for w in words):
            i = skip_lead(segment, lambda t: t[1] if t[0] == "w" else None)
            if segment[i:i + len(want)] == want:
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
