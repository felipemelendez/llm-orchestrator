#!/usr/bin/env python3
"""Shared proportional evidence semantics; private state stays in each harness store.

This is an execution guardrail, not a security boundary against a user who can
edit their own hooks or receipts. No transcript, foreign session, or child prose
is imported as test execution.
"""
import fcntl
import fnmatch
from functools import lru_cache
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time

CONFIG = 'docs/llm-orchestrator/cadence.json'
DEPENDENCY_LOCKS = ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml',
                    'bun.lock', 'bun.lockb', 'Cargo.lock', 'poetry.lock', 'Pipfile.lock',
                    'uv.lock', 'composer.lock', 'Gemfile.lock', 'go.sum', 'packages.lock.json',
                    'Podfile.lock', 'Package.resolved', 'mix.lock', 'flake.lock']
SHARED = ['package.json', '**/package.json',
          'pyproject.toml', 'pytest.ini', 'setup.cfg', 'requirements*.txt',
          'tsconfig*.json', '**/tsconfig*.json', '*jest*config*', '*vitest*config*',
          '.githooks/**', 'scripts/verification/**'] + ['**/' + name for name in DEPENDENCY_LOCKS]
COMPLETION = re.compile(r'(?im)^Verification:[ \t]*(PASS|PENDING|BLOCKED|NOT APPLICABLE)\s*(?:—|–|-)\s*(\S[^\n]*)$')


EXCLUSION_OPTION = re.compile(r'ignore|exclude|deselect|skip', re.I)


def patterns(value):
    return isinstance(value, list) and all(isinstance(p, str) and p and
        not Path(p).is_absolute() and '..' not in Path(p).parts for p in value)


def path_arguments(argv, cwd, root):
    paths = []
    # Flag values which are numbers or test names are not filesystem selectors.
    # Unknown path-shaped values remain unmatched and force conservative scope.
    excluding = False
    for arg in argv[1:]:
        option = arg.split('=', 1)[0] if arg.startswith('-') else ''
        if option and EXCLUSION_OPTION.search(option):
            # `--ignore=tests/x.py`, `--deselect tests/x.py`: the named path did
            # not run, so it neither selects a scope nor covers a PASS claim.
            excluding = '=' not in arg
            continue
        if excluding:
            excluding = False
            continue
        value = arg.split('=', 1)[1] if arg.startswith('-') and '=' in arg else arg
        if value.startswith('-'):
            continue
        value = value.split('::', 1)[0]
        candidate = cwd / value
        if '/' not in value and not Path(value).suffix and not candidate.exists():
            continue
        try:
            rel = candidate.resolve().relative_to(root).as_posix()
        except (OSError, ValueError):
            return None
        paths.append(rel)
    return sorted(set(paths))


def scope_definition(root, config, path_args):
    prod, tests = config.get('prod_globs'), config.get('test_globs')
    configs = config.get('verification_config_globs')
    if not patterns(prod) or not patterns(tests) or not prod + tests or not patterns(configs):
        raise ValueError('configure prod_globs, test_globs and verification_config_globs')
    definitions = config.get('verification_scopes', {})
    if not isinstance(definitions, dict):
        raise ValueError('verification_scopes must be a named object')
    selected = {}
    fallback = not path_args
    for name, definition in definitions.items():
        if not isinstance(name, str) or not isinstance(definition, dict) or not patterns(definition.get('selectors')) or not definition['selectors'] or not patterns(definition.get('inputs')) or not definition['inputs']:
            raise ValueError('each verification scope needs nonempty selectors and inputs')
    for path in path_args or []:
        matching = {n: d for n, d in definitions.items() if matches(path, d['selectors'])}
        if not matching:
            fallback = True
        selected.update(matching)
    if fallback:
        inputs = prod + tests + configs
        selected = {'project': {'inputs': inputs}}
    else:
        inputs = sorted({p for d in selected.values() for p in d['inputs']})
    return {'inputs': sorted(set(inputs)), 'definitions': selected,
            'production_tests': prod + tests, 'fallback': fallback,
            'shared': SHARED + [CONFIG], 'path_arguments': path_args}


@lru_cache(maxsize=512)
def glob_components(pattern):
    return tuple(None if part == '**' else re.compile(fnmatch.translate(part)).fullmatch
                 for part in pattern.split('/'))


def matches(path, globs):
    """Path-component globs: ** matches zero or more directories anywhere."""
    parts = tuple(path.split('/'))
    for pattern in globs:
        selectors = glob_components(pattern)
        def match(i, j):
            if j == len(selectors):
                return i == len(parts)
            if selectors[j] is None:
                return match(i, j + 1) or (i < len(parts) and match(i + 1, j))
            return i < len(parts) and selectors[j](parts[i]) and match(i + 1, j + 1)
        if match(0, 0):
            return True
    return False


def sed_targets(args):
    """Return targets for simple substitutions, w commands and s///w output.

    More complex sed programs/option combinations may write other files; keep
    them uncertain instead of guessing a partial operand list.
    """
    i, expressions = 1, []
    in_place = False
    while i < len(args) and args[i].startswith('-'):
        arg = args[i]
        if arg == '--':
            i += 1
            break
        if arg in ('-e', '--expression'):
            if i + 1 >= len(args):
                return None
            expressions.append(args[i + 1])
            i += 2
            continue
        if arg.startswith('--expression=') or arg.startswith('-e'):
            expressions.append(arg.split('=', 1)[1] if arg.startswith('--') else arg[2:])
        elif arg == '-i':
            in_place = True
            i += 1
            if i < len(args) and args[i] == '':  # BSD explicit no-backup suffix
                i += 1
            continue
        elif arg.startswith('--in-place=') or arg.startswith('-i') or arg == '--in-place':
            in_place = True
        elif arg not in ('-E', '-r', '-n', '--regexp-extended', '--quiet', '--silent'):
            return None
        i += 1
    if not expressions:
        if i >= len(args):
            return None
        expressions.append(args[i])
        i += 1
    operands = args[i:]
    if any(p.startswith('-') for p in operands) or (in_place and not operands):
        return None
    targets = list(operands) if in_place else []
    for expression in expressions:
        # Restrict the supported language, including replacement text: embedded
        # programs, e flags, script files and compound commands remain uncertain.
        address = r'(?:\d+|\$|/(?:\\.|[^/\\])*/)'
        prefix = re.match(r'\s*(?:' + address + r'(?:\s*,\s*' + address + r')?)?\s*!?\s*', expression)
        program = expression[prefix.end():]
        output = re.fullmatch(r'w\s+([^\s;{}]+)', program)
        substitution = re.fullmatch(r's([^\w\s\\]).*?\1.*?\1[gIp0-9]*(?:w\s+([^\s;{}]+))?', program)
        if any(c in program for c in '\n\r;{}'):
            return None
        if output:
            targets.append(output.group(1))
        elif substitution:
            if substitution.group(2):
                targets.append(substitution.group(2))
        elif not re.fullmatch(r'[pPqdDnNhHgGxl=]', program):
            return None
    return targets


def literal_shell(command):
    """No operators or expansion outside literal single-quoted sed programs."""
    quote, escaped = None, False
    for char in command:
        if char in '\n\r':
            return False
        if escaped:
            escaped = False
            continue
        if char == '\\' and quote != "'":
            escaped = True
            continue
        if char == quote:
            quote = None
        elif quote != "'" and char in '$`':
            return False
        elif quote is None and char in "'\"":
            quote = char
        elif quote is None and char in ';|&<>(){}':
            return False
    return quote is None and not escaped


def file_digest(path, api):
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            # Include target contents when inside the tree via the normal selected
            # target path. Symlink identity alone must not attest external inputs.
            raise ValueError('symlink input is not a resolved verification dependency')
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('nonregular verification input')
        return api.digest([stat.S_IMODE(info.st_mode), api.digest(path.read_bytes())])
    except FileNotFoundError:
        return 'deleted'


def candidate_paths(root, api, cache):
    if 'candidates' not in cache:
        cache['candidates'] = sorted(set(api.git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')) - {b''})
    return cache['candidates']


def snapshot(root, config, policy, api, command=None, cwd=None, selected=None, cache=None):
    """A failed/empty fingerprint remains explicit, never a constant green hash."""
    # Only a caller processing one event may share this cache. It is never
    # serialized or reused across the before/after execution boundaries.
    cache = {} if cache is None else cache
    if 'head' not in cache:
        try:
            cache['head'] = os.fsdecode(api.git(root, 'rev-parse', 'HEAD')).strip()
        except subprocess.SubprocessError:
            cache['head'] = 'unknown'
    head = cache['head']
    try:
        if selected is None:
            argv = shlex.split(command or '')
            paths = path_arguments(argv, cwd or root, root) if argv else []
            if paths is None:
                raise ValueError('verification arguments route outside the canonical project')
            selected = scope_definition(root, config, paths)
            selected['command_sha256'] = api.digest(shlex.join(argv).encode())
        else:
            command_hash = selected.get('command_sha256')
            selected = scope_definition(root, config, selected['path_arguments'])
            selected['command_sha256'] = command_hash
        all_patterns = selected['inputs'] + selected['shared']
        selection = (tuple(selected['inputs']), tuple(selected['shared']), tuple(selected['production_tests']))
        selections = cache.setdefault('selections', {})
        if selection not in selections:
            files, meaningful = {}, 0
            digests = cache.setdefault('digests', {})
            for raw in candidate_paths(root, api, cache):
                rel = os.fsdecode(raw)
                if matches(rel, api.DEFAULT_EXCLUDES) or any(p in api.SKIP_PARTS for p in Path(rel).parts):
                    continue
                if not matches(rel, all_patterns):
                    continue
                if rel not in digests:
                    digests[rel] = file_digest(root / rel, api)
                content = digests[rel]
                if content == 'deleted':
                    continue  # Index bookkeeping is not content; deletion commits preserve this set.
                files[rel] = content
                if matches(rel, selected['inputs']) and matches(rel, selected['production_tests']):
                    meaningful += 1
            selections[selection] = files, meaningful
        files, meaningful = selections[selection]
        if not meaningful:
            raise ValueError('verification scope resolves no production/test inputs; configure its input globs')
        if 'machinery' not in cache:
            machinery = [Path(__file__), Path(api.__file__), api.VERIFY_RUNNER]
            cache['machinery'] = [api.digest(p.read_bytes()) for p in machinery]
        return {'head': head, 'files': files, 'scope': selected, 'error': None,
                'fingerprint': api.digest([str(root), selected, policy, files, cache['machinery']])}
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        return {'head': head, 'files': {}, 'scope': selected, 'fingerprint': None,
                'error': str(exc) if isinstance(exc, ValueError) else 'scope fingerprint unavailable'}


def is_source(rel, config, api):
    if matches(rel, api.DEFAULT_EXCLUDES):
        return False
    configured = []
    for key in ('prod_globs', 'test_globs', 'verification_config_globs'):
        if patterns(config.get(key)):
            configured.extend(config[key])
    p = Path(rel)
    return matches(rel, configured + SHARED + [CONFIG]) or p.suffix in api.SOURCE_SUFFIXES or p.name in ('Makefile', 'Dockerfile', 'Podfile', 'Gemfile')


def task_resource_command(args, api):
    if len(args) < 3 or Path(args[0]).name not in ('python', 'python3'):
        return False
    source = Path(__file__).resolve().parents[2]
    helper = Path(__file__).resolve().parent / 'orch-task-resources.py'
    candidates = [helper, source / 'skills/cadence/scripts/orch-task-resources.py',
                  Path.home() / '.agents/skills/cadence/scripts/orch-task-resources.py']
    try:
        script = Path(args[1])
        if not script.is_absolute() or script.resolve() not in [p.resolve() for p in candidates if p.exists()]:
            return False
        # Only the shipped helper operation is exempt; chained shell commands
        # are rejected before this function is called.
        return any(a in ('start', 'acquire', 'copy', 'worktree', 'release', 'finish', 'retry', 'status', 'hook-retry') for a in args[2:])
    except OSError:
        return False


def prune_completed(directory, current=None, retention_days=14):
    """Expire consumed inactive evidence, never unresolved or locked state.

    State is removed only after successful completion consumed it, with no
    unresolved invocation/attribution. The lock file and directory remain to
    avoid racing an already waiting hook. Task-owned raw logs have a separate
    resource lifecycle; this function never deletes them.
    """
    cutoff = time.time() - retention_days * 86400
    for path in directory.glob('*/state.json') if directory.exists() else []:
        if path.parent == current or path.is_symlink() or path.parent.is_symlink():
            continue
        try:
            if path.stat().st_mtime >= cutoff:
                continue
            with (path.parent / 'lock').open('a+') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                data = json.loads(path.read_text())
                if (path.stat().st_mtime < cutoff and data.get('outcome') in ('verified', 'read_only', 'not_applicable')
                        and not any(path.parent.glob('deferred-*.json'))
                        and not data.get('pending') and not data.get('uncertain') and not data.get('mutations')
                        and not data.get('writes') and not data.get('required_validation') and not data.get('continuation_pending')):
                    path.unlink()
        except (OSError, ValueError):
            continue


def owned_disposable_target(path, root):
    try:
        location = Path(__file__).resolve().parent / 'orch-task-resources.py'
        spec = importlib.util.spec_from_file_location('cadence_owned_resources', location)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.owned_disposable_target(path, root)
    except (ImportError, AttributeError, OSError, ValueError, TypeError):
        return False


def readonly_shell(command, api):
    """Recognize simple read pipelines without labeling arbitrary scripts safe."""
    if not isinstance(command, str) or any(c in command for c in '`$\n\r<>'):
        return False
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars='|&;')
        lexer.whitespace_split = True
        lexer.commenters = ''
        segments, segment = [], []
        for token in lexer:
            if token in ('|', '&&', ';'):
                if not segment:
                    return False
                segments.append(segment)
                segment = []
            elif token and set(token) <= set('|&;'):
                return False
            else:
                segment.append(token)
        if not segment:
            return False
        segments.append(segment)
        for args in segments:
            if api.read_command_can_write(args):
                return False
            exe = Path(args[0]).name
            if exe in ('rg', 'grep', 'cat', 'head', 'tail', 'ls', 'pwd', 'wc', 'stat', 'file', 'which'):
                if exe == 'rg' and any(a.startswith('--pre') for a in args[1:]):
                    return False
                continue
            if exe == 'git' and len(args) > 1 and args[1] in ('status', 'diff', 'log', 'show', 'rev-parse', 'ls-files', 'ls-tree', 'grep', 'check-ignore'):
                continue
            if exe == 'gh' and len(args) > 2 and args[1] in ('pr', 'issue') and args[2] in ('view', 'list', 'diff', 'status'):
                continue
            if exe == 'cd' and len(args) == 2:
                continue
            return False
        return True
    except ValueError:
        return False


def mutation_snapshot(root, config, policy, api):
    """Observe source contents independently of commit IDs or incomplete scopes."""
    try:
        configured = config.get('verification_config_globs', [])
        if not patterns(configured):
            return None
        includes = list(policy.get('include_globs', []))
        runner = config.get('runner', {})
        if isinstance(runner, dict):
            includes += runner.get('prod_globs', []) + runner.get('test_globs', [])
        excludes = api.DEFAULT_EXCLUDES + policy.get('exclude_globs', [])
        if isinstance(config.get('notes_dir'), str):
            excludes += [config['notes_dir'].rstrip('/') + '/**']
        files = {}
        for raw in candidate_paths(root, api, {}):
            rel = os.fsdecode(raw)
            if any(p in api.SKIP_PARTS for p in Path(rel).parts) or matches(rel, excludes):
                continue
            if not (is_source(rel, config, api) or matches(rel, includes)):
                continue
            content = file_digest(root / rel, api)
            if content != 'deleted':
                files[rel] = content
        return files
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return None


def write_targets(payload, root, api, harness):
    """Return canonical supported write operands, plus unresolved-target reason."""
    inp = payload.get('tool_input') or {}
    if not isinstance(inp, dict):
        return [], 'missing tool input'
    tool = payload.get('tool_name', '')
    cwd_value = inp.get('workdir') or inp.get('cwd') or payload.get('cwd')
    cwd = Path(cwd_value).resolve() if isinstance(cwd_value, str) and Path(cwd_value).is_absolute() else None
    targets = []
    if tool in ('Write', 'Edit', 'MultiEdit'):
        targets = [inp.get('file_path') or inp.get('path')]
    elif tool == 'apply_patch':
        patch = inp.get('patch') or inp.get('input') or inp.get('command') or ''
        targets = re.findall(r'^\*\*\* (?:Update File|Add File|Delete File|Move to): (.+)$', patch, re.M)
    elif tool == 'Bash':
        command = inp.get('command', inp.get('cmd'))
        if readonly_shell(command, api) or not api.potentially_mutating(payload, command):
            return [], None
        try:
            args = shlex.split(command or '')
        except ValueError:
            return [], 'unresolved shell write target'
        if not args:
            return [], None
        # An explicit initial cd establishes the shell location. Arbitrary
        # snippets/substitutions are uncertainty, not guessed mutation targets.
        if len(args) > 3 and args[0] == 'cd' and args[2] == '&&' and cwd:
            cwd = (cwd / args[1]).resolve()
            args = args[3:]
        if any(c in ' '.join(args) for c in '\n\r;|&`$(){}'):
            return [], 'unresolved shell write target'
        if task_resource_command(args, api):
            return [], None
        exe = Path(args[0]).name
        operands = [a for a in args[1:] if not a.startswith('-')]
        if exe in ('rm', 'touch', 'mkdir', 'rmdir'):
            targets = operands
        elif exe in ('cp', 'mv') and len(operands) == 2:
            if cwd is None or (cwd / operands[-1]).is_dir() or (cwd / operands[0]).is_dir():
                return [], 'directory copy/move target set unavailable'
            targets = operands if exe == 'mv' else operands[1:]
        elif exe == 'sed':
            targets = sed_targets(args)
            if targets is None:
                return [], 'unsupported sed syntax; complete target set unavailable'
            if not targets:
                return [], None
        elif exe in ('echo', 'printf', 'cat') and any(a in ('>', '>>') for a in args):
            targets = [args[i+1] for i, a in enumerate(args[:-1]) if a in ('>', '>>')]
        elif exe == 'git' and len(args) > 1 and args[1] in ('add', 'commit'):
            return [], None  # Index/HEAD updates do not mutate checked contents.
        else:
            return [], 'unresolved shell write target'
        if harness == 'codex' and not (inp.get('workdir') or inp.get('cwd')) and not (command or '').startswith('cd '):
            if any(not Path(p).is_absolute() for p in targets):
                return [], 'shell working directory unavailable; use explicit absolute write operands'
    else:
        return [], None
    if not targets or any(not isinstance(p, str) or not p for p in targets):
        return [], 'missing write target'
    resolved = []
    for target in targets:
        path = Path(target)
        if not path.is_absolute() and cwd is None:
            return [], 'write working directory unavailable'
        full = (cwd / path if cwd else path).resolve()
        try:
            rel = full.relative_to(root).as_posix()
        except ValueError:
            # Canonical known operands outside this tree belong to another
            # coverage boundary. Cleanup ownership does not change attribution.
            continue
        if full.is_dir():
            # Removal/move of a directory includes tracked and untracked source.
            for raw in api.git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0'):
                if raw and os.fsdecode(raw).startswith(rel + '/'):
                    resolved.append(os.fsdecode(raw))
        else:
            resolved.append(rel)
    return sorted(set(resolved)), None


def mutation_invocation(payload, root, api, harness):
    """Bind source observation to the actual tool request and execution cwd."""
    inp = payload.get('tool_input')
    if not isinstance(inp, dict) or payload.get('tool_name') != 'Bash':
        return None
    command = inp.get('command', inp.get('cmd'))
    observed_cwd = inp.get('workdir') or inp.get('cwd') or (payload.get('cwd') if harness == 'claude' else None)
    if not isinstance(command, str) or not isinstance(observed_cwd, str) or not Path(observed_cwd).is_absolute():
        return None
    try:
        execution_cwd = Path(observed_cwd).resolve()
        execution_cwd.relative_to(root)
    except (OSError, ValueError):
        return None
    return {'tool': payload['tool_name'], 'command_sha256': api.digest(command.encode()),
            'cwd': str(execution_cwd), 'session_id': payload.get('session_id'),
            'agent_id': payload.get('agent_id'), 'background': bool(inp.get('run_in_background'))}


def terminal_mutation_response(response, tool, harness, poll=False, event=None):
    if isinstance(response, dict) and response.get('interrupted'):
        return False
    if isinstance(response, dict) and (response.get('session_id') is not None or response.get('status') in ('running', 'pending', 'interrupted')
            or any(response.get(key) for key in ('background', 'backgrounded', 'backgroundTaskId', 'task_id'))):
        return False
    if event == 'PostToolUseFailure' and not poll:
        # The command ended with an error, so its process is over and the source
        # comparison taken now is complete. A grep with no match or a listing
        # that errors must not leave a read-only turn permanently "unfinished".
        # A failed poll of a still-running process says nothing about the
        # process, so polls keep the stricter rules below.
        return True
    if isinstance(response, dict) and response.get('isError'):
        return False
    if not poll and tool != 'Bash':
        return True
    if not isinstance(response, dict):
        return False
    code = response.get('exit_code')
    if harness == 'codex':
        # Raw Codex stdout does not attest completion/exit.
        return isinstance(code, int) and not isinstance(code, bool)
    return ((isinstance(code, int) and not isinstance(code, bool)) or
            any(isinstance(response.get(key), str) for key in ('stdout', 'stderr')))


def completed_mutation(payload, mutation, root, api, harness):
    if not payload or payload.get('hook_event_name') not in ('PostToolUse', 'PostToolUseFailure'):
        return False
    invocation = mutation.get('invocation')
    inp = payload.get('tool_input') or {}
    poll = (payload.get('tool_name') == 'write_stdin' and mutation.get('process_id') is not None
            and inp.get('session_id') == mutation['process_id'])
    if not poll:
        if payload.get('tool_name') != mutation.get('tool'):
            return False
        if mutation.get('input_sha256') != api.digest(inp):
            return False
        if invocation and mutation_invocation(payload, root, api, harness) != invocation:
            return False
        if invocation and invocation.get('background'):
            return False
    return terminal_mutation_response(payload.get('tool_response'), payload.get('tool_name'), harness, poll,
                                      event=payload.get('hook_event_name'))


def record_write(state, rel, at, content, measured=None):
    previous = state.setdefault('writes', {}).get(rel, {})
    write = {'at': at, 'content': content}
    if measured is None:
        measured = previous.get('measured')
    if measured is not None:
        write['measured'] = measured  # decided when the file was still there; survives later commits
    if 'requires_check_after' in previous:
        write.update(requires_check_after=previous['requires_check_after'], obligation=previous['obligation'])
    state['writes'][rel] = write


def measurable_now(root, rel, api):
    """How the fingerprint could contain this existing path right now.

    'tracked' for a file in the index (fingerprinted whatever the ignore rules
    say), True for an untracked file Git would not ignore, False otherwise.
    Recorded with the write; only the 'tracked' answer is trusted later, and
    only for deletions, because a tracked file's removal is measured even after
    the deletion is committed and HEAD forgets it.
    """
    if matches(rel, api.DEFAULT_EXCLUDES) or any(p in api.SKIP_PARTS for p in Path(rel).parts):
        return False
    try:
        api.git(root, 'ls-files', '--error-unmatch', '--', rel)
        return 'tracked'
    except subprocess.SubprocessError:
        pass
    return not ignored_by_git(root, rel, api)


def settle_writes(state, root, config, api, call=None, policy=None, observation=None, harness="codex"):
    for key, mutation in list(state.setdefault('mutations', {}).items()):
        if call is not None and key != call:
            continue
        completed = completed_mutation(observation, mutation, root, api, harness)
        response = observation.get('tool_response') if observation else None
        if isinstance(response, dict) and response.get('session_id') is not None:
            if mutation_invocation(observation, root, api, harness) == mutation.get('invocation'):
                mutation['process_id'] = response['session_id']
        # No completed observation means no closing scan, including at Stop.
        # The before state survives a yielded response and later source edits.
        if not completed:
            if mutation.get('unknown'):
                state.setdefault('uncertain', {})[key] = mutation['unknown']
            continue
        if mutation.get('unknown') and mutation.get('observed_before') is not None:
            after_files = mutation_snapshot(root, config, policy or {}, api)
            if after_files is not None:
                before_files = mutation['observed_before']
                # A matching observed command and reliable cwd bind this diff to
                # its invocation. Absent events/cwd never take this recovery path.
                for rel in set(before_files) | set(after_files):
                    if before_files.get(rel) != after_files.get(rel) and is_source(rel, config, api):
                        record_write(state, rel, mutation['at'], after_files.get(rel, 'deleted'), measured=True)
                mutation['unknown'] = None
                state.setdefault('uncertain', {}).pop(key, None)
        if mutation.get('unknown'):
            state.setdefault('uncertain', {})[key] = mutation['unknown']
        for rel, before in mutation.get('before', {}).items():
            try:
                after = file_digest(root / rel, api)
            except (OSError, ValueError):
                state.setdefault('uncertain', {})[key] = 'write content unavailable'
                continue
            if before != after and is_source(rel, config, api):
                record_write(state, rel, mutation['at'], after, measured=mutation.get('measured', {}).get(rel))
        if not mutation.get('unknown'):
            state['mutations'].pop(key, None)
            if state.setdefault('uncertain', {}).get(key) == 'source completion contents unavailable during contention':
                state['uncertain'].pop(key)
            if key in state.get('observations', {}):
                state['observations'][key]['completed'] = True


def record_check(state, pending, status, code, output, root, api, checkpoint, after=None):
    record = {k: v for k, v in pending.items() if k not in ('before', 'wrapper', 'recorded')}
    record.update(status=status, exit_code=code, finished_at=time.time(), worktree=str(root),
                  before_fingerprint=pending['before']['fingerprint'], after_fingerprint=None,
                  scope=pending['before'].get('scope'), fingerprint_error='source binding unavailable',
                  output_sha256=api.digest(output.encode()))
    previous = pending.get('recorded')
    if previous is not None:
        state['evidence'][previous] = record
    else:
        pending['recorded'] = len(state['evidence'])
        state['evidence'].append(record)
    checkpoint()  # Persist actual exit/failure before any expensive source work.
    if after:
        record.update(after_fingerprint=after['fingerprint'], fingerprint_error=after.get('error'), head=after.get('head'))
    return record


def recover_wrappers(state, root, api, checkpoint):
    """Consume only the receipt reserved by the original invocation, once.

    This reads private execution artifacts, never repository sources. The
    runner owns its two source boundaries; an explicit PASS will bind again to
    current contents in finish(). Invalid/incomplete artifacts retain binding.
    """
    for call, pending in list(state['pending'].items()):
        if 'wrapper' not in pending:
            continue
        status, code, output, receipt = api.wrapper_observation(pending)
        if status == 'running':
            continue
        if receipt is None:
            if pending.get('recorded') is None:
                record_check(state, pending, status, code, output, root, api, checkpoint)
            continue
        terminal = receipt['state'] == 'completed'
        if not terminal and status == 'passed':
            continue
        after = {'fingerprint': receipt.get('after_fingerprint'), 'head': receipt.get('head_after'),
                 'error': receipt.get('fingerprint_error')}
        if not receipt.get('setup_failure') and receipt.get('before_fingerprint') != pending['before']['fingerprint']:
            after.update(fingerprint=None, error='wrapper checked contents do not match observed contents')
        record = record_check(state, pending, status, code, output, root, api, checkpoint, after)
        record['finished_at'] = receipt['finished_at']
        if terminal:
            observed = state.get('observations', {}).get(call)
            if observed is not None:
                observed.update(completed=True, receipt_sha256=api.digest(receipt),
                                receipt_exit_code=code)
            state['pending'].pop(call, None)


def initialize(state):
    for key, value in (('evidence', []), ('pending', {}), ('writes', {}), ('uncertain', {}), ('mutations', {}), ('agents', {}), ('observations', {})):
        state.setdefault(key, value)


def invocation_identity(payload, cwd, api):
    """Retain hashes, not shell arguments or edit bodies, for exact redelivery."""
    return api.digest([payload.get('tool_name'), payload.get('tool_input'), str(cwd),
                       payload.get('session_id'), payload.get('agent_id')])


def conflicting_observation(state, call, detail):
    # Separate from recoverable missing-start/unknown-write entries: a later
    # good command cannot erase conflicting reuse of a harness invocation ID.
    state['uncertain']['conflict:' + call] = 'conflicting invocation observation: ' + detail


def replayed_post(state, payload, cwd, api):
    """Return true for an inert replay or a quarantined conflicting event."""
    call = payload.get('tool_use_id')
    return replayed_observation(state, call, invocation_identity(payload, cwd, api),
                               api.digest([payload.get('hook_event_name'), payload.get('tool_response')]),
                               payload.get('hook_event_name'), payload.get('tool_response'), api)


def replayed_observation(state, call, identity, signature, event, response, api):
    observed = state['observations'].get(call)
    if observed is None:
        return False
    if observed['request_sha256'] != identity:
        conflicting_observation(state, call, 'request identity changed')
        return True
    if signature in observed['posts']:
        return True
    if observed.get('completed'):
        # A wrapper may have completed through polling/Stop before its original
        # Post arrives. Its exclusive receipt, not status-looking stdout, binds
        # that first terminal observation to the already consumed completion.
        if observed.get('receipt_sha256') and observed.get('wrapper_pending'):
            _status, code, _output, receipt = api.wrapper_observation(observed['wrapper_pending'])
            contradicted = event == 'PostToolUseFailure' and code == 0
            if isinstance(response, dict):
                contradicted = contradicted or bool(response.get('isError') and code == 0)
                contradicted = contradicted or bool(response.get('interrupted') and not (receipt or {}).get('interrupted'))
                if 'exit_code' in response:
                    contradicted = contradicted or response['exit_code'] != code
            if receipt and api.digest(receipt) == observed['receipt_sha256'] and not contradicted:
                observed['posts'].append(signature)
                return True
        conflicting_observation(state, call, 'completion changed after terminal observation')
        return True
    observed['posts'].append(signature)
    return False


def pending_declaration(message, api):
    completion = COMPLETION.search(message)
    if not completion or completion.group(1) not in ('PENDING', 'BLOCKED') or api.CLAIM.search(message):
        return None
    reason = completion.group(2)
    # Only words that name validation a person or an external system must supply.
    # Generic words such as "runtime" appear in ordinary reasons and would create
    # an external requirement that no later check could ever resolve.
    categories = {'build': r'build|binary', 'device': r'device|simulator|emulator|hardware',
                  'deployment': r'deploy(?:ment)?',
                  'service': r'service', 'credentials': r'credentials?|authentication'}
    return {'label': completion.group(1), 'reason_sha256': api.digest(reason),
            'requirements': [name for name, words in categories.items()
                             if re.search(r'\b(?:' + words + r')\b', reason, re.I)]}


NAMED_CHECK = re.compile(r'(?<![\w./-])((?:tests?|spec|specs|__tests__)/[\w./-]+\.(?:py|sh))')


def tracked_at_head(root, rel, api):
    try:
        api.git(root, 'cat-file', '-e', 'HEAD:' + rel)
        return True
    except subprocess.SubprocessError:
        return False


def ignored_by_git(root, rel, api):
    try:
        api.git(root, 'check-ignore', '-q', '--', rel)
        return True
    except subprocess.CalledProcessError as exc:
        return exc.returncode != 1  # 1 means not ignored; anything else is unknown
    except subprocess.SubprocessError:
        return True


def unrecorded_named_checks(reason, fresh):
    """Repository-local check paths a PASS names must have a fresh passing record.

    Only whole path tokens rooted at a test directory are inspected; a nested
    `pkg/tests/x.py` mention is neither matched against the root suite nor
    rejected. Records keep normalized path arguments, so a suite run with extra
    arguments, or a directory run that contains the named file, still covers it.
    Prose that names no such path is not inspected: text never supplies
    evidence, it can only contradict it.
    """
    observed = set()
    for record in fresh:
        arguments = (record.get('scope') or {}).get('path_arguments')
        if not arguments:
            return []  # a whole-project run (no path arguments) covers every named check
        for path in arguments:
            observed.add(os.path.normpath(path))
    missing = set()
    for mention in NAMED_CHECK.findall(reason or ''):
        path = os.path.normpath(mention)
        covered = '.' in observed or path in observed or any(
            path.startswith(seen.rstrip('/') + '/') for seen in observed if seen != '.')
        if not covered:
            missing.add(path)
    return sorted(missing)


def latest_checks(records, at=None):
    latest = {}
    def boundary(record):
        # An overlapping green run cannot erase a failure that completes later.
        # Recovery requires a matching invocation begun after that failure.
        return max(record['started_at'], record.get('finished_at', record['started_at'])) if record['status'] != 'passed' else record['started_at']
    for record in records:
        if at is not None and record['started_at'] > at:
            continue
        key = (record['cwd'], record['command_sha256'])
        if key not in latest or boundary(record) >= boundary(latest[key]):
            latest[key] = record
    return latest


def observed_check_result(response, event, kind, api, harness):
    response = dict(response) if isinstance(response, dict) else ({'stdout': response} if isinstance(response, str) else {})
    running = (response.get('session_id') is not None or response.get('status') in ('running', 'pending')
               or any(response.get(key) for key in ('background', 'backgrounded', 'backgroundTaskId', 'task_id')))
    if harness == 'claude' and not running:
        if event == 'PostToolUseFailure':
            response['exit_code'] = response.get('exit_code') or 1
        elif any(isinstance(response.get(key), str) for key in ('stdout', 'stderr')):
            response.setdefault('exit_code', 0)
    status, code, output, process = api.result(response, kind)
    return ('running', None, output, process) if running else (status, code, output, process)


def retain_declaration(state, declaration, at, reason, records):
    required_checks = {}
    for record in records:
        if (record.get('status') == 'passed' and not record.get('fingerprint_error') and
                record.get('before_fingerprint') is not None and
                record['before_fingerprint'] == record.get('after_fingerprint') and
                record.get('finished_at', at) <= at):
            continue  # A later PASS rebinds these contents; handoff alone requires no rerun.
        key = (record['cwd'], record['command_sha256'])
        required_checks[key] = {'command_sha256': record['command_sha256'], 'cwd': record['cwd'],
                                'scope': record.get('scope') or record.get('before', {}).get('scope')}
    requirements = set(declaration['requirements'])
    # Matching execution can witness service recovery, never independent device/build acceptance.
    external = bool(requirements - {'service', 'credentials'}) or (bool(requirements) and not required_checks)
    previous = state.get('required_validation')
    if (not previous or not previous['external']) and (external or state['writes'] or required_checks or state['uncertain']):
        state['required_validation'] = {'at': at, 'reason': reason, 'external': external,
            'paths': sorted(state['writes']), 'path_times': {rel: write['at'] for rel, write in state['writes'].items()},
            'commands': list(required_checks.values())}
    state.update(outcome=declaration['label'].lower(), continuation_pending=False)


def deferred_fact(payload, root, config, policy, cwd, api, harness, captured_at, captured_order):
    """Capture execution facts without persisting payloads or reading source."""
    event, call = payload.get('hook_event_name'), payload.get('tool_use_id')
    inp = payload.get('tool_input') or {}
    command = inp.get('command', inp.get('cmd')) if isinstance(inp, dict) else None
    request = api.wrapper_request(command) if harness == 'codex' and payload.get('tool_name') == 'Bash' else None
    verify_command = shlex.join(request['argv']) if request else command
    kind = api.classification(verify_command, policy, cwd) if payload.get('tool_name') == 'Bash' else None
    response = payload.get('tool_response')
    metadata = {key: response[key] for key in ('exit_code', 'interrupted', 'isError', 'session_id', 'status',
                'background', 'backgrounded', 'backgroundTaskId', 'task_id') if isinstance(response, dict) and key in response}
    if isinstance(response, dict):
        for key in ('stdout', 'stderr'):
            if isinstance(response.get(key), str):
                metadata[key] = ''  # Presence supplies Claude completion semantics; content is never spooled.
    elif isinstance(response, str) and harness == 'claude':
        metadata['stdout'] = ''
    fact = {'schema': 1, 'event': event, 'call': call, 'tool': payload.get('tool_name'),
            'request_sha256': invocation_identity(payload, cwd, api),
            'response_sha256': api.digest([event, response]), 'response': metadata, 'response_structured': isinstance(response, dict),
            'captured_at': captured_at, 'order': captured_order, 'family': 'control',
            'turn_id': payload.get('turn_id'), 'agent_id': payload.get('agent_id'),
            'model': payload.get('model'), 'session_id': payload.get('session_id'), 'harness': harness}
    if event == 'Stop':
        fact['declaration'] = pending_declaration(api.clean_message(payload.get('last_assistant_message')), api)
    if payload.get('tool_name') == 'write_stdin' and isinstance(inp, dict):
        fact['poll_session_id'] = inp.get('session_id')
    if kind:
        fact['family'] = 'check'
        argv = shlex.split(verify_command)
        fact['check'] = {'kind': kind, 'command_sha256': api.digest(shlex.join(argv).encode()),
                         'command_runner': Path(argv[0]).name, 'cwd': str(cwd),
                         'started_at': captured_at, 'tool_use_id': call, 'proportional': True,
                         'session_id': payload.get('session_id'),
                         'before': {'fingerprint': None, 'error': 'source baseline unavailable during contention'}}
        if request:
            expected = {key: value for key, value in request.items() if key != 'argv'}
            if event == 'PreToolUse':
                claim = Path(request['receipt'] + '.request.json')
                try:
                    claim.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    expected['hook_nonce'] = api.secrets.token_hex(24)
                    with os.fdopen(fd, 'w') as stream:
                        json.dump({'schema': 1, 'hook_nonce': expected['hook_nonce'],
                                   'invocation_sha256': request['invocation_sha256']}, stream)
                except FileExistsError:
                    info = claim.lstat()
                    stored = json.loads(claim.read_text())
                    if (stat.S_ISREG(info.st_mode) and not stat.S_IMODE(info.st_mode) & 0o077 and
                            stored.get('schema') == 1 and stored.get('invocation_sha256') == request['invocation_sha256']):
                        expected['hook_nonce'] = stored.get('hook_nonce')
                except (OSError, ValueError):
                    pass
            fact['check']['wrapper'] = dict(expected, hook_nonce=expected.get('hook_nonce'))
        status, code, output, process = observed_check_result(response, event, kind, api, harness)
        if harness == 'codex' and not request and status != 'running':
            status, code = 'unbound', None
        fact['result'] = {'status': status, 'exit_code': code, 'output_sha256': api.digest(output.encode()),
                          'process_id': process}
    elif event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
        targets, unknown = write_targets(payload, root, api, harness)
        targets = [rel for rel in targets if is_source(rel, config, api)]
        fact.update(family='mutation' if targets or unknown else 'read_only', targets=targets, unknown=unknown,
                    input_sha256=api.digest(inp), invocation=mutation_invocation(payload, root, api, harness))
    return fact


def defer_event(directory, payload, root, config, policy, cwd, api, harness, captured_at, captured_order):
    fact = deferred_fact(payload, root, config, policy, cwd, api, harness, captured_at, captured_order)
    control = ([fact.get('session_id'), fact.get('agent_id'), fact.get('turn_id'), fact.get('declaration')]
               if fact['family'] == 'control' else None)
    identity = api.digest([fact['event'], fact['call'], fact['request_sha256'], fact['response_sha256'], control])
    fact['id'] = identity
    fd, temporary = tempfile.mkstemp(prefix='.deferred-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(fact, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, directory / ('deferred-' + format(captured_order, '020d') + '-' + identity + '.json'))
        except FileExistsError:
            pass  # Exact redelivery keeps the first observation time and order.
    finally:
        os.unlink(temporary)
    if fact['event'] == 'PreToolUse' and fact['family'] == 'read_only':
        return {}
    message = 'Cadence observation deferred during bounded lock contention; verification remains PENDING until recorded facts are consumed.'
    if fact['event'] == 'Stop' and not payload.get('stop_hook_active'):
        text = api.clean_message(payload.get('last_assistant_message'))
        completion = COMPLETION.search(text)
        if api.CLAIM.search(text) or (completion and completion.group(1) == 'PASS'):
            return {'decision': 'block', 'reason': message}
    return {'systemMessage': message}


def settle_deferred_mutation(state, call, mutation, fact, api, poll=False):
    # Only an original complete, known target map can recover without another
    # source read. Every target becomes an obligation, not an invented digest.
    if mutation.get('unknown') or not mutation.get('before'):
        return False
    if poll:
        if mutation.get('process_id') is None or fact.get('poll_session_id') != mutation['process_id']:
            return False
    elif (fact['tool'] != mutation.get('tool') or fact.get('input_sha256') != mutation.get('input_sha256') or
          fact.get('invocation') != mutation.get('invocation') or (mutation.get('invocation') or {}).get('background')):
        return False
    response = fact['response'] if fact.get('response_structured') or (fact['tool'] != 'Bash' and not poll) else None
    if not terminal_mutation_response(response, fact['tool'], fact['harness'], poll, event=fact.get('event')):
        return False
    for rel in mutation['before']:
        previous = state['writes'].get(rel, {})
        terminal_at = max(fact['captured_at'], previous.get('requires_check_after', 0))
        write = {'at': terminal_at, 'requires_check_after': terminal_at,
                 'obligation': 'deferred_known_target', 'content': 'unobserved:' + api.digest([fact['id'], call, rel])}
        measured = mutation.get('measured', {}).get(rel, previous.get('measured'))
        if measured is not None:
            write['measured'] = measured  # keeps deletion provenance through a contended completion
        state['writes'][rel] = write
        state.get('applicability', {}).pop(rel, None)
    state['mutations'].pop(call)
    state['uncertain'].pop(call, None)
    if call in state['observations']:
        state['observations'][call]['completed'] = True
    return True


def apply_deferred(state, fact, root, api, checkpoint):
    """Consume normalized facts only; never reconstruct a missed fingerprint."""
    initialize(state)
    event, call, family = fact['event'], fact['call'], fact['family']
    if event in ('SessionStart', 'UserPromptSubmit'):
        state['active_turn'] = fact.get('turn_id')
        return
    if event in ('SubagentStart', 'SubagentStop') and fact.get('agent_id'):
        state['agents'][fact['agent_id']] = {'provider': fact['harness'] + '-native', 'status': event,
            'model_observed': fact.get('model'), 'worktree': str(root), 'session_id': fact.get('session_id'),
            'execution_import': 'unsupported: provenance is not execution evidence'}
        return
    if event == 'Stop' and fact.get('declaration'):
        declaration = fact['declaration']
        latest = latest_checks(state['evidence'], at=fact['captured_at'])
        records = list(latest.values()) + [pending for pending in state['pending'].values()
                                          if pending['started_at'] <= fact['captured_at']]
        reason = 'deferred ' + declaration['label'] + ' declaration'
        if declaration['requirements']:
            reason += ': required ' + ', '.join(declaration['requirements']) + ' validation'
        retain_declaration(state, declaration, fact['captured_at'], reason, records)
        return
    if event not in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
        return
    if not call:
        if family != 'read_only':
            state['uncertain']['missing-tool-id'] = 'deferred source/check identity unavailable'
        return
    observed = state['observations'].get(call)
    if event == 'PreToolUse':
        if observed is not None:
            if observed['request_sha256'] != fact['request_sha256']:
                conflicting_observation(state, call, 'deferred start identity changed')
            elif family in ('check', 'mutation') and fact['captured_at'] < observed.get('observed_at', float('-inf')):
                state['uncertain']['deferred:' + call] = 'earlier source baseline unavailable during contention'
            return
        if call in state['pending'] or call in state['mutations']:
            conflicting_observation(state, call, 'original request unavailable for deferred start')
            return
        observed = {'request_sha256': fact['request_sha256'], 'posts': [], 'completed': False,
                    'observed_at': fact['captured_at']}
        state['observations'][call] = observed
        if family == 'check':
            pending = fact['check']
            state['pending'][call] = pending
            if 'wrapper' in pending:
                observed['wrapper_pending'] = {key: pending[key] for key in ('wrapper', 'kind', 'started_at')}
        elif family == 'mutation':
            reason = 'source baseline unavailable during contention'
            state['uncertain'][call] = reason
            state['mutations'][call] = {'at': fact['captured_at'], 'unknown': reason, 'before': {},
                'tool': fact['tool'], 'input_sha256': fact['input_sha256'], 'invocation': fact['invocation']}
        return
    if replayed_observation(state, call, fact['request_sha256'], fact['response_sha256'], event, fact['response'], api):
        return
    if fact['tool'] == 'write_stdin':
        matched = False
        for mutation_call, mutation in list(state['mutations'].items()):
            if settle_deferred_mutation(state, mutation_call, mutation, fact, api, poll=True):
                matched = True
        if matched:
            state['observations'][call] = {'request_sha256': fact['request_sha256'],
                'posts': [fact['response_sha256']], 'completed': True, 'observed_at': fact['captured_at']}
        return
    pending = state['pending'].get(call)
    if pending is not None:
        if 'wrapper' in pending:
            recover_wrappers(state, root, api, checkpoint)
            return
        result = fact.get('result', {})
        if result.get('status') in ('running', 'unknown'):
            pending['process_id'] = result.get('process_id')
            if result.get('status') == 'running':
                pending['execution_pending'] = True
            return
        record = record_check(state, pending, result.get('status', 'unbound'), result.get('exit_code'), '', root, api, checkpoint)
        record.update(finished_at=fact['captured_at'], output_sha256=result.get('output_sha256'),
                      fingerprint_error='completion fingerprint unavailable during contention')
        state['pending'].pop(call, None)
        state['observations'][call]['completed'] = True
    elif call in state['mutations']:
        mutation = state['mutations'][call]
        if settle_deferred_mutation(state, call, mutation, fact, api):
            return
        response = fact['response']
        if response.get('session_id') is not None:
            mutation['process_id'] = response['session_id']
        if response.get('session_id') is None and response.get('status') not in ('running', 'pending'):
            state['uncertain'][call] = 'source completion contents unavailable during contention'
        # A delayed ordinary Stop never hashes source to reconstruct this event.
    elif family == 'read_only':
        if observed is not None:
            observed['completed'] = True
    elif family in ('check', 'mutation'):
        state['uncertain'][call] = 'source/check start event unavailable during contention'
        if family == 'check':
            check, result = fact['check'], fact.get('result', {})
            state.setdefault('uncertain_checks', {})[call] = {'command_sha256': check['command_sha256'],
                'cwd': check['cwd'], 'at': fact['captured_at']}
            state['evidence'].append({'tool_use_id': call, 'started_at': fact['captured_at'],
                'finished_at': fact['captured_at'], 'cwd': check['cwd'], 'command_sha256': check['command_sha256'],
                'status': result.get('status') if result.get('status') in ('failed', 'interrupted') else 'missing_start',
                'exit_code': result.get('exit_code'), 'output_sha256': result.get('output_sha256'),
                'scope': None, 'before_fingerprint': None, 'after_fingerprint': None})


def drain_deferred(directory, state, root, api, checkpoint):
    # One short batch bounds contention work. A remaining batch prevents PASS;
    # no timer or background worker is introduced.
    paths = sorted(directory.glob('deferred-*.json'))
    if not paths:
        state['deferred_pending'] = False
        return
    batch = paths[:128]  # Bound payload reads before parsing any entry.
    consumed = state.setdefault('deferred_consumed', {})
    removed = []
    deadline = time.monotonic() + 0.25
    for path in batch:
        if time.monotonic() >= deadline:
            break
        name = re.fullmatch(r'deferred-(\d{20})-([a-f0-9]{64})\.json', path.name)
        if not name:
            state.setdefault('uncertain', {})['deferred-order'] = 'deferred observation order unavailable; retained for recovery'
            break
        fact = json.loads(path.read_text())
        if fact.get('schema') != 1 or fact.get('id') != name[2] or fact.get('order') != int(name[1]):
            state.setdefault('uncertain', {})['deferred-order'] = 'deferred observation identity/order conflict; retained for recovery'
            break
        if fact['id'] not in consumed:
            apply_deferred(state, fact, root, api, lambda: None)
            consumed[fact['id']] = {'captured_at': fact['captured_at'], 'order': fact['order']}
        removed.append(path)
    state['deferred_pending'] = len(removed) < len(paths)
    checkpoint()  # Commit the batch once, before removing any consumed facts.
    for path in removed:
        path.unlink(missing_ok=True)
    state['deferred_pending'] = bool(list(directory.glob('deferred-*.json')))


def handle(state, payload, root, config, policy, cwd, api, checkpoint=lambda: None, harness='codex', observed_at=None):
    initialize(state)
    event = payload.get('hook_event_name', '')
    call = payload.get('tool_use_id')
    now = time.time() if observed_at is None else observed_at
    inp = payload.get('tool_input') or {}
    command = inp.get('command', inp.get('cmd')) if isinstance(inp, dict) else None
    request = api.wrapper_request(command) if harness == 'codex' and payload.get('tool_name') == 'Bash' else None
    verify_command = shlex.join(request['argv']) if request else command
    kind = api.classification(verify_command, policy, cwd) if payload.get('tool_name') == 'Bash' else None
    if event in ('SessionStart', 'UserPromptSubmit'):
        state['active_turn'] = payload.get('turn_id')
        if not state.get('continuation_pending'):
            state['block_count'] = 0
        return api.context(event, 'Proportional cadence evidence is active. Use the trusted verification route on the first invocation. Valid scoped checks survive turns and content-preserving commits; unresolved edits/checks remain pending. Finish with Verification: PASS, PENDING, BLOCKED, or NOT APPLICABLE — an accurate reason.')
    if event == 'PreToolUse':
        if not call:
            state['uncertain']['missing-tool-id'] = 'tool identity unavailable'
            return {}
        identity = invocation_identity(payload, cwd, api)
        observed = state['observations'].get(call)
        if observed is not None or call in state['pending'] or call in state['mutations']:
            if observed is not None and observed['request_sha256'] == identity:
                return {}  # Never rebase the first source snapshot or mint a new nonce.
            conflicting_observation(state, call, 'start identity changed or original request unavailable')
            return {'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': 'deny',
                    'permissionDecisionReason': 'Cadence invocation identity conflicts with an earlier observation.'}}
        if kind:
            pending = {'kind': kind, 'command_sha256': api.digest(shlex.join(shlex.split(verify_command)).encode()),
                       'command_runner': shlex.split(verify_command)[0], 'cwd': str(cwd),
                       'started_at': now, 'tool_use_id': call, 'proportional': True,
                       'before': {'fingerprint': None}, 'session_id': payload.get('session_id')}
            if request:
                claim = Path(request['receipt'] + '.request.json')
                if any(os.path.lexists(request[k]) for k in ('receipt', 'output')):
                    return {'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': 'deny', 'permissionDecisionReason': 'Cadence requires fresh private receipt/output paths.'}}
                claim.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                try:
                    fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                except FileExistsError:
                    return {'hookSpecificOutput': {'hookEventName': event, 'permissionDecision': 'deny', 'permissionDecisionReason': 'Cadence request path already exists.'}}
                request['hook_nonce'] = api.secrets.token_hex(24)
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'schema': 1, 'hook_nonce': request['hook_nonce'], 'invocation_sha256': request['invocation_sha256']}, stream)
                pending['wrapper'] = {k: v for k, v in request.items() if k != 'argv'}
            observed = {'request_sha256': identity, 'posts': [], 'completed': False, 'observed_at': now}
            if request:
                observed['wrapper_pending'] = {'wrapper': pending['wrapper'], 'kind': kind, 'started_at': now}
            state['observations'][call] = observed
            state['pending'][call] = pending
            checkpoint()  # Invocation survives fingerprint timeout/crash.
            if harness != 'codex' or request:
                pending['before'] = snapshot(root, config, policy, api, verify_command, cwd)
            return {}
        targets, unknown = write_targets(payload, root, api, harness)
        targets = [rel for rel in targets if is_source(rel, config, api)]
        if targets or unknown:
            mutation = {'at': now, 'unknown': unknown, 'before': {}, 'tool': payload.get('tool_name'),
                        'input_sha256': api.digest(inp),
                        'invocation': mutation_invocation(payload, root, api, harness)}
            state['mutations'][call] = mutation
            state['observations'][call] = {'request_sha256': identity, 'posts': [], 'completed': False, 'observed_at': now}
            if unknown:
                state['uncertain'][call] = unknown
            checkpoint()
            if unknown == 'unresolved shell write target' and mutation['invocation']:
                mutation['observed_before'] = mutation_snapshot(root, config, policy, api)
            for rel in targets:
                try:
                    mutation['before'][rel] = file_digest(root / rel, api)
                    mutation.setdefault('measured', {})[rel] = (
                        measurable_now(root, rel, api) if mutation['before'][rel] != 'deleted' else None)
                except (OSError, ValueError):
                    mutation['unknown'] = 'write target content unavailable'
        return {}
    if event in ('PostToolUse', 'PostToolUseFailure'):
        if replayed_post(state, payload, cwd, api):
            return {}
        pending = state['pending'].get(call)
        wrapper_call = pending is not None and 'wrapper' in pending
        if harness == 'codex':
            recover_wrappers(state, root, api, checkpoint)
        if wrapper_call:
            return api.context(event, 'Cadence retained or consumed the exact execution receipt; current source acceptance requires an explicit Verification: PASS.')
        if pending is not None:
            status, code, output, process = observed_check_result(payload.get('tool_response'), event, pending['kind'], api, harness)
            if status == 'running':
                pending.update(process_id=process, execution_pending=True)
                return {}
            if harness == 'codex':
                status, code, output = 'unbound', None, ''
            record = record_check(state, pending, status, code, output, root, api, checkpoint)
            record['finished_at'] = now
            if status == 'passed' and pending['before'].get('fingerprint'):
                after = snapshot(root, config, policy, api, verify_command, cwd)
                record.update(after_fingerprint=after['fingerprint'], fingerprint_error=after['error'], head=after['head'])
            state['pending'].pop(call, None)
            if call in state['observations']:
                state['observations'][call]['completed'] = True
            return api.context(event, 'Cadence recorded command status: ' + status + '. Current source acceptance requires an explicit Verification: PASS.')
        if payload.get('tool_name') == 'write_stdin':
            for mutation_call, mutation in list(state['mutations'].items()):
                if mutation.get('process_id') is not None and isinstance(inp, dict) and inp.get('session_id') == mutation['process_id']:
                    settle_writes(state, root, config, api, mutation_call, policy=policy, observation=payload, harness=harness)
            return {}
        if kind:
            identity = call or 'missing-verifier-pre'
            state['uncertain'][identity] = 'verification start event missing; checked contents unavailable'
            state.setdefault('uncertain_checks', {})[identity] = {'command_sha256': api.digest(shlex.join(shlex.split(verify_command)).encode()), 'cwd': str(cwd), 'at': now}
            state['evidence'].append({'tool_use_id': call, 'started_at': now, 'finished_at': now, 'cwd': str(cwd),
                'command_sha256': api.digest(shlex.join(shlex.split(verify_command)).encode()), 'status': 'missing_start', 'exit_code': None,
                'scope': None, 'before_fingerprint': None, 'after_fingerprint': None})
        elif call in state['mutations']:
            settle_writes(state, root, config, api, call, policy=policy, observation=payload, harness=harness)
        else:
            targets, unknown = write_targets(payload, root, api, harness)
            if unknown or any(is_source(p, config, api) for p in targets):
                state['uncertain'][call or 'missing-write-pre'] = 'write start event missing'
        return {}
    if event == 'Stop':
        if harness == 'codex':
            recover_wrappers(state, root, api, checkpoint)
        return finish(state, payload, root, config, policy, api)
    # Native identity events are provenance only. No child report is executed evidence.
    if event in ('SubagentStart', 'SubagentStop') and payload.get('agent_id'):
        state['agents'][payload['agent_id']] = {'provider': 'codex-native', 'model_observed': payload.get('model'),
            'status': event, 'worktree': str(root), 'session_id': payload.get('session_id'),
            'execution_import': 'unsupported: no trusted parent-task/delegated execution binding'}
    return {}


def finish(state, payload, root, config, policy, api):
    message = api.clean_message(payload.get('last_assistant_message'))
    completion = COMPLETION.search(message)
    label = completion.group(1) if completion else None
    claims = bool(api.CLAIM.search(message)) or label == 'PASS'
    latest = latest_checks(state['evidence'])
    fresh, unresolved = [], []
    cache = {}
    for record in latest.values():
        usable = (record['status'] == 'passed' and not record.get('fingerprint_error') and record.get('scope') and
                record.get('before_fingerprint') is not None and
                record['before_fingerprint'] == record.get('after_fingerprint'))
        current = (snapshot(root, config, policy, api, selected=record['scope'], cache=cache)
                   if claims and usable else {'fingerprint': None})
        good = usable and record['after_fingerprint'] == current['fingerprint']
        related_write = record.get('scope') and any(matches(rel, record['scope']['inputs'] + record['scope']['shared']) for rel in state['writes'])
        if good:
            fresh.append(record)
        elif not record.get('consumed') or claims or related_write:
            unresolved.append(record)
    applicable = state.get('applicability', {})
    for pending_id, pending in list(state['pending'].items()):
        if 'wrapper' not in pending and not pending.get('execution_pending') and pending.get('process_id') is None and any(r['cwd'] == pending['cwd'] and r['command_sha256'] == pending['command_sha256']
               and r['started_at'] > pending['started_at'] for r in fresh):
            state['pending'].pop(pending_id)
    for uncertain_id, invocation in list(state.get('uncertain_checks', {}).items()):
        if any(r['cwd'] == invocation['cwd'] and r['command_sha256'] == invocation['command_sha256'] and r['started_at'] > invocation['at'] for r in fresh):
            state['uncertain'].pop(uncertain_id, None)
            state['uncertain_checks'].pop(uncertain_id)
    # A write is covered only by a check whose scope globs match it AND whose
    # fingerprint could actually contain it. Ignored files and hard-excluded
    # directories are never enumerated, so a glob match alone would let a
    # changed file keep a passing fingerprint it was never part of.
    unmeasured, unenumerated = [], False
    if claims and state['writes'] and fresh:  # without a fresh check every write is uncovered anyway
        try:
            enumerated = {os.fsdecode(raw) for raw in candidate_paths(root, api, cache)}
        except (OSError, subprocess.SubprocessError):
            enumerated, unenumerated = None, True
        for rel, write in state['writes'].items():
            if applicable.get(rel) == write['content']:
                continue
            shape_ok = (not matches(rel, api.DEFAULT_EXCLUDES)
                        and not any(p in api.SKIP_PARTS for p in Path(rel).parts))
            content = str(write.get('content', ''))
            # A deletion, or a deferred write whose final content was never read:
            # the path may legitimately be gone from the enumeration.
            gone = content == 'deleted' or content.startswith('unobserved:')
            if enumerated is None or not shape_ok:
                fingerprinted = False
            elif rel in enumerated:
                # An existing path is judged by the state a fresh check saw: a
                # fresh fingerprint equals the current tree, so membership now is
                # membership then. Ignore-rule games between check and claim
                # therefore cannot smuggle a change past the fingerprint.
                fingerprinted = True
            elif gone and write.get('measured') in ('tracked', True):
                # It was enumerated when removed (tracked, or seen by the
                # before/after comparison), so its removal is measured even after
                # the deletion is committed and an ignore rule matches the path.
                fingerprinted = True
            elif gone:
                fingerprinted = tracked_at_head(root, rel, api) or not ignored_by_git(root, rel, api)
            else:
                fingerprinted = False
            if not fingerprinted:
                unmeasured.append(rel)
    uncovered = [rel for rel, write in state['writes'].items()
                 if applicable.get(rel) != write['content'] and
                 (rel in unmeasured or
                  not any(matches(rel, r['scope']['inputs'] + r['scope']['shared']) and
                          r['started_at'] >= write.get('requires_check_after', float('-inf')) for r in fresh))]
    unrecorded = []
    if label == 'PASS':
        # Inspect the line as written: drop fenced blocks first (an example in a
        # fence is not the claim), then remove inline code marks so a path inside
        # backticks is judged the same as one in plain text.
        raw = payload.get('last_assistant_message') or ''
        unfenced = re.sub(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*", "", raw).replace('`', '')
        raw_completion = COMPLETION.search(unfenced)
        unrecorded = unrecorded_named_checks((raw_completion or completion).group(2), fresh)
    issues = []
    if unmeasured and unenumerated:
        issues.append('could not list the repository files to match these changed paths: ' + ', '.join(sorted(unmeasured)))
    elif unmeasured:
        issues.append('changed files the checks can never see (ignored, or in a skipped folder): ' + ', '.join(sorted(unmeasured)))
    if unrecorded:
        issues.append('the PASS names checks that were not seen running: ' + ', '.join(unrecorded))
    if state.get('deferred_pending'):
        issues.append('some tool events are still waiting to be recorded')
    if state['uncertain']:
        issues.append('commands whose effect on files could not be determined (' + '; '.join(sorted(set(state['uncertain'].values()))) + ')')
    if state['pending']:
        issues.append('a check is still running or never reported its result')
    if state['mutations']:
        issues.append('a command that may have written files never reported finishing')
    if unresolved:
        dispositions = {('passed earlier but not yet confirmed on the current files' if not claims else 'passed on an older version of the files')
                        if r['status'] == 'passed' else r['status'] for r in unresolved}
        issues.append('checks that did not count: ' + ', '.join(sorted(dispositions)))
        errors = sorted({r['fingerprint_error'] for r in unresolved if r.get('fingerprint_error')})
        if errors:
            issues.append('; '.join(errors))
    if uncovered:
        issues.append('changed files have no passing check that covers them')
    if state['writes'] or state['uncertain']:
        try:
            scope_definition(root, config, [])
        except (ValueError, TypeError) as exc:
            issues.append('the project config needs prod_globs, test_globs and verification_config_globs: ' + str(exc))
            issues.append('no supported direct test runner is configured; Codex checks must go through codex-verify.py')
    requirement = state.get('required_validation')
    if requirement:
        external = requirement['external']
        required_paths, required_commands = requirement.get('paths', []), requirement.get('commands', [])
        covered = all(any(matches(rel, r['scope']['inputs'] + r['scope']['shared']) and
                      r['finished_at'] >= requirement.get('path_times', {}).get(rel, requirement['at'])
                      for r in fresh) for rel in required_paths)
        covered = covered and all(isinstance(required, dict) and any(
            r['command_sha256'] == required['command_sha256'] and r['cwd'] == required['cwd']
            and (required.get('scope') is None or r['scope'] == required['scope'])
            and r['finished_at'] >= requirement['at'] for r in fresh) for required in required_commands)
        if not external and covered and not issues:
            state.pop('required_validation', None)
        else:
            issues.append('an earlier PENDING/BLOCKED declaration is still open')
    if label in ('PENDING', 'BLOCKED') and not claims:
        retain_declaration(state, pending_declaration(message, api), time.time(), completion.group(2),
                           unresolved + list(state['pending'].values()))
        # The reply already says PENDING or BLOCKED; repeating it under the
        # answer is clutter for the person. The obligations are retained silently.
        return {}
    if (label == 'NOT APPLICABLE' and not state['uncertain'] and not state['pending'] and not state['mutations'] and not unresolved
            and not any(write.get('obligation') == 'deferred_known_target' for write in state['writes'].values())):
        # This is an applicability judgment, never a fabricated passing check.
        # An earlier unavailable required check cannot be waived by this label.
        if not state.get('required_validation'):
            state['applicability'] = {rel: write['content'] for rel, write in state['writes'].items()}
            state['writes'] = {}
            state['mutations'] = {}
            state.update(outcome='not_applicable', applicability_reason=completion.group(2), continuation_pending=False)
            return {}
    if not issues and fresh:
        # Latest successful evidence supersedes older attempts of exactly the
        # same observed command. No unrelated failure or pending run is pruned.
        state['evidence'] = list(latest.values())
        for record in fresh:
            record['consumed'] = True
        state['writes'] = {}
        state['mutations'] = {}
        state.update(outcome='verified', continuation_pending=False)
        return {}
    if not issues and not claims:
        state.update(outcome='read_only' if not state['writes'] else 'not_applicable', continuation_pending=False)
        return {}
    if not issues:
        issues.append('a PASS needs a recorded passing check on the final files')
    if state.get('harness') == 'claude':
        remedy = ('Fix: run each check as one foreground command with a long enough tool timeout, '
                  'edit files with the Edit/Write tools, or end with "Verification: PENDING — reason".')
    else:
        remedy = ('Fix: edit files with apply_patch or the file tools (shell writes cannot be attributed in Codex), '
                  'run checks through codex-verify.py, or end with "Verification: PENDING — reason".')
    reason = 'Cadence could not confirm this turn: ' + '; '.join(issues) + '. ' + remedy
    if policy.get('mode') == 'blocking' and not state.get('block_count') and not payload.get('stop_hook_active'):
        state.update(outcome='needs_verification', block_count=1, continuation_pending=True)
        return {'decision': 'block', 'reason': reason}
    state.update(outcome='unverified', continuation_pending=False)
    # The person sees this line; the agent already received the full reason on
    # the block. Keep it short: what happened and the leading cause.
    summary = '; '.join(issues[:2]) + (' (+%d more)' % (len(issues) - 2) if len(issues) > 2 else '')
    return {'systemMessage': 'UNVERIFIED: this PASS was not confirmed by the cadence hooks — ' + summary + '.'}


def claude_main():
    """Exit 3 means legacy/inactive: the existing shell implementation continues."""
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 3
    if not isinstance(payload, dict):
        return 3
    captured_at, captured_order = time.time(), time.monotonic_ns()
    cwd = Path(payload.get('cwd') or os.getcwd()).resolve()
    try:
        root = Path(subprocess.check_output(['git', '-C', str(cwd), 'rev-parse', '--show-toplevel'], stderr=subprocess.DEVNULL, text=True).strip()).resolve()
        config = json.loads((root / CONFIG).read_text())
    except (OSError, ValueError, subprocess.SubprocessError):
        return 3
    if config.get('enabled') is not True or config.get('workflow', 'legacy') == 'legacy':
        return 3
    if config.get('workflow') != 'proportional':
        print(json.dumps({'decision': 'block', 'reason': 'Cadence workflow must be legacy or proportional.'}))
        return 0
    hook = Path(__file__).resolve().parents[1] / 'hooks/codex-evidence.py'
    spec = importlib.util.spec_from_file_location('cadence_evidence_api', hook)
    api = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(api)
    policy = config.get('claude_verification', {'mode': 'blocking'})
    if not isinstance(policy, dict) or policy.get('mode') not in ('blocking', 'warn'):
        print(json.dumps({'systemMessage': 'Cadence Claude execution evidence inactive: configure claude_verification.mode.'}))
        return 0
    sid = payload.get('session_id')
    if not isinstance(sid, str) or not sid:
        print(json.dumps({'decision': 'block', 'reason': 'Cadence execution session identity unavailable; report Verification: PENDING — reason.'}))
        return 0
    if payload.get('hook_event_name') == 'SubagentStop':
        if not isinstance(payload.get('agent_id'), str) or not payload['agent_id']:
            reason = 'Cadence child execution identity unavailable; verification remains pending. Controller evidence was not finalized.'
            result = {'systemMessage': 'UNVERIFIED: ' + reason} if payload.get('stop_hook_active') else {'decision': 'block', 'reason': reason}
            print(json.dumps(result))
            return 0
        # The harness reports the actual child identity. Finalize only that
        # child's ledger; never import its claims/results into its parent.
        payload = dict(payload, hook_event_name='Stop')
    # Same private Claude evidence store, scoped additionally by canonical worktree.
    # Separate child identity avoids importing evidence whose parent binding the
    # harness does not attest. This deliberately reports a supported limitation.
    base = Path(os.environ.get('ORCH_HOME', str(Path.home() / '.llm-orchestrator')))
    identity = sid + ':' + str(payload.get('agent_id') or 'controller')
    directory = base / 'state' / api.digest(str(root))[:12] / ('evidence.' + api.digest(identity))
    prune_completed(directory.parent, directory)
    try:
        with api.locked_state(directory, on_busy=lambda: defer_event(directory, payload, root, config, policy, cwd,
                              api, 'claude', captured_at, captured_order)) as state:
            drain_deferred(directory, state, root, api, lambda: api.save_state(directory, state))
            state.update(schema=2, worktree=str(root), session_id=sid, harness='claude')
            result = handle(state, payload, root, config, policy, cwd, api,
                            checkpoint=lambda: api.save_state(directory, state), harness='claude', observed_at=captured_at)
    except api.DeferredObservation as exc:
        result = exc.result
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(claude_main())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print(json.dumps({'decision': 'block', 'reason': 'Cadence execution evidence unavailable; report Verification: PENDING — hook evidence unavailable.'}))
