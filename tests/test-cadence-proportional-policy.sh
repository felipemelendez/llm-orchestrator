#!/usr/bin/env bash
# Git-policy transitions and installed initialization; no application builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop())
CHECK = ROOT / "skills/cadence/scripts/orch-cadence-check.sh"
INIT = ROOT / "skills/cadence/scripts/cadence-init.sh"
DETECT = ROOT / "skills/cadence/scripts/cadence-detect.sh"
CFG = "docs/llm-orchestrator/cadence.json"
LAWS = "docs/llm-orchestrator/LAWS.md"
LOCK = "docs/llm-orchestrator/LOCK.sha256"
MISSING = object()
evidence_spec = importlib.util.spec_from_file_location("cadence_evidence", ROOT / "scripts/hooks/codex-evidence.py")
evidence = importlib.util.module_from_spec(evidence_spec)
evidence_spec.loader.exec_module(evidence)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="orch-policy-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "project"
        self.repo.mkdir()
        self.env = dict(os.environ, HOME=str(self.base / "home"), GIT_CONFIG_NOSYSTEM="1")
        self.env.pop("ORCH_CADENCE_UNLOCK", None)
        self.env.pop("ORCH_CADENCE_PYTHON", None)
        Path(self.env["HOME"]).mkdir()
        self.run_cmd("git", "init", "-q")
        self.run_cmd("git", "config", "user.name", "Fixture")
        self.run_cmd("git", "config", "user.email", "fixture@example.invalid")

    def run_cmd(self, *args, expected=0, env=None, cwd=None):
        p = subprocess.run([str(a) for a in args], cwd=cwd or self.repo,
                           env=env or self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, expected, p.stdout + p.stderr)
        return p.stdout + p.stderr

    def write(self, name, value):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def configure(self, workflow=MISSING, enabled=True):
        data = {"schema": 1, "enabled": enabled, "ticket_re": "^AB-[0-9]+:", "lock_extra": []}
        if workflow is not MISSING:
            data["workflow"] = workflow
        self.write(CFG, json.dumps(data))

    def stage(self):
        self.run_cmd("git", "add", "-A")

    def relock(self):
        # The unlock belongs only to this suite's disposable fixture process.
        self.run_cmd("bash", CHECK, "--root", self.repo, "--lock",
                     env=dict(self.env, ORCH_CADENCE_UNLOCK="1"))

    def arm(self, workflow=MISSING):
        self.configure(workflow)
        self.write(LAWS, "Ruling 1 — initial policy\n")
        self.relock()
        self.stage()
        self.run_cmd("git", "commit", "-qm", "arm")

    def message(self, message="AB-1: change", expected=0, env=None):
        path = self.base / "message"
        path.write_text(message + "\n")
        return self.run_cmd("bash", CHECK, "--root", self.repo, "--commit-msg", path,
                            expected=expected, env=env)

    def reports(self):
        notes = "docs/llm-orchestrator/notes"
        for seat in ("BRIEFREV", "REV1", "REV2", "REFUTE", "GATE"):
            self.write(f"{notes}/AB-1_{seat}_report.md",
                       "Started: 2099-01-01 00:00:00\nFinished: 2099-01-01 00:00:00\n" +
                       ("EXIT=0\n" if seat == "GATE" else ""))

    def migrate(self, workflow, enabled=True):
        self.configure(workflow, enabled)
        self.write(LAWS, "Ruling 1 — initial policy\nRuling 2 — deliberate migration\n")
        self.relock()
        self.stage()

    def test_proportional_ticket_has_no_report_or_ledger_requirement(self):
        self.arm("proportional")
        self.write("src/change.py", "value = 2\n")
        self.stage()
        self.assertIn("not attested", self.message())
        self.assertFalse((self.repo / "docs/llm-orchestrator/notes").exists())

    def test_missing_and_explicit_legacy_keep_reports(self):
        self.arm()
        for workflow in (MISSING, "legacy"):
            self.configure(workflow)
            self.assertIn("missing", self.run_cmd("bash", CHECK, "--root", self.repo, "--landing", "AB-1", expected=1))
        self.assertIn("missing", self.message(expected=1))
        self.reports()
        self.assertIn("5 reports", self.message())

    def test_staged_migration_uses_proportional_policy_after_ruling(self):
        self.arm()
        self.migrate("proportional")
        text = self.message("AB-1: migrate\n\nRuling 2")
        self.assertIn("proportional Git policy OK", text)
        self.assertNotIn("missing", text)

    def test_staged_reverse_migration_requires_legacy_reports(self):
        self.arm("proportional")
        self.migrate("legacy")
        self.assertIn("missing", self.message("AB-1: migrate\n\nRuling 2", expected=1))
        self.reports()
        self.assertIn("5 reports", self.message("AB-1: migrate\n\nRuling 2"))

    def test_unstaged_flip_never_selects_commit_policy(self):
        self.arm()
        self.configure("proportional")
        self.assertIn("missing", self.message(expected=1))
        # Direct landing deliberately reads the working policy, without saying
        # that the unstaged migration is authorized to commit.
        text = self.run_cmd("bash", CHECK, "--root", self.repo, "--landing", "AB-1")
        self.assertIn("not commit authorization", text)

    def test_unstaged_legacy_does_not_change_proportional_commit(self):
        self.arm("proportional")
        self.configure("legacy")
        self.assertIn("proportional Git policy OK", self.message())

    def test_unauthorized_flip_does_not_waive_ruling_or_lock(self):
        self.arm()
        self.configure("proportional")
        self.stage()
        text = self.message(expected=1)
        self.assertIn("stale lock", text)
        self.assertIn("no numbered ruling", text)
        self.assertNotIn("policy OK", text)

    def test_fresh_lock_without_ruling_still_refused(self):
        self.arm()
        self.migrate("proportional")
        text = self.message(expected=1)
        self.assertIn("no numbered ruling", text)
        self.assertNotIn("policy OK", text)

    def test_proportional_rule_edit_is_still_protected(self):
        self.arm("proportional")
        self.write(LAWS, "rewritten without authorization\n")
        self.stage()
        self.assertIn("no numbered ruling", self.message(expected=1))

    def test_disabled_index_uses_enabled_head_workflow(self):
        self.arm()
        self.configure("proportional", enabled=False)
        self.write(LAWS, "Ruling 1\nRuling 2 — disable\n")
        # --lock is intentionally unavailable while disabled; produce the
        # fixture manifest from its two actual protected files explicitly.
        import hashlib
        self.write(LOCK, "".join(f"{hashlib.sha256((self.repo / p).read_bytes()).hexdigest()}  {p}\n"
                                  for p in (LAWS, CFG)))
        self.stage()
        self.assertIn("missing", self.message("AB-1: disable\n\nRuling 2", expected=1))
        self.reports()
        self.assertIn("5 reports", self.message("AB-1: disable\n\nRuling 2"))

    def test_disabled_index_preserves_proportional_head_policy(self):
        self.arm("proportional")
        self.configure("legacy", enabled=False)
        self.stage()
        text = self.message(expected=1)
        self.assertIn("no numbered ruling", text)
        self.assertNotIn("missing docs/llm-orchestrator/notes", text)
        self.write(LAWS, "Ruling 1\nRuling 2 — disable\n")
        import hashlib
        self.write(LOCK, "".join(f"{hashlib.sha256((self.repo / p).read_bytes()).hexdigest()}  {p}\n"
                                  for p in (LAWS, CFG)))
        self.stage()
        self.assertIn("proportional Git policy OK", self.message("AB-1: disable\n\nRuling 2"))

    def test_absent_and_disabled_projects_are_inert(self):
        self.message()
        self.configure("INVALID", enabled=False)
        self.stage()
        self.message()

    def test_invalid_workflow_never_waives_requirements(self):
        self.arm("proportional")
        for invalid in ("simple", "", None, [], {}, True, 1):
            self.configure(invalid)
            self.stage()
            self.assertIn("invalid workflow", self.message(expected=1))
            text = self.run_cmd("bash", CHECK, "--root", self.repo, "--landing", "AB-1", expected=1)
            self.assertIn('use "legacy" or "proportional"', text)

    def test_malformed_index_refused_even_when_head_enabled(self):
        self.arm("proportional")
        self.write(CFG, '{"enabled": true, "workflow": "proportional", BROKEN}')
        self.stage()
        self.assertIn("does not decode", self.message(expected=1))
        self.assertIn("does not decode", self.run_cmd("bash", CHECK, "--root", self.repo,
                                                       "--landing", "AB-1", expected=1))
        self.assertIn("does not decode", self.run_cmd("bash", CHECK, "--root", self.repo,
                                                       "--lock", expected=1))

    def test_malformed_head_cannot_hide_behind_enabled_index(self):
        self.write(CFG, '{"enabled": true, BROKEN}')
        self.stage()
        self.run_cmd("git", "commit", "-qm", "malformed historical fixture")
        self.configure("proportional")
        self.stage()
        self.assertIn("does not decode", self.message(expected=1))

    def test_audit_selects_historical_policy_after_artifact_cleanup(self):
        self.arm()
        self.reports()
        self.stage()
        self.run_cmd("git", "commit", "-qm", "AB-1: legacy")
        legacy = self.run_cmd("git", "rev-parse", "HEAD").strip()
        self.migrate("proportional")
        shutil.rmtree(self.repo / "docs/llm-orchestrator/notes")
        self.stage()
        self.run_cmd("git", "commit", "-qm", "AB-1: migration\n\nRuling 2")
        self.configure("legacy")
        self.assertIn("proportional Git policy OK", self.run_cmd("bash", CHECK, "--root", self.repo, "--audit", "HEAD"))
        self.assertIn("5 reports", self.run_cmd("bash", CHECK, "--root", self.repo, "--audit", legacy))

    def test_python_unavailable_cannot_waive_reports_from_unparsed_config(self):
        self.arm("proportional")
        env = dict(self.env, ORCH_CADENCE_PYTHON=str(self.base / "no-python"))
        self.assertIn("needs a working python3", self.message(expected=1, env=env))
        self.configure("typo")
        self.stage()
        self.assertIn("invalid workflow", self.message(expected=1, env=env))

    def test_python_unavailable_accepts_pretty_legacy_workflow_last_key(self):
        self.arm("legacy")
        data = json.loads((self.repo / CFG).read_text())
        self.write(CFG, json.dumps(data, indent=2) + "\n")
        self.relock()
        self.stage()
        self.run_cmd("git", "commit", "-qm", "pretty legacy fixture")
        self.reports()
        env = dict(self.env, ORCH_CADENCE_PYTHON=str(self.base / "no-python"))
        self.assertIn("5 reports", self.message(env=env))

    def test_all_detector_profiles_define_evidence_intent_and_fallback_inputs(self):
        for profile in ("jest", "vitest", "pytest", "shell-suites", "unknown"):
            d = json.loads(self.run_cmd("bash", DETECT, "--profile", profile))
            self.assertEqual(d["workflow"], "proportional")
            self.assertEqual(d["codex_verification"]["mode"], "blocking")
            self.assertIsInstance(d["verification_config_globs"], list)
            if profile != "unknown":
                self.assertTrue(d["verification_config_globs"])
            else:
                self.assertEqual(d["prod_globs"], [])

    def test_detector_scopes_track_root_and_nested_sources_and_tests(self):
        for profile, extension, test_names in (
                ("jest", "ts", ("main.test.ts", "__tests__/plain.ts", "src/__tests__/plain.ts")),
                ("vitest", "tsx", ("main.test.tsx", "__tests__/plain.tsx", "src/__tests__/plain.tsx")),
                ("pytest", "py", ("test_main.py", "tests/plain.py", "src/tests/plain.py"))):
            with self.subTest(profile=profile):
                config = json.loads(self.run_cmd("bash", DETECT, "--profile", profile))
                self.write(CFG, json.dumps(config))
                sources = [f"main.{extension}", f"src/main.{extension}", f"src/deep/main.{extension}"]
                paths = sources + list(test_names)
                for name in paths:
                    self.write(name, "original\n")
                before = evidence.proportional.snapshot(self.repo, config, {}, evidence)
                self.assertIsNone(before["error"])
                for name in paths:
                    self.assertIn(name, before["files"])
                    self.write(name, "changed\n")
                    after = evidence.proportional.snapshot(self.repo, config, {}, evidence)
                    self.assertNotEqual(before["fingerprint"], after["fingerprint"], name)
                    self.write(name, "original\n")
                for name in test_names:
                    self.assertTrue(evidence.proportional.matches(name, config["test_globs"]), name)

    def test_source_and_copied_skill_init_default_to_proportional(self):
        copied = self.base / "copied-skill"
        shutil.copytree(ROOT / "skills/cadence", copied)
        for i, script in enumerate((INIT, copied / "scripts/cadence-init.sh")):
            project = self.base / f"initialized-{i}"
            project.mkdir()
            self.run_cmd("git", "init", "-q", cwd=project)
            text = self.run_cmd("bash", script, "--root", project, cwd=project)
            config = json.loads((project / CFG).read_text())
            self.assertEqual(config["workflow"], "proportional")
            self.assertEqual(config["codex_verification"]["mode"], "blocking")
            self.assertIn("activation: not verified", text)
            self.assertIn("installed, enabled, loaded and trusted", text)
            self.assertIn("execution evidence scope is incomplete", text)
            self.assertIn("verification_config_globs", text)
            self.assertIn("claude_verification.commands", text)

    def test_reinitialization_does_not_silently_migrate_legacy(self):
        self.configure()
        self.run_cmd("bash", INIT, "--root", self.repo)
        self.assertNotIn("workflow", json.loads((self.repo / CFG).read_text()))
        self.run_cmd("bash", INIT, "--root", self.repo,
                     env=dict(self.env, ORCH_CADENCE_UNLOCK="1"))
        self.assertNotIn("workflow", json.loads((self.repo / CFG).read_text()))

    def test_init_invalid_confirmed_workflow_refuses_before_writes(self):
        confirmed = self.base / "confirmed.json"
        confirmed.write_text(json.dumps({"workflow": "typo"}))
        text = self.run_cmd("bash", INIT, "--root", self.repo, "--config", confirmed, expected=1)
        self.assertIn("invalid workflow", text)
        self.assertFalse((self.repo / CFG).exists())
        self.assertFalse((self.repo / "AGENTS.md").exists())


unittest.main(verbosity=2)
PY
