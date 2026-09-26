#!/usr/bin/env python3
"""Rule-by-rule tests for scripts/lib/orch-review.py, run with fake claude and codex programs.

No test calls a model. The fakes stand in for Claude Code's /code-review, `codex review`,
the prover, the refuter, the Claude experiment runner and `codex sandbox`.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/lib/orch-review.py"
_SPEC = importlib.util.spec_from_file_location("orch_review", SCRIPT)
MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(MOD)
SIBLING = "11111111-2222-4333-8444-555555555555"


def scratch_parent():
    """A parent for test directories outside every temporary directory a sandbox may write."""
    if sys.platform == "darwin":
        return subprocess.run(["getconf", "DARWIN_USER_CACHE_DIR"], capture_output=True, text=True,
                              check=True).stdout.strip()
    parent = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    parent.mkdir(parents=True, exist_ok=True)
    return str(parent)


# The fakes find the test root from their own path (the review strips unknown environment
# variables): scenario.json, fake.log and project/ sit beside bin/. Each call is logged with its
# role, and the n-th call of a role reads "<role>-<n>" from the scenario before "<role>".
FAKE_COMMON = r'''
import fcntl, json, os, re, shlex, subprocess, sys, time, uuid
from pathlib import Path
FAKE_ROOT = Path(sys.argv[0]).resolve().parent.parent
scenario = json.loads((FAKE_ROOT / "scenario.json").read_text())
SANDBOX_ON = "touch: x: Operation not permitted\nORCH-SANDBOX-ON\n"
def claim(program, role, entry):
    """Log this call and return its number and its behavior, under a lock for parallel calls."""
    with open(FAKE_ROOT / "fake.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = []
        if (FAKE_ROOT / "fake.log").exists():
            rows = [json.loads(line) for line in (FAKE_ROOT / "fake.log").read_text().splitlines()]
        n = sum(row["program"] == program and row["role"] == role for row in rows) + 1
        with open(FAKE_ROOT / "fake.log", "a") as stream:
            stream.write(json.dumps(dict(entry, program=program, role=role, n=n)) + "\n")
    config = scenario.get(program, {})
    return n, config.get(f"{role}-{n}", config.get(role, {}))
def side_effects(spec, cwd):
    for name in spec.get("write_real", []):
        Path(FAKE_ROOT, "project", name).write_text("written by a reviewer\n")
    for name in spec.get("write_copy", []):
        Path(cwd, name).write_text("probe\n")
    time.sleep(spec.get("sleep", 0))
def run_commands(spec, cwd):
    runs = []
    for item in spec.get("commands", []):
        if item.get("background"):
            runs.append((item["command"], "Command running in background with ID: b1", 0, item))
        elif "output" in item:
            runs.append((item["command"], item["output"], item.get("exit", 0), item))
        else:
            done = subprocess.run(item["command"], shell=True, cwd=cwd, capture_output=True, text=True)
            runs.append((item["command"], done.stdout + done.stderr, done.returncode, item))
    return runs
def git_state(cwd):
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=cwd, capture_output=True, text=True).stdout.strip()
    status = subprocess.run(["git", "status", "--porcelain"], cwd=cwd, capture_output=True, text=True).stdout
    spec = Path(cwd, ".git/orch-review/spec.md")
    return {"head": head, "status": status, "spec_copy": spec.read_text() if spec.exists() else None}
def emit(event):
    print(json.dumps(event), flush=True)
def tool_events(n, command, output, code, extra=None):
    request = dict({"command": command}, **(extra or {}))
    return [{"type": "assistant", "message": {"model": "claude-opus-5-5", "content": [
                {"type": "tool_use", "id": f"tool{n}", "name": "Bash", "input": request}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": f"tool{n}", "content": output, "is_error": code != 0}]}}]
DEFAULT_RESULT = {"rank": "mild", "kind": "style", "confidence": 0.9, "claim": "a wording nit",
                  "evidence": {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b",
                               "command": None, "output": None},
                  "mild_reason": "wording only", "repro": None, "not_runnable": None}
def model_output(role, spec, prompt):
    if "output" in spec:
        return spec["output"]
    if role == "prover":
        line = re.search(r"^Finding ids: (.*)$", prompt, re.M)
        ids = [name.strip() for name in line.group(1).split(",") if name.strip()] if line else []
        results = [dict(DEFAULT_RESULT, id=name, **spec.get("results", {}).get(name, {}))
                   for name in ids if name not in spec.get("omit", [])]
        return {"results": results + spec.get("extra", [])}
    if role == "refuter":
        return {"verdicts": spec.get("verdicts", [])}
    return None
'''

FAKE_CLAUDE = "#!/usr/bin/env python3\n" + FAKE_COMMON + r'''
args = sys.argv[1:]
if args[:2] == ["auth", "status"]:
    ok = scenario.get("claude", {}).get("auth", True)
    print(json.dumps({"loggedIn": ok}))
    sys.exit(0 if ok else 1)
def usage(spec):
    return spec.get("model_usage", {"claude-opus-5-5": {"inputTokens": 10, "costUSD": 0.25}})

def code_review():
    prompt = args[1]
    stdin = sys.stdin.read()
    cwd = os.getcwd()
    n, spec = claim("claude", "code-review", {"argv": args, "cwd": cwd, "prompt": prompt, "stdin": stdin,
                                              "env": sorted(os.environ), **git_state(cwd)})
    side_effects(spec, cwd)
    session = args[args.index("--session-id") + 1]
    settings = json.loads(args[args.index("--settings") + 1])["sandbox"]["filesystem"]
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path(os.environ["HOME"]) / ".claude")
    folder = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    project = config / "projects" / folder
    temp = Path(os.environ["TMPDIR"]) / f"claude-{os.getuid()}" / folder
    task = "a" + uuid.uuid4().hex[:16]
    events = [{"type": "user", "message": {"role": "user", "content": "Review target: `" + prompt + "`"}}]
    mode = spec.get("attachment", "ok")
    if mode != "missing":
        deny = [os.path.expanduser(p) for p in settings["denyRead"]]
        allow = [".", *settings["allowWrite"]]
        if mode == "no-run-dir":
            deny = deny[1:]
        if mode == "no-copy":
            allow = ["."]
        text = ("## Bash command sandbox\nHow the sandbox is configured in this session:\nFilesystem: "
                + json.dumps({"read": {"denyOnly": deny, "allowWithinDeny": []},
                              "write": {"allowOnly": allow, "denyWithinAllow": []}}) + "\n\n - more\n")
        events.append({"type": "attachment", "attachment": {"type": "sandbox_instructions", "content": text}})
    probe = re.search(r"run exactly this command with your Bash tool: (.+?)$", prompt, re.M)
    probe_mode = spec.get("probe", "sandboxed")
    commands = list(spec.get("commands", []))
    if probe and probe_mode != "skip":
        command = probe.group(1)
        if probe_mode == "sandboxed":
            commands.insert(0, {"command": command, "output": SANDBOX_ON})
        elif probe_mode == "leaked":
            subprocess.run(command, shell=True, capture_output=True)
            commands.insert(0, {"command": command, "output": SANDBOX_ON})
        elif probe_mode == "both":
            commands.insert(0, {"command": command, "output": SANDBOX_ON + "ORCH-SANDBOX-OFF\n"})
        elif probe_mode == "late":
            commands.insert(0, {"command": command, "output": SANDBOX_ON})
            commands.insert(0, {"command": "ls", "output": "calc.py\n"})
        else:
            commands.insert(0, {"command": command})
    for number, (command, output, code, item) in enumerate(run_commands({"commands": commands}, cwd)):
        extra = {"dangerouslyDisableSandbox": True} if item.get("unsandboxed") else None
        events += tool_events(number, command, output, code, extra)
    if spec.get("findings") is not None or "reply" not in spec:
        reply = ("I reviewed the change.\n\n```json\n" + json.dumps(spec.get("findings", []), indent=2) + "\n```\n")
    else:
        reply = spec["reply"]
    if not spec.get("no_transcript"):
        (project / session / "subagents").mkdir(parents=True, exist_ok=True)
        (project / f"{session}.jsonl").write_text(json.dumps({"type": "user", "message": {"content": prompt}}) + "\n")
        (project / session / "subagents" / f"agent-{task}.jsonl").write_text(
            "".join(json.dumps(event) + "\n" for event in events))
        (temp / session / "tasks").mkdir(parents=True, exist_ok=True)
        (temp / session / "tasks" / f"{task}.output").write_text("x")
    if spec.get("sibling_session"):
        (project / SIBLING_ID).mkdir(parents=True, exist_ok=True)
        (project / f"{SIBLING_ID}.jsonl").write_text("{}\n")
        (temp / SIBLING_ID).mkdir(parents=True, exist_ok=True)
    if spec.get("duplicate_session"):
        (config / "projects" / "another-project" / session).mkdir(parents=True, exist_ok=True)
    if spec.get("lock_session"):
        (project / session / "subagents").chmod(0o500)
    emit({"type": "system", "subtype": "task_started", "task_id": task, "description": "/code-review"})
    if not spec.get("no_init"):
        emit({"type": "system", "subtype": "init", "model": "claude-opus-5-5", "session_id": session,
              "mcp_servers": spec.get("mcp_servers", [])})
    emit({"type": "assistant", "message": {"model": "<synthetic>", "content": [{"type": "text", "text": reply}]}})
    if not spec.get("no_result"):
        emit({"type": "result", "subtype": "success", "is_error": spec.get("is_error", False), "result": reply,
              "session_id": session, "total_cost_usd": 0.25, "modelUsage": usage(spec)})
    sys.exit(spec.get("exit", 0))

def runner(prompt):
    cwd = os.getcwd()
    n, spec = claim("claude", "runner", {"argv": args, "cwd": cwd, "prompt": prompt, "env": sorted(os.environ),
                                         "patch": Path(cwd, ".git/orch-review/patch.diff").exists()})
    lines = re.findall(r"^\d+\. (.*)$", prompt, re.M)
    calls = []
    for number, line in enumerate(lines):
        if number == 0:
            calls.append((line, SANDBOX_ON if spec.get("probe", "sandboxed") == "sandboxed" else "ORCH-SANDBOX-OFF\n"))
            continue
        command = line + " " if spec.get("alter") == number else line
        done = subprocess.run(command, shell=True, cwd=cwd, capture_output=True, text=True,
                              env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        output = done.stdout + done.stderr
        if spec.get("no_marker"):
            output = "\n".join(l for l in output.splitlines() if not l.startswith("ORCH-EXIT="))
        calls.append((command, output))
    if spec.get("swap") and len(calls) > 2:
        calls[1], calls[2] = calls[2], calls[1]
    emit({"type": "system", "subtype": "init", "model": "claude-opus-5-5", "mcp_servers": []})
    for number, (command, output) in enumerate(calls):
        for event in tool_events(number, command, output, 0):
            emit(event)
    if not spec.get("no_result"):
        emit({"type": "result", "subtype": "success", "is_error": False, "result": "DONE", "total_cost_usd": 0.05,
              "modelUsage": usage(spec)})
    sys.exit(spec.get("exit", 0))

def model_launch(prompt):
    role = re.search(r"^Brief: (\S+)", prompt, re.M).group(1)
    cwd = os.getcwd()
    n, spec = claim("claude", role, {"argv": args, "cwd": cwd, "prompt": prompt, "env": sorted(os.environ)})
    side_effects(spec, cwd)
    model = spec.get("served_model", "claude-opus-5-5")
    if not spec.get("no_init"):
        emit({"type": "system", "subtype": "init", "model": model, "mcp_servers": spec.get("mcp_servers", [])})
    commands = list(spec.get("commands", []))
    probe = re.search(r"^Sandbox check: run exactly this command first: (.+)$", prompt, re.M)
    mode = spec.get("probe", "sandboxed")
    if probe and mode != "skip":
        commands.insert(0, {"command": probe.group(1), "output": SANDBOX_ON} if mode == "sandboxed"
                        else {"command": probe.group(1)})
    for number, (command, output, code, item) in enumerate(run_commands({"commands": commands}, cwd)):
        request = {"run_in_background": True} if item.get("background") else None
        for event in tool_events(number, command, output, code, request):
            event["message"]["model"] = model if event["type"] == "assistant" else None
            emit(event)
    output = model_output(role, spec, prompt)
    if not spec.get("no_result"):
        emit({"type": "result", "subtype": "success", "is_error": False, "result": json.dumps(output),
              "structured_output": output, "total_cost_usd": 0.25, "modelUsage": {model: {"inputTokens": 10}}})
    sys.exit(spec.get("exit", 0))

if len(args) > 1 and args[0] == "-p" and args[1].startswith("/code-review"):
    code_review()
prompt = sys.stdin.read()
if prompt.startswith("Run these commands"):
    runner(prompt)
model_launch(prompt)
'''.replace("SIBLING_ID", repr(SIBLING))

FAKE_CODEX = "#!/usr/bin/env python3\n" + FAKE_COMMON + r'''
config = scenario.get("codex", {})
args = sys.argv[1:]
if args[:2] == ["login", "status"]:
    ok = config.get("login", True)
    print("Logged in using ChatGPT" if ok else "Not logged in")
    sys.exit(0 if ok else 1)
if args[:1] == ["sandbox"]:
    claim("codex", "sandbox", {"argv": args, "env": sorted(os.environ)})
    if not config.get("sandbox", True) or args[1:3] != ["-P", ":workspace"] or args[3] != "-C" or args[5] != "--":
        print("sandbox refused to start", file=sys.stderr)
        sys.exit(71)
    done = subprocess.run(args[6:], cwd=args[4], input=sys.stdin.read(), text=True)
    sys.exit(done.returncode)
SESSIONS = Path(os.environ["CODEX_HOME"], "sessions/2026/09/26")

def rollout(conversation, events):
    SESSIONS.mkdir(parents=True, exist_ok=True)
    (SESSIONS / f"rollout-2026-09-26T07-38-09-{conversation}.jsonl").write_text(
        "".join(json.dumps(event) + "\n" for event in events))

def review():
    cwd = os.getcwd()
    notes = [a.split("=", 1)[1] for a in args if a.startswith("developer_instructions=")]
    instruction = json.loads(notes[0]) if notes else None
    n, spec = claim("codex", "codex-review", {"argv": args, "cwd": cwd, "instruction": instruction,
                                              "stdin": sys.stdin.read(), "rust_log": os.environ.get("RUST_LOG"),
                                              "env": sorted(os.environ), **git_state(cwd)})
    side_effects(spec, cwd)
    items = [{"title": f"[P{f.get('priority', 1)}] {f.get('title', 'A problem')}", "body": f.get("body", "It breaks."),
              "confidence_score": 0.9, "priority": f.get("priority", 1),
              "code_location": {"absolute_file_path": os.path.join(cwd, f["file"]),
                                "line_range": {"start": f["line"], "end": f["line"]}}}
             for f in spec.get("findings", [])]
    correctness = spec.get("correctness", "patch is incorrect" if items else "patch is correct")
    message = spec.get("message", json.dumps({"findings": items, "overall_correctness": correctness,
                                              "overall_explanation": "Explained.", "overall_confidence_score": 0.8}))
    parent, helper = str(uuid.uuid4()), str(uuid.uuid4())
    reviews = [str(uuid.uuid4()) for _ in range(spec.get("review_rollouts", 1))]
    rollout(parent, [{"type": "session_meta", "payload": {"id": parent, "source": "exec", "cwd": cwd}},
                     {"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": None}}])
    rollout(helper, [{"type": "session_meta", "payload": {"id": helper, "source": {"subagent": "other"}}},
                     {"type": "turn_context", "payload": {"model": "gpt-helper", "effort": "low"}}])
    for conversation in reviews:
        events = [{"type": "session_meta", "payload": {"id": conversation, "source": {"subagent": "review"}, "cwd": cwd}}]
        if not spec.get("no_developer"):
            events.append({"type": "response_item", "payload": {"type": "message", "role": "developer",
                           "content": [{"type": "input_text", "text": instruction}]}})
        events.append({"type": "turn_context", "payload": {
            "model": spec.get("served_model", config.get("served_model", "gpt-test")),
            "effort": spec.get("effort", "high"), "sandbox_policy": {"type": spec.get("sandbox", "read-only")}}})
        events.append({"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": message}})
        rollout(conversation, events)
    for conversation in [parent, helper, *reviews]:
        if not spec.get("no_start_lines"):
            print('2026-09-26T11:38:09Z  INFO codex_otel.log_only: event.name="codex.conversation_starts" '
                  'sandbox_policy=read-only mcp_servers="%s" conversation.id=%s app.version=0.156.1'
                  % (spec.get("mcp_start", ""), conversation), file=sys.stderr)
            print('2026-09-26T11:38:09Z  INFO codex_otel.trace_safe: event.name="codex.conversation_starts" '
                  'sandbox_policy=read-only mcp_server_count=%d conversation.id=%s' % (spec.get("mcp_count", 0),
                  conversation), file=sys.stderr)
    for conversation in reviews:
        print('2026-09-26T11:38:14Z  INFO codex_otel.trace_safe: event.name="codex.tool_result" tool_name=exec_command '
              'mcp_tool=%s conversation.id=%s' % ("true" if spec.get("mcp_tool") else "false", conversation),
              file=sys.stderr)
    print("Checked the change.\n\nFull review comments:\n")
    count = spec.get("stdout_count", len(items))
    for item in (items * 2)[:count]:
        location = item["code_location"]
        print(f"- {item['title']} — {location['absolute_file_path']}:{location['line_range']['start']}")
        print(f"  {item['body']}\n")
    sys.exit(spec.get("exit", 0))

def model_launch():
    prompt = sys.stdin.read()
    role = re.search(r"^Brief: (\S+)", prompt, re.M).group(1)
    cwd = args[args.index("-C") + 1]
    n, spec = claim("codex", role, {"argv": args, "cwd": os.getcwd(), "prompt": prompt,
                                    "rust_log": os.environ.get("RUST_LOG"), "env": sorted(os.environ)})
    print('2026-09-26T00:00:00Z  INFO session_init: codex_otel.log_only: event.name="codex.conversation_starts" '
          'mcp_servers="%s" event.timestamp=2026-09-26T00:00:00Z' % ", ".join(spec.get("mcp_servers", [])),
          file=sys.stderr, flush=True)
    side_effects(spec, cwd)
    thread = str(uuid.uuid4())
    emit({"type": "thread.started", "thread_id": thread})
    for number, (command, output, code, item) in enumerate(run_commands(spec, cwd)):
        emit({"type": "item.completed", "item": {"id": f"item_{number}", "type": "command_execution",
              "command": "/bin/zsh -lc " + shlex.quote(command), "aggregated_output": output, "exit_code": code}})
    rollout(thread, [{"type": "turn_context", "payload": {
        "model": spec.get("served_model", config.get("served_model", "gpt-test")), "effort": "high"}}])
    output = model_output(role, spec, prompt)
    if not spec.get("no_result"):
        Path(args[args.index("-o") + 1]).write_text(json.dumps(output))
    emit({"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 10}})
    sys.exit(spec.get("exit", 0))

if args[:1] == ["review"]:
    review()
assert args[0] == "exec", args
model_launch()
'''

FIX = textwrap.dedent("""\
    --- a/calc.py
    +++ b/calc.py
    @@ -1,2 +1,2 @@
     def add(a, b):
    -    return a - b
    +    return a + b
    """)
BAD_PATCH = FIX.replace("+    return a + b", "+    return a + b + 1")
CHECK = "python3 check.py"
FILE_LINE = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b", "command": None,
             "output": None}


def code_finding(file="calc.py", line=2, summary="add subtracts", scenario="add(2, 2) returns 0"):
    return {"file": file, "line": line, "summary": summary, "failure_scenario": scenario}


def codex_finding(file="calc.py", line=2, priority=1, title="add subtracts", body="add(2, 2) returns 0"):
    return {"file": file, "line": line, "priority": priority, "title": title, "body": body}


def proof(rank="serious", **extra):
    """A prover result: by default a serious defect with a repro that reproduces."""
    base = {"rank": rank, "kind": "defect", "confidence": 0.9, "claim": "add subtracts, so add(2, 2) returns 0",
            "evidence": dict(FILE_LINE), "mild_reason": None, "repro": {"command": CHECK, "patch": FIX},
            "not_runnable": None}
    base.update(extra)
    return base


def mild(kind="style", reason="wording only", **extra):
    return proof("mild", kind=kind, mild_reason=reason, repro=None, **extra)


def verdict(finding_id, word, rank=None, scenario=None, drop_check=None, explanation="reasons"):
    return {"id": finding_id, "verdict": word, "rank": rank, "scenario": scenario, "drop_check": drop_check,
            "explanation": explanation}


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="orch review tests ", dir=scratch_parent())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.log = self.root / "fake.log"
        self.tmpdir = self.root / "tmp"
        self.tmpdir.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.codex_home = self.home / ".codex"
        self.codex_home.mkdir()
        (self.codex_home / "config.toml").write_text('model = "gpt-test"\n')
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.tools / "git").symlink_to(shutil.which("git"))
        (self.tools / "python3").symlink_to(sys.executable)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, text in (("claude", FAKE_CLAUDE), ("codex", FAKE_CODEX)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.project = self.root / "project"
        self.project.mkdir()
        self.git("init", "-q", "-b", "main")
        (self.project / "calc.py").write_text("def add(a, b):\n    return a + b\n")
        (self.project / "check.py").write_text(
            "import sys\nimport calc\nsys.exit(0 if calc.add(2, 2) == 4 else 1)\n")
        (self.project / ".gitignore").write_text("*.ignored\n__pycache__/\n")
        self.spec = self.root / "spec.md"
        self.spec.write_text("add(a, b) returns the sum of a and b.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.project / "calc.py").write_text("def add(a, b):\n    return a - b\n")
        self.scenario = {"claude": {}, "codex": {}}
        self.runs = 0

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", str(cwd or self.project), *args], check=True,
                              capture_output=True, text=True, env=self.env()).stdout

    def env(self, path_bin=None):
        return {"PATH": f"{path_bin or self.bin}:{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.home),
                "CODEX_HOME": str(self.codex_home), "XDG_STATE_HOME": str(self.home / "state"),
                "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@x.invalid",
                "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@x.invalid", "TMPDIR": str(self.tmpdir),
                "AWS_SECRET_ACCESS_KEY": "aws-secret", "GITHUB_TOKEN": "gh-token",
                "ANTHROPIC_API_KEY": "anthropic-key", "OPENAI_API_KEY": "openai-key"}

    def only(self, *names):
        """A bin directory that holds only the named fakes."""
        directory = self.root / ("only-" + "-".join(names or ("none",)))
        if not directory.exists():
            directory.mkdir()
            for name in names:
                (directory / name).symlink_to(self.bin / name)
        return directory

    def invoke(self, *args, path_bin=None, check_rc=None):
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        result = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.project,
                                capture_output=True, text=True, env=self.env(path_bin), timeout=300)
        if check_rc is not None:
            self.assertEqual(result.returncode, check_rc, result.stdout + result.stderr)
        return result

    def review(self, path="standard", writer="codex", *extra, path_bin=None):
        """Standard on Codex by default, which runs /code-review with both CLIs installed."""
        self.runs += 1
        self.run_dir = self.root / f"run-{self.runs}"
        result = self.invoke("run", "--path", path, "--writer", writer, "--base", self.base,
                             "--spec", str(self.spec), "--run-dir", str(self.run_dir), *extra,
                             path_bin=path_bin)
        review = self.run_dir / "review.json"
        self.assertTrue(review.is_file(), result.stdout + result.stderr)
        self.printed = json.loads(result.stdout) if result.stdout.strip() else {}
        return json.loads(review.read_text())

    def calls(self, program=None, role=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if (program is None or row["program"] == program)
                and (role is None or row["role"] == role)]

    def reviewer(self, program, *findings, **extra):
        key = "code-review" if program == "claude" else "codex-review"
        self.scenario[program][key] = {"findings": list(findings), **extra}

    def prove(self, results, program="claude", **extra):
        self.scenario[program].setdefault("prover", {}).setdefault("results", {}).update(results)
        self.scenario[program]["prover"].update(extra)

    def refute(self, *verdicts, program="claude", **extra):
        self.scenario[program]["refuter"] = {"verdicts": list(verdicts), **extra}

    def outcome_rows(self):
        path = self.home / "state/llm-orchestrator/review-outcomes.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def found(self, review, finding_id):
        return next(f for f in review["findings"] if f["id"] == finding_id)

    def status(self, review, finding_id):
        return self.found(review, finding_id)["status"]

    def assert_incomplete(self, review, fragment):
        self.assertEqual(review["verdict"], "INCOMPLETE", review["incomplete_reasons"])
        self.assertTrue(any(fragment in reason for reason in review["incomplete_reasons"]),
                        review["incomplete_reasons"])

    def config(self, value):
        path = self.project / "docs/llm-orchestrator/cadence.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        self.git("add", "docs")
        self.git("commit", "-qm", "config")

    def unlock_on_cleanup(self):
        def unlock():
            for directory, _, _ in os.walk(self.home):
                os.chmod(directory, 0o700)
        self.addCleanup(unlock)

    # R1
    def test_r1_run_refuses_an_existing_run_directory(self):
        existing = self.root / "existing"
        existing.mkdir()
        result = self.invoke("run", "--path", "standard", "--writer", "claude", "--base", self.base,
                             "--spec", str(self.spec), "--run-dir", str(existing))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_r1_run_refuses_a_run_directory_in_the_repository_or_a_temporary_directory(self):
        for parent, words in ((self.tmpdir, "temporary"), (Path("/tmp"), "temporary"), (self.project, "repository")):
            with self.subTest(parent=str(parent)):
                result = self.invoke("run", "--path", "standard", "--writer", "claude", "--base", self.base,
                                     "--spec", str(self.spec), "--run-dir", str(parent / f"orch-run-{os.getpid()}"))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(words, result.stderr)
        self.assertEqual(self.calls(), [])

    def test_r1_detached_run_finishes_and_wait_reports_the_verdict(self):
        run_dir = self.root / "detached"
        started = self.invoke("run", "--detach", "--path", "standard", "--writer", "claude",
                              "--base", self.base, "--spec", str(self.spec), "--run-dir", str(run_dir),
                              check_rc=0)
        self.assertIn(str(run_dir), started.stdout)
        waited = self.invoke("wait", str(run_dir), "--seconds", "120", check_rc=0)
        self.assertEqual(json.loads(waited.stdout)["verdict"], "READY")

    def test_r1_wait_reports_a_crashed_run_as_incomplete(self):
        run_dir = self.root / "crashed"
        run_dir.mkdir()
        (run_dir / "run.json").write_text("{}")
        dead = subprocess.Popen(["true"])
        dead.wait()
        (run_dir / "pid").write_text(str(dead.pid))
        waited = self.invoke("wait", str(run_dir), "--seconds", "5")
        self.assertNotEqual(waited.returncode, 0)
        self.assertEqual(json.loads(waited.stdout)["status"], "crashed")
        self.assertIn("INCOMPLETE", waited.stdout)

    def test_r1_wait_says_running_when_the_time_runs_out(self):
        self.reviewer("codex", sleep=8)
        run_dir = self.root / "slow"
        self.invoke("run", "--detach", "--path", "standard", "--writer", "claude", "--base", self.base,
                    "--spec", str(self.spec), "--run-dir", str(run_dir), check_rc=0)
        waited = self.invoke("wait", str(run_dir), "--seconds", "1")
        self.assertEqual(json.loads(waited.stdout)["status"], "running")
        self.invoke("wait", str(run_dir), "--seconds", "120", check_rc=0)

    def test_r1_wait_reports_a_run_killed_midway_as_crashed(self):
        self.reviewer("codex", sleep=30)
        run_dir = self.root / "killed"
        started = self.invoke("run", "--detach", "--path", "standard", "--writer", "claude", "--base", self.base,
                              "--spec", str(self.spec), "--run-dir", str(run_dir), check_rc=0)
        pid = json.loads(started.stdout)["pid"]
        deadline = time.monotonic() + 20
        while not self.calls("codex", "codex-review") and time.monotonic() < deadline:
            time.sleep(0.2)
        os.killpg(pid, 9)
        waited = self.invoke("wait", str(run_dir), "--seconds", "20")
        self.assertEqual(json.loads(waited.stdout)["status"], "crashed")
        self.assertFalse((run_dir / "review.json").exists())

    # R2
    def test_r2_the_removed_options_are_refused(self):
        for option in (["--brief", "contract"], ["--adversarial-provider", "claude"], ["--split"], ["--no-refuter"]):
            with self.subTest(option=option[0]):
                result = self.invoke("run", "--path", "standard", "--writer", "claude", "--base", self.base,
                                     "--spec", str(self.spec), "--run-dir", str(self.root / "never"), *option)
                self.assertEqual(result.returncode, 2)
                self.assertIn("unrecognized arguments", result.stderr)
        self.assertEqual(self.calls(), [])

    # R3
    def test_r3_standard_on_claude_runs_codex_review_and_no_refuter(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof()})
        review = self.review("standard", "claude")
        self.assertEqual(len(self.calls("codex", "codex-review")), 1)
        self.assertEqual(self.calls("claude", "code-review"), [])
        self.assertEqual(self.calls("claude", "refuter"), [])
        self.assertEqual([(l["name"], l["provider"]) for l in review["launches"] if l["role"] == "reviewer"],
                         [("codex-review", "codex")])
        self.assertFalse(review["same_provider"])
        self.assertEqual(self.status(review, "codex-review-1"), "verified")
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r3_standard_on_codex_runs_code_review(self):
        self.reviewer("claude", code_finding())
        review = self.review("standard", "codex")
        self.assertEqual(len(self.calls("claude", "code-review")), 1)
        self.assertEqual(self.calls("codex", "codex-review"), [])
        self.assertEqual([f["id"] for f in review["findings"]], ["code-review-1"])
        self.assertFalse(review["same_provider"])

    def test_r3_standard_with_only_the_writer_cli_runs_its_own_and_says_so(self):
        for writer, program, builtin in (("claude", "claude", "code-review"), ("codex", "codex", "codex-review")):
            with self.subTest(writer=writer):
                self.log.unlink(missing_ok=True)
                review = self.review("standard", writer, path_bin=self.only(program))
                self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
                self.assertEqual([l["name"] for l in review["launches"] if l["role"] == "reviewer"], [builtin])
                self.assertTrue(review["same_provider"])
                self.assertTrue(self.printed["same_provider"])
                self.assertIn("same provider", self.printed["verdict_line"])

    def test_r3_full_with_both_clis_runs_one_of_each(self):
        review = self.review("full", "claude")
        self.assertEqual(len(self.calls("claude", "code-review")), 1)
        self.assertEqual(len(self.calls("codex", "codex-review")), 1)
        self.assertEqual(sorted(l["name"] for l in review["launches"] if l["role"] == "reviewer"),
                         ["code-review", "codex-review"])
        self.assertFalse(review["same_provider"])
        self.assertEqual(review["verdict"], "READY")

    def test_r3_full_with_one_cli_runs_its_builtin_twice_independently(self):
        for program, builtin in (("claude", "code-review"), ("codex", "codex-review")):
            with self.subTest(program=program):
                self.log.unlink(missing_ok=True)
                # Both reviews run at once, so each gets the same reply; ids say which review found it.
                self.scenario[program][builtin] = {"findings": [code_finding() if program == "claude"
                                                                else codex_finding(priority=2)]}
                review = self.review("full", program, path_bin=self.only(program))
                calls = self.calls(program, builtin)
                self.assertEqual(len(calls), 2)
                self.assertNotEqual(calls[0]["cwd"], calls[1]["cwd"])
                for call in calls:  # neither is given the other's reply
                    self.assertNotIn("add subtracts", call.get("prompt") or call["instruction"])
                    self.assertIn(call["cwd"] + "/.git/orch-review/spec.md", call.get("prompt") or call["instruction"])
                if program == "claude":
                    sessions = [c["argv"][c["argv"].index("--session-id") + 1] for c in calls]
                    self.assertNotEqual(sessions[0], sessions[1])
                self.assertEqual(sorted(f["id"] for f in review["findings"]), [f"{builtin}-1-1", f"{builtin}-2-1"])
                self.assertEqual(sorted(f["reviewer"] for f in review["findings"]), [f"{builtin}-1", f"{builtin}-2"])
                self.assertTrue(review["same_provider"])
                self.assertIn("both reviews came from one provider", review["verdict_line"])
                self.assertIn("both reviews came from one provider", self.printed["verdict_line"])
                self.assertEqual(sorted(l["name"] for l in review["launches"] if l["role"] == "reviewer"),
                                 [f"{builtin}-1", f"{builtin}-2"])

    def test_r3_prover_and_refuter_run_on_claude_when_installed_else_codex(self):
        self.reviewer("codex", codex_finding())
        for program in ("claude", "codex"):
            self.prove({"codex-review-1": proof()}, program=program)
            self.refute(verdict("codex-review-1", "PROMOTED"), program=program)
        review = self.review("full", "codex")
        self.assertEqual(len(self.calls("claude", "prover")), 1)
        self.assertEqual(len(self.calls("claude", "refuter")), 1)
        self.assertEqual(self.calls("codex", "prover") + self.calls("codex", "refuter"), [])
        self.assertEqual(self.status(review, "codex-review-1"), "promoted")
        self.log.unlink()
        self.prove({"codex-review-1-1": proof(), "codex-review-2-1": proof()}, program="codex")
        self.refute(verdict("codex-review-1-1", "PROMOTED"), verdict("codex-review-2-1", "PROMOTED"),
                    program="codex")
        review = self.review("full", "codex", path_bin=self.only("codex"))
        self.assertEqual(len(self.calls("codex", "prover")), 2)  # one batch per review
        self.assertEqual(len(self.calls("codex", "refuter")), 1)
        self.assertEqual(self.calls("claude"), [])
        self.assertEqual([f["status"] for f in review["findings"]], ["promoted", "promoted"])

    def test_r3_no_signed_in_cli_gives_incomplete_and_a_signed_out_one_too(self):
        review = self.review("standard", "claude", path_bin=self.only())
        self.assert_incomplete(review, "neither claude nor codex")
        self.scenario["codex"]["login"] = False
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "codex is installed but not signed in")
        self.scenario["codex"]["login"] = True
        self.scenario["claude"]["auth"] = False
        self.assert_incomplete(self.review("full", "codex"), "claude is installed but not signed in")
        self.assertEqual(self.calls("claude", "code-review") + self.calls("codex", "codex-review"), [])

    # R4
    def test_r4_both_reviewers_get_the_spec_instruction_and_the_security_lens(self):
        self.review("full", "claude")
        claude = self.calls("claude", "code-review")[0]
        codex = self.calls("codex", "codex-review")[0]
        for text, cwd in ((claude["prompt"], claude["cwd"]), (codex["instruction"], codex["cwd"])):
            self.assertIn(f"The change must implement the spec in {cwd}/.git/orch-review/spec.md. Read it, and "
                          "report every place where the change does not meet it, as well as any other defect.", text)
            self.assertNotIn("Security lens", text)
        (self.project / "auth.py").write_text("password = input()\n")
        self.log.unlink()
        self.review("full", "claude")
        self.assertIn("Security lens", self.calls("claude", "code-review")[0]["prompt"])
        self.assertIn("Security lens", self.calls("codex", "codex-review")[0]["instruction"])

    # Step 3
    def test_step3_the_copy_head_is_the_merge_base_so_the_whole_change_is_uncommitted(self):
        self.git("checkout", "-q", "-b", "work")
        (self.project / "committed.py").write_text("x = 1\n")
        self.git("add", "committed.py")
        self.git("commit", "-qm", "a committed part of the change")
        (self.project / "untracked.py").write_text("y = 2\n")
        self.review("full", "claude")
        for call in (self.calls("claude", "code-review")[0], self.calls("codex", "codex-review")[0]):
            self.assertEqual(call["head"], self.base)
            for name in ("calc.py", "committed.py", "untracked.py"):
                self.assertIn(name, call["status"])
            self.assertEqual(call["spec_copy"], self.spec.read_text())
            self.assertNotIn(str(self.project), call["cwd"])
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.git("rev-parse", "work").strip())

    def test_step3_copies_get_copy_ignored_paths_and_setup_and_are_removed_after(self):
        (self.project / "deps.ignored").write_text("dependency\n")
        self.config({"runner": {"test_cmd": "python3 check.py"},
                     "review": {"copy_ignored": ["deps.ignored"], "setup": "cp deps.ignored setup.ignored"}})
        self.reviewer("claude", code_finding())
        self.prove({}, commands=[{"command": "cat deps.ignored setup.ignored"}])
        review = self.review()
        self.assertEqual(review["verdict"], "READY-WITH-FIXES", review["incomplete_reasons"])
        commands = json.loads((self.run_dir / "launches/prover-1/commands.json").read_text())
        self.assertEqual(commands[-1]["output"].count("dependency"), 2)
        self.assertIn("python3 check.py", self.calls("claude", "prover")[0]["prompt"])
        self.assertFalse(Path(self.calls("claude", "code-review")[0]["cwd"]).exists())

    def test_step3_copy_ignored_paths_excluded_through_info_exclude_are_copied(self):
        with open(self.project / ".git/info/exclude", "a") as exclude:
            exclude.write("deps/\n")
        (self.project / "deps").mkdir()
        (self.project / "deps/lib.py").write_text("x = 1\n")
        self.config({"review": {"copy_ignored": ["deps"]}})
        self.reviewer("claude", commands=[{"command": "cat deps/lib.py"}])
        self.assertEqual(self.review()["verdict"], "READY")

    def test_step3_a_failing_setup_gives_incomplete(self):
        self.config({"review": {"setup": "exit 3"}})
        self.assert_incomplete(self.review(), "setup")

    def test_step3_a_copy_that_does_not_match_the_fingerprint_gives_incomplete_once(self):
        self.config({"review": {"setup": "echo extra > extra.py"}})
        review = self.review()
        self.assert_incomplete(review, "fingerprint")
        self.assertEqual(len([r for r in review["incomplete_reasons"] if "fingerprint" in r]), 1)

    def test_reviewers_and_experiments_get_a_reduced_environment(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        self.refute(verdict("code-review-1", "PROMOTED"))
        self.review("full", "claude")
        rows = self.calls()
        self.assertTrue({row["role"] for row in rows} >= {"code-review", "codex-review", "prover", "refuter", "sandbox"})
        for row in rows:
            with self.subTest(program=row["program"], role=row["role"]):
                self.assertNotIn("AWS_SECRET_ACCESS_KEY", row["env"])
                self.assertNotIn("GITHUB_TOKEN", row["env"])
                keep = {"claude": "ANTHROPIC_API_KEY", "codex": "OPENAI_API_KEY"}[row["program"]]
                drop = {"claude": "OPENAI_API_KEY", "codex": "ANTHROPIC_API_KEY"}[row["program"]]
                self.assertNotIn(drop, row["env"])
                if row["role"] == "sandbox":
                    self.assertNotIn(keep, row["env"])
                    self.assertIn("CODEX_HOME", row["env"])
                else:
                    self.assertIn(keep, row["env"])

    # R5
    def test_r5_code_review_uses_the_exact_flags_and_a_closed_stdin(self):
        self.review()
        call = self.calls("claude", "code-review")[0]
        argv = call["argv"]
        self.assertEqual(argv[0], "-p")
        self.assertTrue(argv[1].startswith("/code-review high Sandbox check: before anything else, run exactly "
                                           "this command with your Bash tool: touch "))
        self.assertEqual(call["stdin"], "")
        for flag in ("--safe-mode", "--restricted", "--strict-mcp-config", "--verbose"):
            self.assertIn(flag, argv)
        self.assertNotIn("--no-session-persistence", argv)
        self.assertNotIn("--append-system-prompt", argv)
        pairs = {argv[i]: argv[i + 1] for i in range(2, len(argv) - 1)}
        self.assertEqual(pairs["--model"], "opus")
        self.assertEqual(pairs["--effort"], "high")
        self.assertEqual(pairs["--output-format"], "stream-json")
        self.assertEqual(pairs["--tools"], "Read,Grep,Glob,Bash,Agent")
        self.assertEqual(pairs["--allowedTools"], "Read,Grep,Glob,Bash,Agent")
        self.assertEqual(pairs["--permission-mode"], "dontAsk")
        self.assertEqual(json.loads(pairs["--mcp-config"]), {"mcpServers": {}})
        self.assertRegex(pairs["--session-id"], r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        sandbox = json.loads(pairs["--settings"])["sandbox"]
        self.assertEqual((sandbox["enabled"], sandbox["failIfUnavailable"], sandbox["allowUnsandboxedCommands"]),
                         (True, True, False))
        self.assertEqual(sandbox["filesystem"]["allowWrite"], [call["cwd"]])
        self.assertIn(str(self.run_dir), sandbox["filesystem"]["denyRead"])
        self.assertIn("~/.claude", sandbox["filesystem"]["denyRead"])
        self.assertEqual(sandbox["network"]["allowedDomains"], [])

    def test_r5_a_failed_skipped_or_late_probe_is_a_dropout(self):
        for probe in ("unsandboxed", "skip", "leaked", "both", "late"):
            with self.subTest(probe):
                self.reviewer("claude", probe=probe)
                self.assert_incomplete(self.review(), "sandbox check")

    def test_r5_a_missing_or_wrong_sandbox_attachment_is_a_dropout(self):
        for mode in ("missing", "no-run-dir", "no-copy"):
            with self.subTest(mode):
                self.reviewer("claude", attachment=mode)
                self.assert_incomplete(self.review(), "sandbox_instructions")

    def test_r5_a_bash_call_asking_to_leave_the_sandbox_is_a_dropout(self):
        self.reviewer("claude", commands=[{"command": "ls", "output": "x", "unsandboxed": True}])
        self.assert_incomplete(self.review(), "outside the sandbox")

    def test_r5_mcp_servers_or_no_init_event_is_a_dropout(self):
        self.reviewer("claude", mcp_servers=[{"name": "slack"}])
        self.assert_incomplete(self.review(), "MCP")
        self.reviewer("claude", no_init=True)
        self.assert_incomplete(self.review(), "init")

    def test_r5_every_model_usage_key_must_be_in_the_opus_family(self):
        self.reviewer("claude", model_usage={"claude-opus-5-5": {}, "claude-haiku-4-5": {}})
        review = self.review()
        self.assert_incomplete(review, "claude-haiku-4-5")
        self.assertEqual(review["launches"][0]["served_model"], ["claude-haiku-4-5", "claude-opus-5-5"])
        self.reviewer("claude", model_usage={})
        self.assert_incomplete(self.review(), "no served model")
        self.reviewer("claude", model_usage={"claude-opus-5-5": {}, "claude-opus-5-5[1m]": {}})
        self.assertEqual(self.review()["verdict"], "READY")

    def test_r5_no_transcript_is_a_dropout(self):
        self.reviewer("claude", no_transcript=True)
        self.assert_incomplete(self.review(), "transcript")

    def test_r5_the_kept_session_is_deleted_by_its_exact_id_only(self):
        self.reviewer("claude", sibling_session=True)
        review = self.review()
        self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
        call = self.calls("claude", "code-review")[0]
        session = call["argv"][call["argv"].index("--session-id") + 1]
        folder = "".join(c if c.isalnum() else "-" for c in call["cwd"])
        project = self.home / ".claude/projects" / folder
        temp = self.tmpdir / f"claude-{os.getuid()}" / folder
        self.assertFalse((project / f"{session}.jsonl").exists())
        self.assertFalse((project / session).exists())
        self.assertFalse((temp / session).exists())
        self.assertTrue((project / f"{SIBLING}.jsonl").exists())
        self.assertTrue((project / SIBLING).is_dir())
        self.assertTrue((temp / SIBLING).is_dir())
        cleanup = review["cleanup"]["sessions"]
        self.assertEqual([(c["session_id"], c["status"]) for c in cleanup], [(session, "deleted")])
        self.assertEqual(self.printed.get("warnings", []), [])
        # Without a sibling the folders are left empty, and so are removed.
        self.reviewer("claude")
        self.review()
        call = self.calls("claude", "code-review")[-1]
        folder = "".join(c if c.isalnum() else "-" for c in call["cwd"])
        self.assertFalse((self.home / ".claude/projects" / folder).exists())
        self.assertFalse((self.tmpdir / f"claude-{os.getuid()}" / folder).exists())

    def test_r5_a_failed_session_delete_is_reported_and_does_not_change_the_verdict(self):
        self.unlock_on_cleanup()
        self.reviewer("claude", lock_session=True)
        review = self.review()
        self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
        cleanup = review["cleanup"]["sessions"][0]
        self.assertEqual(cleanup["status"], "failed")
        self.assertTrue(cleanup["problems"])
        self.assertTrue(any("could not delete" in warning for warning in self.printed["warnings"]))

    def test_r5_two_folders_holding_the_session_delete_nothing_and_are_reported(self):
        self.reviewer("claude", duplicate_session=True)
        review = self.review()
        self.assert_incomplete(review, "transcript")
        cleanup = review["cleanup"]["sessions"][0]
        self.assertEqual(cleanup["status"], "failed")
        self.assertIn("2 project folders", " ".join(cleanup["problems"]))
        call = self.calls("claude", "code-review")[0]
        session = call["argv"][call["argv"].index("--session-id") + 1]
        self.assertTrue((self.home / ".claude/projects/another-project" / session).is_dir())
        folder = "".join(c if c.isalnum() else "-" for c in call["cwd"])
        self.assertTrue((self.home / ".claude/projects" / folder / session).is_dir())
        self.assertTrue(self.printed["warnings"])

    # R6
    def test_r6_codex_review_uses_the_exact_flags(self):
        (self.codex_home / "config.toml").write_text(
            'model = "gpt-test"\n[mcp_servers.figma]\nurl = "https://x.invalid"\n'
            '[mcp_servers.computer-use]\ncommand = "x"\n')
        review = self.review("standard", "claude")
        self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
        call = self.calls("codex", "codex-review")[0]
        argv = call["argv"]
        self.assertEqual(argv[:2], ["review", "--uncommitted"])
        values = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "-c"]
        self.assertEqual(values[:2], ['model_reasoning_effort="high"', 'sandbox_mode="read-only"'])
        self.assertTrue(values[2].startswith('developer_instructions="The change must implement'))
        self.assertIn("mcp_servers.figma.enabled=false", values)
        self.assertIn("mcp_servers.computer-use.enabled=false", values)
        self.assertEqual(sorted(argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--disable"),
                         ["apps", "plugins"])
        for flag in ("-m", "-s", "-C", "--json", "--output-schema", "exec"):
            self.assertNotIn(flag, argv)
        self.assertEqual(call["stdin"], "")
        self.assertIn("codex_otel=info", call["rust_log"])
        launch = review["launches"][0]
        self.assertEqual((launch["requested_model"], launch["served_model"]), ("gpt-test", ["gpt-test"]))
        self.assertEqual((launch["served_effort"], launch["served_sandbox"]), (["high"], ["read-only"]))

    def test_r6_what_codex_review_served_is_checked(self):
        cases = {"served model": {"served_model": "gpt-other"}, "effort": {"effort": "low"},
                 "sandbox": {"sandbox": "workspace-write"}, "developer message": {"no_developer": True},
                 "MCP tool": {"mcp_tool": True}, "MCP server": {"mcp_start": "figma"},
                 "counts one": {"mcp_count": 1},
                 "0 review rollouts": {"review_rollouts": 0}, "2 review rollouts": {"review_rollouts": 2}}
        for fragment, behavior in cases.items():
            with self.subTest(fragment):
                self.reviewer("codex", **behavior)
                self.assert_incomplete(self.review("standard", "claude"), fragment)

    def test_r6_codex_review_without_start_lines_is_accepted(self):
        self.reviewer("codex", no_start_lines=True)
        self.assertEqual(self.review("standard", "claude")["verdict"], "READY")

    def test_r6_a_config_without_a_model_records_but_does_not_compare(self):
        (self.codex_home / "config.toml").write_text("")
        self.reviewer("codex", served_model="gpt-anything")
        review = self.review("standard", "claude")
        self.assertEqual(review["verdict"], "READY")
        self.assertIsNone(review["launches"][0]["requested_model"])
        self.assertEqual(review["launches"][0]["served_model"], ["gpt-anything"])

    # R7
    def test_r7_the_code_review_parser_on_the_recorded_shapes(self):
        items = [{"file": "docsvc/permissions.py", "line": 10, "summary": "admins cross orgs",
                  "failure_scenario": "an admin of org B edits a doc of org A"},
                 {"file": "docsvc/service.py", "line": "12", "summary": "no line", "failure_scenario": ""}]
        text = ("I ran the sandbox check first.\n\n```json\n[]\n```\n\nThen:\n\n```json\n"
                + json.dumps(items, indent=2) + "\n```\n\n```python\nprint('not json')\n```\n")
        found, problem = MOD.code_review_findings(text)
        self.assertIsNone(problem)
        self.assertEqual([(f["file"], f["line"]) for f in found],
                         [("docsvc/permissions.py", 10), ("docsvc/service.py", None)])
        self.assertIn("admins cross orgs", found[0]["words"])
        self.assertIn("an admin of org B", found[0]["words"])
        self.assertEqual(MOD.code_review_findings("No problems.\n\n```json\n[]\n```\n"), ([], None))
        for bad in ("No problems found in the change.", "```json\n[1, 2]\n```",
                    "```json\n[{\"line\": 3}]\n```", "```json\n[]\n```\n```json\n[{\"file\": 3}]\n```"):
            with self.subTest(bad=bad):
                found, problem = MOD.code_review_findings(bad)
                self.assertIsNone(found)
                self.assertTrue(problem)

    def test_r7_the_codex_parser_on_the_recorded_shapes(self):
        copy = self.root / "copy"
        (copy / "docsvc").mkdir(parents=True)
        item = {"title": "[P1] Restrict admins", "body": "Cross-org access.", "confidence_score": 1.0,
                "priority": 1, "code_location": {"absolute_file_path": str(copy / "docsvc/permissions.py"),
                                                 "line_range": {"start": 9, "end": 10}}}
        reply = {"findings": [item], "overall_correctness": "patch is incorrect", "overall_explanation": "x",
                 "overall_confidence_score": 0.9}
        stdout = f"Full review comments:\n\n- [P1] Restrict admins — {copy}/docsvc/permissions.py:9-10\n  x\n"
        found, problem = MOD.codex_review_findings(json.dumps(reply), stdout, copy)
        self.assertIsNone(problem)
        self.assertEqual([(f["file"], f["line"], f["priority"]) for f in found], [("docsvc/permissions.py", 9, 1)])
        self.assertIn("Restrict admins", found[0]["words"])
        clean = dict(reply, findings=[], overall_correctness="patch is correct")
        self.assertEqual(MOD.codex_review_findings(json.dumps(clean), "No issues.\n", copy), ([], None))
        bad = {"prose only": ("The patch looks fine to me.", stdout),
               "no findings but incorrect": (json.dumps(dict(reply, findings=[])), "none\n"),
               "findings but correct": (json.dumps(dict(reply, overall_correctness="patch is correct")), stdout),
               "count differs": (json.dumps(reply), stdout + stdout),
               "missing key": (json.dumps({"findings": []}), ""),
               "finding without a location": (json.dumps(dict(reply, findings=[{"title": "[P1] x", "body": "y"}])),
                                              stdout)}
        for name, (message, out) in bad.items():
            with self.subTest(name):
                found, problem = MOD.codex_review_findings(message, out, copy)
                self.assertIsNone(found)
                self.assertTrue(problem)

    def test_r7_a_prose_only_codex_reply_is_incomplete(self):
        self.reviewer("codex", message="The patch looks correct; I found nothing to flag.")
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "codex-review: dropout")
        self.assertNotEqual(review["verdict"], "READY")

    def test_r7_a_conflicting_or_count_mismatched_codex_reply_is_incomplete(self):
        for behavior in ({"correctness": "patch is incorrect"},
                         {"findings": [codex_finding()], "correctness": "patch is correct"},
                         {"findings": [codex_finding()], "stdout_count": 2}):
            with self.subTest(behavior=behavior):
                self.reviewer("codex", **behavior)
                self.assert_incomplete(self.review("standard", "claude"), "codex-review: dropout")

    def test_r7_a_prose_only_or_wrong_shape_code_review_reply_is_incomplete(self):
        for reply in ("I found no problems in the change.", "```json\n[1, 2]\n```"):
            with self.subTest(reply=reply):
                self.scenario["claude"]["code-review"] = {"reply": reply}
                self.assert_incomplete(self.review(), "code-review: dropout")

    def test_r7_an_empty_array_before_a_full_one_gives_its_findings(self):
        reply = ("Nothing in the first pass.\n```json\n[]\n```\nSecond pass:\n```json\n"
                 + json.dumps([code_finding(), code_finding(line=1, summary="naming")]) + "\n```\n")
        self.scenario["claude"]["code-review"] = {"reply": reply}
        review = self.review()
        self.assertEqual([f["id"] for f in review["findings"]], ["code-review-1", "code-review-2"])
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")

    def test_r7_exits_errors_and_timeouts_are_dropouts(self):
        self.assertEqual(MOD.LAUNCH_TIMEOUT, 3600)
        for behavior, fragment in (({"exit": 1}, "exits nonzero"), ({"is_error": True}, "no final result"),
                                   ({"no_result": True}, "no final result")):
            with self.subTest(fragment):
                self.scenario["claude"]["code-review"] = behavior
                self.assert_incomplete(self.review(), fragment)
        self.reviewer("codex", exit=1)
        self.assert_incomplete(self.review("standard", "claude"), "exits nonzero")

    def test_r7_a_dropout_is_never_replaced_and_its_findings_are_kept_unproved(self):
        self.reviewer("codex", codex_finding(), exit=1)
        review = self.review("full", "claude")
        self.assert_incomplete(review, "codex-review: dropout")
        self.assertEqual(len(self.calls("codex", "codex-review")), 1)
        self.assertEqual(len(self.calls("claude", "code-review")), 1)
        found = self.found(review, "codex-review-1")
        self.assertTrue(found["from_dropout"])
        self.assertEqual(found["status"], "unjudged")
        self.assertNotIn("codex-review-1", " ".join(c["prompt"] for c in self.calls("claude", "prover")))
        self.assertEqual(self.calls("claude", "refuter"), [])

    # R8
    def test_r8_the_prover_gets_batches_of_at_most_ten_and_its_brief(self):
        self.assertEqual((MOD.PROVER_BATCH, MOD.PROVER_PARALLEL), (10, 4))
        self.config({"runner": {"test_cmd": "python3 check.py"}})
        self.reviewer("codex", *[codex_finding(priority=2, title=f"issue {n}") for n in range(12)])
        review = self.review("standard", "claude")
        self.assertEqual(review["verdict"], "READY-WITH-FIXES", review["incomplete_reasons"])
        prompts = [c["prompt"] for c in self.calls("claude", "prover")]
        self.assertEqual(sorted(p.count('"id": "codex-review-') for p in prompts), [2, 10])
        prompt = next(p for p in prompts if "codex-review-1," in p)
        for text in ("add(a, b) returns the sum of a and b.", "Catastrophic", "python3 check.py",
                     "-    return a + b", '"priority": 2', "issue 0", "calc.py"):
            self.assertIn(text, prompt)
        self.assertTrue((ROOT / "skills/requesting-code-review/references/prover.md").read_text().strip() in prompt)

    def test_r8_an_extra_id_is_ignored_and_counted_and_a_missing_one_is_incomplete(self):
        self.reviewer("claude", code_finding())
        self.prove({}, extra=[dict(proof(), id="code-review-9")])
        review = self.review()
        self.assertEqual(review["counts"]["prover_extra_ids"], 1)
        self.assertEqual([f["id"] for f in review["findings"]], ["code-review-1"])
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")
        self.scenario["claude"]["prover"] = {"omit": ["code-review-1"]}
        review = self.review()
        self.assert_incomplete(review, "code-review-1: the prover returned no result")
        self.assertEqual(self.status(review, "code-review-1"), "unjudged")

    def test_r8_a_prover_dropout_is_incomplete(self):
        self.reviewer("claude", code_finding())
        for behavior, fragment in (({"exit": 1}, "prover-1: dropout"), ({"probe": "skip"}, "prover-1: dropout"),
                                   ({"served_model": "claude-sonnet-5"}, "prover-1: dropout")):
            with self.subTest(behavior=behavior):
                self.scenario["claude"]["prover"] = behavior
                self.assert_incomplete(self.review(), fragment)

    def test_r8_step_1_floors(self):
        cases = [("defect", mild("defect"), "serious", True),
                 ("spec-gap", mild("spec-gap"), "serious", True),
                 ("test-tampering", mild("test-tampering", not_runnable="reading only"), "serious", True),
                 ("style with a reason", mild("style"), "mild", False),
                 ("scope-creep with a reason", mild("scope-creep"), "mild", False),
                 ("style without a reason", mild("style", reason=None), "serious", True),
                 ("unknown kind", mild("nonsense"), "serious", True)]
        self.reviewer("claude", *[code_finding(summary=name) for name, *_ in cases])
        self.prove({f"code-review-{n}": result for n, (_, result, _, _) in enumerate(cases, 1)})
        review = self.review()
        for n, (name, _, rank, raised) in enumerate(cases, 1):
            with self.subTest(name):
                found = self.found(review, f"code-review-{n}")
                self.assertEqual((found["rank"], found["rank_raised"]), (rank, raised))
                if raised:
                    self.assertEqual(found["floors"][0]["from"], "mild")
                    self.assertIn(found["status"], ("verified", "unverified"))
        self.assertEqual(self.found(review, "code-review-7")["kind"], "defect")
        self.assertEqual(review["counts"]["replaced_kinds"], 1)
        self.assertEqual(review["verdict"], "NOT-READY")
        self.assertNotIn("R12", " ".join(review["incomplete_reasons"]))

    def test_r8_test_tampering_keeps_a_mild_rank_when_test_changes_are_allowed(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": mild("test-tampering")})
        self.assertEqual(self.found(self.review(), "code-review-1")["rank"], "serious")
        review = self.review("standard", "codex", "--allow-test-changes")
        self.assertEqual((self.found(review, "code-review-1")["rank"], review["verdict"]),
                         ("mild", "READY-WITH-FIXES"))

    def test_r8_a_test_gap_without_a_failing_receipt_is_mild_and_with_one_blocks(self):
        passing = {"command": "true", "patch": FIX}
        self.reviewer("claude", code_finding(), code_finding(line=1), code_finding(line=1, summary="third"))
        self.prove({"code-review-1": proof(kind="test-gap"),
                    "code-review-2": proof(kind="test-gap", repro=passing),
                    "code-review-3": proof(kind="test-gap", repro=None, not_runnable="needs a GPU")})
        review = self.review()
        first, second, third = (self.found(review, f"code-review-{n}") for n in (1, 2, 3))
        self.assertEqual((first["rank"], first["rank_lowered"], first["status"]), ("serious", False, "verified"))
        for found in (second, third):
            self.assertEqual((found["rank"], found["rank_lowered"], found["status"]), ("mild", True, "mild"))
            self.assertTrue(found["mild_reason"])
            self.assertEqual(found["floors"][-1]["step"], 2)
        self.assertEqual(review["counts"]["lowered_ranks"], 2)
        self.assertEqual(review["verdict"], "NOT-READY", review["incomplete_reasons"])

    def test_r8_a_codex_priority_0_or_1_is_serious_even_as_a_test_gap(self):
        self.reviewer("codex", codex_finding(priority=0), codex_finding(priority=1, line=1),
                      codex_finding(priority=2, line=1))
        self.prove({"codex-review-1": mild("style"),
                    "codex-review-2": proof(kind="test-gap", repro=None, not_runnable="no command shows it"),
                    "codex-review-3": mild("style")})
        review = self.review("standard", "claude")
        ranks = [(f["rank"], f["status"]) for f in review["findings"]]
        self.assertEqual(ranks, [("serious", "unverified"), ("serious", "verified"), ("mild", "mild")])
        second = self.found(review, "codex-review-2")
        self.assertEqual([floor["step"] for floor in second["floors"]], [2, 3])
        self.assertEqual(self.found(review, "codex-review-1")["floors"][-1]["step"], 3)
        self.assertEqual(review["verdict"], "NOT-READY", review["incomplete_reasons"])

    def test_r8_prover_under_ranking_cannot_hide_a_finding(self):
        self.reviewer("codex", codex_finding(priority=0))
        self.prove({"codex-review-1": mild("style", reason="a matter of taste", confidence=0.05)})
        review = self.review("standard", "claude")
        found = self.found(review, "codex-review-1")
        self.assertEqual((found["rank"], found["prover_rank"], found["status"]), ("serious", "mild", "unverified"))
        self.assertEqual(review["verdict"], "NOT-READY")
        self.assertIn("codex-review-1", self.printed["blocking"])

    def test_r8_wait_prints_each_mild_finding_with_its_reason(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": mild("scope-creep", reason="touches an unrelated helper")})
        self.review()
        self.assertEqual(self.printed["mild"], [{"id": "code-review-1", "mild_reason": "touches an unrelated helper"}])
        waited = self.invoke("wait", str(self.run_dir), "--seconds", "5", check_rc=0)
        self.assertEqual(json.loads(waited.stdout)["mild"], self.printed["mild"])

    # R9
    def test_r9_file_line_evidence_must_match_the_reviewed_line(self):
        wrong = dict(FILE_LINE, quote="return a + b")
        missing = dict(FILE_LINE, file="nothere.py")
        self.reviewer("claude", code_finding(), code_finding(line=1), code_finding(line=1, summary="third"))
        self.prove({"code-review-1": proof(repro=None, not_runnable="needs a GPU"),
                    "code-review-2": proof(repro=None, not_runnable="needs a GPU", evidence=wrong),
                    "code-review-3": proof(repro=None, not_runnable="needs a GPU", evidence=missing)})
        review = self.review()
        self.assertEqual([f["status"] for f in review["findings"]], ["verified", "unverified", "unverified"])
        self.assertEqual(review["counts"]["invalid_evidence"], 2)

    def test_r9_test_run_evidence_must_match_a_command_the_prover_ran(self):
        ran = {"type": "test-run", "command": CHECK, "output": "boom", "file": None, "line": None, "quote": None}
        cases = {"valid": (ran, "verified"), "other command": (dict(ran, command="python3 other.py"), "unverified"),
                 "line not in output": (dict(ran, output="boom!"), "unverified"),
                 "empty output": (dict(ran, output="\n  \n"), "unverified")}
        self.reviewer("claude", code_finding())
        for program, path_bin in (("claude", None), ("codex", self.only("codex"))):
            for name, (evidence, expected) in cases.items():
                with self.subTest(program=program, case=name):
                    if program == "codex":
                        self.reviewer("codex", codex_finding())
                    self.scenario[program]["prover"] = {
                        "results": {"code-review-1" if program == "claude" else "codex-review-1":
                                    proof(repro=None, not_runnable="needs a GPU", evidence=evidence)},
                        "commands": [{"command": CHECK, "output": "first\nboom\n", "exit": 1}]}
                    review = self.review("standard", "codex", path_bin=path_bin)
                    self.assertEqual(review["findings"][0]["status"], expected, review["incomplete_reasons"])

    def test_r9_a_background_launch_is_not_test_run_evidence(self):
        ran = {"type": "test-run", "command": CHECK, "output": "Command running in background with ID: b1",
               "file": None, "line": None, "quote": None}
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof(repro=None, not_runnable="x", evidence=ran)},
                   commands=[{"command": CHECK, "background": True}])
        self.assertEqual(self.review()["findings"][0]["status"], "unverified")

    # R10
    def test_r10_the_script_runs_the_fix_experiment_in_codex_sandbox(self):
        self.assertEqual(MOD.REPRO_TIMEOUT, 600)
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        review = self.review()
        found = review["findings"][0]
        self.assertTrue(found["reproduced"])
        self.assertNotEqual(found["receipts"]["1"]["exit_code"], 0)
        self.assertEqual(found["receipts"]["2"]["exit_code"], 0)
        self.assertEqual(found["receipts"]["1"]["fingerprint"], review["tree"])
        self.assertNotEqual(found["receipts"]["2"]["fingerprint"], review["tree"])
        sandboxed = [row["argv"] for row in self.calls("codex", "sandbox")]
        self.assertEqual(len(sandboxed), 4)  # the preflight probe, receipt 1, git apply, receipt 2
        for argv in sandboxed:
            self.assertEqual(argv[:3], ["sandbox", "-P", ":workspace"])
        self.assertEqual(sandboxed[1][6:9], ["sh", "-c", CHECK])
        self.assertEqual(sandboxed[2][6:8], ["git", "apply"])
        self.assertEqual((self.project / "calc.py").read_text(), "def add(a, b):\n    return a - b\n")

    def test_r10_a_patch_that_does_not_apply_or_does_not_fix_leaves_it_unverified(self):
        self.reviewer("claude", code_finding(), code_finding(line=1))
        self.prove({"code-review-1": proof(repro={"command": CHECK, "patch": "not a patch\n"}),
                    "code-review-2": proof(repro={"command": CHECK, "patch": BAD_PATCH})})
        review = self.review()
        first, second = review["findings"]
        self.assertEqual((first["status"], second["status"]), ("unverified", "unverified"))
        self.assertIn("did not apply", first["receipts"]["2"]["reason"])
        self.assertNotEqual(second["receipts"]["2"]["exit_code"], 0)
        self.assertEqual(review["counts"]["patches_not_applied"], 1)
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r10_a_sandbox_that_cannot_start_runs_nothing(self):
        self.scenario["codex"]["sandbox"] = False
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        found = self.review()["findings"][0]
        self.assertEqual(found["status"], "unverified")
        self.assertFalse(found["receipts"]["1"]["ran"])
        self.assertEqual(len(self.calls("codex", "sandbox")), 1)

    def test_r10_a_receipt_kills_the_whole_process_group(self):
        copy = self.root / "copy"
        copy.mkdir()
        original = (MOD.sandboxed, MOD.REPRO_TIMEOUT)
        self.addCleanup(lambda: (setattr(MOD, "sandboxed", original[0]), setattr(MOD, "REPRO_TIMEOUT", original[1])))
        MOD.sandboxed = lambda path, argv: argv
        MOD.REPRO_TIMEOUT = 2
        for name, script in (("timed out", "sleep 60 & echo $! > child.pid; sleep 60"),
                             ("exited", "sleep 60 & echo $! > child.pid")):
            with self.subTest(name):
                record = MOD.receipt(copy, ["sh", "-c", script], script, None)
                self.assertLess(record["duration_s"], 10)
                self.assertEqual(record["timed_out"], name == "timed out")
                child = int((copy / "child.pid").read_text())
                deadline = time.monotonic() + 5
                while MOD.alive(child) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertFalse(MOD.alive(child), f"{name}: a child of the experiment is still running")

    def test_r10_claude_only_runs_the_experiment_through_a_runner(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        review = self.review("standard", "claude", path_bin=self.only("claude"))
        found = review["findings"][0]
        self.assertTrue(found["reproduced"], found["receipts"])
        self.assertEqual(found["status"], "verified")
        self.assertEqual((found["receipts"]["1"]["exit_code"], found["receipts"]["2"]["exit_code"]), (1, 0))
        self.assertEqual(found["receipts"]["1"]["fingerprint"], review["tree"])
        runner = self.calls("claude", "runner")[0]
        self.assertTrue(runner["patch"])
        self.assertIn(f"2. sh -c '{CHECK}'; echo ORCH-EXIT=$?", runner["prompt"])
        self.assertIn("3. sh -c 'git apply --whitespace=nowarn .git/orch-review/patch.diff'; echo ORCH-EXIT=$?",
                      runner["prompt"])
        pairs = {runner["argv"][i]: runner["argv"][i + 1] for i in range(len(runner["argv"]) - 1)}
        self.assertEqual(pairs["--tools"], "Bash")
        self.assertIn("--restricted", runner["argv"])
        self.assertEqual([l["role"] for l in review["launches"]].count("runner"), 1)
        self.assertEqual(self.calls("codex"), [])

    def test_r10_a_runner_receipt_fails_when_the_call_order_or_marker_differs(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        for behavior in ({"alter": 1}, {"swap": True}, {"no_marker": True}):
            with self.subTest(behavior=behavior):
                self.scenario["claude"]["runner"] = behavior
                review = self.review("standard", "claude", path_bin=self.only("claude"))
                found = review["findings"][0]
                self.assertFalse(found["reproduced"])
                self.assertEqual(found["status"], "unverified")
                self.assertNotEqual(review["verdict"], "READY")

    def test_r10_a_runner_dropout_gives_incomplete(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        for behavior in ({"exit": 1}, {"probe": "off"}, {"model_usage": {"claude-sonnet-5": {}}}):
            with self.subTest(behavior=behavior):
                self.scenario["claude"]["runner"] = behavior
                self.assert_incomplete(self.review("standard", "claude", path_bin=self.only("claude")),
                                       "runner-code-review-1: dropout")

    def test_r10_a_passing_receipt_1_never_drops_or_lowers_a_defect(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof(repro={"command": "true", "patch": FIX})})
        review = self.review()
        found = review["findings"][0]
        self.assertEqual(found["receipts"]["1"]["exit_code"], 0)
        self.assertEqual((found["rank"], found["status"]), ("serious", "unverified"))
        self.assertEqual(review["verdict"], "NOT-READY")

    # R11
    def test_r11_a_low_confidence_mild_test_gap_stays_visible_and_is_never_ready(self):
        self.reviewer("claude", code_finding(summary="no test covers negative numbers"))
        self.prove({"code-review-1": mild("test-gap", reason="coverage only", confidence=0.05,
                                          evidence=dict(FILE_LINE, quote="made up"))})
        review = self.review()
        found = review["findings"][0]
        self.assertEqual((found["rank"], found["status"], found["confidence"]), ("mild", "mild", 0.05))
        self.assertFalse(found["evidence_valid"])
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")
        self.assertIn("no test covers negative numbers", found["words"])

    def test_r11_serious_findings_block_whether_verified_or_not(self):
        bad = dict(FILE_LINE, line=9, quote="made up")
        self.reviewer("claude", code_finding(), code_finding(line=1), code_finding(line=1, summary="3"))
        self.prove({"code-review-1": proof(evidence=bad, confidence=0.1),
                    "code-review-2": proof(repro=None, not_runnable="needs a GPU"),
                    "code-review-3": proof(repro=None, not_runnable="needs a GPU", evidence=bad)})
        review = self.review()
        self.assertEqual([f["status"] for f in review["findings"]], ["unverified", "verified", "unverified"])
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r11_no_findings_on_complete_reviews_is_ready(self):
        review = self.review("full", "claude")
        self.assertEqual((review["verdict"], review["incomplete_reasons"]), ("READY", []))

    # R12, R13
    def test_r12_a_prover_ranked_serious_without_repro_is_incomplete(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof("catastrophic", repro=None)})
        review = self.review()
        self.assert_incomplete(review, "code-review-1")
        self.assertEqual(review["findings"][0]["status"], "unverified")

    def test_r12_a_rank_the_script_raised_without_repro_blocks_but_is_not_incomplete(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": mild("test-tampering")})
        review = self.review()
        self.assertEqual((review["findings"][0]["rank"], review["findings"][0]["status"]), ("serious", "unverified"))
        self.assertEqual(review["verdict"], "NOT-READY", review["incomplete_reasons"])
        self.assertEqual(review["counts"]["raised_ranks"], 1)

    def test_r12_an_unknown_rank_or_kind_becomes_serious_defect_and_is_counted(self):
        self.reviewer("claude", code_finding(), code_finding(line=1))
        self.prove({"code-review-1": proof("critical"), "code-review-2": proof(kind="bug")})
        review = self.review()
        self.assertEqual([(f["rank"], f["kind"]) for f in review["findings"]],
                         [("serious", "defect"), ("serious", "defect")])
        self.assertEqual((review["counts"]["replaced_ranks"], review["counts"]["replaced_kinds"]), (1, 1))

    # R14
    def test_r14_the_refuter_judges_serious_findings_on_full(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof()})
        self.refute(verdict("codex-review-1", "PROMOTED"))
        review = self.review("full", "claude")
        self.assertEqual(len(self.calls("claude", "refuter")), 1)
        self.assertEqual(self.status(review, "codex-review-1"), "promoted")
        self.assertEqual(review["verdict"], "NOT-READY")
        prompt = self.calls("claude", "refuter")[0]["prompt"]
        for text in ("codex-review-1", "receipts", "add(2, 2) returns 0", "add subtracts, so"):
            self.assertIn(text, prompt)

    def test_r14_the_refuter_is_skipped_without_a_serious_finding_and_never_on_standard(self):
        self.reviewer("codex", codex_finding(priority=2))
        review = self.review("full", "claude")
        self.assertEqual(self.calls("claude", "refuter"), [])
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")
        self.prove({"codex-review-1": proof()})
        self.review("standard", "claude")
        self.assertEqual(self.calls("claude", "refuter"), [])

    def test_r14_the_refuter_waits_for_complete_reviewers(self):
        self.reviewer("codex", codex_finding(), exit=1)
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        review = self.review("full", "claude")
        self.assertEqual(self.calls("claude", "refuter"), [])
        self.assert_incomplete(review, "codex-review: dropout")

    def test_r14_an_unjudged_finding_or_a_refuter_dropout_gives_incomplete(self):
        self.reviewer("codex", codex_finding(), codex_finding(line=1))
        self.prove({"codex-review-1": proof(), "codex-review-2": proof()})
        self.refute(verdict("codex-review-1", "PROMOTED"))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "codex-review-2"), "unjudged")
        self.assert_incomplete(review, "unjudged")
        self.refute(exit=1)
        self.assert_incomplete(self.review("full", "claude"), "refuter: dropout")

    def test_r14_a_raise_makes_a_mild_finding_block(self):
        self.reviewer("codex", codex_finding(), codex_finding(priority=2, line=1))
        self.prove({"codex-review-1": proof(), "codex-review-2": mild("style")})
        self.refute(verdict("codex-review-1", "PROMOTED"), verdict("codex-review-2", "RAISE", rank="serious"))
        review = self.review("full", "claude")
        found = self.found(review, "codex-review-2")
        self.assertEqual((found["rank"], found["status"]), ("serious", "promoted"))
        self.assertIn("codex-review-2", self.calls("claude", "refuter")[0]["prompt"])

    # R15
    def drop(self, command="python3 -c \"print('sum ok')\"", expected="sum ok"):
        return {"command": command, "expected_output": expected}

    def test_r15_a_reproduced_or_not_runnable_finding_cannot_be_dropped(self):
        self.reviewer("codex", codex_finding(), codex_finding(line=1))
        self.prove({"codex-review-1": proof(), "codex-review-2": proof(repro=None, not_runnable="needs a GPU")})
        self.refute(*[verdict(f"codex-review-{n}", "DROPPED", scenario="add(2, 2) returns 0",
                              drop_check=self.drop()) for n in (1, 2)])
        review = self.review("full", "claude")
        self.assertEqual([f["status"] for f in review["findings"]], ["unresolved", "unresolved"])

    def test_r15_a_valid_drop_check_run_by_the_script_drops_the_finding(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof(repro={"command": CHECK, "patch": "not a patch\n"})})
        self.refute(verdict("codex-review-1", "DROPPED", scenario="add(2, 2) returns 0",
                            drop_check=self.drop()))
        review = self.review("full", "claude")
        found = self.found(review, "codex-review-1")
        self.assertEqual(found["status"], "dropped")
        self.assertEqual(found["drop_receipt"]["exit_code"], 0)
        self.assertEqual(found["drop_receipt"]["fingerprint"], review["tree"])
        self.assertEqual(review["verdict"], "READY")
        self.assertEqual([f["id"] for f in review["findings"]], ["codex-review-1"])  # still listed

    def test_r15_an_invalid_drop_is_unresolved(self):
        cases = {"no scenario": dict(scenario=None, drop_check=self.drop()),
                 "no drop check": dict(scenario="s", drop_check=None),
                 "check fails": dict(scenario="s", drop_check=self.drop(command="exit 1")),
                 "line not in output": dict(scenario="s", drop_check=self.drop(expected="sum not ok")),
                 "partial line": dict(scenario="s", drop_check=self.drop(expected="sum")),
                 "empty expected output": dict(scenario="s", drop_check=self.drop(expected="\n \n"))}
        for name, fields in cases.items():
            with self.subTest(name):
                self.reviewer("codex", codex_finding())
                self.prove({"codex-review-1": proof(repro={"command": CHECK, "patch": "not a patch\n"})})
                self.refute(verdict("codex-review-1", "DROPPED", **fields))
                review = self.review("full", "claude")
                self.assertEqual(self.status(review, "codex-review-1"), "unresolved")
                self.assertEqual(review["verdict"], "NOT-READY")

    def test_r15_a_passing_receipt_1_alone_cannot_drop(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof(repro={"command": "true", "patch": FIX})})
        self.refute(verdict("codex-review-1", "DROPPED", scenario="s", explanation="receipt 1 passed"))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "codex-review-1"), "unresolved")

    def test_r15_the_drop_check_runs_on_a_fresh_unpatched_copy_not_the_refuters(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof(repro={"command": CHECK, "patch": "not a patch\n"})})
        self.refute(verdict("codex-review-1", "DROPPED", scenario="s",
                            drop_check=self.drop(command="cat refuter-was-here.txt", expected="probe")),
                    write_copy=["refuter-was-here.txt"])
        review = self.review("full", "claude")
        found = self.found(review, "codex-review-1")
        self.assertEqual(found["status"], "unresolved")
        self.assertNotEqual(found["drop_receipt"]["exit_code"], 0)
        refuter_cwd = self.calls("claude", "refuter")[0]["cwd"]
        drop_cwd = self.calls("codex", "sandbox")[-1]["argv"][4]
        self.assertNotEqual(refuter_cwd, drop_cwd)

    def test_r15_a_drop_check_runs_through_the_runner_on_claude_only(self):
        self.reviewer("claude", code_finding())
        unproved = proof(repro={"command": CHECK, "patch": "not a patch\n"})
        self.prove({"code-review-1-1": unproved, "code-review-2-1": unproved})
        self.refute(*[verdict(f"code-review-{n}-1", "DROPPED", scenario="s", drop_check=self.drop()) for n in (1, 2)])
        review = self.review("full", "claude", path_bin=self.only("claude"))
        self.assertEqual([f["status"] for f in review["findings"]], ["dropped", "dropped"], review["incomplete_reasons"])
        self.assertEqual([f["drop_receipt"]["via"] for f in review["findings"]], ["claude-runner"] * 2)
        self.assertEqual(review["verdict"], "READY")

    def test_r15_a_drop_receipt_from_another_tree_is_not_valid(self):
        self.test_r15_a_valid_drop_check_run_by_the_script_drops_the_finding()
        copy = self.root / "crafted"
        shutil.copytree(self.run_dir, copy)
        verdicts = json.loads((copy / "refuter.json").read_text())
        verdicts[0]["drop_receipt"]["fingerprint"] = "0" * 40
        (copy / "refuter.json").write_text(json.dumps(verdicts))
        review = MOD.decide(copy)
        self.assertEqual(self.status(review, "codex-review-1"), "unresolved")
        self.assert_incomplete(review, "drop copy fingerprint")

    # R16
    def test_r16_a_lowering_needs_a_valid_drop_check_and_respects_the_floors(self):
        self.reviewer("codex", codex_finding(priority=2), codex_finding(priority=2, line=1),
                      codex_finding(priority=2, line=1, title="third"))
        unproved = {"command": CHECK, "patch": "not a patch\n"}
        self.prove({"codex-review-1": proof(kind="style", repro=unproved),
                    "codex-review-2": proof(repro=unproved),
                    "codex-review-3": proof(kind="style", repro=unproved)})
        self.refute(verdict("codex-review-1", "PROMOTED", rank="mild", drop_check=self.drop()),
                    verdict("codex-review-2", "PROMOTED", rank="mild", drop_check=self.drop()),
                    verdict("codex-review-3", "PROMOTED", rank="mild"))
        review = self.review("full", "claude")
        ranks = {f["id"]: (f["rank"], f["status"]) for f in review["findings"]}
        self.assertEqual(ranks["codex-review-1"], ("mild", "mild"))
        self.assertEqual(ranks["codex-review-2"], ("serious", "promoted"))  # a defect's floor is serious
        self.assertEqual(ranks["codex-review-3"], ("serious", "promoted"))  # no drop check, no lowering
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r16_an_invalid_verdict_leaves_the_finding_unjudged(self):
        self.reviewer("codex", codex_finding())
        self.prove({"codex-review-1": proof(repro={"command": "true", "patch": FIX})})
        self.refute(verdict("codex-review-1", "MAYBE", rank="mild", drop_check=self.drop()))
        review = self.review("full", "claude")
        self.assertEqual((review["findings"][0]["rank"], self.status(review, "codex-review-1")),
                         ("serious", "unjudged"))
        self.assert_incomplete(review, "unjudged")

    # R17
    def test_r17_missing_or_unreadable_run_files_give_incomplete(self):
        self.assertEqual(self.review()["verdict"], "READY")
        for name in ("findings.json", "run.json", "provers.json", "fingerprint-start.json", "fingerprint-end.json",
                     "preflight.json"):
            for broken in ("missing", "unreadable"):
                with self.subTest(name=name, broken=broken):
                    copy = self.root / f"decide-{name}-{broken}"
                    shutil.copytree(self.run_dir, copy)
                    if broken == "missing":
                        (copy / name).unlink()
                    else:
                        (copy / name).write_text("{not json")
                    self.assertEqual(MOD.decide(copy)["verdict"], "INCOMPLETE")

    def test_r17_a_missing_reviewer_launch_is_never_agreement(self):
        self.assertEqual(self.review("full", "claude")["verdict"], "READY")
        shutil.rmtree(self.run_dir / "launches/codex-review")
        self.assert_incomplete(MOD.decide(self.run_dir), "codex-review: the reviewer did not run")

    def test_r17_a_step_that_raises_gives_incomplete(self):
        broken = self.project / "deps.ignored"
        broken.mkdir()
        (broken / "secret").write_text("x")
        (broken / "secret").chmod(0)
        self.addCleanup((broken / "secret").chmod, 0o600)
        self.config({"review": {"copy_ignored": ["deps.ignored"]}})
        review = self.review()
        self.assertTrue((self.run_dir / "errors.json").is_file())
        self.assert_incomplete(review, "CalledProcessError")

    def test_r17_a_write_to_the_real_checkout_gives_incomplete(self):
        self.reviewer("claude", write_real=["stray.txt"])
        self.assert_incomplete(self.review(), "real checkout changed")

    def test_r17_writes_inside_a_reviewer_copy_are_allowed(self):
        self.reviewer("claude", write_copy=["probe.txt"])
        self.assertEqual(self.review()["verdict"], "READY")

    def test_r17_a_repro_copy_that_does_not_match_the_fingerprint_gives_incomplete(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        self.assertEqual(self.review()["verdict"], "NOT-READY")
        copy = self.root / "crafted"
        shutil.copytree(self.run_dir, copy)
        recorded = json.loads((copy / "findings.json").read_text())
        recorded["findings"][0]["receipts"]["1"]["fingerprint"] = "0" * 40
        (copy / "findings.json").write_text(json.dumps(recorded))
        self.assert_incomplete(MOD.decide(copy), "repro copy fingerprint")

    def test_r17_submodules_and_an_empty_change_give_incomplete(self):
        self.git("checkout", "--", "calc.py")
        self.assert_incomplete(self.review(), "empty")
        external = self.root / "external"
        subprocess.run(["git", "clone", "-q", str(self.project), str(external)], check=True, env=self.env())
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(external), "sub")
        self.git("commit", "-qm", "submodule")
        (self.project / "calc.py").write_text("def add(a, b):\n    return a - b\n")
        self.assert_incomplete(self.review(), "submodule")
        (self.project / "sub/check.py").write_text("changed inside the submodule\n")
        self.assert_incomplete(self.review(), "submodule")
        self.assertEqual(self.calls("claude", "code-review"), [])

    def test_r17_non_ascii_file_names_are_reviewed(self):
        (self.project / "café.py").write_text("x = 1\n")
        self.reviewer("claude", code_finding(file="café.py", line=1))
        self.prove({"code-review-1": mild("style", evidence=dict(FILE_LINE, file="café.py", line=1, quote="x = 1"))})
        review = self.review()
        self.assertIn("café.py", [f["file"] for f in json.loads((self.run_dir / "fingerprint-start.json")
                                                                   .read_text())["files"]])
        self.assertEqual((review["findings"][0]["status"], review["findings"][0]["evidence_valid"]), ("mild", True))

    # R19
    def test_r19_review_json_records_launches_findings_and_counts(self):
        self.reviewer("codex", codex_finding(), codex_finding(priority=3, line=1))
        self.prove({"codex-review-1": proof()})
        self.refute(verdict("codex-review-1", "PROMOTED"))
        review = self.review("full", "claude")
        launches = {launch["name"]: launch for launch in review["launches"]}
        self.assertEqual(set(launches), {"code-review", "codex-review", "prover-1", "refuter"})
        self.assertEqual({l["role"] for l in launches.values()}, {"reviewer", "prover", "refuter"})
        self.assertEqual(launches["codex-review"]["provider"], "codex")
        self.assertEqual(launches["codex-review"]["served_sandbox"], ["read-only"])
        self.assertEqual(launches["code-review"]["requested_model"], "opus")
        self.assertEqual(launches["code-review"]["served_model"], ["claude-opus-5-5"])
        self.assertEqual(launches["code-review"]["requested_effort"], "high")
        self.assertIn("ORCH-SANDBOX-ON", launches["code-review"]["sandbox_check"])
        self.assertFalse(launches["code-review"]["same_provider"])
        self.assertEqual(review["counts"]["raw_findings"], 2)
        found = self.found(review, "codex-review-1")
        for key in ("words", "priority", "prover_result", "floors", "status", "receipts", "reviewer"):
            self.assertIn(key, found)
        self.assertEqual(found["priority"], 1)
        self.assertEqual(found["prover_result"]["rank"], "serious")

    # R20
    def test_r20_every_run_appends_one_review_row_without_claim_text(self):
        self.reviewer("claude", code_finding())
        self.prove({"code-review-1": proof()})
        self.review()
        self.scenario["codex"]["login"] = False
        self.review("full", "claude")
        rows = self.outcome_rows()
        self.assertEqual([row["verdict"] for row in rows], ["NOT-READY", "INCOMPLETE"])
        for key in ("run_id", "date", "repository", "path", "writer", "reviewers", "same_provider", "launches",
                    "diff_lines", "incomplete_reasons", "counts", "duration_s", "cost_usd"):
            self.assertIn(key, rows[0])
        self.assertEqual(rows[0]["reviewers"], ["code-review"])
        text = json.dumps(rows)
        self.assertNotIn("subtracts", text)
        self.assertNotIn("return a - b", text)

    # R21
    def test_r21_record_needs_a_disposition_for_every_finding(self):
        self.reviewer("claude", code_finding(), code_finding(line=1))
        self.prove({"code-review-1": proof()})
        self.review()
        dispositions = self.root / "dispositions.json"
        dispositions.write_text(json.dumps({"code-review-1": {"disposition": "fixed", "check": CHECK}}))
        result = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("code-review-2", result.stderr)
        self.assertEqual(len(self.outcome_rows()), 1)

    def test_r21_record_checks_each_disposition(self):
        self.reviewer("claude", code_finding(), code_finding(line=1))
        self.prove({"code-review-1": proof()})
        self.review()
        dispositions = self.root / "dispositions.json"
        valid_quote = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b"}
        bad = [
            {"code-review-1": {"disposition": "ignored", "reason": "later"},
             "code-review-2": {"disposition": "ignored", "reason": "style"}},
            {"code-review-1": {"disposition": "fixed"}, "code-review-2": {"disposition": "ignored", "reason": "x"}},
            {"code-review-1": {"disposition": "refuted", "evidence": dict(valid_quote, quote="nope")},
             "code-review-2": {"disposition": "ignored", "reason": "x"}},
            {"code-review-1": {"disposition": "fixed", "check": CHECK},
             "code-review-2": {"disposition": "ignored", "reason": "x"}, "code-review-9": {"disposition": "fixed"}},
        ]
        for case in bad:
            with self.subTest(case=case):
                dispositions.write_text(json.dumps(case))
                result = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
                self.assertNotEqual(result.returncode, 0, result.stdout)
        dispositions.write_text(json.dumps({
            "code-review-1": {"disposition": "ignored", "reason": "the person chose to ship", "person_approved": True},
            "code-review-2": {"disposition": "refuted", "evidence": valid_quote}}))
        self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions), check_rc=0)
        rows = [row for row in self.outcome_rows() if row["row"] == "finding"]
        self.assertEqual([(row["finding"], row["disposition"]) for row in rows],
                         [("code-review-1", "ignored"), ("code-review-2", "refuted")])
        for key in ("run_id", "reviewer", "provider", "rank", "kind", "status"):
            self.assertIn(key, rows[0])
        self.assertNotEqual(self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions)).returncode, 0)

    def test_r21_refuted_needs_a_file_line_quote_not_a_test_run(self):
        self.reviewer("claude", code_finding())
        self.review()
        dispositions = self.root / "dispositions.json"
        dispositions.write_text(json.dumps({"code-review-1": {"disposition": "refuted", "evidence": {
            "type": "test-run", "command": CHECK, "output": "ok"}}}))
        result = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("file-line", result.stderr)
        spec = (ROOT / "docs/specs/review-design.md").read_text()
        skill = (ROOT / "skills/requesting-code-review/SKILL.md").read_text()
        for text in (spec, skill):
            self.assertIn("`refuted`, with a `file-line` quote", " ".join(text.split()))

    # Nothing unused stays
    def test_the_removed_seat_machinery_is_gone(self):
        references = ROOT / "skills/requesting-code-review/references"
        for name in ("contract.md", "adversarial.md", "seat-schema.json"):
            self.assertFalse((references / name).exists(), name)
        for name in ("prover.md", "prover-schema.json", "refuter.md", "refuter-schema.json", "security-lens.md"):
            self.assertTrue((references / name).is_file(), name)
        text = SCRIPT.read_text()
        for word in ("SEAT_RULES", "seat_prompt", "PART_LINES", "parts.json", "not_checked", "SEAT_TIMEOUT",
                     "--brief", "--adversarial-provider", "--split", "--no-refuter", "experimental",
                     "CONFIDENCE_FLOOR", '"note"'):
            self.assertNotIn(word, text)
        schema = json.loads((references / "refuter-schema.json").read_text())
        item = schema["properties"]["verdicts"]["items"]
        self.assertIn("RAISE", item["properties"]["verdict"]["enum"])
        self.assertIn("scenario", item["required"])
        self.assertIn("drop_check", item["required"])
        self.assertNotIn("receipt-1", json.dumps(schema))


if __name__ == "__main__":
    unittest.main(verbosity=2)
