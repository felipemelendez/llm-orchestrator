#!/usr/bin/env python3
"""Provider contract tests; uses a fake CLI and never calls a paid model."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import importlib.util
from unittest.mock import patch

RUNNER = Path(__file__).resolve().parents[1] / "scripts/providers/claude-review.py"


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="claude provider tests ")
        self.root = Path(self.tmp.name)
        self.fake = self.root / "fake claude"
        self.fake.write_text("""#!/usr/bin/env python3
import json, os, sys, time
mode = os.environ.get('FAKE_MODE', 'success')
if '--version' in sys.argv:
    print('2.1.273 (Claude Code)'); sys.exit(0)
if sys.argv[1:3] == ['auth', 'status']:
    print(json.dumps({'loggedIn': mode != 'auth', 'email': 'private@example.test', 'token': 'DO-NOT-RECORD'}))
    sys.exit(1 if mode == 'auth' else 0)
prompt = sys.stdin.read()
Path = __import__('pathlib').Path
Path(os.environ['ARGV_FILE']).write_text(json.dumps({'argv': sys.argv[1:], 'prompt': prompt}))
if mode == 'wait':
    print(json.dumps({'type':'system','subtype':'init','model':'claude-opus-4-8'}), flush=True)
    time.sleep(60)
if mode == 'malformed':
    print('not-json'); sys.exit(0)
model = 'claude-sonnet-4-8' if mode == 'mismatch' else 'claude-opus-4-8'
print(json.dumps({'type':'system','subtype':'init','model':model}))
if mode not in ('unverified', 'usageonly'):
    print(json.dumps({'type':'assistant','message':{'model':model,'content':[{'type':'text','text':'Reviewed'}]}}))
result = {'type':'result','subtype':'success','is_error':False,'result':'Review complete.', 'usage':{'input_tokens':12,'output_tokens':4}}
if mode in ('auxiliary', 'usageonly', 'mismatch'):
    result['modelUsage'] = {'claude-opus-4-8': {'inputTokens':12}, 'claude-haiku-4-5-20251001': {'inputTokens':2}}
if mode == 'empty': result['result'] = '  '
if mode == 'error': result.update(subtype='error_during_execution', is_error=True, result='Denied')
if mode == 'noresult': sys.exit(0)
print(json.dumps(result))
if mode == 'multiple': print(json.dumps(result))
sys.exit(3 if mode == 'exit' else 0)
""")
        self.fake.chmod(0o700)
        self.prompt = self.root / "review prompt.txt"
        self.prompt.write_text("Review only. Literal $(touch unwanted) `no-shell`.\n")
        self.output = self.root / "review output.jsonl"
        self.receipt = self.root / "review receipt.json"
        self.argv = self.root / "argv.json"
        self.env = dict(os.environ, ARGV_FILE=str(self.argv))

    def tearDown(self):
        self.tmp.cleanup()

    def command(self, *extra):
        return [sys.executable, str(RUNNER), "run", "--cwd", str(self.root),
                "--prompt-file", str(self.prompt), "--output", str(self.output),
                "--receipt", str(self.receipt), "--claude-bin", str(self.fake), *extra]

    def run_mode(self, mode="success", *extra):
        result = subprocess.run(self.command(*extra), env=dict(self.env, FAKE_MODE=mode),
                                capture_output=True, text=True, timeout=15)
        self.assertTrue(self.receipt.is_file(), result.stderr)
        return result, json.loads(self.receipt.read_text())

    def test_success_has_bound_artifacts_and_restricted_argv(self):
        run, receipt = self.run_mode()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(receipt["status"], "success")
        self.assertEqual(receipt["provider"], "claude")
        self.assertEqual(receipt["requested_model"], "opus")
        self.assertEqual(receipt["reported_models"], ["claude-opus-4-8"])
        self.assertEqual(receipt["source"]["cwd"], str(self.root.resolve()))
        self.assertEqual(receipt["prompt_sha256"], hashlib.sha256(self.prompt.read_bytes()).hexdigest())
        self.assertEqual(receipt["output"]["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(receipt["usage"]["input_tokens"], 12)
        captured = json.loads(self.argv.read_text())
        args = captured["argv"]
        for flag in ("--safe-mode", "--restricted", "--strict-mcp-config", "--no-session-persistence"):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--tools") + 1], "Read,Grep,Glob")
        self.assertEqual(args[args.index("--permission-mode") + 1], "plan")
        self.assertNotIn("--fallback-model", args)
        self.assertNotIn("--bare", args)
        self.assertNotIn("--dangerously-skip-permissions", args)
        self.assertEqual(captured["prompt"], self.prompt.read_text())
        self.assertNotIn("DO-NOT-RECORD", self.receipt.read_text())

    def test_failures_are_receipted_and_nonzero(self):
        for mode, status in [("auth", "unauthenticated"), ("malformed", "invalid_output"),
                             ("mismatch", "model_mismatch"), ("unverified", "unverified_model"),
                             ("empty", "invalid_output"), ("error", "provider_error"),
                             ("noresult", "invalid_output"), ("multiple", "invalid_output"),
                             ("exit", "provider_error")]:
            with self.subTest(mode=mode):
                run, receipt = self.run_mode(mode)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(receipt["status"], status)
                self.assertIn("finished_at", receipt)
                self.output.unlink()
                self.receipt.unlink()

    def test_missing_executable_is_recorded(self):
        self.fake.unlink()
        run, receipt = self.run_mode()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "unavailable")

    def test_exact_model_must_match(self):
        run, receipt = self.run_mode("success", "--model", "claude-opus-4-7")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "model_mismatch")

    def test_output_and_receipt_collisions_never_overwrite(self):
        for target in (self.output, self.receipt):
            with self.subTest(target=target.name):
                target.write_text("KEEP")
                run = subprocess.run(self.command(), env=self.env, capture_output=True, timeout=10)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(target.read_text(), "KEEP")
                self.assertFalse(self.argv.exists())
                target.unlink()
        run = subprocess.run(self.command("--receipt", str(self.output)), env=self.env, capture_output=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_symlink_collision_is_rejected(self):
        self.output.symlink_to(self.prompt)
        before = self.prompt.read_bytes()
        run = subprocess.run(self.command(), env=self.env, capture_output=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.prompt.read_bytes(), before)

    def test_timeout_is_receipted(self):
        run, receipt = self.run_mode("wait", "--timeout", "0.15")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "timeout")
        self.assertGreater(self.output.stat().st_size, 0)

    def test_sigterm_is_receipted(self):
        proc = subprocess.Popen(self.command(), env=dict(self.env, FAKE_MODE="wait"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 8
        while not self.argv.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(self.argv.exists())
        proc.send_signal(signal.SIGTERM)
        proc.communicate(timeout=8)
        self.assertNotEqual(proc.returncode, 0)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt["status"], "cancelled")

    def test_doctor_does_not_print_auth_identity_or_secrets(self):
        run = subprocess.run([sys.executable, str(RUNNER), "doctor", "--claude-bin", str(self.fake)],
                             env=self.env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(run.stdout)
        self.assertTrue(report["authenticated"])
        self.assertNotIn("private@example.test", run.stdout)
        self.assertNotIn("DO-NOT-RECORD", run.stdout)

    def test_project_config_defaults_and_explicit_overrides(self):
        folder = self.root / "docs/llm-orchestrator"
        folder.mkdir(parents=True)
        config = folder / "cadence.json"
        config.write_text(json.dumps({"codex_providers": {"claude": {
            "enabled": True, "model": "opus", "effort": "high"}}}))
        run, receipt = self.run_mode()
        self.assertEqual(run.returncode, 0)
        self.assertEqual(receipt["requested_effort"], "high")
        self.assertEqual(receipt["config"]["sha256"], hashlib.sha256(config.read_bytes()).hexdigest())
        self.output.unlink()
        self.receipt.unlink()
        run, receipt = self.run_mode("success", "--model", "claude-opus-4-8", "--effort", "max")
        self.assertEqual(run.returncode, 0)
        self.assertEqual(receipt["model_assurance"], "exact-name")
        self.assertEqual(receipt["requested_effort"], "max")

    def test_disabled_provider_is_a_recorded_dropout(self):
        config = self.root / "disabled.json"
        config.write_text(json.dumps({"codex_providers": {"claude": {"enabled": False}}}))
        run, receipt = self.run_mode("success", "--config", str(config))
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "disabled")
        self.assertFalse(self.argv.exists())

    def test_cli_default_model_and_effort_do_not_claim_inheritance(self):
        run, receipt = self.run_mode("success", "--model", "default", "--effort", "default")
        self.assertEqual(run.returncode, 0)
        self.assertIsNone(receipt["requested_model"])
        self.assertIsNone(receipt["requested_effort"])
        self.assertEqual(receipt["model_assurance"], "reported-only")
        args = json.loads(self.argv.read_text())["argv"]
        self.assertNotIn("--model", args)
        self.assertNotIn("--effort", args)

    def test_context_artifacts_are_hashed_without_reading_outside_cwd(self):
        run, receipt = self.run_mode("success", "--context-file", self.prompt.name)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(receipt["context_artifacts"][0]["sha256"], receipt["prompt_sha256"])
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)
        self.output.unlink()
        self.receipt.unlink()
        self.argv.unlink()
        run, receipt = self.run_mode("success", "--context-file", str(__file__))
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "runner_error")
        self.assertFalse(self.argv.exists())

    def test_prompt_stdin_remains_literal(self):
        args = self.command()
        start = args.index("--prompt-file")
        args[start:start + 2] = ["--prompt-stdin"]
        run = subprocess.run(args, env=self.env, input="literal $HOME `no-shell`", text=True,
                             capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(json.loads(self.argv.read_text())["prompt"], "literal $HOME `no-shell`")

    def test_execution_timeout_is_opt_in(self):
        spec = importlib.util.spec_from_file_location("claude_review_runner", RUNNER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for extra, expected in [((), None), (("--timeout", "120"), 120.0)]:
            with self.subTest(extra=extra), patch.object(sys, "argv", self.command(*extra)[1:]), \
                    patch.object(module, "run", return_value=0) as dispatch:
                self.assertEqual(module.main(), 0)
                self.assertEqual(dispatch.call_args.args[0].timeout, expected)

    def test_auxiliary_usage_does_not_override_response_model(self):
        run, receipt = self.run_mode("auxiliary")
        self.assertEqual(run.returncode, 0)
        self.assertEqual(receipt["reported_models"], ["claude-opus-4-8"])
        self.assertEqual(receipt["usage_models"], ["claude-haiku-4-5-20251001", "claude-opus-4-8"])
        self.assertEqual(receipt["auxiliary_usage_models"], ["claude-haiku-4-5-20251001"])
        self.assertIn("claude-haiku-4-5-20251001", receipt["model_usage"])
        self.assertTrue(any(item["source"] == "result.modelUsage" and
                            item["model"] == "claude-haiku-4-5-20251001"
                            for item in receipt["model_evidence"]))

    def test_usage_only_is_not_response_model_evidence(self):
        run, receipt = self.run_mode("usageonly")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(receipt["status"], "unverified_model")
        self.assertEqual(receipt["reported_models"], [])


if __name__ == "__main__":
    unittest.main()
