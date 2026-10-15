#!/usr/bin/env python3
"""Deterministic receipt regression tests; sandbox positives are synthetic.

Live OS sandbox proof is deliberately separate from this portable suite.
No model calls, provider credentials or paid evaluations.
"""
import importlib.util
import json
import os
from pathlib import Path
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
        (self.project / 'src/check.py').write_text('from pathlib import Path\nprint(Path("src/value.txt").read_text())\n')
        (self.project / 'POLICY.md').write_text('Independent review is required.\n')
        self.config = {'schema': 1, 'policies': ['POLICY.md'], 'checks': {'unit': {
            'argv': [sys.executable, 'src/check.py'],
            'inputs': ['src/**'], 'environment': ['ORCH_TEST_VARIANT'], 'tools': [],
            'timeout_s': 10, 'reuse': True, 'immutable': True}}}
        self.write_config()
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Synthetic fixture baseline')
        self.rows = []
        self.outcomes = patch.object(E, 'record_outcome', self.rows.append)
        self.outcomes.start()
        # Simulated immutable adapter for receipt state-machine tests only.
        self.proof = patch.object(E, 'readonly_argv', return_value=(
            [sys.executable, '-c', 'import os,sys;os.execvp(sys.argv[1],sys.argv[1:])'],
            'synthetic sandbox adapter'))
        self.proof.start()

    def tearDown(self):
        self.proof.stop()
        self.outcomes.stop()
        self.env_patch.stop()
        self.temp.cleanup()

    def run_git(self, *args):
        return subprocess.run(['git', *args], cwd=self.project, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write_config(self):
        (self.project / '.llm-orchestrator.json').write_text(json.dumps(self.config))

    def check(self, reuse=False):
        return E.run_check(self.project, 'unit', reuse, self.state)

    def test_without_cadence_and_with_disabled_hooks(self):
        with patch.dict(os.environ, {'ORCH_DISABLED_HOOKS': 'all', 'ORCH_HOOK_PROFILE': 'minimal'}):
            first = self.check()
            second = self.check(True)
        self.assertEqual(first['exit_code'], 0)
        self.assertTrue(first['reusable'])
        self.assertEqual(second['status'], 'reused')
        self.assertFalse((self.project / 'docs/llm-orchestrator/cadence.json').exists())
        self.assertEqual(len(self.rows), 2)

    def test_wrapped_empty_node_suite_is_not_reusable(self):
        output = b'# tests 1\n# pass 0\n# fail 0\n# cancelled 0\n# skipped 1\n'
        self.assertFalse(E.nonempty_execution(['env', 'node', '--test', 'src/test.mjs'], output))
        self.assertFalse(E.supported_reuse_command(['env', 'node', '--test', 'src/test.mjs']))

    def test_actual_executable_is_fingerprinted_without_tools(self):
        binary = self.base / 'custom-check'
        binary.write_text('#!/bin/sh\necho first\n')
        binary.chmod(0o755)
        self.config['checks']['unit']['argv'] = [str(binary)]
        self.write_config()
        first = self.check()
        binary.write_text('#!/bin/sh\necho changed\n')
        second = self.check(True)
        self.assertTrue(first['reusable'])
        self.assertEqual(second['status'], 'complete')

    def test_version_probe_uses_absolute_owned_home(self):
        definition = dict(self.config['checks']['unit'], tools=['python3'])
        original = subprocess.run
        seen = []
        def observe(argv, **kwargs):
            if '--version' in argv:
                seen.append(kwargs['env']['HOME'])
                self.assertTrue(Path(seen[-1]).is_absolute())
                self.assertNotIn('__ORCH_OWNED_HOME__', seen[-1])
            return original(argv, **kwargs)
        with patch.object(E.subprocess, 'run', side_effect=observe):
            env, fingerprint = E.environment(definition)
        self.assertTrue(seen)
        self.assertEqual(env['HOME'], '__ORCH_OWNED_HOME__')
        self.assertIn('python3', fingerprint['tools'])
        self.assertFalse(Path(seen[0]).exists())

    def test_evidence_state_is_rejected_inside_git_before_creation(self):
        state = self.project / 'new-state' / 'receipts'
        with self.assertRaisesRegex(ValueError, 'outside'):
            E.run_check(self.project, 'unit', False, state)
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
            report = E.report(self.project)
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
            report = E.report(self.project)
        profile = report['role_profiles'][0]
        self.assertEqual(profile['served_efforts'], ['medium'])
        self.assertEqual(profile['tokens']['input_tokens'], 12)
        self.assertEqual(profile['unknown_cost_attempts'], 1)
        self.assertIsNone(report['validated_deliveries'])
        self.assertIsNone(report['linked_deliveries']['ticket-1']['validated'])

    def test_revision_change_can_reuse_identical_scoped_inputs(self):
        first = self.check()
        (self.project / 'README.md').write_text('An unrelated document.\n')
        self.run_git('add', 'README.md')
        self.run_git('commit', '-qm', 'Synthetic unrelated revision')
        second = self.check(True)
        self.assertEqual(second['status'], 'reused')
        self.assertNotEqual(first['revision'], second['revision'])
        self.assertEqual(first['revision'], second['source_revision'])

    def test_dirty_and_untracked_scope_changes_invalidate(self):
        self.check()
        (self.project / 'src/value.txt').write_text('dirty')
        self.assertEqual(self.check(True)['status'], 'complete')
        (self.project / 'src/new.txt').write_text('untracked input')
        self.assertEqual(self.check(True)['status'], 'complete')

    def test_environment_and_policy_changes_invalidate(self):
        self.check()
        with patch.dict(os.environ, {'ORCH_TEST_VARIANT': 'different'}):
            self.assertEqual(self.check(True)['status'], 'complete')
        (self.project / 'POLICY.md').write_text('Two independent reviews are required.\n')
        self.assertEqual(self.check(True)['status'], 'complete')

    def test_ignored_policy_is_rejected_instead_of_reused(self):
        self.check()
        (self.project / 'private-policy.md').write_text('one')
        (self.project / '.gitignore').write_text('private-policy.md\n')
        self.config['policies'].append('private-policy.md')
        self.write_config()
        with self.assertRaisesRegex(ValueError, 'ignored'):
            self.check(True)

    def test_unsupported_external_and_inline_commands_are_record_only(self):
        self.config['checks']['unit']['argv'] = [sys.executable, '-c', 'print("external dependencies unknown")']
        self.write_config()
        self.assertFalse(self.check()['reusable'])
        self.assertFalse(E.supported_reuse_command(['node', 'check.js', '/private/tmp/external-input']))

    def test_wholly_skipped_or_todo_node_suites_do_not_qualify(self):
        for summary in (b'# tests 0\n# pass 0\n', b'# tests 1\n# pass 0\n# skipped 1\n',
                        b'# tests 1\n# pass 0\n# todo 1\n', b'# tests 1\n# pass 1\n# fail 1\n'):
            self.assertFalse(E.nonempty_execution(['node', '--test'], summary))
        self.assertTrue(E.nonempty_execution(['node', '--test'], b'# tests 2\n# pass 1\n# skipped 1\n# fail 0\n'))

    def test_tool_version_change_invalidates(self):
        self.check()
        original = E.environment
        def changed(definition):
            env, info = original(definition)
            return env, dict(info, tools={'node': {'version': 'synthetic-changed'}})
        with patch.object(E, 'environment', side_effect=changed):
            self.assertEqual(self.check(True)['status'], 'complete')

    def test_verification_engine_change_invalidates(self):
        self.check()
        with patch.object(E, 'engine_fingerprint', return_value={'version': 'changed engine'}):
            self.assertEqual(self.check(True)['status'], 'complete')

    def test_missing_sandbox_is_record_only_and_never_reuses(self):
        with patch.object(E, 'readonly_argv', return_value=(None, 'unavailable sandbox')):
            first = self.check()
            second = self.check(True)
        self.assertEqual(first['exit_code'], 0)
        self.assertFalse(first['reusable'])
        self.assertEqual(second['status'], 'complete')

    def test_aba_mutation_is_never_reused_without_immutable_execution(self):
        self.config['checks']['unit'].update(immutable=False, argv=[sys.executable, '-c',
            'from pathlib import Path;p=Path("src/value.txt");s=p.read_text();p.write_text("mutated");'
            'assert p.read_text()=="mutated";p.write_text(s);print("ABA restored")'])
        self.write_config()
        first = self.check()
        self.assertTrue(first['stable'])
        self.assertFalse(first['reusable'])
        self.assertEqual(self.check(True)['status'], 'complete')

    def test_detected_source_mutation_is_not_reusable(self):
        self.config['checks']['unit'].update(immutable=False, argv=[sys.executable, '-c',
            'from pathlib import Path;Path("src/value.txt").write_text("changed");print("done")'])
        self.write_config()
        result = self.check()
        self.assertFalse(result['stable'])
        self.assertFalse(result['reusable'])

    def test_latest_failure_and_pending_attempt_shadow_old_pass(self):
        self.check()
        store = E.Store(self.state)
        prior = store.records(E.identity(self.project), 'unit')[-1]
        prior.update(id='a' * 32, started_ns=prior['started_ns'] + 1,
                     status='running', reusable=False)
        store.write(prior)
        self.assertEqual(self.check(True)['status'], 'complete')
        prior = store.records(E.identity(self.project), 'unit')[-1]
        prior.update(id='b' * 32, started_ns=prior['started_ns'] + 1,
                     status='complete', reusable=False, exit_code=1)
        store.write(prior)
        self.assertEqual(self.check(True)['status'], 'complete')

    def test_tampered_receipt_or_output_rejected(self):
        first = self.check()
        receipt = self.state / (first['id'] + '.json')
        original = receipt.read_text()
        altered = json.loads(original)
        altered['revision'] = 'forged'
        receipt.write_text(json.dumps(altered))
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.check(True)
        receipt.write_text(original)
        (self.state / (first['id'] + '.log')).write_text('changed output')
        with self.assertRaisesRegex(ValueError, 'output'):
            self.check(True)

    def test_other_repository_never_borrows_receipt(self):
        self.check()
        other = self.base / 'other'
        subprocess.run(['git', 'clone', '-q', str(self.project), str(other)], check=True)
        result = E.run_check(other, 'unit', True, self.state)
        self.assertEqual(result['status'], 'complete')

    def test_symlink_and_empty_scope_are_rejected(self):
        (self.project / 'src/link').symlink_to('/etc/hosts')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.check()
        (self.project / 'src/link').unlink()
        self.config['checks']['unit']['inputs'] = ['missing/**']
        self.write_config()
        with self.assertRaisesRegex(ValueError, 'scope'):
            self.check()

    def test_explicit_no_reuse_and_no_empty_test_pass(self):
        self.config['checks']['unit'].update(reuse=False)
        self.write_config()
        self.assertFalse(self.check()['reusable'])
        self.assertEqual(self.check(True)['status'], 'complete')
        self.config['checks']['unit'].update(reuse=True, argv=[sys.executable, '-c', 'print("# tests 0")'])
        self.write_config()
        self.assertFalse(self.check()['reusable'])

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
        first = self.check()
        self.assertTrue(first['reusable'])
        receipt = json.loads((self.state / (first['id'] + '.json')).read_text())
        self.assertIn('src/value.txt', receipt['inputs'])
        (self.project / 'src/value.txt').write_text('changed under a directory input')
        self.assertEqual(self.check(True)['status'], 'complete')
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
        self.config['checks']['unit']['immutable'] = False
        self.write_config()
        self.assertEqual(self.check()['exit_code'], 0)
        for inputs in (['docs-link.md'], ['vendor/**']):
            self.config['checks']['unit']['inputs'] = inputs
            self.write_config()
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                self.check()

    def test_a_bad_receipt_never_blocks_a_fresh_run_and_is_named_when_reusing(self):
        first = self.check()
        (self.state / 'foreign.json').write_text('{"from": "another project or key"}')
        fresh = self.check()
        self.assertEqual(fresh['exit_code'], 0)
        self.assertNotIn('skipped_receipts', fresh)
        again = self.check(True)
        self.assertEqual(again['status'], 'complete')
        self.assertEqual(again['skipped_receipts'], ['foreign.json'])
        self.assertNotEqual(again['id'], first['id'])

    def test_interrupt_kills_the_check_and_is_never_a_complete_receipt(self):
        original = subprocess.Popen.wait
        children = []
        def interrupted(process, timeout=None):
            if timeout is not None and 'time.sleep(30)' in str(process.args):
                children.append(process.pid)
                raise KeyboardInterrupt
            return original(process)
        self.config['checks']['unit'].update(immutable=False, argv=[sys.executable, '-c', 'import time; time.sleep(30)'])
        self.write_config()
        with patch.object(subprocess.Popen, 'wait', interrupted):
            with self.assertRaises(KeyboardInterrupt):
                self.check()
        with self.assertRaises(ProcessLookupError):
            os.killpg(children[0], 0)
        receipts = [json.loads(path.read_text()) for path in self.state.glob('*.json')]
        self.assertEqual([receipt['status'] for receipt in receipts], ['failed'])
        self.assertEqual(self.rows[-1]['failed'], True)

    def test_usage_reports_capacity_wait(self):
        path = self.base / 'outcomes.jsonl'
        project_id = E.identity(self.project)
        rows = [{'row': 'launch', 'project_id': project_id, 'capacity': {'wait_s': 2.5}},
                {'row': 'review', 'project_id': project_id, 'launches': [{'capacity': {'wait_s': 0.5}}]}]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            self.assertEqual(E.report(self.project)['capacity_wait_s'], 3.0)
        path.write_text(json.dumps({'row': 'launch', 'project_id': project_id}) + '\n')
        with patch.object(E.module('orch-review'), 'outcome_path', return_value=path):
            self.assertIsNone(E.report(self.project)['capacity_wait_s'])

    def test_zero_test_and_collection_only_runs_are_never_reusable(self):
        for argv, output in (
                (['python3', '-m', 'unittest', 'discover'], b'Ran 0 tests in 0.000s\n\nOK\n'),
                (['python3', '-m', 'pytest', '--collect-only', '-q'], b'tests/test_a.py::test_one\n\n1 test collected\n'),
                (['pytest'], b'collected 0 items\n\n=== no tests ran in 0.01s ===\n'),
                (['node', '--test'], b'# tests 0\n# pass 0\n'),
                (['go', 'test', './...'], b'?   \texample/pkg\t[no test files]\n'),
                (['go', 'test', './...'], b'ok  \texample/pkg\t0.01s [no tests to run]\n'),
                (['python3', 'run.py'], b'Ran 0 tests in 0.000s\n\nOK\n'),
                (['python3', 'run.py'], b'')):
            with self.subTest(argv=argv, output=output):
                self.assertFalse(E.tests_ran(argv, output))
                self.assertFalse(E.nonempty_execution(argv, output))
        self.assertEqual(E.tests_ran(['python3', '-m', 'pytest'], b'something unreadable\n'), 'unknown')
        self.assertFalse(E.nonempty_execution(['python3', '-m', 'pytest'], b'something unreadable\n'))
        self.assertIs(E.tests_ran(['python3', '-m', 'unittest'], b'Ran 2 tests in 0.1s\n\nOK\n'), True)
        self.assertIs(E.tests_ran(['pytest', '-q'], b'2 passed in 0.01s\n'), True)
        self.assertIs(E.tests_ran(['go', 'test', './...'], b'ok  \texample/pkg\t0.01s\n'), True)
        self.assertEqual(E.tests_ran(['./check.sh'], b'custom output\n'), 'custom')
        # A wrapper whose runner found nothing: exit 0 with a zero-test summary.
        (self.project / 'src/zero.py').write_text('print("Ran 0 tests in 0.000s")\nprint()\nprint("OK")\n')
        self.config['checks']['unit']['argv'] = [sys.executable, 'src/zero.py']
        self.write_config()
        result = self.check()
        self.assertEqual(result['exit_code'], 0)
        self.assertFalse(result['reusable'])
        receipt = json.loads((self.state / (result['id'] + '.json')).read_text())
        self.assertIs(receipt['tests_ran'], False)
        self.assertEqual(self.check(True)['status'], 'complete')

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
        receipt = json.loads((self.state / (result['id'] + '.json')).read_text())
        tool = receipt['environment']['tools'][str(script.resolve())]
        self.assertEqual(tool['path'], str(script.resolve()))
        self.assertIn('check.sh', receipt['inputs'])
        self.assertEqual((self.state / (result['id'] + '.log')).read_text(), 'project check\n')

    def test_sandbox_fallback_records_the_environment_that_ran(self):
        seen = {}
        real = E.execute
        def capture(argv, cwd, env, output, timeout):
            seen['env'] = dict(env)
            return real(argv, cwd, env, output, timeout)
        with patch.object(E, 'readonly_argv', return_value=(None, 'unavailable sandbox')), \
                patch.object(E, 'execute', side_effect=capture):
            result = self.check()
        receipt = json.loads((self.state / (result['id'] + '.json')).read_text())
        self.assertEqual(receipt['environment']['variables_sha256'], E.digest(seen['env']))
        self.assertNotIn('__ORCH_OWNED_HOME__', seen['env'].values())
        self.assertTrue(result['stable'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
