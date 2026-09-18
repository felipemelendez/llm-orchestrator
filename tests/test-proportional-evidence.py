#!/usr/bin/env python3
"""Shared completion contract exercised through real Codex and Claude adapters."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('legacy_fixture', ROOT / 'tests/test-codex-evidence.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ProportionalTests(fixture.EvidenceTests):
    # Use fixture helpers, not its intentionally legacy-specific assertions.
    def config(self, value):
        self.write('docs/llm-orchestrator/cadence.json', json.dumps({
            'enabled': True, 'workflow': 'proportional', 'codex_verification': value,
            'prod_globs': ['src/**', 'native/**'], 'test_globs': ['tests/**'],
            'verification_config_globs': ['check-config.json'],
            'verification_scopes': {'app': {'selectors': ['tests/test-check.py'],
                'inputs': ['src/**', 'tests/test-check.py', 'check-config.json']},
                'other': {'selectors': ['tests/test-other.py'], 'inputs': ['native/**', 'tests/test-other.py']}}}))

    def mutate(self, path, text):
        self.seq += 1
        fields = dict(tool_name='apply_patch', tool_use_id=f'source-edit-{self.seq}',
                      tool_input={'command': '*** Update File: ' + path})
        self.event('PreToolUse', **fields)
        self.write(path, text)
        self.event('PostToolUse', **fields)

    def assert_blocked(self):
        self.assertEqual(self.stop('Verification: PASS — current checks cover the changed source').get('decision'), 'block')

    def test_actual_wrapper_verifies_with_raw_stdout_hook_payload(self):
        self.change()
        ran, receipt, output = self.run_check()
        self.assertEqual(ran.returncode, 0)
        self.assertEqual(self.stop('Verification: PASS — observed wrapper execution'), {})
        self.assertEqual(self.records()['outcome'], 'verified')
        self.assertEqual(json.loads(receipt.read_text())['exit_code'], 0)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_prop_duplicate_write_start_keeps_first_baseline(self):
        fields = dict(tool_name='apply_patch', tool_use_id='duplicate-write',
                      tool_input={'command': '*** Update File: src/main.py'})
        self.event('PreToolUse', **fields)
        first = self.records()['mutations']['duplicate-write']
        self.write('src/main.py', 'value = 2\n')
        self.assertEqual(self.event('PreToolUse', **fields), {})
        self.assertEqual(self.records()['mutations']['duplicate-write'], first)
        self.event('PostToolUse', **fields)
        self.assertIn('src/main.py', self.records()['writes'])
        self.assertEqual(self.stop('Finished the edit.').get('decision'), 'block')

    def test_prop_duplicate_write_completion_survives_consumption(self):
        fields = dict(tool_name='apply_patch', tool_use_id='replayed-write',
                      tool_input={'command': '*** Update File: src/main.py'})
        self.event('PreToolUse', **fields)
        self.write('src/main.py', 'value = 2\n')
        self.event('PostToolUse', **fields)
        first = self.records()['writes']
        self.event('PostToolUse', **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.records()['writes'], first)
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — observed changed source'), {})
        self.event('PreToolUse', **fields)
        self.event('PostToolUse', **fields)
        self.assertFalse(self.records()['mutations'])
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.stop('This explains the finished change.'), {})
        self.event('PostToolUseFailure', tool_response={'exit_code': 7}, **fields)
        self.assertTrue(self.records()['uncertain'])
        self.run_check()
        self.assert_blocked()

    def test_prop_conflicting_write_identity_never_replaces_baseline(self):
        fields = dict(tool_name='apply_patch', tool_use_id='conflicting-write',
                      tool_input={'command': '*** Update File: src/main.py'})
        conflicting = dict(fields, tool_input={'command': '*** Update File: native/module.py'})
        self.event('PreToolUse', **fields)
        first = self.records()['mutations']['conflicting-write']
        self.write('src/main.py', 'value = 2\n')
        self.event('PreToolUse', **conflicting)
        self.assertEqual(self.records()['mutations']['conflicting-write'], first)
        self.event('PostToolUse', **conflicting)
        self.event('PostToolUse', **fields)
        self.assertTrue(self.records()['uncertain'])
        self.run_check()
        self.assert_blocked()

    def actual_check_fields(self):
        if isinstance(self, ClaudeTests):
            self.seq += 1
            return (dict(tool_name='Bash', tool_use_id=f'replay-check-{self.seq}',
                         tool_input={'command': 'python3 tests/test-check.py'}),
                    ['python3', 'tests/test-check.py'])
        fields, command, _receipt, _output = self.request()
        return fields, command

    def observed_check_response(self, ran):
        if isinstance(self, ClaudeTests):
            return {'stdout': ran.stdout, 'stderr': ran.stderr, 'exit_code': ran.returncode}
        return ran.stdout

    def test_prop_duplicate_check_start_cannot_rebind_paused_verifier(self):
        ready, release = self.artifacts / 'check-ready', self.artifacts / 'check-release'
        self.write('tests/test-check.py', "import os,time\nfrom pathlib import Path\n"
            "assert Path('src/main.py').read_text() == 'value = 1\\n'\n"
            "Path(os.environ['CHECK_READY']).write_text('asserted original source')\n"
            "while not Path(os.environ['CHECK_RELEASE']).exists(): time.sleep(0.01)\n"
            "print('Ran 1 test')\n")
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        first = self.records()['pending'][fields['tool_use_id']]
        proc = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env={**os.environ, 'CHECK_READY': str(ready), 'CHECK_RELEASE': str(release)})
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), 'verifier did not assert original source')
            self.write('src/main.py', 'value = 2\n')
            self.assertEqual(self.event('PreToolUse', **fields), {})
            self.assertEqual(self.records()['pending'][fields['tool_use_id']], first)
            release.write_text('finish')
            stdout, stderr = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, stderr)
            ran = subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
            self.event('PostToolUse', tool_response=self.observed_check_response(ran), **fields)
            self.assert_blocked()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def paused_check_case(self, metadata, contended):
        import fcntl
        ready, release = self.artifacts / 'paused-ready', self.artifacts / 'paused-release'
        self.write('tests/test-check.py', "import os,sys,time\nfrom pathlib import Path\n"
            "print('Ran 1 test', flush=True)\n"
            "if os.environ.get('PAUSED_RELEASE'):\n"
            " Path(os.environ['PAUSED_READY']).write_text('running')\n"
            " while not Path(os.environ['PAUSED_RELEASE']).exists(): time.sleep(.01)\n"
            " sys.exit(7)\n")
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        proc = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env={**os.environ, 'PAUSED_READY': str(ready), 'PAUSED_RELEASE': str(release)})
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            if isinstance(self, ClaudeTests):
                early = proc.stdout.readline()
            else:
                request = fixture.evidence.wrapper_request(fields['tool_input']['command'])
                early = Path(request['output']).read_text()
            self.assertEqual(early, 'Ran 1 test\n')
            self.assertIsNone(proc.poll())
            response = dict(metadata, stdout=early)
            state_path = next(self.state.rglob('state.json'))
            if contended:
                with (state_path.parent / 'lock').open('a+') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.event('PostToolUse', tool_response=response, **fields)
            else:
                self.event('PostToolUse', tool_response=response, **fields)
            ran, _receipt, _output = self.run_check()
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.stop('Verification: PASS — newer matching invocation completed')
            self.assertIsNone(proc.poll())
            self.assertIn(fields['tool_use_id'], self.records()['pending'])
            self.assertNotEqual(self.records()['outcome'], 'verified')
            release.write_text('finish with the actual failure')
            stdout, stderr = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 7, stderr)
            if isinstance(self, ClaudeTests):
                stdout = early + stdout
            completed = subprocess.CompletedProcess(command, proc.returncode, stdout, stderr)
            self.event('PostToolUseFailure', tool_response=self.observed_check_response(completed), **fields)
            failed = next(record for record in self.records()['evidence'] if record['tool_use_id'] == fields['tool_use_id'])
            self.assertEqual((failed['status'], failed['exit_code']), ('failed', 7))
            self.stop('Verification: PASS — earlier overlapping green cannot erase this failure')
            self.assertNotEqual(self.records()['outcome'], 'verified')
            ran, _receipt, _output = self.run_check()
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertEqual(self.stop('Verification: PASS — matching check began after the failure'), {})
        finally:
            release.write_text('release fixture process')
            if proc.poll() is None:
                proc.communicate(timeout=5)

    def test_prop_running_check_stays_pending_through_overlapping_green(self):
        self.paused_check_case({'session_id': 712, 'status': 'running'}, False)

    def test_prop_deferred_running_check_stays_pending_through_overlapping_green(self):
        self.paused_check_case({'session_id': 712, 'status': 'running'}, True)

    def test_prop_background_check_stays_pending_without_numeric_process_id(self):
        self.paused_check_case({'backgroundTaskId': 'task-871'}, False)

    def test_prop_deferred_background_check_stays_pending_without_numeric_process_id(self):
        self.paused_check_case({'backgroundTaskId': 'task-871'}, True)

    def test_prop_completed_check_replay_survives_pruning_and_detects_conflict(self):
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        response = self.observed_check_response(ran)
        self.event('PostToolUse', tool_response=response, **fields)
        self.run_check()  # Same command has a newer invocation; old evidence is pruned at PASS.
        self.assertEqual(self.stop('Verification: PASS — observed checks'), {})
        self.assertNotIn(fields['tool_use_id'], [r['tool_use_id'] for r in self.records()['evidence']])
        self.event('PreToolUse', **fields)
        self.event('PostToolUse', tool_response=response, **fields)
        self.assertFalse(self.records()['pending'])
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.stop('Verification: PASS — same observed checks'), {})
        self.event('PostToolUseFailure', tool_response={'stdout': 'failed after prior result', 'exit_code': 9}, **fields)
        self.assertTrue(self.records()['uncertain'])
        self.assertNotEqual(self.stop('Verification: PASS — conflicting result').get('decision'), None)
        self.assertNotEqual(self.records()['outcome'], 'verified')

    def test_prop_failed_check_replay_cannot_replace_failure_with_success(self):
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True,
                             env={**os.environ, 'FIXTURE_EXIT': '7'})
        self.assertEqual(ran.returncode, 7, ran.stderr)
        self.event('PostToolUseFailure', tool_response=self.observed_check_response(ran), **fields)
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.event('PostToolUse', tool_response={'stdout': 'Ran 3 tests', 'exit_code': 0}, **fields)
        self.assertTrue(self.records()['uncertain'])
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.assert_blocked()

    def test_prop_conflicting_check_start_keeps_original_binding(self):
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        first = self.records()['pending'][fields['tool_use_id']]
        alternate, _alternate_command = self.actual_check_fields()
        alternate['tool_use_id'] = fields['tool_use_id']
        if isinstance(self, ClaudeTests):
            alternate['tool_input'] = {'command': 'python3 tests/test-other.py'}
        self.event('PreToolUse', **alternate)
        self.assertEqual(self.records()['pending'][fields['tool_use_id']], first)
        self.assertTrue(self.records()['uncertain'])
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response=self.observed_check_response(ran), **fields)
        self.assert_blocked()

    def test_prop_late_original_failure_post_preserves_reserved_result(self):
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True,
                             env={**os.environ, 'FIXTURE_EXIT': '7'})
        self.assertEqual(ran.returncode, 7, ran.stderr)
        self.stop('Verification: PENDING — original check needs attention')
        self.event('PostToolUseFailure', tool_response=self.observed_check_response(ran), **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.assert_blocked()

    def test_prop_contended_readonly_observation_does_not_poison_session(self):
        import fcntl
        fields = dict(tool_name='Bash', tool_use_id='contended-cat', tool_input={
            'command': 'cat src/main.py', 'workdir': str(self.root)})
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            result = self.event('PreToolUse', **fields)
            self.assertLess(time.monotonic() - started, 2)
            self.assertNotEqual(result.get('decision'), 'block')
            self.assertNotEqual(result.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
            queued = list(state_path.parent.glob('deferred-*.json'))
            self.assertTrue(queued)
            self.assertNotIn('cat src/main.py', ''.join(p.read_text() for p in queued))
        ran = subprocess.run(['cat', 'src/main.py'], cwd=self.root, capture_output=True, text=True)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertFalse(list(state_path.parent.glob('deferred-*.json')))
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.stop('The source contains one value.'), {})

    def test_prop_contended_source_start_never_invents_baseline(self):
        import fcntl
        fields = dict(tool_name='apply_patch', tool_use_id='contended-source',
                      tool_input={'command': '*** Update File: src/main.py'})
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PreToolUse', **fields)
        self.write('src/main.py', 'value = 2\n')
        self.event('PostToolUse', **fields)
        self.assertTrue(self.records()['uncertain'])
        self.assertNotIn('concurrent-hook', self.records()['uncertain'])
        self.run_check()
        self.assert_blocked()

    def test_prop_contended_failed_completion_recovers_exact_exit(self):
        import fcntl
        fields, command = self.actual_check_fields()
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True,
                             env={**os.environ, 'FIXTURE_EXIT': '7'})
        self.assertEqual(ran.returncode, 7, ran.stderr)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PostToolUseFailure', tool_response=self.observed_check_response(ran), **fields)
        self.event('UserPromptSubmit', turn_id='recover-contention')
        self.assertFalse(self.records()['pending'])
        self.assertEqual(self.records()['evidence'][-1]['exit_code'], 7)
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — matching real check recovered'), {})

    def test_codex_runner_setup_failure_does_not_leave_immortal_pending(self):
        fields, command, receipt, _output = self.request()
        blocked_parent = self.artifacts / 'ordinary-file'
        blocked_parent.write_text('not a directory')
        command[command.index('--output') + 1] = str(blocked_parent / 'check.log')
        fields['tool_input']['command'] = shlex.join(command)
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 2, ran.stderr)
        self.event('PostToolUseFailure', tool_response=ran.stdout, **fields)
        saved = json.loads(receipt.read_text())
        self.assertEqual(saved['state'], 'completed')
        self.assertTrue(saved['setup_failure'])
        self.assertFalse(self.records()['pending'])
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — fresh retry actually ran'), {})

    def test_prop_sed_readonly_addresses_are_structural(self):
        api = fixture.evidence
        for program in ('/value/,/end/p', '/value/p', '1,/end/p', '/value/,$p', r'/va\/lue/p', '/handleAuth/,/^}/p'):
            command = shlex.join(['sed', '-n', program, 'src/main.py'])
            self.assertFalse(api.potentially_mutating({'tool_name': 'Bash'}, command), program)
            fields = dict(tool_name='Bash', tool_use_id='sed-read-' + str(self.seq),
                          tool_input={'command': command, 'workdir': str(self.root)})
            self.seq += 1
            self.event('PreToolUse', **fields)
            ran = subprocess.run(shlex.split(command), cwd=self.root, capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': 0}, **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.stop('Read-only source inspection finished.'), {})
        for command in ("sed -n '/value/w src/main.py' input.txt", "sed '/value/e' input.txt",
                        "sed -f commands.sed input.txt", "sed 's/value/new/e' input.txt"):
            self.assertTrue(api.potentially_mutating({'tool_name': 'Bash'}, command))

    def test_prop_pending_review_reuses_prior_content_bound_success(self):
        self.change()
        self.run_check()
        self.stop('Verification: PENDING — independent review remains')
        self.event('UserPromptSubmit', turn_id='review-returned')
        self.assertEqual(self.stop('Verification: PASS — unchanged source checks and review complete'), {})
        self.assertNotIn('required_validation', self.records())

    def test_prop_external_source_operand_does_not_belong_to_current_tree(self):
        external = self.artifacts / 'probe.py'
        fields = dict(tool_name='apply_patch', tool_use_id='external-edit',
                      tool_input={'command': '*** Add File: ' + str(external)})
        self.event('PreToolUse', **fields)
        external.write_text('value = 5\n')
        self.event('PostToolUse', **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertEqual(self.stop('External probe prepared.'), {})
        # Moving an external file into this tree still has an inside operand.
        moved = dict(tool_name='Bash', tool_use_id='mixed-move', tool_input={
            'command': shlex.join(['mv', str(external), 'src/main.py']), 'workdir': str(self.root)})
        self.event('PreToolUse', **moved)
        ran = subprocess.run(shlex.split(moved['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': 0}, **moved)
        self.assertIn('src/main.py', self.records()['writes'])
        self.assert_blocked()

    def test_prop_dependency_lock_inputs_do_not_match_source_words(self):
        self.write('native/module.py', 'value = 1\n')
        self.write('src/BlockedUsers.tsx', 'old source\n')
        self.write('yarn.lock', '# original lock\n')
        self.run_check(argv=['python3', 'tests/test-other.py'])
        self.write('src/BlockedUsers.tsx', 'new source\n')
        self.assertEqual(self.stop('Verification: PASS — unchanged native scope'), {})
        self.write('yarn.lock', '# modified lock\n')
        self.assert_blocked()

    def test_prop_live_fifo_copy_raw_output_never_proves_completion(self):
        fifo = self.root / 'input.fifo'
        os.mkfifo(fifo)
        fields = dict(tool_name='Bash', tool_use_id='live-copy', tool_input={
            'command': 'cp input.fifo src/main.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        proc = subprocess.Popen(['cp', 'input.fifo', 'src/main.py'], cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.event('PostToolUse', tool_response='', **fields)
            self.assertIsNone(proc.poll())
            self.run_check()
            self.assert_blocked()
            with fifo.open('w') as stream:
                stream.write('value = 777\n')
            stdout, stderr = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, stderr)
            self.event('PostToolUse', tool_response={'stdout': stdout, 'exit_code': 0}, **fields)
            self.assertIn('src/main.py', self.records()['writes'])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_prop_deferred_drain_is_bounded_and_commits_once(self):
        api = fixture.evidence
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        directory = self.artifacts / 'deferred-state'
        directory.mkdir()
        for index in range(300):
            api.proportional.defer_event(directory, {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                'tool_use_id': f'read-{index}', 'session_id': 'session', 'tool_input': {'command': 'cat src/main.py'}},
                self.root.resolve(), config, config['codex_verification'], self.root.resolve(), api,
                'claude' if isinstance(self, ClaudeTests) else 'codex', 1000 + index, 1000 + index)
        state, reads, commits = {}, [], []
        original_read = Path.read_text
        def read(path, *args, **kwargs):
            if path.name.startswith('deferred-'):
                reads.append(path)
            return original_read(path, *args, **kwargs)
        with patch.object(Path, 'read_text', read), \
                patch.object(api.proportional, 'file_digest', side_effect=AssertionError('deferred drain read source')), \
                patch.object(api.proportional, 'snapshot', side_effect=AssertionError('deferred drain recreated a baseline')):
            api.proportional.drain_deferred(directory, state, self.root.resolve(), api, lambda: commits.append(True))
            self.memory_stop(state, 'Ordinary discussion after queued observations.')
        self.assertLessEqual(len(reads), 128)
        self.assertEqual(len(commits), 1)
        self.assertGreater(len(reads), 0)
        self.assertTrue(state['deferred_pending'])
        self.assertFalse(state['uncertain'])
        self.assertEqual([v['order'] for v in state['deferred_consumed'].values()], list(range(1000, 1000 + len(reads))))

    def test_prop_deferred_commit_before_unlink_replays_without_effect(self):
        api = fixture.evidence
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        directory = self.artifacts / 'crash-deferred-state'
        directory.mkdir()
        payload = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_use_id': 'once',
                   'session_id': 'session', 'tool_input': {'command': 'cat src/main.py'}}
        api.proportional.defer_event(directory, payload, self.root.resolve(), config, config['codex_verification'],
            self.root.resolve(), api, 'codex', 1234, 1234)
        state = {}
        def interrupted_commit():
            api.save_state(directory, state)
            raise RuntimeError('fixture crash after durable commit')
        with self.assertRaises(RuntimeError):
            api.proportional.drain_deferred(directory, state, self.root.resolve(), api, interrupted_commit)
        self.assertEqual(len(list(directory.glob('deferred-*.json'))), 1)
        restored = json.loads((directory / 'state.json').read_text())
        before = dict(restored['observations'])
        with patch.object(api.proportional, 'apply_deferred', side_effect=AssertionError('consumed fact replayed')):
            api.proportional.drain_deferred(directory, restored, self.root.resolve(), api,
                                           lambda: api.save_state(directory, restored))
        self.assertFalse(list(directory.glob('deferred-*.json')))
        self.assertEqual(restored['observations'], before)
        self.assertFalse(restored['uncertain'])

    def test_prop_contended_running_write_keeps_late_target_binding(self):
        import fcntl
        self.write('input.txt', 'value = 77\n')
        fields = dict(tool_name='Bash', tool_use_id='queued-running-write', tool_input={
            'command': "sed -n 'w src/main.py' input.txt", 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PostToolUse', tool_response={'session_id': 842, 'status': 'running'}, **fields)
        self.stop('Verification: PENDING — write process is running')
        self.assertEqual(self.records()['mutations']['queued-running-write']['process_id'], 842)
        ran = subprocess.run(shlex.split(fields['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_name='write_stdin', tool_use_id='queued-running-poll',
            tool_input={'session_id': 842}, tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode})
        self.assertIn('src/main.py', self.records()['writes'])
        self.assertFalse(self.records()['mutations'])
        self.assert_blocked()

    def test_prop_deferred_known_completion_requires_post_terminal_check(self):
        import fcntl
        fields = dict(tool_name='apply_patch', tool_use_id='queued-completed-edit',
                      tool_input={'command': '*** Update File: src/main.py'})
        self.event('PreToolUse', **fields)
        self.write('src/main.py', 'value = 88\n')
        ran, _receipt, _output = self.run_check()
        self.assertEqual(ran.returncode, 0)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PostToolUse', **fields)
        state, api = json.loads(state_path.read_text()), fixture.evidence
        with patch.object(api.proportional, 'snapshot', side_effect=AssertionError('terminal drain scanned source')), \
                patch.object(api.proportional, 'file_digest', side_effect=AssertionError('terminal drain read source')):
            api.proportional.drain_deferred(state_path.parent, state, self.root.resolve(), api,
                lambda: api.save_state(state_path.parent, state))
            self.memory_stop(state, 'Ordinary discussion after the completed edit.')
        self.assertFalse(state['mutations'])
        self.assertFalse(state['uncertain'])
        self.assertIn('src/main.py', state['writes'])
        self.assertIsNotNone(state['writes']['src/main.py']['content'])
        self.mutate('src/main.py', 'value = 89\n')
        self.mutate('src/main.py', 'value = 88\n')  # Restoring checked contents retains the terminal boundary.
        self.stop('Verification: PASS — earlier green observed these same contents')
        self.assertNotEqual(self.records()['outcome'], 'verified')
        self.stop('Verification: NOT APPLICABLE — no additional source changes')
        self.assertIn('src/main.py', self.records()['writes'])
        self.event('PostToolUse', **fields)  # Exact terminal replay cannot add a missing-start gap.
        self.assertFalse(self.records()['uncertain'])
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — actual check began after completed edit observation'), {})
        self.event('PostToolUse', **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertFalse(self.records()['writes'])

    def test_prop_deferred_terminal_poll_closes_only_matching_known_writer(self):
        import fcntl
        fifo = self.root / 'deferred-input.fifo'
        os.mkfifo(fifo)
        fields = dict(tool_name='Bash', tool_use_id='deferred-fifo-writer', tool_input={
            'command': 'cp deferred-input.fifo src/main.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        proc = subprocess.Popen(['cp', 'deferred-input.fifo', 'src/main.py'], cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.event('PostToolUse', tool_response={'session_id': 712, 'status': 'running'}, **fields)
            self.assertIsNone(proc.poll())
            with fifo.open('w') as stream:
                stream.write('value = 777\n')
            stdout, stderr = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, stderr)
            poll = dict(tool_name='write_stdin', tool_use_id='deferred-terminal-poll',
                        tool_input={'session_id': 712}, tool_response={'stdout': stdout, 'exit_code': proc.returncode})
            state_path = next(self.state.rglob('state.json'))
            with (state_path.parent / 'lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.event('PostToolUse', **poll)
            self.event('UserPromptSubmit', turn_id='after-terminal-poll')
            self.assertFalse(self.records()['mutations'])
            self.assertFalse(self.records()['uncertain'])
            self.assertIn('src/main.py', self.records()['writes'])
            self.event('PostToolUse', **poll)
            self.assertFalse(self.records()['uncertain'])
            self.run_check()
            self.assertEqual(self.stop('Verification: PASS — actual check after exact terminal poll'), {})
            self.event('PostToolUse', **poll)
            self.assertFalse(self.records()['writes'])
            self.assertFalse(self.records()['uncertain'])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_prop_deferred_raw_writer_output_needs_exact_terminal_evidence(self):
        import fcntl
        self.write('input.txt', 'value = 909\n')
        fields = dict(tool_name='Bash', tool_use_id='deferred-raw-writer', tool_input={
            'command': "sed -n 'w src/main.py' input.txt", 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(shlex.split(fields['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PostToolUse', tool_response=ran.stdout, **fields)
        self.run_check()
        self.stop('Verification: PASS — later check cannot prove writer completion')
        self.assertIn(fields['tool_use_id'], self.records()['mutations'])
        self.assertNotEqual(self.records()['outcome'], 'verified')
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertFalse(self.records()['mutations'])
        self.assertFalse(self.records()['uncertain'])

    def test_prop_deferred_readonly_conflicting_identity_stays_uncertain(self):
        import fcntl
        fields = dict(tool_name='apply_patch', tool_use_id='queued-conflict',
                      tool_input={'command': '*** Update File: src/main.py'})
        self.event('PreToolUse', **fields)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.event('PreToolUse', tool_name='Bash', tool_use_id='queued-conflict',
                       tool_input={'command': 'cat src/main.py'})
        self.event('UserPromptSubmit')
        self.assertIn('conflict:queued-conflict', self.records()['uncertain'])
        self.assertIn('queued-conflict', self.records()['mutations'])

    def test_codex_runner_invalid_timeout_publishes_bound_nonstart(self):
        self.config({'mode': 'blocking', 'timeout_seconds': 0})
        ran, receipt, _output = self.run_check()
        self.assertEqual(ran.returncode, 2)
        saved = json.loads(receipt.read_text())
        self.assertTrue(saved['setup_failure'])
        self.assertFalse(saved['child_started'])
        self.assertFalse(self.records()['pending'])
        self.assertEqual(self.records()['evidence'][-1]['status'], 'failed')
        self.config({'mode': 'blocking'})
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — valid fresh retry executed'), {})

    def memory_stop(self, state, message):
        api = fixture.evidence
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        return api.proportional.handle(state, {'hook_event_name': 'Stop', 'session_id': 'session',
            'last_assistant_message': message}, self.root.resolve(), config,
            config['codex_verification'], self.root.resolve(), api,
            harness='claude' if isinstance(self, ClaudeTests) else 'codex')

    def test_prop_long_session_stops_without_source_reads(self):
        import copy
        for i in range(2400):
            self.write(f'src/group{i % 4}/input{i}.py', f'value = {i}\n')
        self.change()
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — initial valid check'), {})
        state = self.records()
        sample = state['evidence'][0]
        for i, status in enumerate(['unbound', 'failed', 'interrupted', 'empty', 'missing_start', 'passed'] * 6):
            record = dict(sample, status=status, command_sha256=str(i), consumed=False,
                          fingerprint_error='binding unavailable' if status == 'passed' else None)
            state['evidence'].append(record)
        state['mutations']['running-writer'] = {'tool': 'Bash', 'at': 1,
            'before': {'src/main.py': 'original'}, 'process_id': 8}
        state['writes']['src/main.py'] = {'at': 1, 'content': 'unverified'}
        for message in ('Discussion continues.', 'Verification: PENDING — tests unavailable',
                        'Verification: BLOCKED — required device unavailable'):
            current = copy.deepcopy(state)
            with patch.object(fixture.evidence.proportional, 'file_digest', side_effect=AssertionError('source read on no-scan stop')) as reads, \
                    patch.object(fixture.evidence, 'git', side_effect=AssertionError('candidate scan on no-scan stop')):
                self.memory_stop(current, message)
            self.assertEqual(reads.call_count, 0)
            self.assertNotEqual(current['outcome'], 'verified')
            self.assertEqual(current['mutations'], state['mutations'])
            self.assertEqual(current['writes'], state['writes'])
            self.assertEqual(current['evidence'], state['evidence'])
        # An explicit passing assertion with only unusable old checks also
        # cannot justify rescanning thousands of known irrelevant inputs.
        state['evidence'] = state['evidence'][1:]
        with patch.object(fixture.evidence.proportional, 'file_digest', side_effect=AssertionError('unusable record scanned')):
            self.memory_stop(state, 'Verification: PASS — unsupported assertion')
        self.assertNotEqual(state['outcome'], 'verified')

    def test_prop_overlapping_checks_share_reads_only_inside_one_pass(self):
        for i in range(2400):
            self.write(f'src/group{i % 4}/input{i}.py', f'value = {i}\n')
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        config['verification_scopes']['other']['inputs'] = ['src/group0/**', 'tests/test-other.py']
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(config))
        for i in range(12):
            self.run_check(argv=['python3', 'tests/test-check.py' if i % 2 else 'tests/test-other.py', '--case', str(i)])
        state = self.records()
        api, reads, enumerations = fixture.evidence, [], []
        original_digest, original_git = api.proportional.file_digest, api.git
        def counted_digest(path, imported_api):
            reads.append(path)
            return original_digest(path, imported_api)
        def counted_git(root, *args):
            if args[0] == 'ls-files':
                enumerations.append(args)
            return original_git(root, *args)
        with patch.object(api.proportional, 'file_digest', side_effect=counted_digest), patch.object(api, 'git', side_effect=counted_git):
            self.assertEqual(self.memory_stop(state, 'Verification: PASS — twelve observed overlapping checks'), {})
        self.assertEqual(len(enumerations), 1)
        self.assertEqual(len(reads), len(set(reads)))
        self.assertGreater(len(reads), 2400)
        # Keep size and timestamps identical; a later invocation must reread
        # actual contents rather than reuse this event's digest cache.
        changed = self.root / 'src/group0/input0.py'
        info = changed.stat()
        changed.write_text('value = 9\n')
        os.utime(changed, ns=(info.st_atime_ns, info.st_mtime_ns))
        reads.clear()
        with patch.object(api.proportional, 'file_digest', side_effect=counted_digest):
            result = self.memory_stop(state, 'Verification: PASS — prior observed checks')
        self.assertEqual(result.get('decision'), 'block')
        self.assertGreater(len(reads), 2400)
        self.assertNotEqual(state['outcome'], 'verified')

    def test_prop_delayed_known_write_requires_matching_terminal_observation(self):
        fields = dict(tool_name='Bash', tool_use_id='delayed-sed', tool_input={
            'command': "sed -n 'w src/main.py' input.txt", 'workdir': str(self.root)})
        self.write('input.txt', 'value = 77\n')
        self.event('PreToolUse', **fields)
        self.event('PostToolUse', tool_response={'session_id': 712, 'status': 'running'}, **fields)
        self.assertIn('delayed-sed', self.records()['mutations'])
        self.stop('Verification: PENDING — source writer is running')
        ran = subprocess.run(shlex.split(fields['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_name='write_stdin', tool_use_id='wrong-poll',
            tool_input={'session_id': 999}, tool_response={'exit_code': 0, 'stdout': ran.stdout})
        self.assertIn('delayed-sed', self.records()['mutations'])
        self.event('PostToolUse', tool_name='write_stdin', tool_use_id='actual-poll',
            tool_input={'session_id': 712}, tool_response={'exit_code': ran.returncode, 'stdout': ran.stdout})
        self.assertFalse(self.records()['mutations'])
        self.assertIn('src/main.py', self.records()['writes'])
        self.assert_blocked()

    def test_prop_sed_output_and_unknown_forms_preserve_obligations(self):
        api = fixture.evidence
        self.write('input.txt', 'value = 77\n')
        for index, program in enumerate(("w src/main.py", "s/77/88/w src/main.py")):
            fields = dict(tool_name='Bash', tool_use_id=f'sed-output-{index}', tool_input={
                'command': shlex.join(['sed', '-n', '-e', program, 'input.txt']), 'workdir': str(self.root)})
            self.event('PreToolUse', **fields)
            self.assertIn('src/main.py', self.records()['mutations'][fields['tool_use_id']]['before'])
            ran = subprocess.run(shlex.split(fields['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertIn('src/main.py', self.records()['writes'])
        for command in ("sed -f writer.sed input.txt", "sed -n '1w src/main.py;2w native/other.py' input.txt"):
            self.assertTrue(api.potentially_mutating({'tool_name': 'Bash'}, command))
            targets, unknown = api.proportional.write_targets({'tool_name': 'Bash', 'cwd': str(self.root),
                'tool_input': {'command': command, 'workdir': str(self.root)}}, self.root, api, 'codex')
            self.assertTrue(unknown)
        self.assertFalse(api.potentially_mutating({'tool_name': 'Bash'}, "sed -n '1,20p' src/main.py"))
        self.assert_blocked()

    def test_prop_custom_globstar_source_write_is_observed(self):
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        config['prod_globs'] += ['assets/**/*.storekit']
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(config))
        self.write('assets/catalog.storekit', 'old')
        self.write('scripts/write-asset.py', "from pathlib import Path\nPath('assets/catalog.storekit').write_text('new')\n")
        fields = dict(tool_name='Bash', tool_use_id='asset-script', tool_input={
            'command': 'python3 scripts/write-asset.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(shlex.split(fields['tool_input']['command']), cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'exit_code': ran.returncode, 'stdout': ran.stdout}, **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertIn('assets/catalog.storekit', self.records()['writes'])
        self.assert_blocked()

    def test_codex_direct_checks_never_fingerprint_either_boundary(self):
        api, state = fixture.evidence, {}
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        with patch.object(api.proportional, 'snapshot', side_effect=AssertionError('unbound check fingerprinted')):
            for i in range(32):
                fields = dict(tool_name='Bash', tool_use_id=f'unbound-{i}', session_id='session',
                    tool_input={'command': f'python3 tests/test-check.py --case {i}'})
                api.proportional.handle(state, dict(fields, hook_event_name='PreToolUse'), self.root.resolve(), config,
                    config['codex_verification'], self.root.resolve(), api)
                api.proportional.handle(state, dict(fields, hook_event_name='PostToolUse',
                    tool_response={'exit_code': 0, 'stdout': 'Ran 3 tests'}), self.root.resolve(), config,
                    config['codex_verification'], self.root.resolve(), api)
        self.assertEqual(len(state['evidence']), 32)
        self.assertEqual({r['status'] for r in state['evidence']}, {'unbound'})
        self.assertTrue(all(r['before_fingerprint'] is None and r['after_fingerprint'] is None for r in state['evidence']))

    def test_codex_yielded_wrapper_recovers_completed_receipt_once(self):
        release = self.artifacts / 'release-check'
        self.write('tests/test-check.py', fixture.FIXTURE + "\nif os.environ.get('FIXTURE_WAIT'):\n    while not Path(os.environ['FIXTURE_WAIT']).exists():\n        time.sleep(0.01)\n")
        # Wait before the fixture's final sys.exit, not after it.
        script = self.root / 'tests/test-check.py'
        script.write_text(script.read_text().replace('sys.exit(int(os.environ.get("FIXTURE_EXIT", "0")))', ''))
        fields, command, receipt, _output = self.request()
        self.event('PreToolUse', **fields)
        proc = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, 'FIXTURE_WAIT': str(release)})
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if receipt.exists() and json.loads(receipt.read_text()).get('state') == 'running':
                    break
                time.sleep(0.01)
            else:
                self.fail('runner did not publish a running receipt')
            self.event('PostToolUse', tool_response={'session_id': 702, 'status': 'running'}, **fields)
            self.assertIn(fields['tool_use_id'], self.records()['pending'])
            self.stop('Verification: PENDING — verification process is running')
            self.run_check()
            self.assertEqual(self.stop('Verification: PASS — newer matching check completed').get('decision'), 'block')
            self.assertIn(fields['tool_use_id'], self.records()['pending'])
            release.write_text('finish the original invocation')
            stdout, stderr = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, stderr)
            self.event('PostToolUse', tool_name='write_stdin', tool_use_id='poll-completion',
                tool_input={'session_id': 702}, tool_response={'exit_code': proc.returncode, 'output': stdout})
            self.assertFalse(self.records()['pending'])
            self.assertEqual(len(self.records()['evidence']), 2)
            self.assertEqual({r['status'] for r in self.records()['evidence']}, {'passed'})
            self.assertEqual(self.stop('Verification: PASS — completed original invocation'), {})
            self.event('PostToolUse', tool_response=stdout, **fields)
            self.assertFalse(self.records()['uncertain'])
            self.event('PostToolUse', tool_name='write_stdin', tool_use_id='duplicate-poll',
                tool_input={'session_id': 702}, tool_response={'exit_code': proc.returncode, 'output': stdout})
            self.assertEqual(len(self.records()['evidence']), 1)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_codex_interrupted_wrapper_preserves_unrelated_failure(self):
        self.run_check(7, argv=['python3', 'tests/test-other.py'])
        fields, command, receipt, _output = self.request()
        self.event('PreToolUse', **fields)
        proc = subprocess.Popen(command, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, 'FIXTURE_SLEEP': '20'})
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if receipt.exists() and json.loads(receipt.read_text()).get('before_fingerprint'):
                    break
                time.sleep(0.01)
            else:
                self.fail('runner did not bind its starting contents')
            self.event('PostToolUse', tool_response={'session_id': 703, 'status': 'running'}, **fields)
            time.sleep(0.05)
            proc.terminate()
            stdout, stderr = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 130, stderr)
            self.event('PostToolUse', tool_name='write_stdin', tool_use_id='interrupted-poll',
                tool_input={'session_id': 703}, tool_response={'exit_code': proc.returncode, 'output': stdout})
            self.assertEqual([r['status'] for r in self.records()['evidence']], ['failed', 'interrupted'])
            self.stop('Verification: PENDING — interrupted original check')
            self.run_check()
            self.assertEqual(self.stop('Verification: PASS — other check recovered').get('decision'), 'block')
            self.assertIn('failed', [r['status'] for r in self.records()['evidence']])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def test_prop_contended_hook_returns_promptly_without_inventing_source_gap(self):
        import fcntl
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            response = self.stop('Verification: PASS — unavailable concurrent observation')
            self.assertLess(time.monotonic() - started, 2)
            self.assertTrue(response.get('decision') == 'block' or 'unavailable' in response.get('systemMessage', ''))
        self.event('UserPromptSubmit')
        self.assertFalse(self.records()['uncertain'])
        self.assert_blocked()

    def test_prop_globstar_in_middle_covers_direct_children(self):
        data = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        data['prod_globs'] = ['src/**/*.py', 'native/**/*.py']
        data['verification_scopes']['app']['inputs'] = ['src/**/*.py', 'tests/test-check.py']
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(data))
        self.change()
        self.run_check()
        self.write('src/main.py', 'value = 9\n')
        self.assert_blocked()
        matcher = fixture.evidence.proportional.matches
        self.assertTrue(matcher('front/useExample.ts', ['front/**/*.ts']))
        self.assertTrue(matcher('front/deep/useExample.ts', ['front/**/*.ts']))
        self.assertFalse(matcher('front/deep/useExample.ts', ['front/*.ts']))

    def test_prop_external_requirement_survives_discussion_and_unrelated_green(self):
        self.change()
        self.stop('Verification: BLOCKED — Felipe must build and validate on a device')
        self.event('UserPromptSubmit', turn_id='discussion')
        self.stop('Implementation is ready for the next step.')
        self.run_check()
        self.event('UserPromptSubmit', turn_id='attempt-waiver')
        response = self.stop('Verification: NOT APPLICABLE — manual diff inspected')
        self.assertTrue(response.get('decision') == 'block' or 'UNVERIFIED' in response.get('systemMessage', ''))
        self.assertTrue(self.records()['required_validation']['external'])
        self.assertNotEqual(self.records().get('outcome'), 'verified')

    def test_prop_source_pending_resolves_with_applicable_execution(self):
        self.change()
        self.run_check(1)
        self.stop('Verification: PENDING — failing source check')
        self.event('UserPromptSubmit', turn_id='fix')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — focused source check'), {})
        self.assertNotIn('required_validation', self.records())

    def test_prop_matching_service_check_can_resolve_declared_blocker(self):
        self.change()
        self.run_check(1, output='Cannot connect to test service')
        self.stop('Verification: BLOCKED — cannot connect to its test service')
        captured = self.records()['required_validation']['commands'][0]
        self.assertEqual(captured['cwd'], str(self.root.resolve()))
        self.assertTrue(captured['scope']['inputs'])
        self.assertFalse(self.records()['required_validation']['external'])
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — same integration check passed after recovery'), {})
        self.assertNotIn('required_validation', self.records())

    def test_prop_unrelated_check_cannot_resolve_service_blocker(self):
        self.change()
        self.run_check(1, output='Cannot connect to test service')
        self.stop('Verification: BLOCKED — cannot connect to its test service')
        self.run_check(argv=['python3', 'tests/test-other.py'])
        self.assertEqual(self.stop('Verification: PASS — unrelated suite').get('decision'), 'block')
        self.assertIn('required_validation', self.records())

    def test_prop_matching_check_cannot_waive_independent_device_acceptance(self):
        self.change()
        self.run_check(1, output='Cannot connect to test service')
        self.stop('Verification: BLOCKED — test service unavailable; Felipe must also build the binary and validate on a device')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — integration check recovered').get('decision'), 'block')
        self.assertTrue(self.records()['required_validation']['external'])

    def test_prop_contended_device_declaration_survives_green_and_waiver(self):
        import fcntl
        self.change()
        ran, _receipt, _output = self.run_check()
        self.assertEqual(ran.returncode, 0)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.stop('Verification: PENDING — device acceptance requires a new build; private-ticket-XY42')
        queued = list(state_path.parent.glob('deferred-*.json'))
        self.assertEqual(len(queued), 1)
        self.assertNotIn('private-ticket-XY42', queued[0].read_text())
        api = fixture.evidence
        state = json.loads(state_path.read_text())
        with patch.object(api.proportional, 'snapshot', side_effect=AssertionError('deferred Stop scanned source')), \
                patch.object(api.proportional, 'file_digest', side_effect=AssertionError('deferred Stop read source')):
            api.proportional.drain_deferred(state_path.parent, state, self.root.resolve(), api,
                lambda: api.save_state(state_path.parent, state))
            self.memory_stop(state, 'Ordinary discussion following the handoff.')
        self.assertTrue(state['required_validation']['external'])
        for message in ('Verification: PASS — the observed check remains green',
                        'Verification: NOT APPLICABLE — no further source edits'):
            self.stop(message)
            self.assertNotEqual(self.records()['outcome'], 'verified')
            self.assertTrue(self.records()['required_validation']['external'])

    def test_prop_contended_review_handoff_reuses_observed_success(self):
        import fcntl
        self.change()
        ran, _receipt, _output = self.run_check()
        self.assertEqual(ran.returncode, 0)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.stop('Verification: PENDING — independent review is in progress')
        self.assertEqual(self.stop('Verification: PASS — unchanged source retains its observed success'), {})
        self.assertNotIn('required_validation', self.records())

    def test_prop_contended_service_declaration_requires_matching_recovery(self):
        import fcntl
        self.change()
        ran, _receipt, _output = self.run_check(1, output='Cannot authenticate to test service')
        self.assertEqual(ran.returncode, 1)
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.stop('Verification: BLOCKED — credentials for the test service are unavailable')
        self.event('UserPromptSubmit', turn_id='service-recovery')
        self.assertFalse(self.records()['required_validation']['external'])
        self.assertTrue(self.records()['required_validation']['commands'])
        self.run_check(argv=['python3', 'tests/test-other.py'])
        self.stop('Verification: PASS — unrelated check passed')
        self.assertNotEqual(self.records()['outcome'], 'verified')
        self.assertIn('required_validation', self.records())
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — matching service check recovered'), {})
        self.assertNotIn('required_validation', self.records())

    def test_prop_contended_unbound_service_declaration_cannot_be_waived(self):
        import fcntl
        self.run_check()
        state_path = next(self.state.rglob('state.json'))
        with (state_path.parent / 'lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.stop('Verification: BLOCKED — independent test service credentials unavailable')
        self.stop('Verification: PASS — prior source checks remain green')
        self.assertTrue(self.records()['required_validation']['external'])
        self.assertNotEqual(self.records()['outcome'], 'verified')

    def test_prop_deferred_declarations_have_distinct_identity_and_exact_replay(self):
        api = fixture.evidence
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        directory = self.artifacts / 'declarations'
        directory.mkdir()
        messages = [('first', 'PENDING', 'independent review secret-one'),
                    ('first', 'PENDING', 'device acceptance and new build secret-two'),
                    ('first', 'PENDING', 'device acceptance and new build secret-two'),
                    ('second', 'PENDING', 'device acceptance and new build secret-two'),
                    ('second', 'BLOCKED', 'credentials for test service secret-three')]
        for index, (turn, label, reason) in enumerate(messages):
            api.proportional.defer_event(directory, {'hook_event_name': 'Stop', 'session_id': 'session',
                'agent_id': 'worker', 'turn_id': turn, 'last_assistant_message': f'Verification: {label} — {reason}'},
                self.root.resolve(), config, config['codex_verification'], self.root.resolve(), api,
                'claude' if isinstance(self, ClaudeTests) else 'codex', 1000 + index, 1000 + index)
        facts = [json.loads(path.read_text()) for path in sorted(directory.glob('deferred-*.json'))]
        self.assertEqual(len({fact['id'] for fact in facts}), 4)
        self.assertEqual(facts[1]['id'], facts[2]['id'])
        self.assertTrue(all('secret-' not in json.dumps(fact) for fact in facts))
        state = {}
        api.proportional.drain_deferred(directory, state, self.root.resolve(), api, lambda: None)
        self.assertEqual(len(state['deferred_consumed']), 4)
        self.assertTrue(state['required_validation']['external'])
        self.assertEqual(state['required_validation']['at'], 1001)
        self.assertFalse(list(directory.glob('deferred-*.json')))

    def test_prop_unknown_mutation_needs_exact_completed_observation(self):
        self.write('scripts/observe.py', "print('completed')\n")
        (self.root / 'nested').mkdir()
        for variant in ('command', 'cwd', 'tool', 'missing', 'interrupted', 'running', 'raw'):
            with self.subTest(variant=variant):
                fields = dict(tool_name='Bash', tool_use_id='unknown-' + variant, tool_input={
                    'command': 'python3 scripts/observe.py', 'workdir': str(self.root)})
                self.event('PreToolUse', **fields)
                ran = subprocess.run(['python3', 'scripts/observe.py'], cwd=self.root, capture_output=True, text=True)
                actual_response = {'stdout': ran.stdout, 'exit_code': ran.returncode}
                altered = dict(fields, tool_input=dict(fields['tool_input']))
                response = dict(actual_response)
                if variant == 'command':
                    altered['tool_input']['command'] = 'python3 scripts/different.py'
                elif variant == 'cwd':
                    altered['tool_input']['workdir'] = str(self.root / 'nested')
                elif variant == 'tool':
                    altered['tool_name'] = 'Read'
                elif variant == 'interrupted':
                    response['interrupted'] = True
                elif variant == 'running':
                    response['session_id'] = 123
                    response.pop('exit_code')
                elif variant == 'raw':
                    response = ran.stdout
                if variant == 'missing':
                    self.event('PostToolUse', **altered)
                else:
                    self.event('PostToolUse', tool_response=response, **altered)
                self.assertIn(fields['tool_use_id'], self.records()['uncertain'])
                self.assertIn(fields['tool_use_id'], self.records()['mutations'])
                # A late but exact completed observation can recover this same
                # invocation; an earlier mismatch must not erase its baseline.
                self.event('PostToolUse', tool_response=actual_response, **fields)
                self.assertNotIn(fields['tool_use_id'], self.records()['uncertain'])
                self.assertNotIn(fields['tool_use_id'], self.records()['mutations'])
        # Exact late completion closes its original baseline. Conflicting
        # request identities remain quarantined even after that recovery.
        self.assertEqual(set(self.records()['uncertain']), {
            'conflict:unknown-command', 'conflict:unknown-cwd', 'conflict:unknown-tool'})
        self.assertEqual(self.stop('Observed read script completed without source changes.').get('decision'), 'block')

    def test_prop_empty_nonexternal_pending_does_not_poison_later_check(self):
        self.stop('Verification: PENDING — completion summary still being prepared')
        self.assertNotIn('required_validation', self.records())
        # Also recover a private fixture state produced by the prior version.
        state_path = next(self.state.rglob('state.json'))
        old_state = json.loads(state_path.read_text())
        old_state['required_validation'] = {'at': 0, 'reason': 'summary pending',
                                            'external': False, 'paths': [], 'commands': []}
        state_path.write_text(json.dumps(old_state))
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — observed app check'), {})
        self.assertNotIn('required_validation', self.records())
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_unknown_script_config_writes_remain_source_obligations(self):
        self.write('yarn.lock', '# initial lock\n')
        self.write('pytest.ini', '[pytest]\n')
        self.write('scripts/update-config.py', "from pathlib import Path\nPath('yarn.lock').write_text('# changed lock\\n')\nPath('pytest.ini').write_text('[pytest]\\naddopts = -q\\n')\n")
        fields = dict(tool_name='Bash', tool_use_id='config-script', tool_input={
            'command': 'python3 scripts/update-config.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(['python3', 'scripts/update-config.py'], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertEqual(set(self.records()['writes']), {'yarn.lock', 'pytest.ini'})
        self.assertFalse(self.records()['uncertain'])
        self.assert_blocked()

    def test_prop_completion_colon_whitespace_matches_graders(self):
        self.change()
        response = self.stop('Verification:BLOCKED — required device unavailable')
        self.assertNotIn('decision', response)
        self.assertEqual(self.records()['outcome'], 'blocked')
        self.assertTrue(self.records()['required_validation']['external'])

    def test_prop_sed_tracks_every_modified_operand(self):
        self.write('native/module.py', 'value = 1\n')
        # `-i.bak` (attached suffix) is the one in-place spelling GNU and BSD sed share.
        fields = dict(tool_name='Bash', tool_use_id='sed-write', tool_input={
            'command': "sed -i.bak 's/1/2/g' native/module.py src/main.py", 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(['sed', '-i.bak', 's/1/2/g', 'native/module.py', 'src/main.py'], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': 0}, **fields)
        self.run_check()
        self.assert_blocked()
        self.assertEqual(set(self.records()['writes']), {'src/main.py', 'native/module.py'})
        for flags in ('--in-place=.bak', '-Ei'):
            self.assertTrue(fixture.evidence.potentially_mutating({'tool_name': 'Bash'}, 'sed ' + flags + " 's/1/2/g' src/main.py"))

    def test_prop_owned_disposable_copy_source_edit_does_not_poison_project(self):
        helper = ROOT / 'scripts/lib/orch-task-resources.py'
        state_dir = Path(self.tmp.name) / 'task-state'
        def resource(*args):
            ran = subprocess.run(['python3', str(helper), '--state-dir', str(state_dir), *args], text=True, capture_output=True)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            return json.loads(ran.stdout)
        task = resource('start', '--project', str(self.root), '--task', 'evidence-fixture')
        lease = resource('acquire', '--id', task['id'], '--consumer', 'fixture')
        copied = resource('copy', '--id', task['id'], '--token', lease['token'])
        target = Path(copied['path']) / 'probe.py'
        self.event('PreToolUse', tool_name='apply_patch', tool_use_id='scratch-source',
                   tool_input={'command': '*** Update File: ' + str(target)})
        target.write_text('value = 1\n')
        self.event('PostToolUse', tool_name='apply_patch', tool_use_id='scratch-source',
                   tool_input={'command': '*** Update File: ' + str(target)})
        self.assertEqual(self.stop('Review probe finished.'), {})
        self.assertFalse(self.records()['uncertain'])
        resource('release', '--id', task['id'], '--token', lease['token'], '--stopped')
        resource('finish', '--id', task['id'])

    def test_prop_read_shaped_output_write_is_attributed(self):
        fields = dict(tool_name='Bash', tool_use_id='git-output-write', tool_input={
            'command': 'git diff --output=src/main.py | head -5', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(fields['tool_input']['command'], shell=True, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': 0}, **fields)
        self.assertIn('src/main.py', self.records()['writes'])
        self.assert_blocked()
        api = fixture.evidence
        for command in ('git diff --output=src/main.py', 'rg --pre scripts/modify.py pattern src', 'file -C'):
            self.assertTrue(api.potentially_mutating({'tool_name': 'Bash'}, command))
            self.assertFalse(api.proportional.readonly_shell(command, api))

    def test_prop_readonly_pipeline_never_creates_uncertainty(self):
        fields = dict(tool_name='Bash', tool_use_id='read-pipeline',
                      tool_input={'command': 'git log --oneline | head -5'})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(fields['tool_input']['command'], shell=True, cwd=self.root, capture_output=True, text=True)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertEqual(self.stop('This is the recent history.'), {})
        self.assertFalse(self.records()['uncertain'])

    def test_prop_paired_unknown_command_recovers_actual_source_coverage(self):
        self.write('scripts/modify.py', "from pathlib import Path\nPath('src/main.py').write_text('value = 22\\n')\n")
        fields = dict(tool_name='Bash', tool_use_id='script-write',
                      tool_input={'command': 'python3 scripts/modify.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(['python3', 'scripts/modify.py'], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout, 'exit_code': ran.returncode}, **fields)
        self.assertFalse(self.records()['uncertain'])
        self.assertIn('src/main.py', self.records()['writes'])
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — observed source check'), {})

    def test_prop_cancelled_check_recovers_with_matching_actual_execution(self):
        fields = dict(tool_name='Bash', tool_use_id='cancelled-check', tool_input={'command': 'python3 tests/test-check.py'})
        self.event('PreToolUse', **fields)  # denied/cancelled: no post event
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — subsequent actual check'), {})
        self.assertFalse(self.records()['pending'])

    def test_prop_missing_check_start_recovers_only_matching_real_execution(self):
        self.change()
        self.event('PostToolUse', tool_name='Bash', tool_use_id='missing-pre',
            tool_input={'command': 'python3 tests/test-check.py'}, tool_response={'stdout': 'Ran 3 tests', 'exit_code': 0})
        self.assertTrue(self.records()['uncertain'])
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — matching observed rerun'), {})
        self.assertFalse(self.records()['uncertain'])

    def test_prop_empty_scope_diagnostic_without_known_runner(self):
        data = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        data.update(prod_globs=[], test_globs=[], verification_config_globs=[], verification_scopes={})
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(data))
        self.change()
        self.event('PreToolUse', tool_name='Bash', tool_use_id='unsupported-go', tool_input={'command': 'go test ./...'})
        result = self.stop('Source changed.')
        self.assertIn('prod_globs', result['reason'])
        self.assertIn('verification_config_globs', result['reason'])
        self.assertIn('direct test runner', result['reason'])

    def test_prop_content_preserving_commit_reuses_verified_check_across_turns(self):
        self.change()
        self.run_check()
        self.assertNotIn('decision', self.stop('Verification: PASS — app fixture'))
        self.git('add', '.')
        self.git('commit', '-qm', 'preserve tested contents')
        self.event('UserPromptSubmit', turn_id='next')
        self.assertNotIn('decision', self.stop('Verification: PASS — app fixture'))
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_deletion_commit_preserves_content_fingerprint(self):
        self.event('PreToolUse', tool_name='apply_patch', tool_use_id='delete-source',
                   tool_input={'command': '*** Update File: src/main.py'})
        (self.root / 'src/main.py').unlink()
        self.event('PostToolUse', tool_name='apply_patch', tool_use_id='delete-source',
                   tool_input={'command': '*** Update File: src/main.py'})
        self.run_check()
        self.git('add', '.')
        self.git('commit', '-qm', 'delete source after checking')
        self.assertEqual(self.stop('Verification: PASS — app fixture'), {})

    def test_prop_completed_task_does_not_attach_obligation_to_later_discussion(self):
        self.change()
        self.run_check()
        self.stop('Verification: PASS — app fixture')
        self.event('UserPromptSubmit', turn_id='new-question')
        self.write('src/main.py', 'value = 100\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'another task')
        self.assertEqual(self.stop('This setting controls toast visibility.'), {})

    def test_prop_not_applicable_survives_ordinary_question(self):
        self.change()
        self.stop('Verification: NOT APPLICABLE — no automated check applies; manual diff inspected')
        self.event('UserPromptSubmit', turn_id='question')
        self.assertEqual(self.stop('The behavior is unchanged.'), {})

    def test_prop_completed_private_state_expires_but_pending_and_active_do_not(self):
        import fcntl
        import time
        base = Path(self.tmp.name) / 'retention'
        base.mkdir()
        api = fixture.evidence.proportional
        states = {}
        for name, outcome in [('completed', 'verified'), ('pending', 'pending'), ('busy', 'verified')]:
            directory = base / name
            directory.mkdir()
            path = directory / 'state.json'
            path.write_text(json.dumps({'outcome': outcome, 'evidence': []}))
            old = time.time() - 30 * 86400
            os.utime(path, (old, old))
            states[name] = path
        outside = Path(self.tmp.name) / 'unowned-evidence'
        outside.mkdir()
        outside_state = outside / 'state.json'
        outside_state.write_text(json.dumps({'outcome': 'verified'}))
        os.utime(outside_state, (old, old))
        (base / 'foreign-link').symlink_to(outside, target_is_directory=True)
        with (base / 'busy/lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            api.prune_completed(base)
        self.assertFalse(states['completed'].exists())
        self.assertTrue(states['pending'].exists())
        self.assertTrue(states['busy'].exists())
        self.assertTrue(outside_state.exists())

    def test_prop_owned_resource_helper_does_not_create_source_uncertainty(self):
        command = shlex.join(['python3', str(ROOT / 'scripts/lib/orch-task-resources.py'), 'status', '--id', 'a' * 32])
        fields = dict(tool_name='Bash', tool_use_id='resource', tool_input={'command': command})
        self.event('PreToolUse', **fields)
        self.event('PostToolUse', tool_response='', **fields)
        self.assertEqual(self.stop('Task resources checked.'), {})

    def test_prop_own_unverified_edit_survives_pending_then_discussion(self):
        # A discussion turn that changes nothing is never blocked, but the edit's
        # obligation survives it and still refuses a later unsupported PASS.
        self.change()
        self.stop('Verification: PENDING — unavailable check')
        self.event('UserPromptSubmit', turn_id='discussion')
        self.assertEqual(self.stop('The option controls toast visibility.'), {})
        self.assertIn('src/main.py', self.records()['writes'])
        self.event('UserPromptSubmit', turn_id='claim')
        self.assert_blocked()

    def test_prop_readonly_pipelines_with_filters_and_safe_git_stay_readonly(self):
        module = fixture.evidence.proportional
        api = fixture.evidence
        for command in ('grep -rn TODO src | cut -d: -f1 | wc -l',
                        'git branch -a && git tag -l && git remote -v && git stash list',
                        'git config --get core.hooksPath; git cat-file -p HEAD:src/main.py | wc -l',
                        'cat package.json | jq .name; diff a.txt b.txt; shasum src/main.py',
                        'eas build:list --limit 3 | jq .'):
            expected = not command.startswith('eas')
            self.assertEqual(module.readonly_shell(command, api), expected, command)
        # Programs with an output option, a program language or a command runner
        # are not read-only however they are spelled.
        for command in ('find . -name "*.pyc" -delete', 'find . -name "*.py"', 'git branch -D old', 'git stash',
                        'grep TODO src | tee notes.txt', 'git config core.hooksPath .githooks',
                        'git config --file src/settings.conf -- demo.value --get',
                        'sort -o sorted.txt names.txt', 'sort -ro src/main.py names.txt', 'grep x | sort',
                        'uniq names.txt src/main.py', "awk '{print}' data", "awk 'BEGIN {system (\"touch x\")}'",
                        'tree -o out.txt', 'date -s tomorrow', 'xargs rm', 'printf x | less -O native/module.py',
                        "git grep -O'cp src/main.py' value -- native/module.py", 'git log --output=notes.txt',
                        "git grep -nO'cp src/main.py' value", "git grep --open-files-in-pag='cp a b' value",
                        'rg --hostname-bin ./scripts/update-source.sh value src/main.py',
                        'file --comp -m magic', 'file -0C -m magic', 'file --co -m magic',
                        "git grep --open='cp src/main.py' value -- native/module.py", 'git log --o=notes.txt',
                        'git log --{output=notes.txt,oneline}', 'file -{C,b} -m magic',
                        "printf x | sed 's@x@touch probe.py@e #@'", "sed 's/a/b/e' data", "sed -n 's/a/b/w out.txt' data",
                        "printf x | sed 's@x@touch probe.py #\\\\@e #@'", "sed 's/a/b\\\\/e' data", "sed 's/a/b/;e touch x' data"):
            self.assertFalse(module.readonly_shell(command, api), command)
        self.assertTrue(module.readonly_shell("sed -n 's/a/b/p' data | sed -n '2,4p'", api))
        self.assertTrue(module.readonly_shell("sed -n 's@x@y@gp' data", api))
        self.assertTrue(module.readonly_shell("sed -n 's/a\\/b/c\\\\d/p' data", api))
        self.assertEqual(module.parse_substitution('s@x@touch probe.py #\\\\@e #@'), None)
        self.assertEqual(module.parse_substitution('s/a\\/b/c/gp'), ('gp', None))
        self.assertEqual(module.parse_substitution('s/a/b/w out.txt'), ('', 'out.txt'))
        self.assertEqual(module.parse_substitution('s/a/b\\/c/g'), ('g', None))       # escaped delimiter in the replacement
        self.assertEqual(module.parse_substitution('s|a|b|'), ('', None))              # metacharacter delimiter
        self.assertEqual(module.parse_substitution('s.a.b.'), ('', None))
        self.assertEqual(module.parse_substitution('s///'), ('', None))                # empty fields
        self.assertEqual(module.parse_substitution('s/a/b'), None)                     # missing closing delimiter
        self.assertEqual(module.parse_substitution('s/a/b/ '), None)                   # trailing whitespace is not a flag
        self.assertEqual(module.parse_substitution('s/a/b/gx'), None)                  # unknown flag
        self.assertEqual(module.sed_targets(['sed', '-n', '-e', 's/a/b/p', '-e', 's/c/d/w out.txt', 'data']), ['out.txt'])
        self.assertEqual(module.sed_targets(['sed', '-e', 's/a/b/p', '-e', 's/c/d/e', 'data']), None)

    def test_prop_write_completing_this_turn_counts_as_touching_it(self):
        # Pre in one turn, completion in the next: the turn that saw the write
        # finish is the one that must declare it.
        fields = dict(tool_name='apply_patch', tool_use_id='slow-edit',
                      tool_input={'command': '*** Update File: src/main.py'})
        self.event('PreToolUse', **fields)
        self.event('UserPromptSubmit', turn_id='next')
        self.write('src/main.py', 'value = 7\n')
        self.event('PostToolUse', **fields)
        self.assertEqual(self.stop('Here is what the setting does.').get('decision'), 'block')

    def test_prop_failed_check_reported_honestly_is_not_blocked(self):
        self.change()
        self.run_check(1)
        self.assertEqual(self.stop('Verification: PENDING — the app check fails on the new branch'), {})
        self.event('UserPromptSubmit', turn_id='ask')
        self.assertEqual(self.stop('The failure comes from the toast timer.'), {})
        self.assert_blocked()

    def test_prop_docs_cleanup_after_foreign_commit_is_read_only(self):
        self.write('native/module.py', 'x = 8\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'unrelated native change')
        self.event('PreToolUse', tool_name='Bash', tool_use_id='cleanup',
            tool_input={'command': 'rm ' + str(self.root / 'report.md')})
        self.event('PostToolUse', tool_name='Bash', tool_use_id='cleanup',
            tool_input={'command': 'rm ' + str(self.root / 'report.md')}, tool_response='')
        self.assertEqual(self.stop('The reviewed spec is ready.'), {})
        self.assertEqual(self.records()['outcome'], 'read_only')

    def test_prop_foreign_native_change_does_not_invalidate_app_scope(self):
        self.change()
        self.run_check()
        self.write('native/module.py', 'x = 8\n')
        self.assertEqual(self.stop('Verification: PASS — app fixture'), {})

    def test_prop_own_native_change_is_separate_obligation(self):
        self.change()
        self.run_check()
        self.mutate('native/module.py', 'x = 8\n')
        self.assert_blocked()

    def test_prop_config_test_and_source_edits_stale_covered_check(self):
        self.change()
        self.run_check()
        self.write('check-config.json', '{"new":true}')
        self.assert_blocked()

    def test_prop_covered_test_addition_invalidates_fallback(self):
        self.change()
        self.run_check(argv=['python3', 'tests/test-check.py', 'unknown/path.py'])
        self.write('tests/new.py', 'x = 4\n')
        self.assert_blocked()

    def test_prop_unresolved_write_cannot_be_cleared_by_check_or_na(self):
        self.event('PreToolUse', tool_name='Bash', tool_use_id='unknown-writer',
                   tool_input={'command': 'python3 scripts/update-source.py'})
        self.run_check()
        self.assertEqual(self.stop('Verification: NOT APPLICABLE — manual diff inspected').get('decision'), 'block')
        self.assertTrue(self.records()['uncertain'])

    def test_prop_not_applicable_low_risk_without_automated_check(self):
        self.change()
        self.assertEqual(self.stop('Verification: NOT APPLICABLE — no meaningful automated check; manual diff inspection performed'), {})
        self.assertEqual(self.records()['outcome'], 'not_applicable')

    def test_prop_write_outside_fingerprinted_set_never_passes(self):
        # A glob match is not coverage: paths the fingerprint can never contain
        # (hard-excluded directories, ignored files) keep a passing check fresh
        # even after they change, so they must stay pending until resolved.
        self.mutate('src/build/rules.py', 'rule = 1\n')
        self.run_check()
        self.assert_blocked()
        self.assertIn('the checks can never see', self.stop('Verification: PASS — app check').get('systemMessage', ''))

    def test_prop_ignored_source_write_never_passes(self):
        self.write('.gitignore', 'src/generated.py\n')
        self.mutate('src/generated.py', 'generated = 1\n')
        self.run_check()
        self.assert_blocked()

    def test_prop_deleting_unfingerprinted_file_never_passes(self):
        # Deleting a file the fingerprint never contained changes nothing the
        # check measured, so the deletion is not covered by that check.
        self.write('src/build/rules.py', 'rule = 1\n')
        self.git('add', 'src/build/rules.py')
        self.git('commit', '-qm', 'excluded file')
        self.run_check()
        self.delete_observed('src/build/rules.py')
        self.assert_blocked()
        self.assertIn('the checks can never see', self.stop('Verification: PASS — app check').get('systemMessage', ''))

    def delete_observed(self, rel):
        self.seq += 1
        fields = dict(tool_name='Bash', tool_use_id=f'delete-{self.seq}',
                      tool_input={'command': 'rm ' + rel, 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        (self.root / rel).unlink()
        self.event('PostToolUse', tool_response={'stdout': '', 'stderr': '', 'exit_code': 0}, **fields)

    def test_prop_deleting_ignored_untracked_file_never_passes(self):
        self.write('.gitignore', 'src/scratch.py\n')
        self.write('src/scratch.py', 'scratch = 1\n')
        self.run_check()
        self.delete_observed('src/scratch.py')
        self.assert_blocked()
        self.assertFalse(self.records()['uncertain'], self.records()['uncertain'])

    def test_prop_named_check_matching_is_bounded_and_normalized(self):
        module = fixture.evidence.proportional
        fresh = [{'scope': {'path_arguments': ['tests/test-check.py', 'InstalledTests.test_x']}},
                 {'scope': {'path_arguments': ['tests/unit']}}]
        self.assertEqual(module.unrecorded_named_checks('ran tests/./test-check.py fine', fresh), [])
        self.assertEqual(module.unrecorded_named_checks('tests/unit/test_alpha.py via the directory run', fresh), [])
        self.assertEqual(module.unrecorded_named_checks('pkg/tests/test-check.py was not run', fresh), [])
        self.assertEqual(module.unrecorded_named_checks('tests/test-security.py passed', fresh), ['tests/test-security.py'])
        # A whole-repository run covers every named file; an excluded path is not a path argument.
        self.assertEqual(module.unrecorded_named_checks('tests/test-security.py passed', [{'scope': {'path_arguments': ['.']}}]), [])
        self.assertEqual(module.unrecorded_named_checks('tests/test-security.py passed', [{'scope': {'path_arguments': []}}]), [])
        root = self.root.resolve()
        self.assertEqual(module.path_arguments(['python3', '-m', 'pytest', 'tests', '--ignore=tests/test-check.py'], root, root), ['tests'])
        self.assertEqual(module.path_arguments(['python3', '-m', 'pytest', '--deselect', 'tests/test-check.py', 'tests/test-other.py'], root, root), ['tests/test-other.py'])

    def test_prop_pass_naming_unrun_check_in_backticks_is_rejected(self):
        self.change()
        self.run_check()
        rejected = self.stop('Verification: PASS — python3 `tests/test-security.py` passed')
        self.assertEqual(rejected.get('decision'), 'block', rejected)

    def test_prop_fenced_example_does_not_shadow_the_real_completion_line(self):
        self.change()
        self.run_check()
        fenced_example = ('An example of the line:\n```\nVerification: PASS — tests/test-security.py passed\n```\n'
                          'Verification: PASS — tests/test-check.py passed on the final source')
        self.assertEqual(self.stop(fenced_example), {})
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_failed_readonly_command_does_not_poison_a_readonly_turn(self):
        # A compound read command that exits non-zero (grep with no match) ends
        # with a failure event. The command is over, the tree is unchanged, so
        # the turn stays read-only and NOT APPLICABLE is accepted.
        for seq, response in enumerate(({'stdout': '', 'stderr': 'no match', 'interrupted': False}, None)):
            fields = dict(tool_name='Bash', tool_use_id=f'failed-read-{seq}',
                          tool_input={'command': 'grep -rn TODO src | sort | head -5', 'workdir': str(self.root)})
            self.event('PreToolUse', **fields)
            self.event('PostToolUseFailure', tool_response=response, **fields)
        self.assertFalse(self.records()['mutations'], self.records()['mutations'])
        self.assertFalse(self.records()['uncertain'], self.records()['uncertain'])
        self.assertEqual(self.stop('Verification: NOT APPLICABLE — read-only investigation; no source changed'), {})

    def test_prop_failed_poll_is_not_process_termination(self):
        module = fixture.evidence.proportional
        failed_poll = {'isError': True, 'stdout': '', 'stderr': 'poll failed'}
        self.assertFalse(module.terminal_mutation_response(failed_poll, 'write_stdin', 'codex', poll=True, event='PostToolUseFailure'))
        self.assertFalse(module.terminal_mutation_response(failed_poll, 'write_stdin', 'claude', poll=True, event='PostToolUseFailure'))
        self.assertTrue(module.terminal_mutation_response({'stderr': 'boom'}, 'Bash', 'codex', event='PostToolUseFailure'))
        self.assertFalse(module.terminal_mutation_response({'interrupted': True}, 'Bash', 'claude', event='PostToolUseFailure'))
        self.assertFalse(module.terminal_mutation_response({'backgroundTaskId': 'b1'}, 'Bash', 'claude', event='PostToolUseFailure'))

    def test_prop_failed_write_command_still_records_its_actual_effect(self):
        fields = dict(tool_name='Bash', tool_use_id='failing-writer',
                      tool_input={'command': 'python3 scripts/edit.py', 'workdir': str(self.root)})
        self.event('PreToolUse', **fields)
        self.write('src/main.py', 'value = 3\n')  # the command changed source before failing
        self.event('PostToolUseFailure', tool_response={'stdout': '', 'stderr': 'boom', 'interrupted': False}, **fields)
        self.assertIn('src/main.py', self.records()['writes'])
        self.assert_blocked()

    def test_prop_reignored_edit_cannot_ride_an_earlier_check(self):
        # Check while the file is ignored (not fingerprinted), unignore it,
        # edit it, ignore it again: the earlier check must not cover the edit.
        self.write('.gitignore', 'src/gen.py\n')
        self.write('src/gen.py', 'gen = 1\n')
        self.run_check()
        self.write('.gitignore', '')
        self.mutate('src/gen.py', 'gen = 2\n')
        self.write('.gitignore', 'src/gen.py\n')
        self.assert_blocked()

    def test_prop_initially_ignored_edit_passes_once_tracked_and_rechecked(self):
        self.write('.gitignore', 'src/gen.py\n')
        self.write('src/gen.py', 'gen = 1\n')
        self.mutate('src/gen.py', 'gen = 2\n')
        self.git('add', '-f', 'src/gen.py')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — app check on the final source'), {})
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_staged_deletion_of_tracked_ignore_matching_file_can_pass(self):
        # A tracked file that happens to match an ignore rule was fingerprinted,
        # so deleting it, staging the deletion and rerunning the check is covered.
        self.write('.gitignore', 'src/legacy.py\n')
        self.write('src/legacy.py', 'legacy = 1\n')
        self.git('add', '-f', 'src/legacy.py', '.gitignore')
        self.git('commit', '-qm', 'tracked despite the ignore rule')
        self.run_check()
        self.delete_observed('src/legacy.py')
        self.git('rm', '-q', '--cached', 'src/legacy.py')
        self.git('commit', '-qm', 'remove the legacy file')  # HEAD no longer knows the file
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — app check on the final source'), {})
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_pass_naming_unrun_check_is_rejected(self):
        self.change()
        self.run_check()
        rejected = self.stop('Verification: PASS — python3 tests/test-security.py passed')
        self.assertEqual(rejected.get('decision'), 'block', rejected)
        self.assertIn('tests/test-security.py', rejected['reason'])
        self.assertEqual(self.stop('Verification: PASS — tests/test-check.py passed on the final source'), {})
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_ordinary_runtime_wording_is_not_an_external_requirement(self):
        self.change()
        self.stop('Verification: PENDING — runtime tests remain')
        self.event('UserPromptSubmit', turn_id='run-them')
        self.run_check()
        self.assertEqual(self.stop('Verification: PASS — app check on the final source'), {})
        self.assertEqual(self.records()['outcome'], 'verified')

    def test_prop_not_applicable_cannot_waive_failed_check(self):
        self.change()
        self.run_check(1)
        self.assertEqual(self.stop('Verification: NOT APPLICABLE — manual diff inspection performed').get('decision'), 'block')

    def test_prop_failed_check_survives_discussion_and_other_green(self):
        self.change()
        self.run_check(1)
        self.stop('Verification: PENDING — failing app check')
        self.event('UserPromptSubmit', turn_id='next')
        self.run_check(argv=['python3', 'tests/test-other.py'])
        self.assert_blocked()

    def test_prop_empty_config_scope_never_passes(self):
        data = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        data.update(prod_globs=[], test_globs=[], verification_scopes={})
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(data))
        self.change()
        self.run_check()
        self.assert_blocked()
        record = self.records()['evidence'][-1]
        self.assertIsNone(record['after_fingerprint'])
        self.assertEqual(record['exit_code'], 0)

    def test_prop_nonmatching_config_globs_never_pass(self):
        data = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        data.update(prod_globs=['absent/**'], test_globs=['absent-tests/**'], verification_scopes={})
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(data))
        self.change()
        self.run_check()
        self.assert_blocked()

    def test_prop_failed_exit_survives_invalid_fingerprint(self):
        data = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        data.pop('verification_config_globs')
        self.write('docs/llm-orchestrator/cadence.json', json.dumps(data))
        self.change()
        _ran, receipt, _out = self.run_check(7)
        saved = json.loads(receipt.read_text())
        self.assertEqual(saved['exit_code'], 7)
        self.assertIsNone(saved['after_fingerprint'])
        self.assertEqual(self.records()['evidence'][-1]['exit_code'], 7)
        self.assert_blocked()

    def test_prop_crash_after_observed_exit_keeps_failed_record(self):
        from unittest.mock import patch
        self.change()
        fields, command, _receipt, _out = self.request()
        self.event('PreToolUse', **fields)
        ran = subprocess.run(command, capture_output=True, text=True,
                             env={**os.environ, 'FIXTURE_EXIT': '7'})
        self.assertEqual(ran.returncode, 7, ran.stderr)
        state_path = next(self.state.rglob('state.json'))
        state = json.loads(state_path.read_text())
        config = json.loads((self.root / 'docs/llm-orchestrator/cadence.json').read_text())
        payload = dict(session_id='session', cwd=str(self.root), hook_event_name='PostToolUse',
                       tool_response=ran.stdout, **fields)
        api = fixture.evidence
        with patch.object(api.proportional, 'snapshot', side_effect=OSError('fingerprint disappeared')):
            api.proportional.handle(state, payload, self.root.resolve(), config, config['codex_verification'],
                self.root.resolve(), api, checkpoint=lambda: api.save_state(state_path.parent, state))
        durable = json.loads(state_path.read_text())['evidence'][-1]
        self.assertEqual(durable['exit_code'], 7)
        self.assertEqual(durable['status'], 'failed')
        self.assertIsNone(durable['after_fingerprint'])

    def test_prop_missing_post_recovers_only_reserved_completed_receipt(self):
        self.change()
        fields, command, _receipt, _out = self.request()
        self.event('PreToolUse', **fields)
        subprocess.run(command, capture_output=True, check=True)
        self.assertEqual(self.stop('Verification: PASS — exact receipt recovered at completion'), {})
        self.assertFalse(self.records()['pending'])

    def test_prop_write_without_pre_event_cannot_be_readonly(self):
        self.write('src/main.py', 'x = 10\n')
        self.event('PostToolUse', tool_name='apply_patch', tool_use_id='missed',
                   tool_input={'command': '*** Update File: src/main.py'})
        self.assert_blocked()

    def test_prop_foreign_session_cannot_borrow_green(self):
        self.run_check()
        self.event('UserPromptSubmit', session_id='foreign')
        self.assertEqual(self.event('Stop', session_id='foreign', last_assistant_message='Verification: PASS — tests passed').get('decision'), 'block')


# Select new cases plus applicable legacy regressions; legacy behavior itself is
# covered by test-codex-evidence.py unchanged.
KEEP = {'test_actual_wrapper_verifies_with_raw_stdout_hook_payload',
        'test_actual_failed_wrapper_blocks_even_if_output_claims_pass',
        'test_empty_suite_is_not_success', 'test_failure_summary_with_exit_zero_is_not_success',
        'test_wrong_request_nonce_cannot_produce_green', 'test_changed_output_artifact_invalidates_receipt',
        'test_fake_harness_header_in_raw_stdout_cannot_make_direct_green',
        'test_source_changed_during_verifier_is_stale', 'test_timeout_writes_failed_completed_receipt',
        'test_explicit_other_worktree_cannot_verify_session_tree'}
for name in dir(fixture.EvidenceTests):
    if name.startswith('test_') and name not in KEEP:
        setattr(ProportionalTests, name, None)


class ClaudeTests(ProportionalTests):
    def event(self, name, **extra):
        payload = dict(session_id='session', turn_id='turn', cwd=str(self.root), hook_event_name=name)
        payload.update(extra)
        if payload.get('tool_name') == 'apply_patch':
            payload['tool_name'] = 'Edit'
            payload['tool_input'] = {'file_path': payload['tool_input']['command'].split(': ', 1)[1]}
        hook = ROOT / 'scripts/hooks' / ('orch-verify-gate.sh' if name in ('Stop', 'SubagentStop') else 'orch-evidence-ledger.sh')
        ran = subprocess.run(['bash', str(hook)], input=json.dumps(payload), text=True, capture_output=True,
            cwd=self.root, env={**os.environ, 'ORCH_HOME': str(self.state)})
        self.assertEqual(ran.returncode, 0, ran.stderr)
        return json.loads(ran.stdout or '{}')

    def records(self, root=None):
        directory = self.state / 'state' / fixture.evidence.digest(str((root or self.root).resolve()))[:12]
        return json.loads(next(directory.rglob('state.json')).read_text())

    def run_check(self, code=0, output='Ran 3 tests in 0.1s\nOK', cwd=None,
                  argv=None, mutate=False, after=None, sleep=None):
        self.seq += 1
        argv = argv or ['python3', 'tests/test-check.py']
        fields = dict(tool_name='Bash', tool_use_id=f'check-{self.seq}', tool_input={'command': shlex.join(argv)})
        self.event('PreToolUse', cwd=str(cwd or self.root), **fields)
        env = {**os.environ, 'FIXTURE_EXIT': str(code), 'FIXTURE_OUTPUT': output}
        if mutate:
            env['FIXTURE_MUTATE'] = '1'
        ran = subprocess.run(argv, cwd=cwd or self.root, capture_output=True, text=True, env=env)
        self.event('PostToolUseFailure' if ran.returncode else 'PostToolUse', cwd=str(cwd or self.root),
                   tool_response={'stdout': ran.stdout, 'stderr': ran.stderr, 'interrupted': False}, **fields)
        return ran, None, None

    def test_claude_child_stop_finalizes_only_actual_child_store(self):
        self.change()  # Parent must remain unfinished.
        self.event('UserPromptSubmit', agent_id='reader')
        response = self.event('SubagentStop', agent_id='reader', last_assistant_message='Review completed without source changes.')
        self.assertEqual(response, {})
        states = [json.loads(p.read_text()) for p in self.state.rglob('state.json')]
        self.assertEqual(sum(s.get('outcome') == 'read_only' for s in states), 1)
        self.assertEqual(self.stop('Parent implementation complete.').get('decision'), 'block')

    def test_claude_child_stop_cannot_forge_parent_execution(self):
        fields = dict(tool_name='Bash', tool_use_id='child-check', agent_id='child',
                      tool_input={'command': 'python3 tests/test-check.py'})
        self.event('PreToolUse', **fields)
        ran = subprocess.run(['python3', 'tests/test-check.py'], cwd=self.root, capture_output=True, text=True)
        self.event('PostToolUse', tool_response={'stdout': ran.stdout}, **fields)
        self.assertEqual(self.event('SubagentStop', agent_id='child',
            last_assistant_message='Verification: PASS — observed child check'), {})
        self.assertEqual(self.stop('Verification: PASS — child report').get('decision'), 'block')
        response = self.event('SubagentStop', last_assistant_message='Verification: PASS — missing child identity')
        self.assertEqual(response.get('decision'), 'block')
        self.assertIn('identity unavailable', response['reason'])

    def test_claude_missing_child_identity_has_bounded_continuation(self):
        self.change()
        before = self.records()
        first = self.event('SubagentStop', last_assistant_message='Review completed.')
        self.assertEqual(first.get('decision'), 'block')
        repeated = self.event('SubagentStop', stop_hook_active=True, last_assistant_message='Review completed.')
        self.assertNotIn('decision', repeated)
        self.assertIn('UNVERIFIED', repeated['systemMessage'])
        self.assertEqual(self.records(), before)

    def test_claude_missing_or_crashing_dispatcher_blocks_explicitly(self):
        import shutil
        with tempfile.TemporaryDirectory() as copied:
            install = Path(copied) / 'scripts'
            shutil.copytree(ROOT / 'scripts/hooks', install / 'hooks')
            shutil.copytree(ROOT / 'scripts/lib', install / 'lib')
            helper = install / 'lib/orch-proportional-evidence.py'
            for fault in ('missing', 'crash', 'empty'):
                if helper.exists():
                    helper.unlink()
                if fault != 'missing':
                    helper.write_text('raise ImportError("fixture missing dependency")\n' if fault == 'crash' else '')
                for hook in ('orch-verify-gate.sh', 'orch-evidence-ledger.sh'):
                    with self.subTest(fault=fault, hook=hook):
                        payload = {'cwd': str(self.root), 'session_id': 'session', 'hook_event_name': 'Stop',
                                   'last_assistant_message': 'Verification: PASS — unsupported claim'}
                        ran = subprocess.run(['bash', str(install / 'hooks' / hook)], input=json.dumps(payload),
                                             cwd=self.root, text=True, capture_output=True)
                        self.assertEqual(ran.returncode, 2)
                        self.assertIn('Verification: PENDING', ran.stderr)

    def test_claude_legacy_pre_events_never_record_execution_or_mutex_claim(self):
        self.write('docs/llm-orchestrator/cadence.json', json.dumps({'enabled': True}))
        for command in ('npm test', 'mkdir ' + str(self.root / '.orch-active')):
            self.event('PreToolUse', tool_name='Bash', tool_use_id='denied',
                       agent_id='loser', tool_input={'command': command})
        self.assertFalse(list(self.state.rglob('*.tsv')))
        self.assertEqual(self.event('SubagentStop', agent_id='reader',
            last_assistant_message='Changed: source\nVerify: npm test passed'), {})

    def test_claude_interrupted_check_keeps_unknown_outcome(self):
        self.change()
        fields = dict(tool_name='Bash', tool_use_id='interrupted', tool_input={'command': 'python3 tests/test-check.py'})
        self.event('PreToolUse', **fields)
        self.event('PostToolUse', tool_response={'interrupted': True, 'stdout': 'Ran 3 tests'}, **fields)
        self.assert_blocked()

    def test_claude_child_prose_and_session_do_not_supply_execution(self):
        self.run_check()
        self.assertEqual(self.event('Stop', agent_id='child', last_assistant_message='Verification: PASS — tests passed').get('decision'), 'block')


CODEX_ONLY = KEEP | {name for name in dir(ProportionalTests) if name.startswith('test_codex_')} | {'test_prop_crash_after_observed_exit_keeps_failed_record', 'test_prop_failed_exit_survives_invalid_fingerprint', 'test_prop_missing_post_recovers_only_reserved_completed_receipt'}
for name in CODEX_ONLY:
    setattr(ClaudeTests, name, None)

if __name__ == '__main__':
    unittest.main()
