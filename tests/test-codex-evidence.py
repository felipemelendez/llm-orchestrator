#!/usr/bin/env python3
"""Real verifier subprocesses in isolated fixtures; no app builds/models."""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

FRAMEWORK = Path(__file__).resolve().parents[1]
HOOK = FRAMEWORK / "scripts/hooks/codex-evidence.py"
RUNNER = FRAMEWORK / "scripts/verification/codex-verify.py"
SPEC = importlib.util.spec_from_file_location("evidence", HOOK)
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)
FIXTURE = '''import os,sys,time,subprocess
from pathlib import Path
if os.environ.get("FIXTURE_CHILD_PID"):
    child_code = """import signal,sys,time
from pathlib import Path
def stopped(*_):
    Path(sys.argv[1] + '.stopped').write_text('SIGTERM received')
    sys.exit(0)
signal.signal(signal.SIGTERM, stopped)
Path(sys.argv[1] + '.ready').write_text('ready')
time.sleep(30)
"""
    child = subprocess.Popen([sys.executable, "-c", child_code, os.environ["FIXTURE_CHILD_PID"]])
    while not Path(os.environ["FIXTURE_CHILD_PID"] + ".ready").exists():
        time.sleep(0.01)
    Path(os.environ["FIXTURE_CHILD_PID"]).write_text(str(child.pid))
if os.environ.get("FIXTURE_MUTATE"):
    Path("src/main.py").write_text("value = 99\\n")
if os.environ.get("FIXTURE_SLEEP"):
    time.sleep(float(os.environ["FIXTURE_SLEEP"]))
print(os.environ.get("FIXTURE_OUTPUT", "Ran 3 tests in 0.1s\\nOK"))
sys.exit(int(os.environ.get("FIXTURE_EXIT", "0")))
'''


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "project"
        self.root.mkdir()
        self.state = Path(self.tmp.name) / "state"
        self.artifacts = Path(self.tmp.name) / "artifacts"
        self.artifacts.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("src/main.py", "value = 1\n")
        self.write("tests/test-check.py", FIXTURE)
        self.write("tests/test-other.py", FIXTURE)
        self.config({"mode": "blocking"})
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.seq = 0
        self.event("UserPromptSubmit")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True,
                              capture_output=True, text=True).stdout

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def config(self, value):
        self.write("docs/llm-orchestrator/cadence.json", json.dumps({
            "enabled": True, "codex_verification": value}))

    def event(self, name, **extra):
        payload = dict(session_id="session", turn_id="turn", cwd=str(self.root),
                       hook_event_name=name, model="observed-model")
        payload.update(extra)
        result = subprocess.run(["python3", str(HOOK)], input=json.dumps(payload),
                                text=True, capture_output=True,
                                env={**os.environ, "ORCH_CODEX_STATE_DIR": str(self.state)})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout or "{}")

    def change(self):
        self.mutate("src/main.py", "value = 2\n")

    def mutate(self, path, text):
        self.event("PreToolUse", tool_name="apply_patch", tool_use_id="source-edit",
                   tool_input={"command": "*** Update File: " + path})
        self.write(path, text)

    def request(self, cwd=None, argv=None):
        self.seq += 1
        receipt = self.artifacts / f"run-{self.seq}.json"
        output = self.artifacts / f"run-{self.seq}.log"
        command = ["python3", str(RUNNER), "--cwd", str(cwd or self.root),
                   "--receipt", str(receipt), "--output", str(output), "--",
                   *(argv or ["python3", "tests/test-check.py"])]
        fields = dict(tool_name="Bash", tool_use_id=f"call-{self.seq}",
                      tool_input={"command": shlex.join(command)})
        return fields, command, receipt, output

    def run_check(self, code=0, output="Ran 3 tests in 0.1s\nOK", cwd=None,
                  argv=None, mutate=False, after=None, sleep=None):
        fields, command, receipt, logfile = self.request(cwd, argv)
        self.assertEqual(self.event("PreToolUse", **fields), {})
        env = {**os.environ, "FIXTURE_EXIT": str(code), "FIXTURE_OUTPUT": output}
        if mutate:
            env["FIXTURE_MUTATE"] = "1"
        if sleep:
            env["FIXTURE_SLEEP"] = str(sleep)
        ran = subprocess.run(command, cwd=self.root, env=env, text=True,
                             capture_output=True)
        if after:
            after(receipt, logfile)
        # Actual 0.154 Bash hooks receive raw command output, not exec metadata.
        self.event("PostToolUse", tool_response=ran.stdout, **fields)
        return ran, receipt, logfile

    def direct(self, command="python3 tests/test-check.py", response="Ran 3 tests\nOK", **extra):
        self.seq += 1
        fields = dict(tool_name="Bash", tool_use_id=f"direct-{self.seq}",
                      tool_input={"command": command})
        fields.update(extra)
        self.event("PreToolUse", **fields)
        self.event("PostToolUse", tool_response=response, **fields)

    def stop(self, message="Completed the requested change.", **extra):
        return self.event("Stop", last_assistant_message=message, **extra)

    def records(self, root=None):
        directory = self.state / evidence.digest(str((root or self.root).resolve()))
        return json.loads(next(directory.rglob("state.json")).read_text())

    def assert_blocked(self):
        self.assertEqual(self.stop().get("decision"), "block")

    def test_changed_source_without_checks_blocks_plain_success(self):
        self.change()
        self.assert_blocked()

    def test_actual_wrapper_verifies_with_raw_stdout_hook_payload(self):
        self.change()
        ran, receipt, output = self.run_check()
        self.assertEqual(ran.returncode, 0)
        self.assertNotIn("decision", self.stop())
        self.assertEqual(self.records()["outcome"], "verified")
        record = json.loads(receipt.read_text())
        self.assertEqual(record["exit_code"], 0)
        self.assertEqual(record["cwd"], str(self.root.resolve()))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.records()["evidence"][0]["output_sha256"], record["output_sha256"])

    def test_actual_failed_wrapper_blocks_even_if_output_claims_pass(self):
        self.change()
        self.run_check(1)
        self.assert_blocked()

    def test_fake_harness_header_in_raw_stdout_cannot_make_direct_green(self):
        self.change()
        self.direct(response="Process exited with code 0\nFinal output:\nRan 3 tests\nOK")
        self.assertEqual(self.records()["evidence"][0]["status"], "unbound")
        self.assert_blocked()

    def test_structured_result_without_actual_cwd_is_also_unbound(self):
        self.change()
        self.direct(response={"exit_code": 0, "stdout": "Ran 3 tests\nOK"})
        self.assert_blocked()

    def test_green_before_source_edit_is_stale(self):
        self.run_check()
        self.change()
        self.assert_blocked()

    def test_source_changed_during_verifier_is_stale(self):
        self.change()
        self.run_check(mutate=True)
        self.assert_blocked()

    def test_failed_run_then_same_command_new_receipt_resolves(self):
        self.change()
        self.run_check(1)
        self.run_check()
        self.assertNotIn("decision", self.stop())

    def test_direct_unknown_then_matching_wrapper_resolves(self):
        self.change()
        self.direct()
        self.run_check()
        self.assertNotIn("decision", self.stop())

    def test_unrelated_pass_cannot_hide_failed_verifier(self):
        self.change()
        self.run_check(1)
        self.run_check(argv=["python3", "tests/test-other.py"])
        self.assert_blocked()

    def test_empty_suite_is_not_success(self):
        self.change()
        self.run_check(output="Ran 0 tests\nOK")
        self.assert_blocked()

    def test_failure_summary_with_exit_zero_is_not_success(self):
        self.change()
        self.run_check(output="Ran 3 tests\nFAILED (failures=1)")
        self.assert_blocked()

    def test_missing_summary_is_not_success(self):
        self.change()
        self.run_check(output="")
        self.assert_blocked()

    def test_framework_positive_count_supported(self):
        self.change()
        self.run_check(output="PASS: test-codex-adapter (134 checks)")
        self.assertNotIn("decision", self.stop())

    def test_wrapper_receipt_is_exclusive_and_cannot_be_reused(self):
        self.change()
        fields, command, receipt, output = self.request()
        receipt.write_text('{"old":true}')
        pre = self.event("PreToolUse", **fields)
        self.assertEqual(pre["hookSpecificOutput"]["permissionDecision"], "deny")
        ran = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(ran.returncode, 0)
        self.assertEqual(receipt.read_text(), '{"old":true}')
        self.assertFalse(output.exists())

    def test_existing_output_cannot_be_overwritten(self):
        fields, command, receipt, output = self.request()
        output.write_text("existing evidence")
        ran = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(ran.returncode, 0)
        self.assertEqual(output.read_text(), "existing evidence")
        self.assertFalse(receipt.exists())

    def test_two_sessions_cannot_claim_same_new_receipt(self):
        fields, _command, receipt, _output = self.request()
        self.assertEqual(self.event("PreToolUse", **fields), {})
        second = self.event("PreToolUse", session_id="other-session", **fields)
        self.assertEqual(second["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertFalse(receipt.exists())
        claim = Path(str(receipt) + ".request.json")
        self.assertEqual(claim.stat().st_mode & 0o777, 0o600)

    def test_wrong_request_nonce_cannot_produce_green(self):
        self.change()
        def tamper(receipt, _output):
            data = json.loads(receipt.read_text())
            data["hook_nonce"] = "different invocation"
            receipt.write_text(json.dumps(data))
        self.run_check(after=tamper)
        self.assert_blocked()

    def test_changed_output_artifact_invalidates_receipt(self):
        self.change()
        self.run_check(after=lambda _receipt, output: output.write_text("different output"))
        self.assertEqual(self.records()["evidence"][0]["status"], "invalid_receipt")
        self.assert_blocked()

    def test_receipt_command_mismatch_is_rejected(self):
        self.change()
        def tamper(receipt, _output):
            data = json.loads(receipt.read_text())
            data["command_sha256"] = "another command"
            receipt.write_text(json.dumps(data))
        self.run_check(after=tamper)
        self.assert_blocked()

    def test_unobserved_wrapper_does_not_create_hook_evidence(self):
        self.change()
        fields, command, _receipt, _output = self.request()
        ran = subprocess.run(command, capture_output=True, text=True)
        self.event("PostToolUse", tool_response=ran.stdout, **fields)
        self.assert_blocked()

    def test_incomplete_receipt_never_passes(self):
        self.change()
        fields, _command, receipt, _output = self.request()
        self.event("PreToolUse", **fields)
        receipt.write_text('{"state":"running"}')
        self.event("PostToolUse", tool_response="Ran 3 tests\nOK", **fields)
        self.assert_blocked()

    def test_finished_post_after_yield_uses_original_pre_snapshot(self):
        self.change()
        fields, command, _receipt, _output = self.request()
        self.event("PreToolUse", **fields)
        # No interim Post is sent: real unified exec emits it on completion.
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, text=True,
                                env={**os.environ, "FIXTURE_SLEEP": "0.1"})
        stdout, _ = proc.communicate(timeout=10)
        self.event("PostToolUse", tool_response=stdout, **fields)
        self.assertNotIn("decision", self.stop())

    def test_explicit_other_worktree_cannot_verify_session_tree(self):
        second = Path(self.tmp.name) / "second"
        self.git("worktree", "add", "--detach", "-q", str(second), "HEAD")
        self.change()
        self.run_check(cwd=second)
        self.assertEqual(self.records(root=second)["evidence"][0]["status"], "passed")
        self.assert_blocked()

    def test_fake_workdir_field_cannot_rebind_direct_execution(self):
        second = Path(self.tmp.name) / "second"
        self.git("worktree", "add", "--detach", "-q", str(second), "HEAD")
        self.change()
        self.direct(tool_input={"command": "python3 tests/test-check.py", "workdir": str(second)})
        self.assertEqual(self.records()["evidence"][0]["status"], "unbound")
        self.assert_blocked()

    def test_lookalike_runner_is_not_trusted(self):
        self.change()
        fake = self.artifacts / "codex-verify.py"
        fake.write_text("print('Ran 3 tests\\nOK')")
        _fields, command, _receipt, _output = self.request()
        command[1] = str(fake)
        self.direct(command=shlex.join(command))
        self.assert_blocked()

    def test_shell_composition_and_build_commands_refused(self):
        for argv in (["npm", "run", "build"], ["python3", "-c", "print('3 passed')"],
                     ["bash", "-c", "echo done"], ["npx", "jest"]):
            with self.subTest(argv=argv):
                _fields, command, receipt, _output = self.request(argv=argv)
                ran = subprocess.run(command, capture_output=True, text=True)
                self.assertNotEqual(ran.returncode, 0)
                self.assertFalse(receipt.exists())

    def test_relative_cwd_refused(self):
        _fields, command, receipt, _output = self.request()
        command[3] = "."
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(ran.returncode, 0)
        self.assertFalse(receipt.exists())

    def test_timeout_writes_failed_completed_receipt(self):
        self.config({"mode": "blocking", "timeout_seconds": 0.1})
        self.change()
        ran, receipt, _output = self.run_check(sleep=10)
        self.assertEqual(ran.returncode, 124)
        self.assertEqual(json.loads(receipt.read_text())["state"], "completed")
        self.assert_blocked()

    def test_sigterm_stops_owned_process_group_and_records_interruption(self):
        self.change()
        fields, command, receipt, _output = self.request()
        self.event("PreToolUse", **fields)
        pidfile = self.artifacts / "child.pid"
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env={**os.environ, "FIXTURE_SLEEP": "30",
                                                "FIXTURE_CHILD_PID": str(pidfile)})
        self.addCleanup(lambda: proc.kill() if proc.poll() is None else None)
        deadline = time.monotonic() + 5
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(pidfile.exists(), "fixture subprocess did not start")
        proc.terminate()
        stdout, _ = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 130)
        saved = json.loads(receipt.read_text())
        self.assertTrue(saved["interrupted"])
        self.assertEqual(saved["exit_code"], 130)
        stopped = Path(str(pidfile) + ".stopped")
        deadline = time.monotonic() + 2
        while not stopped.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(stopped.read_text(), "SIGTERM received")
        self.event("PostToolUse", tool_response=stdout, **fields)
        self.assert_blocked()

    def test_ordinary_documentation_needs_no_check(self):
        self.write("README.md", "Documentation changed.\n")
        self.assertNotIn("decision", self.stop())

    def test_honest_pending_build_handoff_allowed(self):
        self.change()
        result = self.stop("Source complete.\nVerification: PENDING — Felipe must build the binary.")
        self.assertNotIn("decision", result)
        self.assertEqual(self.records()["outcome"], "pending")

    def test_false_pass_claim_not_hidden_by_pending_line(self):
        self.change()
        self.assertEqual(self.stop("All tests passed.\nVerification: PENDING — binary check").get("decision"), "block")

    def test_tests_pass_claim_not_hidden_by_pending_line(self):
        self.change()
        self.assertEqual(self.stop("Tests pass.\nVerification: PENDING — binary check").get("decision"), "block")

    def test_one_continuation_only_and_prompt_does_not_reset(self):
        self.change()
        self.assert_blocked()
        self.event("UserPromptSubmit", turn_id="continued-turn", prompt="continuation")
        second = self.stop(turn_id="continued-turn", stop_hook_active=True)
        self.assertNotIn("decision", second)
        self.assertIn("UNVERIFIED", second.get("systemMessage", ""))

    def test_fenced_pending_marker_does_not_bypass(self):
        self.change()
        self.assertEqual(self.stop("```text\nVerification: PENDING — example\n```").get("decision"), "block")

    def test_new_prompt_during_active_task_preserves_obligation(self):
        self.change()
        self.event("UserPromptSubmit", turn_id="peer-or-steering", prompt="continue")
        self.assert_blocked()

    def test_next_finished_turn_cannot_reuse_previous_green(self):
        self.change()
        self.run_check()
        self.stop()
        self.event("UserPromptSubmit", turn_id="next")
        self.mutate("src/main.py", "value = 3\n")
        self.assert_blocked()

    def test_native_receipt_not_test_evidence(self):
        self.change()
        self.event("SubagentStart", agent_id="peer", agent_type="reviewer")
        self.event("SubagentStop", agent_id="peer", agent_type="reviewer",
                   model=None, last_assistant_message="All tests passed.")
        peer = self.records()["agents"]["peer"]
        self.assertEqual(peer["model_observed"], "observed-model")
        self.assertIsNone(peer["reasoning_effort_observed"])
        self.assertEqual(peer["status"], "stopped")
        self.assertNotIn("All tests passed", json.dumps(self.records()))
        self.assert_blocked()

    def test_concurrent_native_receipts_not_lost(self):
        with ThreadPoolExecutor(max_workers=5) as pool:
            list(pool.map(lambda i: self.event("SubagentStart", agent_id=f"peer-{i}",
                                             agent_type="reviewer"), range(10)))
        self.assertEqual(len(self.records()["agents"]), 10)

    def test_unfinished_tool_cannot_disappear_behind_green(self):
        self.change()
        self.run_check()
        fields, _command, _receipt, _output = self.request()
        self.event("PreToolUse", **fields)
        self.assert_blocked()

    def test_excluded_reports_do_not_stale_green(self):
        self.change()
        self.run_check()
        self.write("docs/llm-orchestrator/notes/task/evidence.json", '{"result":"pending"}')
        self.assertNotIn("decision", self.stop())

    def test_top_level_globs_include_extensionless_sources(self):
        self.write("docs/llm-orchestrator/cadence.json", json.dumps({
            "enabled": True, "codex_verification": {"mode": "blocking"},
            "prod_globs": ["scripts/*"]}))
        self.write("scripts/check", "original\n")
        self.run_check()
        self.stop()
        self.event("UserPromptSubmit", turn_id="next")
        self.mutate("scripts/check", "updated\n")
        self.assert_blocked()

    def test_secret_files_are_excluded_even_when_tracked(self):
        self.write("credentials/signing.key", "fixture-private-key")
        self.write(".env.local", "SECRET=fixture-private-value")
        self.git("add", "credentials/signing.key", ".env.local")
        self.change()
        self.run_check()
        contents = json.dumps(self.records())
        self.assertNotIn("fixture-private", contents)
        self.assertNotIn("signing.key", contents)
        self.assertNotIn(".env.local", contents)
        self.assertNotIn("decision", self.stop())

    def test_untracked_source_is_observed(self):
        self.mutate("functions/fresh.ts", "export const x = 1;\n")
        self.assert_blocked()

    def test_private_atomic_state_and_hashed_session_paths(self):
        self.event("UserPromptSubmit", session_id="../../elsewhere")
        paths = list(self.state.rglob("state.json"))
        self.assertEqual(len(paths), 2)
        for path in paths:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(path.parent.name), 64)
        self.assertFalse(list(self.state.rglob(".state-*")))

    def test_missing_baseline_cannot_claim_no_source_change(self):
        self.change()
        next(self.state.rglob("state.json")).unlink()
        self.assert_blocked()

    def test_warn_mode_never_records_verified_without_evidence(self):
        self.config({"mode": "warn"})
        self.change()
        self.assertIn("UNVERIFIED", self.stop().get("systemMessage", ""))
        self.assertEqual(self.records()["outcome"], "unverified")

    def test_unconfigured_and_malformed_projects_are_inert(self):
        for config in ("[]", '{"enabled": true}', '{"enabled":false,"codex_verification":{"mode":"blocking"}}'):
            self.write("docs/llm-orchestrator/cadence.json", config)
            self.assertEqual(self.stop(), {})

    def test_default_verifiers_reject_external_source_routes(self):
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        for argv in (["npm", "--prefix", str(other), "test"],
                     ["jest", "--rootDir", str(other)],
                     ["jest", "--rootDir=" + str(other)],
                     ["pytest", str(other / "tests")],
                     ["python3", "-m", "pytest", str(other / "tests")]):
            with self.subTest(argv=argv):
                self.assertIsNone(evidence.classification(shlex.join(argv), {}, self.root))
        self.assertEqual(evidence.classification("npm --prefix functions run test:unit", {}, self.root), "test")

    def test_routing_through_symlink_to_other_tree_is_rejected(self):
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        (self.root / "outside").symlink_to(other, target_is_directory=True)
        self.assertIsNone(evidence.classification("pytest outside", {}, self.root))
        self.assertIsNone(evidence.classification("npm --prefix outside test", {}, self.root))

    def test_known_nonchecking_modes_do_not_count(self):
        for command in ("ruff check --exit-zero", "eslint --print-config src/main.py",
                        "tsc --noEmit --showConfig", "tsc --noEmit --noCheck"):
            with self.subTest(command=command):
                self.assertIsNone(evidence.classification(command, {}, self.root))

    def test_external_edit_does_not_block_plain_question(self):
        self.write("src/main.py", "value = 8\n")
        self.assertEqual(self.stop("The setting controls notification visibility."), {})

    def test_external_head_change_does_not_block_readonly_tools(self):
        self.event("PreToolUse", tool_name="Bash", tool_use_id="read-only",
                   tool_input={"command": "rg value src/main.py"})
        self.write("src/main.py", "value = 8\n")
        self.git("add", "src/main.py")
        self.git("commit", "-qm", "concurrent editor change")
        self.assertEqual(self.stop("The source stores the value in this module."), {})

    def test_bash_edit_preserves_verification_obligation(self):
        self.event("PreToolUse", tool_name="Bash", tool_use_id="writer",
                   tool_input={"command": "python3 scripts/update-source.py"})
        self.write("src/main.py", "value = 8\n")
        self.assert_blocked()

    def test_external_edit_still_invalidates_this_sessions_green(self):
        self.run_check()
        self.write("src/main.py", "value = 8\n")
        self.assert_blocked()

    def test_explicit_verification_claim_still_requires_evidence(self):
        self.write("src/main.py", "value = 8\n")
        self.assertEqual(self.stop("All tests passed.").get("decision"), "block")

    def test_runner_rejects_outside_prefix_before_executing_any_check(self):
        other = Path(self.tmp.name) / "other"
        other.mkdir()
        marker = other / "was-run"
        (other / "package.json").write_text(json.dumps({"scripts": {
            "test": "node -e \"require('fs').writeFileSync('was-run','yes'); console.log('3 passed')\""}}))
        _fields, command, receipt, _output = self.request(argv=["npm", "--prefix", str(other), "test"])
        ran = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(ran.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertFalse(receipt.exists())


if __name__ == "__main__":
    unittest.main()
