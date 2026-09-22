#!/usr/bin/env python3
"""Exercise installed proportional hooks and helpers in disposable projects."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = '''from pathlib import Path
import unittest

class Fixture(unittest.TestCase):
    def test_source_has_integer_value(self):
        namespace = {}
        exec(Path("src/main.py").read_text(), namespace)
        self.assertIsInstance(namespace["value"], int)

if __name__ == "__main__":
    unittest.main()
'''


class InstalledTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="orch-proportional-install-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.project = self.base / "project"
        self.project.mkdir()
        self.artifacts = self.base / "receipts"
        self.artifacts.mkdir()
        self.env = {**os.environ, "HOME": str(self.home),
                    "ORCH_HOME": str(self.base / "claude-state"),
                    "ORCH_CODEX_STATE_DIR": str(self.base / "codex-state"),
                    "ORCH_HOOK_PROFILE": "standard", "ORCH_DISABLED_HOOKS": ""}
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("src/main.py", "value = 1\n")
        self.write("tests/test-check.py", CHECK)
        self.write("config.json", "{}\n")
        self.write("docs/llm-orchestrator/cadence.json", json.dumps({
            "enabled": True, "workflow": "proportional", "codex_verification": {"mode": "blocking"},
            "prod_globs": ["src/**"], "test_globs": ["tests/**"],
            "verification_config_globs": ["config.json"],
            "verification_scopes": {"app": {"selectors": ["tests/test-check.py"],
                "inputs": ["src/**", "tests/test-check.py", "config.json"]}}}))
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.sequence = 0

    def run_command(self, command, input=None, code=0):
        result = subprocess.run(command, cwd=self.project, env=self.env, input=input,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.run_command(["git", *args]).stdout

    def write(self, relative, value):
        path = self.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def install(self, mode):
        args = ["bash", str(ROOT / "scripts/install.sh"), mode]
        if mode == "--copy":
            args.append(str(self.project))
        return self.run_command(args)

    def hook_command(self, hooks, event, basename):
        found = [hook["command"] for group in hooks["hooks"].get(event, [])
                 for hook in group.get("hooks", [])
                 if isinstance(hook.get("command"), str)
                 and any(Path(word).name == basename for word in shlex.split(hook["command"]))]
        self.assertEqual(len(found), 1, (event, basename, found))
        return shlex.split(found[0])

    def event(self, hooks, harness, name, **extra):
        basename = "codex-evidence.py" if harness == "codex" else (
            "orch-verify-gate.sh" if name == "Stop" else "orch-evidence-ledger.sh")
        payload = dict(session_id="installed", turn_id="turn", cwd=str(self.project), hook_event_name=name)
        payload.update(extra)
        if harness == "claude" and name == "UserPromptSubmit":
            # Exercise the registered prompt adapter, including either inline
            # forwarding or a separately registered evidence hook.
            self.run_command(self.hook_command(hooks, name, "user-prompt-submit.sh"), json.dumps(payload))
            commands = [hook.get("command", "") for group in hooks["hooks"].get(name, [])
                        for hook in group.get("hooks", [])]
            if not any("orch-evidence-ledger.sh" in command for command in commands if isinstance(command, str)):
                return {}
        result = self.run_command(self.hook_command(hooks, name, basename), json.dumps(payload))
        return json.loads(result.stdout or "{}")

    def edit(self, hooks, harness, value):
        tool = "apply_patch" if harness == "codex" else "Edit"
        target = {"command": "*** Update File: src/main.py"} if harness == "codex" else {
            "file_path": str(self.project / "src/main.py")}
        self.event(hooks, harness, "PreToolUse", tool_name=tool, tool_use_id=f"edit-{value}", tool_input=target)
        self.write("src/main.py", f"value = {value}\n")
        self.event(hooks, harness, "PostToolUse", tool_name=tool, tool_use_id=f"edit-{value}",
                   tool_input=target, tool_response={})

    def check(self, hooks, harness, runner=None):
        self.sequence += 1
        command = ["python3", "tests/test-check.py"]
        if runner:
            command = ["python3", str(runner), "--cwd", str(self.project),
                       "--receipt", str(self.artifacts / f"receipt-{self.sequence}.json"),
                       "--output", str(self.artifacts / f"output-{self.sequence}.log"), "--", *command]
        fields = dict(tool_name="Bash", tool_use_id=f"check-{self.sequence}",
                      tool_input={"command": shlex.join(command)})
        self.assertEqual(self.event(hooks, harness, "PreToolUse", **fields), {})
        result = self.run_command(command)
        self.assertIn("Ran 1 test", result.stdout + result.stderr)
        response = result.stdout if harness == "codex" else {
            "stdout": result.stdout, "stderr": result.stderr, "interrupted": False}
        self.event(hooks, harness, "PostToolUse", tool_response=response, **fields)

    def assert_verification_lifecycle(self, hooks, harness, runner=None):
        self.event(hooks, harness, "UserPromptSubmit")
        self.edit(hooks, harness, 2)
        pending = self.event(hooks, harness, "Stop",
                             last_assistant_message="Verification: PENDING — fixture check remains")
        self.assertNotIn("decision", pending, pending)
        self.event(hooks, harness, "UserPromptSubmit", turn_id="discussion-before-check")
        # A discussion turn that changes nothing is never blocked; the edit's
        # obligation survives it and is judged at the next PASS claim.
        unresolved = self.event(hooks, harness, "Stop", turn_id="discussion-before-check",
                                last_assistant_message="The setting controls the toast.")
        self.assertNotIn("decision", unresolved, unresolved)
        self.event(hooks, harness, "UserPromptSubmit", turn_id="check-now")
        self.check(hooks, harness, runner)
        # Another observed source edit makes the successful command stale.
        self.edit(hooks, harness, 3)
        rejected = self.event(hooks, harness, "Stop", last_assistant_message="Verification: PASS — fixture check")
        self.assertEqual(rejected.get("decision"), "block", rejected)
        self.check(hooks, harness, runner)
        accepted = self.event(hooks, harness, "Stop", last_assistant_message="Verification: PASS — fixture check")
        self.assertNotIn("decision", accepted, accepted)
        # The next unrelated discussion must not inherit the completed task's
        # source obligation just because another actor commits covered source.
        self.event(hooks, harness, "UserPromptSubmit", turn_id="new-question")
        self.write("src/main.py", "value = 50\n")
        self.git("add", "src/main.py")
        self.git("commit", "-qm", "other task")
        discussion = self.event(hooks, harness, "Stop", turn_id="new-question",
                                last_assistant_message="The setting controls the toast.")
        self.assertNotIn("decision", discussion, discussion)

    def assert_helper_lifecycle(self, helper):
        state = self.base / ("resource-state-" + str(self.sequence))
        self.sequence += 1
        command = ["python3", str(helper), "--state-dir", str(state)]
        def call(*args):
            return json.loads(self.run_command([*command, *args]).stdout)
        task = call("start", "--project", str(self.project), "--task", "installed helper")
        lease = call("acquire", "--id", task["id"], "--consumer", "reviewer")
        copy = call("copy", "--id", task["id"], "--token", lease["token"])
        snapshot = Path(copy["path"])
        self.assertEqual((snapshot / "src/main.py").read_text(), "value = 1\n")
        self.assertFalse((snapshot / ".git").exists())
        call("release", "--id", task["id"], "--token", lease["token"], "--stopped")
        self.assertEqual(call("finish", "--id", task["id"])["status"], "done")
        self.assertFalse(Path(task["scratch"]).exists())
        self.assertTrue((self.project / "src/main.py").exists())

    def test_codex_installed_runner_hooks_and_reinstall_preserve_foreign_entries(self):
        codex = self.home / ".codex"
        codex.mkdir()
        foreign = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/bin/true"}]}],
                             "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": 42}]}]}}
        (codex / "hooks.json").write_text(json.dumps(foreign))
        (codex / "AGENTS.md").write_text("Keep this unrelated instruction.\n")
        self.install("--codex")
        first_hooks = (codex / "hooks.json").read_bytes()
        self.install("--codex")
        self.assertEqual(first_hooks, (codex / "hooks.json").read_bytes())
        self.assertIn("Keep this unrelated instruction.", (codex / "AGENTS.md").read_text())
        hooks = json.loads(first_hooks)
        for event in ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop"):
            self.hook_command(hooks, event, "codex-evidence.py")
        self.hook_command(hooks, "Stop", "orch-task-cleanup.sh")
        self.assertTrue(any(hook.get("command") == "/bin/true" for group in hooks["hooks"]["Stop"] for hook in group["hooks"]))
        self.assertTrue(any(hook.get("command") == 42 for group in hooks["hooks"]["PreToolUse"] for hook in group["hooks"]))
        skill = self.home / ".agents/skills/cadence"
        marker = (skill / ".orch-installed").read_text().splitlines()
        runners = [line.split("=", 1)[1] for line in marker if line.startswith("verification_runner=")]
        self.assertEqual(len(runners), 1)
        self.assertTrue(Path(runners[0]).is_file())
        self.assert_helper_lifecycle(skill / "scripts/orch-task-resources.py")
        self.assert_verification_lifecycle(hooks, "codex", Path(runners[0]))

    def test_claude_copied_hooks_execute_with_installed_dependencies(self):
        settings = {"env": {"CUSTOM_KEEP": "yes"}, "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "/bin/true"}]}]}}
        self.write(".claude/settings.json", json.dumps(settings))
        self.install("--copy")
        self.install("--copy")
        self.assertEqual(json.loads((self.project / ".claude/settings.json").read_text()), settings)
        installed = self.project / ".claude"
        hooks = json.loads((installed / "hooks/hooks.json").read_text())
        self.hook_command(hooks, "Stop", "orch-task-cleanup.sh")
        for event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
            command = self.hook_command(hooks, event, "orch-evidence-ledger.sh")
            self.assertTrue(all(str(ROOT) not in word for word in command))
        self.assert_helper_lifecycle(installed / "skills/cadence/scripts/orch-task-resources.py")
        self.assert_verification_lifecycle(hooks, "claude")
        # The copied runner also imports its copied hooks and proportional helper.
        self.run_command(["python3", str(installed / "scripts/verification/codex-verify.py"), "--help"])

    def test_legacy_suites_ignore_enabled_launch_project(self):
        # Their legacy payloads intentionally omit cwd. The suite process must
        # select its own disposable fixture, even when the caller is enabled.
        for suite in ("test-verify-gate.sh", "test-evidence-ledger.sh"):
            with self.subTest(suite=suite):
                result = self.run_command(["bash", str(ROOT / "tests" / suite)])
                self.assertIn("PASS: " + Path(suite).stem, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
