#!/usr/bin/env python3
"""Observed check receipts and conservative reuse, independent of Cadence.

Receipts are local guardrails, not an adversarial attestation service. Only
owned source snapshots with an observed read-only sandbox are reusable.
Review, hosted CI and final approval remain separate, current obligations.
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
import tempfile
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


def engine_fingerprint():
    return {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest() for name in
            ('orch-evidence.py', 'orch-policy.py', 'orch-task-resources.py')}


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
    """Read actual tracked and nonignored untracked bytes, never follow symlinks."""
    rows = git(project, 'ls-files', '-s', '-z').split(b'\0')
    if any(row.startswith(b'160000 ') for row in rows):
        raise ValueError('submodules are unsupported verification inputs')
    names = git(project, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
    result = {}
    for raw in sorted(set(names) - {b''}):
        name = os.fsdecode(raw)
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('input escapes repository')
        path = project / relative
        for parent in [path, *path.parents]:
            if parent == project:
                break
            if parent.is_symlink():
                raise ValueError('symlink input is unsupported: ' + name)
        if not path.exists():
            result[name] = None
        elif not path.is_file():
            raise ValueError('nonregular input is unsupported: ' + name)
        else:
            before = path.stat()
            contents = path.read_bytes()
            after = path.stat()
            if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError('input changed while fingerprinting: ' + name)
            result[name] = {'sha256': hashlib.sha256(contents).hexdigest(),
                            'executable': bool(after.st_mode & 0o111)}
    return result


def matches(path, patterns):
    return any(pattern in ('*', '**', '**/*') or fnmatch.fnmatchcase(path, pattern)
               or (pattern.startswith('**/') and fnmatch.fnmatchcase(path, pattern[3:])) for pattern in patterns)


def scoped(files, definition, policy):
    patterns = definition['inputs']
    required = {'.llm-orchestrator.json', *policy.data.get('policies', [])}
    result = {name: value for name, value in files.items() if name in required or matches(name, patterns)}
    if not result or not any(matches(name, patterns) and value is not None for name, value in result.items()):
        raise ValueError('declared scope has no existing input files')
    return result


def environment(definition):
    """Only these inherited variables reach the command; values are never logged."""
    allowed = {'PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'TZ', 'SYSTEMROOT', 'WINDIR'}
    allowed.update(definition.get('environment', []))
    env = {key: value for key, value in os.environ.items() if key in allowed}
    immutable = definition.get('immutable', False)
    if immutable:
        # Stable placeholders are replaced with owned per-run paths only after
        # admission. Neither user Git configuration nor user site packages are
        # an undeclared dependency of a reusable source check.
        env.update(HOME='__ORCH_OWNED_HOME__', TMPDIR='__ORCH_OWNED_TMPDIR__',
                   GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                   PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1')
    versions = {}
    names = list(dict.fromkeys([definition['argv'][0], *definition.get('tools', [])]))
    # Version probes may themselves write HOME/TMPDIR (Codex does). Never
    # launch a probe with the stable fingerprint placeholders as real paths.
    with tempfile.TemporaryDirectory(prefix='orch-tool-probe-') as temporary:
      probe_env = dict(env)
      if immutable:
        probe_env.update(HOME=temporary, TMPDIR=temporary)
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
            result = subprocess.run([str(path), '--version'], env=probe_env, capture_output=True, timeout=15)
            if result.returncode:
                raise ValueError('cannot observe tool version: ' + name)
            observed['version_sha256'] = hashlib.sha256(result.stdout).hexdigest()
        versions[name] = observed
    return env, {'platform': platform.platform(), 'machine': platform.machine(),
                 'variables_sha256': digest(env), 'tools': versions}


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

    def records(self, project_id, name):
        result = []
        for path in self.path.glob('*.json'):
            if path.is_symlink():
                raise ValueError('symlink receipt')
            try:
                record = json.loads(path.read_text())
                signature = record.pop('signature')
                if not hmac.compare_digest(signature, hmac.new(self.key, canonical(record), hashlib.sha256).hexdigest()):
                    raise ValueError('receipt signature mismatch: ' + path.name)
                if path.name != record['id'] + '.json' or not isinstance(record['started_ns'], int):
                    raise ValueError('receipt identity mismatch')
                if record.get('project_id') == project_id and record.get('check') == name:
                    result.append(record)
            except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
                raise ValueError('malformed receipt: ' + path.name) from error
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
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            return None, True
        finally:
            module('orch-review').kill_group(process)


def readonly_argv(snapshot, env):
    """A bounded, actual sandbox probe. Failure means record-only execution."""
    binary = shutil.which('codex', path=env.get('PATH'))
    if not binary:
        return None, 'Codex sandbox unavailable; execution cannot be reused'
    # Temporary roots may be writable by the sandbox independently of the profile.
    roots = {Path(tempfile.gettempdir()).resolve(), Path('/tmp').resolve(), Path('/var/tmp').resolve()}
    if any(snapshot == path or path in snapshot.parents for path in roots):
        return None, 'snapshot state is inside a writable temporary root; execution cannot be reused'
    # Give tests a separate owned writable workspace and normal temporary
    # storage, while source lives outside both roots. The wrapper enters source
    # only after the OS policy has been resolved for the output workspace.
    writable = snapshot.parent / ('output-' + snapshot.name)
    writable.mkdir(mode=0o700)
    for name in ('home', 'tmp'):
        (writable / name).mkdir(mode=0o700)
    env.update(HOME=str(writable / 'home'), TMPDIR=str(writable / 'tmp'))
    enter = 'cd "$1" || exit; shift; exec "$@"'
    filesystem = {':minimal': 'read', str(snapshot): 'read', str(writable): 'write'}
    settings = '{' + ','.join(json.dumps(key) + '=' + json.dumps(value) for key, value in filesystem.items()) + '}'
    prefix = [binary, 'sandbox', '-P', 'orch-immutable-check', '-C', str(writable),
              '-c', 'permissions.orch-immutable-check.filesystem=' + settings,
              '-c', 'permissions.orch-immutable-check.network.enabled=false', '--',
              '/bin/sh', '-c', enter, 'orch-check', str(snapshot)]
    probe = snapshot / '.orch-immutability-probe'
    code = 'if (printf probe > "$1") 2>/dev/null; then exit 1; fi; printf ORCH-READONLY-CONFIRMED'
    try:
        result = subprocess.run([*prefix, '/bin/sh', '-c', code, 'orch-probe', str(probe)], env=env,
                                capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, 'sandbox probe unavailable: ' + str(error)
    if result.returncode or result.stdout.strip() != b'ORCH-READONLY-CONFIRMED' or probe.exists():
        return None, 'read-only sandbox was not demonstrated; execution cannot be reused'
    outside = snapshot.parent / ('outside-' + snapshot.name)
    outside.write_text('private canary')
    read_probe = 'if /bin/cat "$1" >/dev/null 2>&1; then exit 1; fi; printf ORCH-READ-BOUNDARY-CONFIRMED'
    try:
        result = subprocess.run([*prefix, '/bin/sh', '-c', read_probe, 'orch-probe', str(outside)], env=env,
                                capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, 'read boundary probe unavailable: ' + str(error)
    if result.returncode or result.stdout.strip() != b'ORCH-READ-BOUNDARY-CONFIRMED':
        return None, 'external read boundary was not demonstrated; execution cannot be reused'
    return prefix, 'read-only source snapshot demonstrated'


def supported_reuse_command(argv):
    # Opaque inline interpreters and external data arguments cannot establish a
    # portable source dependency boundary. They can still run record-only.
    if Path(argv[0]).name in ('env', 'timeout', 'nice', 'stdbuf', 'uv', 'npx', 'npm', 'pnpm', 'yarn'):
        return False
    return not any(word in ('-c', '-e', '--eval', '--print') or Path(word).is_absolute()
                   for word in argv[1:])


def nonempty_execution(argv, output):
    counts = {name: int(value) for name, value in re.findall(
        r'(?m)^(?:#|\u2139) (tests|pass|fail|cancelled|skipped|todo) (\d+)\s*$', output.decode(errors='replace'))}
    if counts or (Path(argv[0]).name == 'node' and '--test' in argv):
        return counts.get('tests', 0) > 0 and counts.get('pass', 0) > 0 and counts.get('fail', 0) == 0 and counts.get('cancelled', 0) == 0
    return bool(output.strip())


def run_check(project, name, reuse=False, state_dir=None):
    project = root(project)
    policy = module('orch-policy').Policy(project)
    definition = policy.data.get('checks', {}).get(name)
    if not definition:
        raise ValueError('unknown configured check: ' + name)
    files = inventory(project)
    context = policy.policy_context()
    if any(item['path'] not in files for item in context['files']):
        raise ValueError('ignored or external policy inputs are unsupported; include canonical policy in source inventory')
    inputs = scoped(files, definition, policy)
    env, observed_env = environment(definition)
    project_id = identity(project)
    revision = os.fsdecode(git(project, 'rev-parse', 'HEAD')).strip()
    key = digest({'check': definition, 'inputs': inputs, 'environment': observed_env,
                  'engine': engine_fingerprint(),
                  'policy_context_sha256': digest(context)})
    store = Store(state_dir, project)
    prior = store.records(project_id, name)
    latest = prior[-1] if prior else None
    if reuse and definition.get('reuse', False) and latest and latest.get('reusable') is True and latest.get('key') == key:
        output = store.path / (latest['id'] + '.log')
        if not output.is_file() or output.is_symlink() or hashlib.sha256(output.read_bytes()).hexdigest() != latest.get('output_sha256'):
            raise ValueError('receipt output is missing or changed')
        record_outcome({'row': 'check', 'project_id': project_id, 'repository': project.name, 'check': name,
                        'receipt_id': latest['id'], 'revision': revision, 'source_revision': latest['revision'],
                        'reused': True, 'exit_code': 0, 'duration_s': 0, 'date': time.time()})
        return {'status': 'reused', 'receipt_id': latest['id'], 'revision': revision,
                'source_revision': latest['revision'], 'exit_code': 0,
                'scope': definition['inputs'], 'limitations': 'declared coverage; hosted CI and independent gates are not reused'}
    record = {'schema': 1, 'id': uuid.uuid4().hex, 'started_ns': time.time_ns(), 'project_id': project_id,
              'project': str(project), 'revision': revision, 'check': name, 'argv': definition['argv'],
              'inputs': inputs, 'environment': observed_env, 'key': key, 'status': 'running', 'reusable': False}
    store.write(record)
    start = time.monotonic()
    snapshot = manager = task = token = None
    try:
        prefix, reason = None, 'record-only check; no immutable execution requested'
        cwd = project
        if definition.get('immutable', False):
            manager = module('orch-task-resources').Manager(store.path / 'resources')
            task = manager.start(str(project), 'verification-' + record['id'])
            token = manager.acquire(task['id'], 'check-runner')['token']
            snapshot = Path(manager.create(task['id'], token, 'copy')['path'])
            for path, expected in files.items():
                if path not in inputs and expected is not None:
                    (snapshot / path).unlink()
            for path, expected in files.items():
                target = snapshot / path
                if path in inputs and expected is not None and (not target.is_file() or target.is_symlink() or
                        hashlib.sha256(target.read_bytes()).hexdigest() != expected['sha256']):
                    raise ValueError('source changed while preparing snapshot: ' + path)
            if inventory(project) != files:
                raise ValueError('source changed before snapshot execution')
            prefix, reason = readonly_argv(snapshot, env)
            if prefix:
                cwd = snapshot
            else:
                env = environment(dict(definition, immutable=False))[0]
        output = store.path / (record['id'] + '.log')
        argv = [*(prefix or []), *definition['argv']]
        exit_code, timed_out = execute(argv, cwd, env, output, definition.get('timeout_s', 600))
        after = scoped(inventory(project), definition, policy)
        stable = inputs == after and observed_env == environment(definition)[1]
        if prefix:
            # The command cannot mutate inputs. This also detects interference by
            # a cooperating outside process; source snapshots have unique ownership.
            for path, expected in files.items():
                target = snapshot / path
                if path in inputs and expected is not None and (not target.is_file() or target.is_symlink() or
                        hashlib.sha256(target.read_bytes()).hexdigest() != expected['sha256']):
                    stable = False
        content = output.read_bytes()
        reusable = bool(definition.get('reuse') and prefix and stable and exit_code == 0
                        and supported_reuse_command(definition['argv'])
                        and nonempty_execution(definition['argv'], content))
        record.update(status='complete', exit_code=exit_code, timed_out=timed_out,
                      duration_s=round(time.monotonic() - start, 6), reusable=reusable,
                      immutable_observed=bool(prefix), stable=stable, execution_cwd=str(cwd),
                      output_sha256=hashlib.sha256(content).hexdigest(),
                      reason=reason if stable else 'inputs or environment changed during execution',
                      finished_ns=time.time_ns())
        store.write(record)
        record_outcome({'row': 'check', 'project_id': project_id, 'repository': project.name,
                        'check': name, 'receipt_id': record['id'], 'revision': revision, 'reused': False,
                        'exit_code': exit_code, 'duration_s': record['duration_s'],
                        'reusable': reusable, 'date': time.time()})
        return {key: record.get(key) for key in ('status', 'id', 'revision', 'exit_code', 'timed_out',
                'reusable', 'immutable_observed', 'stable', 'reason', 'duration_s')}
    except BaseException as error:
        record.update(status='failed', reusable=False, reason=str(error), finished_ns=time.time_ns())
        store.write(record)
        record_outcome({'row': 'check', 'project_id': project_id, 'repository': project.name,
                        'check': name, 'receipt_id': record['id'], 'revision': revision, 'reused': False,
                        'exit_code': None, 'failed': True, 'date': time.time()})
        raise
    finally:
        if manager and task:
            if token:
                manager.release(task['id'], token, stopped=True)
            cleanup = manager.finish(task['id'])
            record['snapshot_cleanup'] = cleanup
            store.write(record)


def report(project):
    project = root(project)
    project_id = identity(project)
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
    executed = [row for row in checks if row.get('reused') is False]
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
            'checks_reused': sum(row.get('reused') is True for row in checks),
            'repeated_same_revision_checks': repeated, 'launches': len(launches), 'reviews': len(reviews),
            'observed_cost_usd': round(sum(costs), 6) if costs else None,
            'unknown_cost_records': sum(row.get('cost_usd') is None or row.get('cost_complete') is False for row in launches + reviews),
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
    check.add_argument('--reuse', action='store_true')
    stats = sub.add_parser('report')
    stats.add_argument('--project', default='.')
    args = parser.parse_args(argv)
    try:
        result = report(args.project) if args.command == 'report' else run_check(args.project, args.name, args.reuse, args.state_dir)
        print(json.dumps(result, sort_keys=True))
        return 0 if args.command == 'report' or result.get('exit_code') == 0 else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'error', 'reason': str(error)}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
