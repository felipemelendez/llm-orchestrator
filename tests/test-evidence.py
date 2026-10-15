#!/usr/bin/env python3
"""Deterministic receipt tests. Receipts record; nothing is reused.

No model calls, provider credentials or paid evaluations.
"""
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts/lib' / (name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


E = load('orch-evidence')
C = load('orch-completion-check')


class Recognition(unittest.TestCase):
    def test_node_native_runner_and_inspection(self):
        for command in ('node --test', 'node --test tests/example.test.mjs',
                        'node --import loader.mjs --test', 'node --test-reporter tap --test',
                        'node --test-timeout 300 --test', 'node --env-file .env --test',
                        'node --test-coverage-include src/** --test',
                        'node --test-global-setup setup.mjs --test',
                        'env CI=1 node --test tests/a.js'):
            with self.subTest(command=command):
                self.assertTrue(C.ran_a_check(command))
        for command in ('node program.js --test', 'node -- --test', 'node --test --help',
                        'node --check --test', 'node -e "console.log(1)" --test',
                        'node --test-list-only --test', 'echo node --test', 'node --version --test'):
            with self.subTest(command=command):
                self.assertFalse(C.ran_a_check(command))

    def test_node_inspection_only_options_are_not_checks(self):
        for command in ('node --test --v8-options', 'node --test --completion-bash',
                        'node --test --prof-process', 'node --run=test --test', 'node --test --eval=1',
                        'node --build-snapshot --test'):
            with self.subTest(command=command):
                self.assertFalse(C.ran_a_check(command))

    def test_custom_exact_argv_not_prefix_or_echo(self):
        checks = [['node', 'scripts/catalog.mjs', '--verify']]
        self.assertTrue(C.ran_a_check('node scripts/catalog.mjs --verify', check_commands=checks))
        self.assertTrue(C.ran_a_check('env CI=1 node scripts/catalog.mjs --verify', check_commands=checks))
        for command in ('node scripts/catalog.mjs --verify --help', 'echo node scripts/catalog.mjs --verify',
                        'node scripts/catalog.mjs', 'node scripts/catalog.mjs --verify-extra'):
            self.assertFalse(C.ran_a_check(command, check_commands=checks), command)


class Receipts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='orch-evidence-test-')
        self.base = Path(self.temp.name)
        self.project = self.base / 'generic'
        self.project.mkdir()
        self.state = self.base / 'evidence'
        self.env_patch = patch.dict(os.environ, {'XDG_STATE_HOME': str(self.base / 'state')})
        self.env_patch.start()
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Synthetic test')
        self.run_git('config', 'user.email', 'synthetic@example.invalid')
        (self.project / 'src').mkdir()
        (self.project / 'src/value.txt').write_text('original')
        (self.project / 'src/check.py').write_text(
            'import unittest\nfrom pathlib import Path\n\n\nclass Value(unittest.TestCase):\n'
            '    def test_value(self):\n        print(Path("src/value.txt").read_text())\n')
        (self.project / 'POLICY.md').write_text('Independent review is required.\n')
        self.config = {'schema': 1, 'policies': ['POLICY.md'], 'checks': {'unit': {
            'argv': [sys.executable, '-B', '-m', 'unittest', 'src/check.py'],
            'inputs': ['src/**'], 'environment': ['ORCH_TEST_VARIANT'], 'tools': [], 'timeout_s': 10}}}
        self.write_config()
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Synthetic fixture baseline')
        self.rows = []
        self.outcomes = patch.object(E, 'record_outcome', self.rows.append)
        self.outcomes.start()

    def tearDown(self):
        self.outcomes.stop()
        self.env_patch.stop()
        self.temp.cleanup()

    def run_git(self, *args):
        return subprocess.run(['git', *args], cwd=self.project, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write_config(self):
        (self.project / '.llm-orchestrator.json').write_text(json.dumps(self.config))

    def check(self):
        return E.run_check(self.project, 'unit', self.state)

    def receipt(self, result):
        return json.loads((self.state / (result['id'] + '.json')).read_text())

    def signed(self):
        """Every receipt for this project whose signature verifies, oldest first."""
        return E.Store(self.state).records(E.identity(self.project))

    def test_without_cadence_and_with_disabled_hooks(self):
        with patch.dict(os.environ, {'ORCH_DISABLED_HOOKS': 'all', 'ORCH_HOOK_PROFILE': 'minimal'}):
            self.assertEqual(self.check()['exit_code'], 0)
        self.assertFalse((self.project / 'docs/llm-orchestrator/cadence.json').exists())
        self.assertEqual(len(self.rows), 1)

    def test_a_check_always_runs_and_nothing_is_reused(self):
        # Receipts record; they do not reuse. The same check on the same inputs runs again.
        self.assertNotIn('reuse', inspect.signature(E.run_check).parameters)
        for name in ('nonempty_execution', 'readonly_argv', 'copy_inputs', 'supported_reuse_command'):
            self.assertFalse(hasattr(E, name), name)
        first, second = self.check(), self.check()
        self.assertEqual((first['status'], second['status']), ('complete', 'complete'))
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual([row['receipt_id'] for row in self.rows], [first['id'], second['id']])
        for result in (first, second):
            self.assertIn('Ran 1 test', (self.state / (result['id'] + '.log')).read_text())
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            E.main(['check', '--project', str(self.project), '--name', 'unit', '--reuse'])

    def test_a_passing_run_writes_a_signed_receipt_with_what_ran(self):
        (self.project / 'src/value.txt').write_text('dirty')
        (self.project / 'src/new.txt').write_text('untracked input')
        result = self.check()
        self.assertEqual(result['exit_code'], 0)
        [receipt] = self.signed()
        self.assertEqual(receipt['id'], result['id'])
        self.assertEqual(receipt['status'], 'complete')
        self.assertEqual(receipt['argv'], self.config['checks']['unit']['argv'])
        self.assertEqual(receipt['cwd'], str(self.project.resolve()))
        self.assertLessEqual(receipt['started_ns'], receipt['finished_ns'])
        self.assertEqual(receipt['revision'], self.run_git('rev-parse', 'HEAD'))
        self.assertEqual(receipt['project_id'], E.identity(self.project))
        log = (self.state / (result['id'] + '.log')).read_bytes()
        self.assertEqual(receipt['output_sha256'], hashlib.sha256(log).hexdigest())
        self.assertEqual(receipt['inputs']['src/value.txt']['sha256'], hashlib.sha256(b'dirty').hexdigest())
        self.assertIn('src/new.txt', receipt['inputs'])
        self.assertIn('POLICY.md', receipt['inputs'])
        self.assertEqual(receipt['check_sha256'], E.digest(self.config['checks']['unit']))
        self.assertIn('policy_context_sha256', receipt)
        self.assertIn('variables_sha256', receipt['environment'])
        self.assertEqual(receipt['environment']['tools'][sys.executable]['path'], str(Path(sys.executable).resolve()))
        self.assertTrue(receipt['stable'])

    def test_a_failing_run_writes_a_signed_failed_result(self):
        (self.project / 'src/check.py').write_text(
            'import unittest\n\n\nclass Value(unittest.TestCase):\n'
            '    def test_value(self):\n        self.fail("synthetic failure")\n')
        result = self.check()
        self.assertEqual(result['exit_code'], 1)
        [receipt] = self.signed()
        self.assertEqual((receipt['status'], receipt['exit_code']), ('complete', 1))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(E.main(['check', '--project', str(self.project), '--name', 'unit',
                                     '--state-dir', str(self.state)]), 1)

    def test_environment_and_policy_are_fingerprinted(self):
        first = self.receipt(self.check())
        with patch.dict(os.environ, {'ORCH_TEST_VARIANT': 'different'}):
            second = self.receipt(self.check())
        (self.project / 'POLICY.md').write_text('Two independent reviews are required.\n')
        third = self.receipt(self.check())
        self.assertNotEqual(first['environment']['variables_sha256'], second['environment']['variables_sha256'])
        self.assertEqual(first['policy_context_sha256'], second['policy_context_sha256'])
        self.assertNotEqual(second['policy_context_sha256'], third['policy_context_sha256'])

    def test_actual_executable_is_fingerprinted_without_tools(self):
        binary = self.base / 'pytest'
        binary.write_text('#!/bin/sh\necho "1 passed in 0.01s"\n')
        binary.chmod(0o755)
        self.config['checks']['unit']['argv'] = [str(binary)]
        self.write_config()
        first = self.receipt(self.check())
        binary.write_text('#!/bin/sh\necho "2 passed in 0.01s"\n')
        second = self.receipt(self.check())
        key = str(binary)
        self.assertNotEqual(first['environment']['tools'][key]['sha256'], second['environment']['tools'][key]['sha256'])

    def test_tool_versions_are_recorded(self):
        definition = dict(self.config['checks']['unit'], tools=['python3'])
        env, fingerprint = E.environment(definition)
        self.assertEqual(env['HOME'], os.environ['HOME'])
        self.assertIn('version_sha256', fingerprint['tools']['python3'])

    def test_tests_ran_is_recorded_as_what_the_runner_printed(self):
        result = self.check()
        receipt = self.receipt(result)
        self.assertEqual((result['tests_ran'], receipt['tests_ran']), (1, 1))
        self.assertEqual(receipt['tests_ran_is'], 'what the runner printed, not proof')
        script = self.project / 'src/check.sh'
        script.write_text('#!/bin/sh\necho hello\n')
        script.chmod(0o755)
        self.config['checks']['unit']['argv'] = ['src/check.sh']
        self.write_config()
        self.assertEqual(self.receipt(self.check())['tests_ran'], 'unknown')

    def test_a_printed_fake_summary_is_simply_recorded(self):
        # A wholly skipped suite whose module prints a fake summary: recorded, never believed.
        (self.project / 'src/check.py').write_text(
            'import unittest\nprint("Ran 5 tests in 0.0s")\n\n\nclass Value(unittest.TestCase):\n'
            '    @unittest.skip("synthetic")\n    def test_value(self):\n        pass\n')
        receipt = self.receipt(self.check())
        self.assertEqual((receipt['exit_code'], receipt['tests_ran']), (0, 5))
        self.assertEqual(receipt['tests_ran_is'], 'what the runner printed, not proof')

    @unittest.skipUnless(shutil.which('node'), 'node is not installed')
    def test_a_node_file_with_no_tests_is_recorded_as_node_counts_it(self):
        # Node counts a file with no test() calls as one passing test.
        (self.project / 'src/empty.test.mjs').write_text('// no tests\n')
        self.config['checks']['unit']['argv'] = ['node', '--test', 'src/empty.test.mjs']
        self.write_config()
        receipt = self.receipt(self.check())
        self.assertEqual((receipt['exit_code'], receipt['tests_ran']), (0, 1))
        self.assertEqual(receipt['tests_ran_is'], 'what the runner printed, not proof')

    def test_evidence_state_is_rejected_inside_git_before_creation(self):
        state = self.project / 'new-state' / 'receipts'
        with self.assertRaisesRegex(ValueError, 'outside'):
            E.run_check(self.project, 'unit', state)
        self.assertFalse(state.exists())
        for directory in (self.project / '.git' / 'new-state', self.base / 'bare.git' / 'new-state'):
            if directory.parent.name == 'bare.git':
                subprocess.run(['git', 'init', '--bare', '-q', str(directory.parent)], check=True)
            with self.assertRaisesRegex(ValueError, 'outside'):
                E.Store(directory, self.project)
            self.assertFalse(directory.exists())

    def test_partial_cost_stays_unknown(self):
        path = self.base / 'outcomes.jsonl'
        path.write_text(json.dumps({'row': 'review', 'project_id': E.identity(self.project),
                                    'cost_usd': 0.12, 'cost_complete': False}) + '\n')
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            report = E.report(self.project, self.state)
        self.assertEqual(report['unknown_cost_records'], 1)
        self.assertEqual(report['observed_cost_usd'], 0.12)

    def test_usage_groups_observed_roles_and_delivery_attempts(self):
        path = self.base / 'outcomes.jsonl'
        launch = {'provider': 'codex', 'role': 'writer', 'requested_model': 'current-model',
                  'requested_effort': 'medium', 'served_model': ['current-model'],
                  'served_effort': ['medium'], 'cost_usd': None, 'tokens': {'input_tokens': 12}}
        row = {'row': 'review', 'project_id': E.identity(self.project), 'delivery_id': 'ticket-1',
               'cost_usd': None, 'cost_complete': False, 'launches': [launch]}
        path.write_text(json.dumps(row) + '\n')
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            report = E.report(self.project, self.state)
        profile = report['role_profiles'][0]
        self.assertEqual(profile['served_efforts'], ['medium'])
        self.assertEqual(profile['tokens']['input_tokens'], 12)
        self.assertEqual(profile['unknown_cost_attempts'], 1)
        self.assertIsNone(report['validated_deliveries'])
        self.assertIsNone(report['linked_deliveries']['ticket-1']['validated'])
        self.assertNotIn('checks_reused', report)

    def test_ignored_policy_is_rejected(self):
        (self.project / 'private-policy.md').write_text('one')
        (self.project / '.gitignore').write_text('private-policy.md\n')
        self.config['policies'].append('private-policy.md')
        self.write_config()
        with self.assertRaisesRegex(ValueError, 'ignored'):
            self.check()

    def test_input_changed_by_the_check_is_recorded_as_unstable(self):
        self.config['checks']['unit']['argv'] = [sys.executable, '-c',
            'from pathlib import Path;Path("src/value.txt").write_text("changed");print("done")']
        self.write_config()
        result = self.check()
        self.assertFalse(result['stable'])
        self.assertFalse(self.receipt(result)['stable'])

    def test_tampered_receipt_is_refused_when_reporting(self):
        first = self.check()
        receipt = self.state / (first['id'] + '.json')
        altered = json.loads(receipt.read_text())
        altered['revision'] = 'forged'
        receipt.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, 'signature'):
            E.report(self.project, self.state)

    def test_symlink_and_empty_scope_are_rejected(self):
        (self.project / 'src/link').symlink_to('/etc/hosts')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.check()
        (self.project / 'src/link').unlink()
        self.config['checks']['unit']['inputs'] = ['missing/**']
        self.write_config()
        with self.assertRaisesRegex(ValueError, 'scope'):
            self.check()

    def test_mia_rules_preserved_and_custom_checks_recognized(self):
        self.config['project_rules'] = {
            'review': {'minimum_independent_reviews': 1, 'high_risk_independent_reviews': 2,
                       'non_author_final_verification': True, 'confirmed_defects_block': True},
            'wip': {'active': 2, 'parked': 1, 'total': 3},
            'delivery': {'merge_method': 'squash', 'handoff': 'github',
                         'exact_revision': True, 'post_merge_verification': True}}
        self.write_config()
        self.assertEqual(self.check()['exit_code'], 0)
        self.assertEqual(C.configured_check_commands(self.project), [self.config['checks']['unit']['argv']])

    def test_directory_input_covers_every_file_under_it(self):
        self.config['checks']['unit']['inputs'] = ['src']
        self.write_config()
        first = self.receipt(self.check())
        self.assertIn('src/value.txt', first['inputs'])
        (self.project / 'src/value.txt').write_text('changed under a directory input')
        second = self.receipt(self.check())
        self.assertNotEqual(first['inputs']['src/value.txt'], second['inputs']['src/value.txt'])
        self.assertEqual(sorted(E.scoped({'src/a.py': 'file', 'srcx.py': 'file', 'lib/b.py': 'file'},
                                         {'inputs': ['src/', 'lib/*.py']}, type('P', (), {'data': {}}))),
                         ['lib/b.py', 'src/a.py'])

    def test_out_of_scope_symlink_and_submodule_do_not_block_a_check(self):
        (self.project / 'docs-link.md').symlink_to('POLICY.md')
        sub = self.base / 'sub'
        sub.mkdir()
        subprocess.run(['git', 'init', '-q'], cwd=sub, check=True)
        subprocess.run(['git', '-c', 'user.name=s', '-c', 'user.email=s@example.invalid', 'commit', '-q',
                        '--allow-empty', '-m', 'synthetic'], cwd=sub, check=True)
        commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=sub, check=True, capture_output=True,
                                text=True).stdout.strip()
        self.run_git('update-index', '--add', '--cacheinfo', '160000,%s,vendor/sub' % commit)
        self.assertEqual(self.check()['exit_code'], 0)
        for inputs in (['docs-link.md'], ['vendor/**']):
            self.config['checks']['unit']['inputs'] = inputs
            self.write_config()
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                self.check()

    def test_out_of_scope_linked_folder_does_not_block_a_check(self):
        (self.project / 'other').mkdir()
        (self.project / 'other/x.txt').write_text('tracked under a folder that becomes a link\n')
        self.run_git('add', 'other/x.txt')
        self.run_git('commit', '-qm', 'Synthetic out-of-scope entry')
        target = self.base / 'elsewhere'
        target.mkdir()
        (target / 'x.txt').write_text('tracked under a folder that becomes a link\n')
        (self.project / 'other/x.txt').unlink()
        (self.project / 'other').rmdir()
        (self.project / 'other').symlink_to(target)
        self.assertEqual(self.check()['exit_code'], 0)

    def test_a_bad_receipt_never_blocks_a_run_and_is_named_when_reporting(self):
        first = self.check()
        (self.state / 'foreign.json').write_text('{"from": "another project or key"}')
        # code-review-7: a RecursionError while parsing is an unreadable receipt, not tampering.
        (self.state / 'corrupt.json').write_text('[' * 1000000)
        fresh = self.check()
        self.assertEqual(fresh['exit_code'], 0)
        self.assertNotIn('skipped_receipts', fresh)
        report = E.report(self.project, self.state)
        self.assertEqual(report['skipped_receipts'], ['corrupt.json', 'foreign.json'])
        self.assertEqual(report['receipts'], 2)
        self.assertNotEqual(fresh['id'], first['id'])

    def test_interrupt_kills_the_check_and_is_never_a_complete_receipt(self):
        original = subprocess.Popen.wait
        children = []
        def interrupted(process, timeout=None):
            if timeout is not None and 'time.sleep(30)' in str(process.args):
                children.append(process.pid)
                raise KeyboardInterrupt
            return original(process)
        self.config['checks']['unit'].update(argv=[sys.executable, '-c', 'import time; time.sleep(30)'])
        self.write_config()
        with patch.object(subprocess.Popen, 'wait', interrupted):
            with self.assertRaises(KeyboardInterrupt):
                self.check()
        with self.assertRaises(ProcessLookupError):
            os.killpg(children[0], 0)
        [receipt] = self.signed()
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(self.rows[-1]['failed'], True)

    def test_usage_reports_capacity_wait(self):
        path = self.base / 'outcomes.jsonl'
        project_id = E.identity(self.project)
        rows = [{'row': 'launch', 'project_id': project_id, 'capacity': {'wait_s': 2.5}},
                {'row': 'review', 'project_id': project_id, 'launches': [{'capacity': {'wait_s': 0.5}}]}]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            self.assertEqual(E.report(self.project, self.state)['capacity_wait_s'], 3.0)
        path.write_text(json.dumps({'row': 'launch', 'project_id': project_id}) + '\n')
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            self.assertIsNone(E.report(self.project, self.state)['capacity_wait_s'])

    def test_relative_executable_resolves_against_the_project(self):
        script = self.project / 'check.sh'
        script.write_text('#!/bin/sh\necho project check\n')
        script.chmod(0o755)
        self.config['checks']['unit']['argv'] = ['./check.sh']
        self.write_config()
        caller = self.base / 'caller'
        caller.mkdir()
        decoy = caller / 'check.sh'
        decoy.write_text('#!/bin/sh\necho decoy\n')
        decoy.chmod(0o755)
        previous = os.getcwd()
        os.chdir(caller)
        try:
            result = self.check()
        finally:
            os.chdir(previous)
        self.assertEqual(result['exit_code'], 0)
        receipt = self.receipt(result)
        tool = receipt['environment']['tools'][str(script.resolve())]
        self.assertEqual(tool['path'], str(script.resolve()))
        self.assertIn('check.sh', receipt['inputs'])
        self.assertEqual((self.state / (result['id'] + '.log')).read_text(), 'project check\n')

    def test_receipt_records_the_environment_that_ran(self):
        seen = {}
        real = E.execute
        def capture(argv, cwd, env, output, timeout):
            seen['env'] = dict(env)
            return real(argv, cwd, env, output, timeout)
        with patch.object(E, 'execute', side_effect=capture):
            receipt = self.receipt(self.check())
        self.assertEqual(receipt['environment']['variables_sha256'], E.digest(seen['env']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
