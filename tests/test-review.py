#!/usr/bin/env python3
"""Rule-by-rule tests for scripts/lib/orch-review.py, run with fake claude and codex programs."""
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


def scratch_parent():
    """A parent for test directories outside every temporary directory a sandbox may write."""
    if sys.platform == "darwin":
        return subprocess.run(["getconf", "DARWIN_USER_CACHE_DIR"], capture_output=True, text=True,
                              check=True).stdout.strip()
    parent = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    parent.mkdir(parents=True, exist_ok=True)
    return str(parent)

# The fakes find the test root from their own path (the review strips unknown
# environment variables): scenario.json, fake.log and project/ sit beside bin/.
# A prompt names its
# brief on a "Brief: <name>" line and its part on a "Part: <n> of <m>" line;
# the fake looks up "<brief>-<part>", then "<brief>", in the scenario.
FAKE_COMMON = r'''
import json, os, re, subprocess, sys, time, uuid
from pathlib import Path
FAKE_ROOT = Path(sys.argv[0]).resolve().parent.parent
scenario = json.loads((FAKE_ROOT / "scenario.json").read_text())
def log(entry):
    with open(FAKE_ROOT / "fake.log", "a") as stream:
        stream.write(json.dumps(entry) + "\n")
def role(prompt):
    brief = re.search(r"^Brief: (\S+)", prompt, re.M).group(1)
    part = re.search(r"^Part: (\d+)", prompt, re.M)
    return brief, (part.group(1) if part else "1")
def behavior(section, prompt):
    brief, part = role(prompt)
    seats = scenario.get(section, {}).get("seats", {})
    return brief, seats.get(f"{brief}-{part}", seats.get(brief, {"output": {"findings": [], "not_checked": []}}))
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
            runs.append((item["command"], "Command running in background with ID: b1", 0))
        elif "output" in item:
            runs.append((item["command"], item["output"], item.get("exit", 0)))
        else:
            done = subprocess.run(item["command"], shell=True, cwd=cwd, capture_output=True, text=True)
            runs.append((item["command"], done.stdout + done.stderr, done.returncode))
    return runs
'''

FAKE_CLAUDE = "#!/usr/bin/env python3\n" + FAKE_COMMON + r'''
if sys.argv[1:3] == ["auth", "status"]:
    ok = scenario.get("claude", {}).get("auth", True)
    print(json.dumps({"loggedIn": ok}))
    sys.exit(0 if ok else 1)
prompt = sys.stdin.read()
brief, spec = behavior("claude", prompt)
log({"program": "claude", "brief": brief, "argv": sys.argv[1:], "cwd": os.getcwd(), "prompt": prompt,
     "env": sorted(os.environ)})
side_effects(spec, os.getcwd())
model = spec.get("served_model", "claude-opus-5-5")
def emit(event):
    print(json.dumps(event), flush=True)
emit({"type": "system", "subtype": "init", "model": model, "mcp_servers": spec.get("mcp_servers", [])})
background = {item["command"] for item in spec.get("commands", []) if item.get("background")}
unsandboxed = {item["command"] for item in spec.get("commands", []) if item.get("unsandboxed")}
for n, (command, output, code) in enumerate(run_commands(spec, os.getcwd())):
    emit({"type": "assistant", "message": {"model": model, "content": [
        {"type": "tool_use", "id": f"tool{n}", "name": "Bash",
         "input": dict({"command": command}, **({"run_in_background": True} if command in background else {}),
                       **({"dangerouslyDisableSandbox": True} if command in unsandboxed else {}))}]}})
    emit({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": f"tool{n}", "content": output, "is_error": code != 0}]}})
emit({"type": "assistant", "message": {"model": model, "content": [{"type": "text", "text": "done"}]}})
if not spec.get("no_result"):
    emit({"type": "result", "subtype": "success", "is_error": False, "result": json.dumps(spec.get("output")),
          "structured_output": spec.get("output"), "total_cost_usd": 0.25,
          "modelUsage": {model: {"inputTokens": 10}}})
sys.exit(spec.get("exit", 0))
'''

FAKE_CODEX = "#!/usr/bin/env python3\n" + FAKE_COMMON + r'''
config = scenario.get("codex", {})
args = sys.argv[1:]
if args[:2] == ["login", "status"]:
    ok = config.get("login", True)
    print("Logged in using ChatGPT" if ok else "Not logged in")
    sys.exit(0 if ok else 1)
if args[:1] == ["sandbox"]:
    log({"program": "codex", "brief": "sandbox", "argv": args, "env": sorted(os.environ)})
    if not config.get("sandbox", True) or args[1:3] != ["-P", ":workspace"] or args[3] != "-C" or args[5] != "--":
        print("sandbox refused to start", file=sys.stderr)
        sys.exit(71)
    done = subprocess.run(args[6:], cwd=args[4], input=sys.stdin.read(), text=True)
    sys.exit(done.returncode)
assert args[0] == "exec", args
prompt = sys.stdin.read()
brief, spec = behavior("codex", prompt)
cwd = args[args.index("-C") + 1]
log({"program": "codex", "brief": brief, "argv": args, "cwd": os.getcwd(), "prompt": prompt,
     "rust_log": os.environ.get("RUST_LOG"), "env": sorted(os.environ)})
if not spec.get("no_mcp_log"):
    # The line codex 0.157.0 writes at RUST_LOG=codex_otel=info when a session starts.
    print('2026-09-25T00:00:00Z  INFO session_init: codex_otel.log_only: event.name="codex.conversation_starts" '
          'mcp_servers="%s" event.timestamp=2026-09-25T00:00:00Z' % ", ".join(spec.get("mcp_servers", [])),
          file=sys.stderr, flush=True)
side_effects(spec, cwd)
thread = str(uuid.uuid4())
def emit(event):
    print(json.dumps(event), flush=True)
emit({"type": "thread.started", "thread_id": thread})
for n, (command, output, code) in enumerate(run_commands(spec, cwd)):
    emit({"type": "item.completed", "item": {"id": f"item_{n}", "type": "command_execution",
          "command": "/bin/zsh -lc " + __import__("shlex").quote(command),
          "aggregated_output": output, "exit_code": code, "status": "completed" if code == 0 else "failed"}})
if not spec.get("no_rollout"):
    sessions = Path(os.environ["CODEX_HOME"], "sessions/2026/09/25")
    sessions.mkdir(parents=True, exist_ok=True)
    served = spec.get("served_model", config.get("served_model", "gpt-test"))
    (sessions / f"rollout-2026-09-25T00-00-00-{thread}.jsonl").write_text(json.dumps(
        {"type": "turn_context", "payload": {"model": served, "effort": "high"}}) + "\n")
if not spec.get("no_result"):
    Path(args[args.index("-o") + 1]).write_text(json.dumps(spec.get("output")))
emit({"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 10}})
sys.exit(spec.get("exit", 0))
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


def finding(rank="serious", **extra):
    base = {"file": "calc.py", "line": 2, "rank": rank, "kind": "defect", "confidence": 0.9,
            "claim": "add subtracts, so add(2, 2) returns 0",
            "evidence": {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b",
                         "command": None, "output": None},
            "repro": {"command": CHECK, "patch": FIX}, "not_runnable": None}
    base.update(extra)
    return base


def seat(*findings, not_checked=(), **extra):
    return {"output": {"findings": list(findings), "not_checked": list(not_checked)}, **extra}


def verdict(finding_id, word, rank=None, evidence=None):
    return {"id": finding_id, "verdict": word, "rank": rank,
            "evidence": evidence or {"type": "none", "file": None, "line": None, "quote": None,
                                     "explanation": None}}


def refuter(*verdicts, **extra):
    return {"output": {"verdicts": list(verdicts)}, **extra}


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
        self.scenario = {"claude": {"seats": {}}, "codex": {"seats": {}}}
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

    def invoke(self, *args, path_bin=None, check_rc=None):
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        result = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.project,
                                capture_output=True, text=True, env=self.env(path_bin), timeout=300)
        if check_rc is not None:
            self.assertEqual(result.returncode, check_rc, result.stdout + result.stderr)
        return result

    def review(self, path="full", writer="claude", *extra, path_bin=None):
        self.runs += 1
        self.run_dir = self.root / f"run-{self.runs}"
        result = self.invoke("run", "--path", path, "--writer", writer, "--base", self.base,
                             "--spec", str(self.spec), "--run-dir", str(self.run_dir), *extra,
                             path_bin=path_bin)
        review = self.run_dir / "review.json"
        self.assertTrue(review.is_file(), result.stdout + result.stderr)
        return json.loads(review.read_text())

    def launches(self, program=None, brief=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if (program is None or row["program"] == program)
                and (brief is None or row["brief"] == brief)]

    def outcome_rows(self):
        path = self.home / "state/llm-orchestrator/review-outcomes.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def status(self, review, finding_id):
        return next(f for f in review["findings"] if f["id"] == finding_id)["status"]

    def assert_incomplete(self, review, fragment):
        self.assertEqual(review["verdict"], "INCOMPLETE", review["incomplete_reasons"])
        self.assertTrue(any(fragment in reason for reason in review["incomplete_reasons"]),
                        review["incomplete_reasons"])

    # R1
    def test_r1_run_refuses_an_existing_run_directory(self):
        existing = self.root / "existing"
        existing.mkdir()
        result = self.invoke("run", "--path", "standard", "--writer", "claude", "--base", self.base,
                             "--spec", str(self.spec), "--run-dir", str(existing))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stdout + result.stderr)
        self.assertEqual(self.launches(), [])

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
        self.scenario["claude"]["seats"]["contract"] = seat(sleep=8)
        run_dir = self.root / "slow"
        self.invoke("run", "--detach", "--path", "standard", "--writer", "claude", "--base", self.base,
                    "--spec", str(self.spec), "--run-dir", str(run_dir), check_rc=0)
        waited = self.invoke("wait", str(run_dir), "--seconds", "1")
        self.assertEqual(json.loads(waited.stdout)["status"], "running")
        self.invoke("wait", str(run_dir), "--seconds", "120", check_rc=0)

    # R2, R3
    def test_r3_standard_runs_one_contract_seat_on_the_writer_provider_and_no_refuter(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        review = self.review("standard", "claude")
        self.assertEqual([row["brief"] for row in self.launches("claude")], ["contract"])
        self.assertEqual(self.launches("codex", "contract") + self.launches("codex", "adversarial"), [])
        self.assertEqual(review["verdict"], "NOT-READY")
        self.assertEqual(self.status(review, "contract-1-1"), "verified")
        self.assertEqual([launch["provider"] for launch in review["launches"]], ["claude"])

    def test_r3_standard_on_codex_uses_the_codex_seat(self):
        review = self.review("standard", "codex")
        self.assertEqual([row["brief"] for row in self.launches("codex") if row["brief"] != "sandbox"],
                         ["contract"])
        self.assertEqual(self.launches("claude"), [])
        self.assertEqual(review["verdict"], "READY")

    def test_r3_brief_option_picks_the_standard_seat_brief(self):
        review = self.review("standard", "claude", "--brief", "adversarial")
        self.assertEqual([row["brief"] for row in self.launches("claude")], ["adversarial"])
        self.assertIn("Test tampering", self.launches("claude")[0]["prompt"])
        self.assertEqual(review["launches"][0]["brief"], "adversarial")

    # R4
    def test_r4_full_on_claude_puts_the_adversarial_seat_on_codex(self):
        review = self.review("full", "claude")
        briefs = {(row["program"], row["brief"]) for row in self.launches() if row["brief"] != "sandbox"}
        self.assertEqual(briefs, {("claude", "contract"), ("codex", "adversarial")})
        self.assertEqual(review["verdict"], "READY")

    def test_r4_full_on_codex_puts_the_adversarial_seat_on_claude(self):
        self.review("full", "codex")
        briefs = {(row["program"], row["brief"]) for row in self.launches() if row["brief"] != "sandbox"}
        self.assertEqual(briefs, {("codex", "contract"), ("claude", "adversarial")})

    def test_r4_adversarial_provider_option_swaps_the_seats(self):
        self.review("full", "claude", "--adversarial-provider", "claude")
        briefs = {(row["program"], row["brief"]) for row in self.launches() if row["brief"] != "sandbox"}
        self.assertEqual(briefs, {("codex", "contract"), ("claude", "adversarial")})

    def test_r4_seats_run_in_separate_fresh_clones_outside_the_checkout(self):
        self.review("full", "claude")
        cwds = [row["cwd"] for row in self.launches() if row["brief"] != "sandbox"]
        self.assertEqual(len(set(cwds)), 2)
        for cwd in cwds:
            self.assertNotIn(str(self.project), cwd)

    def test_seats_and_experiments_get_a_reduced_environment(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding())
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "PROMOTED"))
        self.review("full", "claude")
        rows = self.launches()
        self.assertTrue(rows)
        for row in rows:
            with self.subTest(program=row["program"], brief=row["brief"]):
                self.assertNotIn("AWS_SECRET_ACCESS_KEY", row["env"])
                self.assertNotIn("GITHUB_TOKEN", row["env"])
                keep = {"claude": "ANTHROPIC_API_KEY", "codex": "OPENAI_API_KEY"}[row["program"]]
                drop = {"claude": "OPENAI_API_KEY", "codex": "ANTHROPIC_API_KEY"}[row["program"]]
                self.assertNotIn(drop, row["env"])
                if row["brief"] == "sandbox":
                    self.assertNotIn(keep, row["env"])
                else:
                    self.assertIn(keep, row["env"])

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

    # R5
    def test_r5_claude_launch_uses_the_fixed_flags_and_no_mcp(self):
        self.review("standard", "claude")
        argv = self.launches("claude")[0]["argv"]
        for flag in ("-p", "--safe-mode", "--restricted", "--strict-mcp-config", "--no-session-persistence",
                     "--verbose"):
            self.assertIn(flag, argv)
        pairs = {argv[i]: argv[i + 1] for i in range(len(argv) - 1)}
        self.assertEqual(pairs["--model"], "opus")
        self.assertEqual(pairs["--effort"], "high")
        self.assertEqual(pairs["--output-format"], "stream-json")
        self.assertEqual(pairs["--tools"], "Read,Grep,Glob,Bash")
        self.assertEqual(pairs["--allowedTools"], "Read,Grep,Glob,Bash")
        self.assertEqual(pairs["--permission-mode"], "dontAsk")
        self.assertEqual(pairs["--permission-prompts"], "none")
        self.assertEqual(json.loads(pairs["--mcp-config"]), {"mcpServers": {}})
        self.assertIn("findings", json.loads(pairs["--json-schema"])["properties"])
        sandbox = json.loads(pairs["--settings"])["sandbox"]
        cwd = self.launches("claude")[0]["cwd"]
        self.assertEqual((sandbox["enabled"], sandbox["failIfUnavailable"], sandbox["allowUnsandboxedCommands"]),
                         (True, True, False))
        self.assertEqual(sandbox["excludedCommands"], [])
        self.assertEqual(sandbox["filesystem"]["allowWrite"], [cwd])
        self.assertIn(str(self.run_dir), sandbox["filesystem"]["denyRead"])
        self.assertEqual(sandbox["network"]["allowedDomains"], [])

    def test_r5_a_claude_bash_call_outside_the_sandbox_is_a_dropout(self):
        self.scenario["claude"]["seats"]["contract"] = seat(commands=[{"command": "ls", "output": "x",
                                                                       "unsandboxed": True}])
        self.assert_incomplete(self.review("standard", "claude"), "sandbox")

    def test_r5_a_claude_launch_that_loads_mcp_servers_is_a_dropout(self):
        self.scenario["claude"]["seats"]["contract"] = seat(mcp_servers=[{"name": "slack"}])
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "MCP")

    def test_r5_claude_served_model_outside_the_alias_family_is_a_dropout(self):
        self.scenario["claude"]["seats"]["contract"] = seat(served_model="claude-sonnet-5")
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "served model")
        self.assertEqual(review["launches"][0]["served_model"], ["claude-sonnet-5"])

    # R6
    def test_r6_codex_launch_uses_the_cli_default_model_and_records_the_rollout(self):
        review = self.review("standard", "codex")
        argv = next(row["argv"] for row in self.launches("codex", "contract"))
        self.assertNotIn("-m", argv)
        self.assertNotIn("--model", argv)
        self.assertNotIn("--ephemeral", argv)
        self.assertEqual(argv[:4], ["exec", "--json", "-s", "workspace-write"])
        self.assertIn('model_reasoning_effort="high"', argv)
        self.assertIn("--output-schema", argv)
        self.assertEqual(argv[-1], "-")
        launch = review["launches"][0]
        self.assertEqual((launch["requested_model"], launch["served_model"]), ("gpt-test", ["gpt-test"]))
        self.assertEqual(launch["served_effort"], ["high"])

    def test_r6_codex_launch_turns_off_the_person_mcp_servers_apps_and_plugins(self):
        (self.codex_home / "config.toml").write_text(
            'model = "gpt-test"\n[mcp_servers.figma]\nurl = "https://x.invalid"\n'
            '[mcp_servers.computer-use]\ncommand = "x"\n')
        review = self.review("standard", "codex")
        self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
        row = next(row for row in self.launches("codex", "contract"))
        argv = row["argv"]
        pairs = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "-c"]
        self.assertIn("mcp_servers.figma.enabled=false", pairs)
        self.assertIn("mcp_servers.computer-use.enabled=false", pairs)
        disabled = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--disable"]
        self.assertEqual(sorted(disabled), ["apps", "plugins"])
        self.assertIn("codex_otel=info", row["rust_log"])

    def test_r6_a_codex_launch_that_loads_mcp_servers_is_a_dropout(self):
        self.scenario["codex"]["seats"]["contract"] = seat(mcp_servers=["figma", "codex_apps"])
        self.assert_incomplete(self.review("standard", "codex"), "MCP")

    def test_r6_a_codex_launch_that_shows_no_mcp_server_list_is_a_dropout(self):
        self.scenario["codex"]["seats"]["contract"] = seat(no_mcp_log=True)
        self.assert_incomplete(self.review("standard", "codex"), "MCP")

    def test_r6_codex_served_model_mismatch_is_a_dropout(self):
        self.scenario["codex"]["seats"]["contract"] = seat(served_model="gpt-other")
        self.assert_incomplete(self.review("standard", "codex"), "served model")

    def test_r6_codex_config_without_a_model_records_but_does_not_compare(self):
        (self.codex_home / "config.toml").write_text("")
        self.scenario["codex"]["seats"]["contract"] = seat(served_model="gpt-anything")
        review = self.review("standard", "codex")
        self.assertEqual(review["verdict"], "READY")
        self.assertIsNone(review["launches"][0]["requested_model"])
        self.assertEqual(review["launches"][0]["served_model"], ["gpt-anything"])

    # R7
    def test_r7_dropouts_give_incomplete_and_are_never_replaced(self):
        cases = {"exits nonzero": seat(exit=1), "no final result": seat(no_result=True),
                 "no served model": seat(no_rollout=True)}
        for reason, behavior in cases.items():
            with self.subTest(reason):
                self.log.unlink(missing_ok=True)
                self.scenario["codex"]["seats"]["adversarial"] = behavior
                review = self.review("full", "claude")
                self.assert_incomplete(review, reason)
                self.assertEqual(len(self.launches("codex", "adversarial")), 1)
                self.assertEqual(len(self.launches("claude", "adversarial")), 0)
                self.assertEqual(len(self.launches("claude", "contract")), 1)
                self.assertNotEqual(review["verdict"], "READY")

    def test_r7_a_missing_seat_is_never_ready(self):
        self.scenario["claude"]["seats"]["contract"] = seat(no_result=True)
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "contract-1")

    # Step 1: preflight
    def test_preflight_full_needs_both_clis_signed_in(self):
        self.scenario["codex"]["login"] = False
        review = self.review("full", "claude")
        self.assert_incomplete(review, "codex")
        self.assertEqual(self.launches("claude"), [])
        self.scenario["codex"]["login"] = True
        self.scenario["claude"]["auth"] = False
        self.assert_incomplete(self.review("full", "codex"), "claude")

    def test_preflight_standard_on_claude_runs_without_codex_and_leaves_fixes_unverified(self):
        only_claude = self.root / "only-claude"
        only_claude.mkdir()
        (only_claude / "claude").symlink_to(self.bin / "claude")
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        review = self.review("standard", "claude", path_bin=only_claude)
        self.assertEqual(review["verdict"], "NOT-READY")
        found = review["findings"][0]
        self.assertEqual(found["status"], "unverified")
        self.assertFalse(found["reproduced"])
        self.assertIn("sandbox", found["receipts"]["1"]["reason"])

    def test_preflight_standard_on_codex_needs_codex(self):
        only_claude = self.root / "no-codex"
        only_claude.mkdir()
        (only_claude / "claude").symlink_to(self.bin / "claude")
        self.assert_incomplete(self.review("standard", "codex", path_bin=only_claude), "codex")

    def test_preflight_uses_the_template_harm_ranking_without_project_laws(self):
        self.review("standard", "claude")
        prompt = self.launches("claude")[0]["prompt"]
        self.assertIn("Reviewers grade every finding", prompt)
        laws = self.project / "docs/llm-orchestrator/LAWS.md"
        laws.parent.mkdir(parents=True)
        laws.write_text("# Laws\n\n**Harm ranking.** Project ranking.\n\n- Catastrophic: lost money.\n\n## 2. Next\n")
        self.git("add", "docs")
        self.git("commit", "-qm", "laws")
        self.log.unlink()
        self.review("standard", "claude")
        prompt = self.launches("claude")[0]["prompt"]
        ranking = prompt.split("## Harm ranking", 1)[1].split("## Test command", 1)[0]
        self.assertIn("Catastrophic: lost money.", ranking)
        self.assertNotIn("Reviewers grade every finding", ranking)
        self.assertNotIn("## 2. Next", ranking)

    def test_preflight_dirty_submodule_gives_incomplete(self):
        external = self.root / "external"
        subprocess.run(["git", "clone", "-q", str(self.project), str(external)], check=True, env=self.env())
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(external), "sub")
        self.git("commit", "-qm", "submodule")
        (self.project / "sub/check.py").write_text("changed inside the submodule\n")
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "submodule")
        self.assertEqual(self.launches("claude"), [])

    def test_a_clean_submodule_gives_incomplete_before_any_seat(self):
        external = self.root / "external"
        subprocess.run(["git", "clone", "-q", str(self.project), str(external)], check=True, env=self.env())
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(external), "sub")
        self.git("commit", "-qm", "submodule")
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "submodule")
        self.assertEqual(self.launches("claude"), [])

    def test_preflight_empty_change_is_incomplete(self):
        self.git("checkout", "--", "calc.py")
        self.assert_incomplete(self.review("standard", "claude"), "empty")

    # Step 2 and step 8: fingerprints
    def test_a_write_to_the_real_checkout_gives_incomplete(self):
        self.scenario["claude"]["seats"]["contract"] = seat(write_real=["stray.txt"])
        self.assert_incomplete(self.review("standard", "claude"), "real checkout changed")

    def test_writes_inside_a_seat_copy_are_allowed(self):
        self.scenario["claude"]["seats"]["contract"] = seat(write_copy=["probe.txt"])
        self.assertEqual(self.review("standard", "claude")["verdict"], "READY")

    def test_submodule_made_dirty_during_the_review_gives_incomplete(self):
        external = self.root / "external"
        subprocess.run(["git", "clone", "-q", str(self.project), str(external)], check=True, env=self.env())
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(external), "sub")
        self.git("commit", "-qm", "submodule")
        self.scenario["claude"]["seats"]["contract"] = seat(write_real=["sub/check.py"])
        self.assert_incomplete(self.review("standard", "claude"), "submodule")

    # Step 3: copies
    def test_copies_get_copy_ignored_paths_and_setup_and_are_removed_after(self):
        (self.project / "deps.ignored").write_text("dependency\n")
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"runner": {"test_cmd": "python3 check.py"},
                                      "review": {"copy_ignored": ["deps.ignored"],
                                                 "setup": "cp deps.ignored setup.ignored"}}))
        self.git("add", "docs")
        self.git("commit", "-qm", "config")
        self.scenario["claude"]["seats"]["contract"] = seat(commands=[
            {"command": "cat deps.ignored setup.ignored"}])
        review = self.review("standard", "claude")
        self.assertEqual(review["verdict"], "READY", review["incomplete_reasons"])
        stream = (self.run_dir / "launches/contract-1/stream.jsonl").read_text()
        self.assertEqual(stream.count("dependency"), 2)
        self.assertIn("python3 check.py", self.launches("claude")[0]["prompt"])
        self.assertFalse(Path(self.launches("claude")[0]["cwd"]).exists())

    def test_no_test_command_tells_the_seat_to_find_the_tests(self):
        self.review("standard", "claude")
        self.assertIn("no test command is configured; find and run the project's tests",
                      self.launches("claude")[0]["prompt"])

    def test_a_failing_setup_gives_incomplete(self):
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"review": {"setup": "exit 3"}}))
        self.git("add", "docs")
        self.git("commit", "-qm", "config")
        self.assert_incomplete(self.review("standard", "claude"), "setup")

    # Step 4: parts
    def test_split_groups_whole_files_into_parts_of_at_most_150_lines(self):
        for name, lines in (("a.py", 100), ("b.py", 40), ("c.py", 200), ("d.py", 20)):
            (self.project / name).write_text("".join(f"x{n} = {n}\n" for n in range(lines)))
        self.git("checkout", "--", "calc.py")
        self.scenario["claude"]["seats"]["contract-2"] = seat(finding(
            rank="mild", file="c.py", line=1, repro=None,
            evidence={"type": "file-line", "file": "c.py", "line": 1, "quote": "x0 = 0",
                      "command": None, "output": None}))
        review = self.review("standard", "claude", "--split")
        parts = json.loads((self.run_dir / "parts.json").read_text())
        self.assertEqual([part["files"] for part in parts], [["a.py", "b.py"], ["c.py"], ["d.py"]])
        prompts = [row["prompt"] for row in self.launches("claude")]
        self.assertEqual(len(prompts), 3)
        self.assertTrue(all("c.py (200 lines)" in prompt for prompt in prompts))
        self.assertEqual(review["findings"][0]["id"], "contract-2-1")
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")

    def test_without_split_the_whole_change_is_one_part(self):
        self.review("standard", "claude")
        self.assertEqual(len(json.loads((self.run_dir / "parts.json").read_text())), 1)

    # Security lens
    def test_security_lens_is_added_when_the_diff_matches(self):
        self.review("standard", "claude")
        self.assertNotIn("Security lens", self.launches("claude")[0]["prompt"])
        (self.project / "auth.py").write_text("password = input()\n")
        self.log.unlink()
        self.review("full", "claude")
        for row in self.launches():
            if row["brief"] in {"contract", "adversarial"}:
                self.assertIn("Security lens", row["prompt"])

    # R8, R9: evidence
    def test_r9_file_line_quote_must_match_the_reviewed_line(self):
        wrong = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a + b",
                 "command": None, "output": None}
        missing = dict(wrong, file="nothere.py")
        self.scenario["claude"]["seats"]["contract"] = seat(
            finding("mild", repro=None), finding("mild", repro=None, evidence=wrong),
            finding("mild", repro=None, evidence=missing))
        review = self.review("standard", "claude")
        self.assertEqual([f["status"] for f in review["findings"]], ["mild", "note", "note"])
        self.assertEqual(review["counts"]["invalid_evidence"], 2)

    def test_r9_test_run_evidence_must_match_a_command_the_seat_ran(self):
        ran = {"type": "test-run", "command": CHECK, "output": "boom", "file": None, "line": None,
               "quote": None}
        commands = [{"command": CHECK, "output": "first\nboom\n", "exit": 1}]
        cases = {"valid": (ran, "mild"),
                 "other command": (dict(ran, command="python3 other.py"), "note"),
                 "line not in output": (dict(ran, output="boom!"), "note"),
                 "partial line": (dict(ran, output="boo"), "note"),
                 "empty output": (dict(ran, output="\n  \n"), "note")}
        for program, writer in (("claude", "claude"), ("codex", "codex")):
            for name, (evidence, expected) in cases.items():
                with self.subTest(program=program, case=name):
                    self.scenario[program]["seats"]["contract"] = seat(
                        finding("mild", repro=None, evidence=evidence), commands=commands)
                    review = self.review("standard", writer)
                    self.assertEqual(review["findings"][0]["status"], expected)

    def test_r9_a_background_launch_is_not_test_run_evidence(self):
        ran = {"type": "test-run", "command": CHECK, "output": "Command running in background with ID: b1",
               "file": None, "line": None, "quote": None}
        self.scenario["claude"]["seats"]["contract"] = seat(
            finding("mild", repro=None, evidence=ran), commands=[{"command": CHECK, "background": True}])
        review = self.review("standard", "claude")
        self.assertEqual(review["findings"][0]["status"], "note")

    def test_r8_findings_get_seat_part_number_ids(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding("mild", repro=None),
                                                           finding("mild", repro=None))
        review = self.review("standard", "claude")
        self.assertEqual([f["id"] for f in review["findings"]], ["contract-1-1", "contract-1-2"])

    # R10: fix experiments
    def test_r10_script_runs_the_fix_experiment_in_the_sandbox(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        review = self.review("standard", "claude")
        found = review["findings"][0]
        self.assertTrue(found["reproduced"])
        self.assertNotEqual(found["receipts"]["1"]["exit_code"], 0)
        self.assertEqual(found["receipts"]["2"]["exit_code"], 0)
        self.assertEqual(found["receipts"]["1"]["fingerprint"], review["tree"])
        self.assertNotEqual(found["receipts"]["2"]["fingerprint"], review["tree"])
        for key in ("command", "output", "duration_s"):
            self.assertIn(key, found["receipts"]["1"])
        sandboxed = [row["argv"] for row in self.launches("codex", "sandbox")]
        self.assertEqual(len(sandboxed), 4)
        for argv in sandboxed:
            self.assertEqual(argv[:3], ["sandbox", "-P", ":workspace"])
            self.assertEqual((argv[3], argv[5]), ("-C", "--"))
        self.assertEqual(sandboxed[1][6:9], ["sh", "-c", CHECK])
        self.assertEqual(sandboxed[2][6:8], ["git", "apply"])
        self.assertEqual((self.project / "calc.py").read_text(), "def add(a, b):\n    return a - b\n")

    def test_r10_a_patch_that_does_not_apply_leaves_the_finding_unverified(self):
        broken = finding(repro={"command": CHECK, "patch": "not a patch\n"})
        self.scenario["claude"]["seats"]["contract"] = seat(broken)
        review = self.review("standard", "claude")
        found = review["findings"][0]
        self.assertEqual(found["status"], "unverified")
        self.assertIn("did not apply", found["receipts"]["2"]["reason"])
        self.assertEqual(review["counts"]["patches_not_applied"], 1)
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r10_a_patch_that_does_not_fix_it_leaves_the_finding_unverified(self):
        self.scenario["claude"]["seats"]["contract"] = seat(
            finding(repro={"command": CHECK, "patch": BAD_PATCH}))
        review = self.review("standard", "claude")
        self.assertEqual(review["findings"][0]["status"], "unverified")
        self.assertNotEqual(review["findings"][0]["receipts"]["2"]["exit_code"], 0)

    def test_r10_a_sandbox_that_cannot_start_runs_nothing(self):
        self.scenario["codex"]["sandbox"] = False
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        review = self.review("standard", "claude")
        found = review["findings"][0]
        self.assertEqual(found["status"], "unverified")
        self.assertFalse(found["receipts"]["1"]["ran"])
        self.assertEqual(len(self.launches("codex", "sandbox")), 1)

    # R11
    def test_r11_mild_below_the_floor_or_without_confidence_is_a_note(self):
        self.scenario["claude"]["seats"]["contract"] = seat(
            finding("mild", repro=None, confidence=0.5), finding("mild", repro=None, confidence=None),
            finding("mild", repro=None, confidence=0.8))
        review = self.review("standard", "claude")
        self.assertEqual([f["status"] for f in review["findings"]], ["note", "note", "mild"])
        self.assertEqual(review["counts"]["below_floor"], 2)
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")

    def test_r11_serious_with_invalid_evidence_stays_blocking(self):
        bad = {"type": "file-line", "file": "calc.py", "line": 9, "quote": "made up", "command": None,
               "output": None}
        self.scenario["claude"]["seats"]["contract"] = seat(
            finding(evidence=bad, confidence=0.1), finding(evidence=bad, repro=None, not_runnable="needs a GPU"))
        review = self.review("standard", "claude")
        self.assertEqual([f["status"] for f in review["findings"]], ["unverified", "unverified"])
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r11_serious_not_runnable_with_valid_evidence_is_verified(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding(repro=None, not_runnable="needs a GPU"))
        self.assertEqual(self.review("standard", "claude")["findings"][0]["status"], "verified")

    # R12
    def test_r12_serious_without_repro_or_not_runnable_is_incomplete(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding("catastrophic", repro=None))
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "contract-1-1")
        self.assertEqual(review["findings"][0]["status"], "unverified")

    # R13
    def test_r13_not_checked_items_are_returned_verbatim_and_give_incomplete(self):
        item = {"category": "tests-not-run", "text": "the integration suite needs a database"}
        self.scenario["claude"]["seats"]["contract"] = seat(not_checked=[item])
        review = self.review("standard", "claude")
        self.assert_incomplete(review, "not checked")
        self.assertEqual(review["not_checked"], [dict(item, launch="contract-1")])

    def test_r13_test_tampering_is_raised_unless_test_changes_are_allowed(self):
        tampering = finding("mild", kind="test-tampering", repro=None, not_runnable="reading only")
        self.scenario["claude"]["seats"]["contract"] = seat(tampering)
        review = self.review("standard", "claude")
        self.assertEqual((review["findings"][0]["rank"], review["findings"][0]["status"]),
                         ("serious", "verified"))
        self.assertEqual(review["counts"]["raised_ranks"], 1)
        review = self.review("standard", "claude", "--allow-test-changes")
        self.assertEqual(review["findings"][0]["rank"], "mild")

    def test_r13_an_unknown_rank_becomes_serious_and_is_counted(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding("critical"), {"junk": True})
        review = self.review("standard", "claude")
        self.assertEqual([f["rank"] for f in review["findings"]], ["serious", "serious"])
        self.assertEqual(review["counts"]["replaced_ranks"], 2)
        self.assertEqual(review["findings"][1]["raw"], {"junk": True})
        self.assert_incomplete(review, "contract-1-2")

    # R14
    def test_r14_refuter_runs_on_full_when_a_serious_finding_exists(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding())
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "PROMOTED"))
        review = self.review("full", "claude")
        self.assertEqual(len(self.launches("claude", "refuter")), 1)
        self.assertEqual(self.status(review, "adversarial-1-1"), "promoted")
        self.assertEqual(review["verdict"], "NOT-READY")
        prompt = self.launches("claude", "refuter")[0]["prompt"]
        self.assertIn("adversarial-1-1", prompt)
        self.assertIn("receipt", prompt)

    def test_r14_refuter_is_skipped_without_a_serious_finding(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding("mild", repro=None))
        review = self.review("full", "claude")
        self.assertEqual(self.launches("claude", "refuter"), [])
        self.assertEqual(review["verdict"], "READY-WITH-FIXES")

    def test_r14_refuter_never_runs_on_standard(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        self.review("standard", "claude")
        self.assertEqual(self.launches("claude", "refuter"), [])

    def test_r14_an_unjudged_finding_or_a_refuter_dropout_gives_incomplete(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding(), finding(line=2))
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "PROMOTED"))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-2"), "unjudged")
        self.assert_incomplete(review, "unjudged")
        self.scenario["claude"]["seats"]["refuter"] = refuter(exit=1)
        self.assert_incomplete(self.review("full", "claude"), "refuter")

    def test_r14_refuter_waits_for_complete_seats(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding(), exit=1)
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        review = self.review("full", "claude")
        self.assertEqual(self.launches("claude", "refuter"), [])
        self.assert_incomplete(review, "adversarial-1")

    def test_r14_no_refuter_marks_the_review_experimental(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding())
        review = self.review("full", "claude", "--no-refuter")
        self.assertEqual(self.launches("claude", "refuter"), [])
        self.assertTrue(review["experimental"])
        self.assertEqual(self.status(review, "adversarial-1-1"), "verified")

    # R15
    def test_r15_an_invented_drop_leaves_the_finding_blocking(self):
        unreproduced = finding(repro={"command": CHECK, "patch": "not a patch\n"})
        self.scenario["codex"]["seats"]["adversarial"] = seat(unreproduced)
        invented = {"type": "file-line", "file": "calc.py", "line": 1, "quote": "def sub(a, b):",
                    "explanation": "the function is named sub"}
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "DROPPED",
                                                                      evidence=invented))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-1"), "unresolved")
        self.assertEqual(review["counts"]["invalid_drops"], 1)
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r15_a_reproduced_or_not_runnable_finding_cannot_be_dropped(self):
        quote = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b",
                 "explanation": "this is intended"}
        self.scenario["codex"]["seats"]["adversarial"] = seat(
            finding(), finding(repro=None, not_runnable="needs a GPU"))
        self.scenario["claude"]["seats"]["refuter"] = refuter(
            verdict("adversarial-1-1", "DROPPED", evidence=quote),
            verdict("adversarial-1-2", "DROPPED", evidence=quote))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-1"), "unresolved")
        self.assertEqual(self.status(review, "adversarial-1-2"), "unresolved")

    def test_r15_a_drop_needs_a_passing_receipt_1(self):
        passing = finding(repro={"command": "true", "patch": FIX})
        failing = finding(repro={"command": CHECK, "patch": "not a patch\n"})
        cite = {"type": "receipt-1", "file": None, "line": None, "quote": None,
                "explanation": "the command passed without the fix"}
        self.scenario["codex"]["seats"]["adversarial"] = seat(passing, failing)
        self.scenario["claude"]["seats"]["refuter"] = refuter(
            verdict("adversarial-1-1", "DROPPED", evidence=cite),
            verdict("adversarial-1-2", "DROPPED", evidence=cite))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-1"), "dropped")
        self.assertEqual(self.status(review, "adversarial-1-2"), "unresolved")
        self.assertEqual(review["verdict"], "NOT-READY")

    def test_r15_a_quote_cannot_drop_a_finding_whose_experiment_ran(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(
            finding(repro={"command": CHECK, "patch": "not a patch\n"}))
        quote = {"type": "file-line", "file": "check.py", "line": 3,
                 "quote": "sys.exit(0 if calc.add(2, 2) == 4 else 1)", "explanation": "the check expects 4"}
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "DROPPED",
                                                                      evidence=quote))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-1"), "unresolved")
        self.assertEqual(review["verdict"], "NOT-READY")
        self.assertEqual(review["findings"][0]["refuter"]["evidence"], quote)

    def test_r15_a_quote_drops_only_an_unrun_finding_and_only_on_its_own_line(self):
        self.scenario["codex"]["sandbox"] = False
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding(), finding())
        own = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b",
               "explanation": "the spec asks for the difference"}
        other = {"type": "file-line", "file": "check.py", "line": 3,
                 "quote": "sys.exit(0 if calc.add(2, 2) == 4 else 1)", "explanation": "the check expects 4"}
        self.scenario["claude"]["seats"]["refuter"] = refuter(
            verdict("adversarial-1-1", "DROPPED", evidence=own),
            verdict("adversarial-1-2", "DROPPED", evidence=other))
        review = self.review("full", "claude")
        self.assertEqual(self.status(review, "adversarial-1-1"), "dropped")
        self.assertEqual(self.status(review, "adversarial-1-2"), "unresolved")
        self.assertEqual(review["verdict"], "NOT-READY")

    # R16
    def test_r16_rank_changes_follow_the_drop_rule_and_never_go_up(self):
        not_applied = {"command": CHECK, "patch": "not a patch\n"}
        quote = {"type": "file-line", "file": "calc.py", "line": 1, "quote": "def add(a, b):",
                 "explanation": "only a naming concern"}
        cite = {"type": "receipt-1", "file": None, "line": None, "quote": None,
                "explanation": "the command passed without the fix"}
        self.scenario["codex"]["seats"]["adversarial"] = seat(
            finding(repro={"command": "true", "patch": FIX}), finding(repro=not_applied), finding(),
            finding("mild", repro=None))
        self.scenario["claude"]["seats"]["refuter"] = refuter(
            verdict("adversarial-1-1", "PROMOTED", rank="mild", evidence=cite),
            verdict("adversarial-1-2", "PROMOTED", rank="mild"),
            verdict("adversarial-1-3", "PROMOTED", rank="mild", evidence=quote),
            verdict("adversarial-1-4", "PROMOTED", rank="catastrophic", evidence=quote))
        review = self.review("full", "claude")
        ranks = {f["id"]: (f["rank"], f["status"]) for f in review["findings"]}
        self.assertEqual(ranks["adversarial-1-1"], ("mild", "mild"))
        self.assertEqual(ranks["adversarial-1-2"], ("serious", "promoted"))
        self.assertEqual(ranks["adversarial-1-3"], ("serious", "promoted"))
        self.assertEqual(ranks["adversarial-1-4"], ("mild", "mild"))
        self.assertEqual(review["counts"]["invalid_rank_changes"], 3)

    def test_r16_a_rank_change_without_a_valid_verdict_leaves_the_finding_unjudged(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding(repro={"command": "true", "patch": FIX}))
        cite = {"type": "receipt-1", "file": None, "line": None, "quote": None, "explanation": "passed"}
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "MAYBE", rank="mild",
                                                                      evidence=cite))
        review = self.review("full", "claude")
        self.assertEqual((review["findings"][0]["rank"], self.status(review, "adversarial-1-1")),
                         ("serious", "unjudged"))
        self.assert_incomplete(review, "unjudged")

    # R17, R18, R19
    def test_r17_missing_or_unreadable_run_files_give_incomplete(self):
        self.assertEqual(self.review("standard", "claude")["verdict"], "READY")
        for name in ("findings.json", "run.json", "parts.json", "fingerprint-start.json", "preflight.json"):
            for broken in ("missing", "unreadable"):
                with self.subTest(name=name, broken=broken):
                    copy = self.root / f"decide-{name}-{broken}"
                    shutil.copytree(self.run_dir, copy)
                    if broken == "missing":
                        (copy / name).unlink()
                    else:
                        (copy / name).write_text("{not json")
                    self.assertEqual(MOD.decide(copy)["verdict"], "INCOMPLETE")

    def test_r17_a_run_directory_inside_a_temporary_directory_is_refused(self):
        for parent in (self.tmpdir, Path("/tmp")):
            with self.subTest(parent=str(parent)):
                result = self.invoke("run", "--path", "standard", "--writer", "claude", "--base", self.base,
                                     "--spec", str(self.spec), "--run-dir", str(parent / f"orch-run-{os.getpid()}"))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("temporary", result.stderr)
        self.assertEqual(self.launches(), [])

    def test_r17_no_findings_on_complete_seats_is_ready(self):
        review = self.review("full", "claude")
        self.assertEqual(review["verdict"], "READY")
        self.assertEqual(review["incomplete_reasons"], [])

    def test_r17_a_seat_copy_that_does_not_match_the_fingerprint_gives_incomplete(self):
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"review": {"setup": "echo extra > extra.py"}}))
        self.git("add", "docs")
        self.git("commit", "-qm", "config")
        self.assert_incomplete(self.review("standard", "claude"), "fingerprint")

    def test_r19_review_json_records_launches_findings_and_counts(self):
        self.scenario["codex"]["seats"]["adversarial"] = seat(finding(), finding("mild", repro=None,
                                                                                  confidence=0.2))
        self.scenario["claude"]["seats"]["refuter"] = refuter(verdict("adversarial-1-1", "PROMOTED"))
        review = self.review("full", "claude")
        launches = {launch["name"]: launch for launch in review["launches"]}
        self.assertEqual(set(launches), {"contract-1", "adversarial-1", "refuter"})
        self.assertEqual(launches["adversarial-1"]["provider"], "codex")
        self.assertEqual(launches["refuter"]["provider"], "claude")
        self.assertEqual(launches["contract-1"]["requested_model"], "opus")
        self.assertEqual(launches["contract-1"]["served_model"], ["claude-opus-5-5"])
        self.assertEqual(launches["contract-1"]["requested_effort"], "high")
        self.assertEqual(review["counts"]["raw_findings"], 2)
        self.assertEqual(review["counts"]["notes"], 1)
        self.assertEqual(review["findings"][0]["raw"], finding())

    # R20
    def test_r20_every_run_appends_one_review_row_without_claim_text(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding())
        self.review("standard", "claude")
        self.scenario["codex"]["login"] = False
        self.review("full", "claude")
        rows = self.outcome_rows()
        self.assertEqual([row["verdict"] for row in rows], ["NOT-READY", "INCOMPLETE"])
        for key in ("run_id", "date", "repository", "path", "writer", "launches", "parts", "diff_lines",
                    "incomplete_reasons", "counts", "duration_s", "cost_usd"):
            self.assertIn(key, rows[0])
        text = json.dumps(rows)
        self.assertNotIn("subtracts", text)
        self.assertNotIn("return a - b", text)

    # R21
    def test_r21_record_needs_a_disposition_for_every_finding(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding(), finding("mild", repro=None))
        self.review("standard", "claude")
        dispositions = self.root / "dispositions.json"
        dispositions.write_text(json.dumps({"contract-1-1": {"disposition": "fixed", "check": CHECK}}))
        result = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contract-1-2", result.stdout + result.stderr)
        self.assertEqual(len(self.outcome_rows()), 1)

    def test_r21_record_checks_each_disposition(self):
        self.scenario["claude"]["seats"]["contract"] = seat(finding(), finding("mild", repro=None))
        self.review("standard", "claude")
        dispositions = self.root / "dispositions.json"
        valid_quote = {"type": "file-line", "file": "calc.py", "line": 2, "quote": "return a - b"}
        bad = [
            {"contract-1-1": {"disposition": "ignored", "reason": "later"},
             "contract-1-2": {"disposition": "ignored", "reason": "style"}},
            {"contract-1-1": {"disposition": "fixed"}, "contract-1-2": {"disposition": "ignored", "reason": "x"}},
            {"contract-1-1": {"disposition": "refuted", "evidence": dict(valid_quote, quote="nope")},
             "contract-1-2": {"disposition": "ignored", "reason": "x"}},
            {"contract-1-1": {"disposition": "fixed", "check": CHECK},
             "contract-1-2": {"disposition": "ignored", "reason": "x"}, "contract-1-9": {"disposition": "fixed"}},
        ]
        for case in bad:
            with self.subTest(case=case):
                dispositions.write_text(json.dumps(case))
                result = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
                self.assertNotEqual(result.returncode, 0, result.stdout)
        dispositions.write_text(json.dumps({
            "contract-1-1": {"disposition": "ignored", "reason": "the person chose to ship",
                             "person_approved": True},
            "contract-1-2": {"disposition": "refuted", "evidence": valid_quote}}))
        self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions), check_rc=0)
        rows = [row for row in self.outcome_rows() if row["row"] == "finding"]
        self.assertEqual([(row["finding"], row["disposition"]) for row in rows],
                         [("contract-1-1", "ignored"), ("contract-1-2", "refuted")])
        for key in ("run_id", "seat", "provider", "rank", "kind", "status"):
            self.assertIn(key, rows[0])
        again = self.invoke("record", str(self.run_dir), "--dispositions", str(dispositions))
        self.assertNotEqual(again.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
