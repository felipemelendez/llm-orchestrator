#!/usr/bin/env python3
"""Signed receipts of checks that ran, independent of Cadence.

A receipt records what ran, on which inputs, and what it printed. It is never
reused: every check runs. Receipts are local records, not an adversarial
attestation service. Review, hosted CI and final approval remain separate.
"""
import argparse
import fnmatch
import functools
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent


@functools.lru_cache(maxsize=None)
def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def atomic(path, value):
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write('\n')
    os.replace(temporary, path)


def git(project, *args):
    return subprocess.run(['git', '-C', str(project), *args], check=True,
                          capture_output=True, timeout=30).stdout


def root(project):
    return Path(os.fsdecode(git(project, 'rev-parse', '--show-toplevel')).strip()).resolve()


def identity(project):
    return module('orch-policy').project_id(project)


def inventory(project):
    """Name every tracked and nonignored untracked path and its kind, without reading contents.

    Kinds: file, missing, symlink, submodule, nonregular. Only scoped() decides
    whether a symlink or submodule matters; one outside the scope never does.
    """
    rows = git(project, 'ls-files', '-s', '-z').split(b'\0')
    gitlinks = {os.fsdecode(row.split(b'\t', 1)[1]) for row in rows if row.startswith(b'160000 ')}
    names = git(project, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
    result = {}
    for raw in sorted(set(names) - {b''}):
        name = os.fsdecode(raw)
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('input escapes repository')
        path = project / relative
        parents = [path, *path.parents]
        if name in gitlinks:
            result[name] = 'submodule'
        elif any(parent.is_symlink() for parent in parents[:parents.index(project)]):
            result[name] = 'symlink'
        elif not path.exists():
            result[name] = 'missing'
        else:
            result[name] = 'file' if path.is_file() else 'nonregular'
    return result


def fingerprint(project, names):
    """Read the actual bytes of the scoped files only; never follow a symlink."""
    result = {}
    for name, kind in names.items():
        path = project / name
        if kind == 'missing' and not os.path.lexists(path):
            result[name] = None
            continue
        if kind != 'file' or path.is_symlink() or not path.is_file():
            raise ValueError('input changed while fingerprinting: ' + name)
        before = path.stat()
        contents = path.read_bytes()
        after = path.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError('input changed while fingerprinting: ' + name)
        result[name] = {'sha256': hashlib.sha256(contents).hexdigest(),
                        'executable': bool(after.st_mode & 0o111)}
    return result


def matches(path, patterns):
    # A plain directory input such as "src" or "src/" covers every file under it.
    return any(pattern in ('*', '**', '**/*') or fnmatch.fnmatchcase(path, pattern)
               or path.startswith(pattern.rstrip('/') + '/')
               or (pattern.startswith('**/') and fnmatch.fnmatchcase(path, pattern[3:])) for pattern in patterns)


def project_relative(name):
    return '/' in name and not Path(name).is_absolute()


def scoped(names, definition, policy):
    patterns = definition['inputs']
    required = {'.llm-orchestrator.json', *policy.data.get('policies', [])}
    executable = definition.get('argv', [''])[0]
    if project_relative(executable):
        # The project's own check script is part of what runs, so it is an input.
        required.add(os.path.normpath(executable))
    result = {name: kind for name, kind in names.items() if name in required or matches(name, patterns)}
    for name, kind in result.items():
        if kind in ('symlink', 'submodule', 'nonregular'):
            raise ValueError(f'{kind} input is unsupported: {name}')
    if not any(matches(name, patterns) and kind == 'file' for name, kind in result.items()):
        raise ValueError('declared scope has no existing input files')
    return result


def resolved(definition, project):
    """The definition whose executable is the project's own file when argv[0] is project-relative.

    That file is a fingerprinted input; the caller's directory never matters.
    """
    executable = definition['argv'][0]
    if not project_relative(executable):
        return definition
    return dict(definition, argv=[str(project / os.path.normpath(executable)), *definition['argv'][1:]])


def environment(definition):
    """Only these inherited variables reach the command; values are never logged."""
    allowed = {'PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'SYSTEMROOT', 'WINDIR'}
    allowed.update(definition.get('environment', []))
    env = {key: value for key, value in os.environ.items() if key in allowed}
    versions = {}
    names = list(dict.fromkeys([definition['argv'][0], *definition.get('tools', [])]))
    for name in names:
        binary = shutil.which(name, path=env.get('PATH'))
        if not binary:
            raise ValueError('required check tool is unavailable: ' + name)
        path = Path(binary).resolve()
        stat = path.stat()
        # An arbitrary custom executable need not implement --version. Its
        # actual bytes are always a dependency; version probes are opt-in.
        observed = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'identity': [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns]}
        if name in definition.get('tools', []):
            result = subprocess.run([str(path), '--version'], env=env, capture_output=True, timeout=15)
            if result.returncode:
                raise ValueError('cannot observe tool version: ' + name)
            observed['version_sha256'] = hashlib.sha256(result.stdout).hexdigest()
        versions[name] = observed
    return env, {'platform': platform.platform(), 'machine': platform.machine(),
                 'variables_sha256': digest(env), 'tools': versions}


class Tampered(Exception):
    """A receipt that claims this project but fails its signature."""


class Store:
    def __init__(self, path=None, project=None):
        self.path = Path(path) if path else Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state') / 'llm-orchestrator' / 'verification'
        if self.path.is_symlink():
            raise ValueError('evidence state directory must not be a symlink')
        resolved = self.path.resolve()
        if project and (resolved == project or project in resolved.parents):
            raise ValueError('evidence state must be outside the project')
        # Check before creating anything, including a not-yet-existing path.
        existing = next(parent for parent in [resolved, *resolved.parents] if parent.exists())
        if subprocess.run(['git', '-C', str(existing), 'rev-parse', '--absolute-git-dir'],
                          capture_output=True, timeout=15).returncode == 0:
            raise ValueError('evidence state must be outside every Git checkout')
        self.path.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.path.resolve()
        key = self.path / 'receipt.key'
        try:
            fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(secrets.token_bytes(32))
        if key.is_symlink() or not key.is_file():
            raise ValueError('invalid receipt key')
        self.key = key.read_bytes()
        if len(self.key) != 32:
            raise ValueError('invalid receipt key length')

    def write(self, record):
        record = dict(record)
        record['signature'] = hmac.new(self.key, canonical(record), hashlib.sha256).hexdigest()
        atomic(self.path / (record['id'] + '.json'), record)

    def records(self, project_id, name=None):
        """This project's signed receipts, for one check or all of them, oldest first.

        Unreadable receipts are skipped and named in self.skipped, so a report can
        say what it could not read. A receipt that claims this project (and check)
        but fails its signature is tampering and raises.
        """
        result, self.skipped = [], []
        for path in sorted(self.path.glob('*.json')):
            try:
                if path.is_symlink():
                    raise ValueError('symlink receipt')
                record = json.loads(path.read_text())
                signature = record.pop('signature')
                ours = record.get('project_id') == project_id and name in (None, record.get('check'))
                if not isinstance(signature, str) or not hmac.compare_digest(
                        signature, hmac.new(self.key, canonical(record), hashlib.sha256).hexdigest()):
                    if ours:
                        raise Tampered('receipt signature mismatch: ' + path.name)
                    raise ValueError('unverified receipt')
                if path.name != record['id'] + '.json' or not isinstance(record['started_ns'], int):
                    raise ValueError('receipt identity mismatch')
                if ours:
                    result.append(record)
            except Tampered as error:
                raise ValueError(str(error)) from None
            except Exception:  # any other unreadable receipt, a RecursionError included
                self.skipped.append(path.name)
        return sorted(result, key=lambda row: (row['started_ns'], row['id']))


def record_outcome(row):
    # Use the existing usage/outcome sink. No parallel live status board.
    module('orch-review').append_outcome(row)


def execute(argv, cwd, env, output, timeout):
    with output.open('wb') as stream:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout), False
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if isinstance(error, KeyboardInterrupt):
                raise  # an interrupted check is never a complete receipt
            return None, True
        finally:
            module('orch-review').kill_group(process)


def tests_ran(argv, output):
    """How many tests the output says ran, skipped tests left out: information only.

    This is what the runner printed, not proof. No reading of runner output can
    prove a test body ran: Node counts a file with no tests as one passing test,
    and a module can print a fake summary. A count for unittest, pytest,
    node --test, go test -v and cargo test; 'unknown' for anything else.
    """
    text = output.decode(errors='replace')
    name = Path(argv[0]).name
    flags = [word.partition('=')[0] for word in argv[1:]]
    module = None
    if re.fullmatch(r'python[0-9.]*', name) and '-m' in argv[1:]:
        at = argv.index('-m', 1)
        if all(word.startswith('-') for word in argv[1:at]) and at + 1 < len(argv):
            module = argv[at + 1]
    if name == 'node' and '--test' in argv:
        counts = dict(re.findall(r'(?m)^(?:#|\u2139) (tests|pass|fail|cancelled|skipped|todo) (\d+)\s*$', text))
        if 'pass' not in counts:
            return 'unknown'
        return int(counts['pass']) + int(counts.get('fail', 0))
    if module == 'unittest':
        ran = re.findall(r'(?m)^Ran (\d+) tests? in ', text)
        if not ran:
            return 'unknown'
        skipped = re.findall(r'(?m)^(?:OK|FAILED) \(.*\bskipped=(\d+)', text)
        return max(0, sum(map(int, ran)) - sum(map(int, skipped)))
    if module == 'pytest' or name in ('pytest', 'py.test'):
        if set(flags) & {'--collect-only', '--co', '--setup-only', '--setup-plan', '--fixtures', '--fixtures-per-test'}:
            return 0
        for line in reversed(text.splitlines()):
            if re.search(r'\bin \d+(\.\d+)?s\b', line) and re.search(
                    r'\b\d+ (passed|failed|skipped|deselected|xfailed|xpassed|errors?)\b|\bno tests ran\b', line):
                return sum(int(value) for value in re.findall(r'\b(\d+) (?:passed|failed|xfailed|xpassed)\b', line))
        return 'unknown'
    if name == 'go' and argv[1:2] == ['test']:
        if set(flags) & {'-list', '--list', '-test.list'}:
            return 0  # names tests without running them
        executed = len(re.findall(r'(?m)^\s*--- (?:PASS|FAIL): ', text))
        if executed:
            return executed
        oks = re.findall(r'(?m)^ok\s.*$', text)
        if re.search(r'(?m)^\s*--- SKIP: ', text) or (
                (oks or '[no test files]' in text) and all('[no tests to run]' in line for line in oks)):
            return 0
        return 'unknown'  # without -v, a package's ok line does not show skipped tests
    if name == 'cargo' and argv[1:2] == ['test']:
        if '--no-run' in argv or '--list' in argv:
            return 0
        results = re.findall(r'(?m)^test result: \w+\. (\d+) passed; (\d+) failed;', text)
        if not results:
            return 'unknown'
        return sum(int(passed) + int(failed) for passed, failed in results)
    return 'unknown'


TESTS_RAN_IS = 'what the runner printed, not proof'


def run_check(project, name, state_dir=None):
    """Run the configured check and write its signed receipt. Every call runs it."""
    project = root(project)
    policy = module('orch-policy').Policy(project)
    definition = policy.data.get('checks', {}).get(name)
    if not definition:
        raise ValueError('unknown configured check: ' + name)
    names = inventory(project)
    context = policy.policy_context()
    if any(item['path'] not in names for item in context['files']):
        raise ValueError('ignored or external policy inputs are unsupported; include canonical policy in source inventory')
    inputs = fingerprint(project, scoped(names, definition, policy))
    runs = resolved(definition, project)
    env, observed_env = environment(runs)
    project_id = identity(project)
    revision = os.fsdecode(git(project, 'rev-parse', 'HEAD')).strip()
    store = Store(state_dir, project)
    record = {'schema': 1, 'id': uuid.uuid4().hex, 'started_ns': time.time_ns(), 'project_id': project_id,
              'project': str(project), 'revision': revision, 'check': name, 'argv': definition['argv'],
              'cwd': str(project), 'check_sha256': digest(definition),
              'policy_context_sha256': digest(context), 'inputs': inputs, 'environment': observed_env,
              'status': 'running'}
    store.write(record)
    start = time.monotonic()
    try:
        output = store.path / (record['id'] + '.log')
        exit_code, timed_out = execute(definition['argv'], project, env, output, definition.get('timeout_s', 600))
        # Recorded, not enforced: did the inputs or environment change while it ran?
        stable = (inputs == fingerprint(project, scoped(inventory(project), definition, policy))
                  and observed_env == environment(runs)[1])
        content = output.read_bytes()
        record.update(status='complete', exit_code=exit_code, timed_out=timed_out, stable=stable,
                      tests_ran=tests_ran(definition['argv'], content), tests_ran_is=TESTS_RAN_IS,
                      duration_s=round(time.monotonic() - start, 6),
                      output_sha256=hashlib.sha256(content).hexdigest(), finished_ns=time.time_ns())
        store.write(record)
        record_outcome({'row': 'check', 'project_id': project_id, 'repository': project.name,
                        'check': name, 'receipt_id': record['id'], 'revision': revision,
                        'exit_code': exit_code, 'duration_s': record['duration_s'], 'date': time.time()})
        return {key: record[key] for key in ('status', 'id', 'revision', 'exit_code', 'timed_out',
                                             'stable', 'duration_s', 'tests_ran', 'tests_ran_is')}
    except BaseException as error:
        record.update(status='failed', reason=str(error) or type(error).__name__, finished_ns=time.time_ns())
        store.write(record)
        record_outcome({'row': 'check', 'project_id': project_id, 'repository': project.name,
                        'check': name, 'receipt_id': record['id'], 'revision': revision,
                        'exit_code': None, 'failed': True, 'date': time.time()})
        raise


def report(project, state_dir=None):
    project = root(project)
    project_id = identity(project)
    store = Store(state_dir, project)
    receipts = store.records(project_id)
    review = module('orch-review')
    rows = []
    path = review.outcome_path()
    if path.is_file():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get('project_id') == project_id:
                rows.append(row)
    checks = [row for row in rows if row.get('row') == 'check']
    launches = [row for row in rows if row.get('row') == 'launch']
    reviews = [row for row in rows if row.get('row') == 'review']
    costs = [row['cost_usd'] for row in launches + reviews if type(row.get('cost_usd')) in (int, float)]
    # Rows from older releases may say reused; those ran nothing.
    executed = [row for row in checks if row.get('reused') is not True]
    repeated = len(executed) - len({(row['check'], row['revision']) for row in executed})
    # Reviews already contain their launches; expanding those rows preserves
    # the existing outcome sink without counting both a review and its helpers.
    attempts = [*launches, *(launch for row in reviews for launch in row.get('launches', []))]
    profiles = {}
    for attempt in attempts:
        key = (attempt.get('provider'), attempt.get('role'), attempt.get('requested_model'),
               attempt.get('requested_effort'), tuple(attempt.get('served_model') or []),
               tuple(attempt.get('served_effort') or []))
        profile = profiles.setdefault(key, {'provider': key[0], 'role': key[1],
            'requested_model': key[2], 'requested_effort': key[3],
            'served_models': list(key[4]), 'served_efforts': list(key[5]),
            'attempts': 0, 'tokens': {}, 'known_cost_usd': 0, 'unknown_cost_attempts': 0})
        profile['attempts'] += 1
        for name, value in (attempt.get('tokens') or {}).items():
            if type(value) is int:
                profile['tokens'][name] = profile['tokens'].get(name, 0) + value
        cost = attempt.get('cost_usd')
        if type(cost) in (int, float):
            profile['known_cost_usd'] = round(profile['known_cost_usd'] + cost, 6)
        if cost is None or attempt.get('cost_complete') is False:
            profile['unknown_cost_attempts'] += 1
    waits = [attempt['capacity']['wait_s'] for attempt in attempts if isinstance(attempt.get('capacity'), dict)
             and type(attempt['capacity'].get('wait_s')) in (int, float)]
    linked = {}
    for row in launches + reviews:
        if row.get('delivery_id'):
            item = linked.setdefault(row['delivery_id'], {'attempt_records': 0,
                'observed_cost_usd': 0, 'unknown_cost_records': 0, 'validated': None})
            item['attempt_records'] += 1
            if type(row.get('cost_usd')) in (int, float):
                item['observed_cost_usd'] = round(item['observed_cost_usd'] + row['cost_usd'], 6)
            if row.get('cost_usd') is None or row.get('cost_complete') is False:
                item['unknown_cost_records'] += 1
    return {'project_id': project_id, 'checks_executed': len(executed),
            'receipts': len(receipts), 'skipped_receipts': store.skipped,
            'repeated_same_revision_checks': repeated, 'launches': len(launches), 'reviews': len(reviews),
            'observed_cost_usd': round(sum(costs), 6) if costs else None,
            'unknown_cost_records': sum(row.get('cost_usd') is None or row.get('cost_complete') is False for row in launches + reviews),
            'capacity_wait_s': round(sum(waits), 4) if waits else None,
            'role_profiles': list(profiles.values()), 'linked_deliveries': linked,
            'validated_deliveries': None, 'cost_per_validated_delivery_usd': None,
            'delivery_measurement': 'pending: review/check results alone do not authenticate delivery and non-author final integration gates'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('check')
    check.add_argument('--project', default='.')
    check.add_argument('--name', required=True)
    check.add_argument('--state-dir')
    stats = sub.add_parser('report')
    stats.add_argument('--project', default='.')
    stats.add_argument('--state-dir')
    args = parser.parse_args(argv)
    try:
        result = report(args.project, args.state_dir) if args.command == 'report' else run_check(
            args.project, args.name, args.state_dir)
        print(json.dumps(result, sort_keys=True))
        return 0 if args.command == 'report' or result.get('exit_code') == 0 else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
