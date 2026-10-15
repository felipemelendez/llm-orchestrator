#!/usr/bin/env python3
"""Synthetic SessionStart policy loading; no provider/model launches."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/hooks/session-start.sh"
CONTROL = ROOT / "scripts/lib/orch-control.py"


class SessionPolicyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="orch-session-synthetic-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        subprocess.run(["git", "-C", str(self.project), "init", "-q", "-b", "main"], check=True)
        self.home = self.root / "home"
        self.home.mkdir()
        self.document = self.project / "POLICY.md"
        self.document.write_text("Current canonical policy: preserve a voluntary stopping point.\n")
        self.config = {"schema": 1, "policies": ["POLICY.md"]}
        self.write_config()
        self.environment = {**os.environ, "HOME": str(self.home), "ORCH_HOME": str(self.root / "state"),
            "CLAUDE_PLUGIN_ROOT": str(ROOT), "CLAUDE_PROJECT_DIR": str(self.project),
            "ORCH_HOOK_PROFILE": "standard", "ORCH_DISABLED_HOOKS": "", "ORCH_HOOK_DRY_RUN": "0",
            "ORCH_SESSION_MAX_CHARS": "8000"}

    def write_config(self):
        (self.project / ".llm-orchestrator.json").write_text(json.dumps(self.config))

    def hook(self, source="startup", **environment):
        result = subprocess.run(["bash", str(HOOK)], cwd=self.project,
            input=json.dumps({"source": source, "cwd": str(self.project), "session_id": "synthetic"}),
            env={**self.environment, **environment}, capture_output=True, text=True, timeout=9)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        context = json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"] if result.stdout else ""
        return context, result

    def test_every_session_source_reads_current_policy_without_cadence(self):
        for source in ("startup", "clear", "resume", "compact"):
            with self.subTest(source=source):
                text = f"Fresh instruction for {source}: preserve independent verification.\n"
                self.document.write_text(text)
                context, _ = self.hook(source)
                self.assertIn(text.strip(), context)
                self.assertIn(hashlib.sha256(self.document.read_bytes()).hexdigest(), context)
                self.assertIn(f"SessionStart ({source})", context)
                self.assertIn("Full canonical policy text supplied", context)
                self.assertNotIn("## Reply format in a cadence-enabled project", context)
                self.assertFalse((self.project / "docs/llm-orchestrator/cadence.json").exists())

    def test_minimal_profile_refreshes_policy_after_compaction(self):
        context, _ = self.hook("compact", ORCH_HOOK_PROFILE="minimal")
        self.assertIn(self.document.read_text().strip(), context)
        self.assertIn("SessionStart (compact)", context)

    def test_malformed_config_is_actionable_and_never_claims_loaded(self):
        self.config["unrecognized_key"] = True
        self.write_config()
        context, result = self.hook()
        self.assertIn("Shared project policy ERROR", context)
        self.assertIn("Policy loading is pending", context)
        self.assertIn("orch-control.py", context)
        self.assertNotIn("Full canonical policy text supplied", context)
        self.assertIn("expected object", result.stderr)

    def test_disabled_hook_is_silent_but_explicit_session_api_still_works(self):
        context, result = self.hook(ORCH_DISABLED_HOOKS="orch-session-start")
        self.assertEqual(context, "")
        self.assertEqual(result.stderr, "")
        explicit = subprocess.run([sys.executable, str(CONTROL), "session", "--project", str(self.project)],
            env={**self.environment, "ORCH_DISABLED_HOOKS": "orch-session-start"},
            capture_output=True, text=True, timeout=5)
        self.assertEqual(explicit.returncode, 0, explicit.stderr)
        self.assertEqual(json.loads(explicit.stdout)["policy_context"]["files"][0]["text"], self.document.read_text())

    def test_oversized_policy_is_read_fresh_and_explicitly_pending_in_model_context(self):
        self.document.write_text("large canonical policy\n" + "x" * 30000)
        for maximum in (8000, 20000):
            context, _ = self.hook(ORCH_SESSION_MAX_CHARS=str(maximum))
            self.assertLessEqual(len(context), min(maximum, 10000))
            self.assertIn("POLICY TEXT LOADING PENDING", context)
            self.assertIn("NOT loaded into the model context", context)
            self.assertIn(hashlib.sha256(self.document.read_bytes()).hexdigest(), context)
            self.assertIn("POLICY.md", context)
            self.assertNotIn("x" * 500, context)
        context, _ = self.hook(ORCH_SESSION_MAX_CHARS="500")
        self.assertLessEqual(len(context), 500)
        self.assertIn("POLICY LOAD PENDING", context)
        self.assertIn("orch-control.py session", context)

    def test_missing_meta_skill_still_reports_opted_in_policy(self):
        empty = self.root / "missing-meta"
        empty.mkdir()
        context, _ = self.hook(CLAUDE_PLUGIN_ROOT=str(empty))
        self.assertIn(self.document.read_text().strip(), context)

    def test_session_from_subdirectory_loads_git_root_policy(self):
        nested = self.project / "nested"
        nested.mkdir()
        context, _ = self.hook(CLAUDE_PROJECT_DIR=str(nested))
        self.assertIn(self.document.read_text().strip(), context)

    def test_existing_cadence_verdict_remains_first_with_shared_policy(self):
        directory = self.project / "docs/llm-orchestrator"
        directory.mkdir(parents=True)
        (directory / "cadence.json").write_text(json.dumps({"schema": 1, "enabled": True, "workflow": "proportional"}))
        (directory / "LAWS.md").write_text("# Fixture laws\n\nRuling 1 — fixture only.\n")
        (self.project / ".claude").mkdir()
        (self.project / ".claude/settings.json").write_text("{}\n")
        for name in ("AGENTS.md", "CLAUDE.md"):
            (self.project / name).write_text("# Fixture\n\n<!-- ORCH:LAWS:START -->\nlaws\n<!-- ORCH:LAWS:END -->\n")
        context, _ = self.hook()
        self.assertTrue(context.startswith("cadence:"), context[:200])
        self.assertIn(self.document.read_text().strip(), context)

    def test_unconfigured_project_keeps_previous_hook_output(self):
        (self.project / ".llm-orchestrator.json").unlink()
        context, result = self.hook()
        self.assertNotIn("Shared project policy", context)
        self.assertNotIn("POLICY LOAD PENDING", context)
        self.assertIn("You are running LLM Orchestrator", context)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
