#!/usr/bin/env python3
"""Record observed Codex execution and check completion in opted-in projects.

Only documented hook payloads are consumed; transcripts and model-written
reports are never imported as executed test evidence. This guard is not a
security boundary against the user or an agent able to edit its own state.
"""
import contextlib
import fcntl
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile
import time


CONFIG = "docs/llm-orchestrator/cadence.json"
VERIFY_RUNNER = Path(__file__).resolve().parents[1] / "verification/codex-verify.py"
SOURCE_SUFFIXES = set(".py .sh .bash .zsh .js .jsx .ts .tsx .mjs .cjs .json .toml .yaml .yml .xml .gradle .java .kt .m .mm .swift .c .cc .cpp .h .hpp .rs .go .rb .php .css .scss .html .sql .rules .plist .entitlements .pbxproj".split())
SKIP_PARTS = {".git", "node_modules", "__pycache__", ".pytest_cache", "coverage", "dist", "build", "Pods"}
DEFAULT_EXCLUDES = ["docs/llm-orchestrator/notes/**", "**/*_report.md", "artifacts/**", "**/artifacts/**", ".env*", "**/.env*", "credentials/**", "**/credentials/**", "**/*.pem", "**/*.key"]
POSITIVE = re.compile(r"\b(?:[1-9][0-9]*\s+(?:passed|passing|(?:tests?|checks?) passed)|Ran\s+[1-9][0-9]*\s+tests?|#\s*pass\s+[1-9][0-9]*)\b", re.I)
SCRIPT_PASS = re.compile(r"^PASS:\s+[^\n]+\([1-9][0-9]* checks\)\s*$", re.M)
EMPTY = re.compile(r"\b(?:no tests (?:found|ran|collected)|collected\s+0\b|Ran\s+0\s+tests?|0\s+tests?\b|0\s+passing\b)|(?:Tests:|# tests)\s*0\b", re.I)
FAILURE = re.compile(r"^\s*(?:FAIL(?:ED)?\b|ERROR(?:S)?\b)|\b[1-9][0-9]*\s+(?:failed|failures|errors)\b|#\s*fail\s+[1-9][0-9]*\b", re.I | re.M)
CLAIM = re.compile(r"\b(?:tests pass|all (?:tests|checks) (?:passed|pass|are green)|fully verified|verification (?:passed|complete)|verified successfully)\b", re.I)


PROP_SPEC = importlib.util.spec_from_file_location("orch_proportional_evidence", Path(__file__).resolve().parents[1] / "lib/orch-proportional-evidence.py")
proportional = importlib.util.module_from_spec(PROP_SPEC)
PROP_SPEC.loader.exec_module(proportional)


def _module_api():
    from types import SimpleNamespace
    return SimpleNamespace(**globals())


def digest(value):
    if not isinstance(value, bytes):
        value = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(value).hexdigest()


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True, timeout=8).stdout


def project(payload):
    cwd = Path(payload.get("cwd") or os.getcwd()).resolve()
    inp = payload.get("tool_input")
    request = wrapper_request(inp.get("command", inp.get("cmd"))) if isinstance(inp, dict) else None
    if request:
        cwd = Path(request["cwd"])
    try:
        root = Path(os.fsdecode(git(cwd, "rev-parse", "--show-toplevel")).strip()).resolve()
        config = json.loads((root / CONFIG).read_text())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if not isinstance(config, dict):
        return None
    policy = config.get("codex_verification", {})
    if config.get("enabled") is not True or not isinstance(policy, dict) or policy.get("mode") not in ("blocking", "warn"):
        return None
    return root, config, policy, cwd


def wrapper_request(command):
    """Only the exact installed sibling runner can introduce receipt paths."""
    if not isinstance(command, str) or any(c in command for c in "\n\r;|&<>`$(){}"):
        return None
    try:
        args = shlex.split(command)
        if len(args) < 10 or Path(args[0]).name not in ("python", "python3"):
            return None
        if not Path(args[1]).is_absolute() or Path(args[1]).resolve() != VERIFY_RUNNER.resolve():
            return None
        args = args[2:]
        if args[0] != "--cwd" or args[2] != "--receipt" or args[4] != "--output" or args[6] != "--":
            return None
        cwd, receipt, output = (Path(args[i]) for i in (1, 3, 5))
        if not all(p.is_absolute() for p in (cwd, receipt, output)) or not args[7:]:
            return None
        request = {"cwd": str(cwd.resolve()), "receipt": str(receipt.resolve()),
                   "output": str(output.resolve()), "argv": args[7:]}
        if request["receipt"] == request["output"]:
            return None
        request["command_sha256"] = digest(shlex.join(args[7:]).encode())
        request["invocation_sha256"] = digest(request)
        request["runner_sha256"] = digest(VERIFY_RUNNER.read_bytes())
        return request
    except (OSError, ValueError, IndexError):
        return None


def matches(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) or
               (pattern.startswith("**/") and fnmatch.fnmatchcase(path, pattern[3:]))
               for pattern in patterns if isinstance(pattern, str))


def snapshot(root, config, policy, command=None, cwd=None):
    if config.get("workflow") == "proportional":
        return proportional.snapshot(root, config, policy, sys.modules[__name__] if __name__ in sys.modules else _module_api(), command, cwd)
    includes = policy.get("include_globs", [])
    includes = includes + config.get("prod_globs", []) + config.get("test_globs", [])
    runner = config.get("runner", {})
    if isinstance(runner, dict):
        includes = includes + runner.get("prod_globs", []) + runner.get("test_globs", [])
    excludes = DEFAULT_EXCLUDES + policy.get("exclude_globs", [])
    notes = config.get("notes_dir")
    if isinstance(notes, str) and notes:
        excludes.append(notes.rstrip("/") + "/**")
    paths = sorted(set(git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")) - {b""})
    files = {}
    for raw in paths:
        rel = os.fsdecode(raw)
        path = Path(rel)
        if any(part in SKIP_PARTS for part in path.parts) or matches(rel, excludes):
            continue
        if not (path.suffix in SOURCE_SUFFIXES or path.name in ("Dockerfile", "Makefile", "Podfile", "Gemfile", ".gitattributes", ".gitignore") or matches(rel, includes)):
            continue
        full = root / path
        try:
            info = full.lstat()
            if stat.S_ISLNK(info.st_mode):
                content = os.fsencode(os.readlink(full))
            elif stat.S_ISREG(info.st_mode):
                content = full.read_bytes()
            else:
                continue
            files[rel] = digest([stat.S_IMODE(info.st_mode), digest(content)])
        except FileNotFoundError:
            files[rel] = "deleted"
    try:
        head = os.fsdecode(git(root, "rev-parse", "HEAD")).strip()
    except subprocess.CalledProcessError:
        head = "unborn"
    return {"head": head, "fingerprint": digest([str(root), head, files]), "files": files}


def classification(command, policy, cwd):
    # Never mistake echo, a pipeline, `... || true`, or a shell snippet for an
    # executed verification command. Projects may add direct command patterns.
    if not isinstance(command, str) or any(c in command for c in "\n\r;|&<>`$(){}"):
        return None
    try:
        args = shlex.split(command)
    except ValueError:
        return None
    no_check = {"--help", "-h", "--version", "-V", "--listTests", "--collect-only", "--list", "--list-only", "--exit-zero", "--print-config", "--showConfig", "--noCheck"}
    if not args or any(a.split("=", 1)[0] in no_check for a in args):
        return None
    for rule in policy.get("commands", []):
        if isinstance(rule, dict) and rule.get("kind") in ("test", "lint", "typecheck"):
            if re.fullmatch(rule.get("pattern", "(?!)"), command):
                return rule["kind"]
    if not source_routes_inside_tree(args[1:], cwd):
        return None
    exe = Path(args[0]).name
    tail = args[1:]
    if exe in ("npm", "pnpm", "yarn"):
        if tail[:1] == ["--prefix"] and len(tail) > 2:
            tail = tail[2:]
        if tail[:1] == ["run"]:
            tail = tail[1:]
        if not tail:
            return None
        script = tail[0]
        if script == "test" or script.startswith("test:"):
            return "test"
        if script == "lint" or script.startswith("lint:"):
            return "lint"
        if script == "typecheck" or script.startswith("typecheck:"):
            return "typecheck"
        return None
    if exe == "npx":
        tail = [a for a in tail if a != "--no-install"]
        if not tail:
            return None
        exe, tail = Path(tail[0]).name, tail[1:]
    if exe in ("jest", "vitest", "pytest", "pytest3"):
        return "test"
    if exe in ("eslint", "ruff") and "--fix" not in tail and (exe != "ruff" or "check" in tail):
        return "lint"
    if exe == "tsc" and "--noEmit" in tail:
        return "typecheck"
    if exe in ("python", "python3") and tail[:1] == ["-m"] and len(tail) > 1 and tail[1] in ("unittest", "pytest"):
        return "test"
    if exe in ("bash", "sh", "python", "python3") and tail and not tail[0].startswith("-"):
        script = Path(tail[0])
        if re.fullmatch(r"test[-_].*\.(?:py|sh)", script.name):
            try:
                (cwd / script).resolve().relative_to(cwd.resolve())
                return "test"
            except ValueError:
                pass
    return None


def source_routes_inside_tree(arguments, cwd):
    """Default verifier routing cannot select a different source checkout."""
    try:
        root = Path(os.fsdecode(git(cwd, "rev-parse", "--show-toplevel")).strip()).resolve()
        routes = {"--prefix", "--cwd", "--dir", "--root", "--rootDir", "--rootdir", "--project", "--projects", "--config", "-c", "-p", "-s", "--start-directory", "--top-level-directory"}
        expect_path = False
        for argument in arguments:
            option, equal, value = argument.partition("=")
            if equal and option in routes:
                candidate, must_check = value, True
            else:
                candidate, must_check = argument, expect_path
            expect_path = argument in routes
            if expect_path:
                continue
            if candidate.startswith("-") and not must_check:
                continue
            path = Path(candidate.split("::", 1)[0]).expanduser()
            resolved = (cwd / path).resolve()
            if must_check or path.is_absolute() or candidate.startswith(".") or resolved.exists():
                resolved.relative_to(root)
        return not expect_path
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def read_command_can_write(args):
    """Known read-tool options that execute helpers or write output files."""
    if not args:
        return False
    exe = Path(args[0]).name
    options = {a.split("=", 1)[0] for a in args[1:]}
    if exe == "git":
        return bool(options & {"--output", "--ext-diff", "--textconv", "--open-files-in-pager", "-O"})
    if exe == "rg":
        return any(a.startswith("--pre") for a in args[1:])
    if exe == "file":
        return "--compile" in options or any(re.fullmatch(r"-[A-Za-z]*C[A-Za-z]*", a) for a in args[1:])
    return False


def potentially_mutating(payload, command):
    if payload.get("tool_name") == "apply_patch":
        return True
    if payload.get("tool_name") != "Bash":
        return False
    if not isinstance(command, str):
        return True
    try:
        args = shlex.split(command)
    except ValueError:
        return True
    if not args:
        return False
    exe = Path(args[0]).name
    if exe == 'sed' and proportional.literal_shell(command) and proportional.sed_targets(args) == []:
        return False
    if any(c in command for c in "\n\r;|&<>`$(){}"):
        return True
    if read_command_can_write(args):
        return True
    if exe in ("rg", "grep", "cat", "head", "tail", "ls", "pwd", "wc", "stat", "file", "which"):
        return False
    if exe == "sed":
        return proportional.sed_targets(args) != []
    if exe == "git" and len(args) > 1 and args[1] in ("status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree", "grep", "check-ignore"):
        return False
    return True


def result(response, kind):
    """Unknown output never becomes green merely because the hook exited zero."""
    code, output, process = None, "", None
    if isinstance(response, dict):
        code = response.get("exit_code")
        if isinstance(code, bool) or not isinstance(code, int):
            code = None
        output = response.get("output", response.get("stdout", ""))
        if not isinstance(output, str):
            output = json.dumps(output, sort_keys=True)
        stderr = response.get("stderr", "")
        if isinstance(stderr, str) and stderr:
            output += "\n" + stderr
        process = response.get("session_id")
        if response.get("isError") or response.get("interrupted"):
            return "interrupted", code, output, process
    elif isinstance(response, str):
        output = response
    if code is None:
        return ("running" if process is not None else "unknown"), None, output, process
    if code != 0:
        return "failed", code, output, process
    if kind == "test":
        # Deliberately conservative: a failure or empty-selection phrase anywhere
        # in a zero-exit run keeps it from counting as passed, even when a later
        # line carries a positive count. Narrowing this to a "summary window" was
        # tried and reverted: a trailing positive line then hid a real failure.
        # The cost is a false rejection for suites whose fixture labels or
        # diagnostics use those words; keep suite output concise instead.
        if FAILURE.search(output):
            return "failed", code, output, process
        if EMPTY.search(output):
            return "empty", code, output, process
        if not POSITIVE.search(output) and not SCRIPT_PASS.search(output):
            return "unconfirmed", code, output, process
    return "passed", code, output, process


def wrapper_observation(pending):
    """Validate only the exclusive artifact introduced by this exact tool call."""
    expected = pending["wrapper"]
    try:
        path = Path(expected["receipt"])
        log = Path(expected["output"])
        for artifact in (path,):
            info = artifact.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("not a private regular artifact")
        receipt = json.loads(path.read_text())
        if receipt.get("schema") != 1 or receipt.get("state") not in ("running", "finishing", "completed"):
            raise ValueError("incomplete")
        for key in ("cwd", "output", "receipt", "command_sha256", "invocation_sha256", "runner_sha256", "hook_nonce"):
            if receipt.get(key) != expected[key]:
                raise ValueError("request mismatch")
        if not pending["started_at"] <= receipt["started_at"] <= time.time():
            raise ValueError("stale time")
        if receipt['state'] == 'running':
            return 'running', None, '', receipt
        if not receipt['started_at'] <= receipt['finished_at'] <= time.time():
            raise ValueError('stale finish time')
        if receipt.get('setup_failure') is True:
            if (receipt['state'] != 'completed' or receipt.get('child_started') is not False or
                    type(receipt.get('exit_code')) is not int or receipt['exit_code'] == 0):
                raise ValueError('invalid setup failure')
            return 'failed', receipt['exit_code'], '', receipt
        info = log.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError('not a private regular output artifact')
        raw = log.read_bytes()
        if digest(raw) != receipt.get("output_sha256"):
            raise ValueError("output changed")
        code = receipt.get("exit_code")
        if not isinstance(code, int) or isinstance(code, bool):
            raise ValueError("missing exit status")
        status, code, output, _ = result({"exit_code": code, "output": raw.decode("utf-8", "replace"),
                                         "interrupted": receipt.get("interrupted", False)}, pending["kind"])
        return status, code, output, receipt
    except (OSError, ValueError, TypeError, KeyError):
        return "invalid_receipt", None, "", None


def wrapper_result(pending, snap):
    status, code, output, receipt = wrapper_observation(pending)
    if not receipt or receipt['state'] != 'completed':
        return 'invalid_receipt', None, ''
    if not pending.get('proportional') and not receipt.get('setup_failure') and (receipt['before_fingerprint'] != pending['before']['fingerprint'] or receipt['after_fingerprint'] != snap['fingerprint']):
        return 'invalid_receipt', None, ''
    return status, code, output


def clean_message(message):
    if not isinstance(message, str):
        return ""
    message = re.sub(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*", "", message)
    return re.sub(r"`[^`\n]*`", "", message)


def context(event, message):
    return {"hookSpecificOutput": {"hookEventName": event, "additionalContext": message}}


def begin(state, snap, turn):
    state.update(baseline=snap, started_at=time.time(), active_turn=turn,
                 continuation_pending=False, block_count=0, outcome="active", baseline_missing=False,
                 mutation_observed=False)


def handle(state, payload, root, config, policy, cwd, checkpoint=lambda: None, observed_at=None):
    if config.get("workflow") == "proportional":
        return proportional.handle(state, payload, root, config, policy, cwd, _module_api(), checkpoint, observed_at=observed_at)
    if config.get("workflow", "legacy") != "legacy":
        return {"decision": "block", "reason": "Cadence workflow must be legacy or proportional."}
    event = payload.get("hook_event_name", "")
    turn = payload.get("turn_id") or state.get("active_turn", "unknown")
    now = time.time()
    inp = payload.get("tool_input") or {}
    inp = inp if isinstance(inp, dict) else {}
    command = inp.get("command", inp.get("cmd"))
    call = payload.get("tool_use_id")
    request = wrapper_request(command) if payload.get("tool_name") == "Bash" else None
    verify_command = shlex.join(request["argv"]) if request else command
    kind = classification(verify_command, policy, cwd) if payload.get("tool_name") == "Bash" else None
    observed_mutation = event == "PreToolUse" and potentially_mutating(payload, command)
    if observed_mutation and "baseline" in state:
        state["mutation_observed"] = True
    if "baseline" in state:
        # Searches and unrelated tools need not hash thousands of source files.
        # Stop compares the full tree; a missing baseline is captured before the
        # first tool so edits still cannot silently establish a new baseline.
        if event == "PreToolUse" and not (kind and call):
            return {}
        if event == "PostToolUse" and call not in state.get("pending", {}):
            return {}
    snap = snapshot(root, config, policy)
    state.setdefault("evidence", [])
    state.setdefault("pending", {})
    state.setdefault("agents", {})
    if "baseline" not in state:
        begin(state, snap, turn)
        state["baseline_missing"] = event not in ("UserPromptSubmit", "SessionStart")
        state["mutation_observed"] = observed_mutation
    if event in ("SessionStart", "UserPromptSubmit"):
        # Stop continuations are new prompts with new turn IDs. Preserve the
        # original obligation and the one-block limit until that attempt ends.
        if state.get("continuation_pending"):
            state["active_turn"] = turn
        elif state.get("outcome") not in ("active", "needs_verification"):
            begin(state, snap, turn)
        return context(event, "Cadence execution evidence is active. After source edits, run relevant non-build checks on the final tree. For unavailable validation, end with 'Verification: PENDING — reason' or 'Verification: BLOCKED — reason'; never run a build to satisfy this hook.")
    if event in ("SubagentStart", "SubagentStop"):
        agent = payload.get("agent_id")
        if isinstance(agent, str) and agent:
            receipt = state["agents"].setdefault(agent, {"provider": "codex-native", "agent_id": agent, "model_observed": None})
            receipt.update(session_id=payload.get("session_id"), turn_id=turn,
                           agent_type=payload.get("agent_type"), worktree=str(root),
                           head=snap["head"], source_fingerprint=snap["fingerprint"],
                           reasoning_effort_observed=None,
                           status="started" if event == "SubagentStart" else "stopped")
            if payload.get("model"):
                receipt["model_observed"] = payload["model"]
            receipt["started_at" if event == "SubagentStart" else "stopped_at"] = now
            if event == "SubagentStop":
                text = payload.get("last_assistant_message")
                receipt["output_sha256"] = digest(text.encode()) if isinstance(text, str) else None
                receipt["output_present"] = bool(text)
                receipt["stop_hook_active"] = payload.get("stop_hook_active") is True
        return {}
    if event == "PreToolUse" and kind and call:
        if request:
            claim = Path(request["receipt"] + ".request.json")
            denial = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Cadence requires new receipt/output/request paths; an artifact or concurrent request already exists."}}
            if any(os.path.lexists(request[k]) for k in ("receipt", "output")):
                return denial
            claim.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            try:
                fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                return denial
            request["hook_nonce"] = secrets.token_hex(24)
            with os.fdopen(fd, "w") as stream:
                json.dump({"schema": 1, "hook_nonce": request["hook_nonce"],
                           "invocation_sha256": request["invocation_sha256"]}, stream)
        state["pending"][call] = {"kind": kind, "command_sha256": digest(shlex.join(shlex.split(verify_command)).encode()),
                                  "command_runner": shlex.split(verify_command)[0],
                                  "cwd": str(cwd), "before": snap,
                                  "session_id": payload.get("session_id"), "turn_id": turn,
                                  "started_at": now, "tool_use_id": call}
        if request:
            state["pending"][call]["wrapper"] = {k: v for k, v in request.items() if k != "argv"}
    if event == "PostToolUse":
        pending = state["pending"].pop(call, None) if call else None
        if pending:
            if "wrapper" in pending:
                status, code, output = wrapper_result(pending, snap)
            else:
                status, code, output = "unbound", None, ""
            record = {k: v for k, v in pending.items() if k != "before"}
            record.update(status=status, exit_code=code, finished_at=now,
                          before_fingerprint=pending["before"]["fingerprint"],
                          after_fingerprint=snap["fingerprint"], head=snap["head"],
                          output_sha256=digest(output.encode()), output_bytes=len(output.encode()),
                          worktree=str(root))
            state["evidence"] = [r for r in state["evidence"] if r["tool_use_id"] != record["tool_use_id"]]
            state["evidence"].append(record)
            return context(event, "Cadence recorded verification status: " + status + ". This is execution evidence, not a judgment about coverage or an independent review.")
        return {}
    if event != "Stop":
        return {}
    changed = state.get("baseline_missing", False) or snap["fingerprint"] != state["baseline"]["fingerprint"]
    message = clean_message(payload.get("last_assistant_message"))
    claims = bool(CLAIM.search(message))
    records = [r for r in state["evidence"] if r["started_at"] >= state["started_at"]]
    pending_checks = [p for p in state["pending"].values() if p["started_at"] >= state["started_at"]]
    activity = state.get("mutation_observed") or records or pending_checks or claims or state.get("baseline_missing")
    if not activity:
        state.update(outcome="read_only", continuation_pending=False)
        return {}
    latest = {}
    for record in sorted(records, key=lambda r: r["started_at"]):
        latest[(record["cwd"], record["command_sha256"])] = record
    fresh = [r for r in latest.values() if r["status"] == "passed" and
             r["before_fingerprint"] == r["after_fingerprint"] == snap["fingerprint"]]
    failed = [r for r in latest.values() if r["status"] != "passed"]
    failed += [{"status": "unfinished"} for p in pending_checks]
    if not changed and not claims and not records and not pending_checks:
        state.update(outcome="no_source_change", continuation_pending=False)
        return {}
    if fresh and not failed:
        state.update(outcome="verified", continuation_pending=False)
        return {}
    handoff = re.search(r"(?im)^Verification:[ \t]*(PENDING|BLOCKED)\s*(?:—|–|-)\s*(\S[^\n]*)$", message)
    if handoff and not claims:
        state.update(outcome=handoff.group(1).lower(), continuation_pending=False)
        return {"systemMessage": "Cadence: verification remains " + handoff.group(1) + "; no passing outcome was recorded."}
    reason = "Cadence: final source has no sufficient fresh executed verification. "
    if state.get("baseline_missing"):
        reason += "The turn-start source baseline is unavailable. "
    if failed:
        reason += "Latest recorded check status: " + ", ".join(sorted({r["status"] for r in failed})) + ". "
    elif records:
        reason += "Recorded successes predate the final source or changed while running. "
    reason += "Run the relevant non-build checks on the final tree, or report the exact limitation on a final line 'Verification: PENDING — reason' or 'Verification: BLOCKED — reason'. Do not run builds, install dependencies, or fabricate receipts."
    if policy["mode"] == "blocking" and not state.get("block_count") and not payload.get("stop_hook_active"):
        state.update(block_count=1, continuation_pending=True, outcome="needs_verification")
        return {"decision": "block", "reason": reason}
    state.update(outcome="unverified", continuation_pending=False)
    return {"systemMessage": "UNVERIFIED: " + reason + " The single continuation limit has been reached or this project is warn-only."}


class DeferredObservation(Exception):
    def __init__(self, result):
        self.result = result


@contextlib.contextmanager
def locked_state(directory, on_busy=None):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / "lock").open("a+") as lock:
        deadline = time.monotonic() + 0.75
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() < deadline:
                    time.sleep(0.01)
                    continue
                if on_busy is not None:
                    raise DeferredObservation(on_busy())
                # Bound contention while allowing ordinary short events to
                # serialize. The marker preserves any missed observation.
                marker_fd, _ = tempfile.mkstemp(prefix='missed-event-', dir=directory)
                os.close(marker_fd)
                raise
        path = directory / "state.json"
        state = json.loads(path.read_text()) if path.exists() else {}
        markers = list(directory.glob('missed-event-*'))
        if markers:
            state.setdefault('uncertain', {})['concurrent-hook'] = 'concurrent hook observation unavailable'
            state['baseline_missing'] = True
            save_state(directory, state)
            for marker in markers:
                marker.unlink()
        yield state
        save_state(directory, state)


def save_state(directory, state):
    fd, temp = tempfile.mkstemp(prefix=".state-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, directory / "state.json")
    finally:
        if os.path.exists(temp):
            os.unlink(temp)



def main():
    payload = {}
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return {}
        captured_at, captured_order = time.time(), time.monotonic_ns()
        found = project(payload)
        if not found or not isinstance(payload.get("session_id"), str) or not payload["session_id"]:
            return {}
        root, config, policy, cwd = found
        base = Path(os.environ.get("ORCH_CODEX_STATE_DIR", str(Path.home() / ".llm-orchestrator/codex")))
        directory = base / digest(str(root)) / digest(payload["session_id"])
        if config.get("workflow") == "proportional":
            proportional.prune_completed(directory.parent, directory)
        on_busy = (lambda: proportional.defer_event(directory, payload, root, config, policy, cwd,
                   _module_api(), 'codex', captured_at, captured_order)) if config.get('workflow') == 'proportional' else None
        with locked_state(directory, on_busy=on_busy) as state:
            if config.get('workflow') == 'proportional':
                proportional.drain_deferred(directory, state, root, _module_api(), lambda: save_state(directory, state))
            state.update(schema=1, worktree=str(root), session_id=payload["session_id"])
            return handle(state, payload, root, config, policy, cwd, checkpoint=lambda: save_state(directory, state), observed_at=captured_at)
    except DeferredObservation as exc:
        return exc.result
    except (OSError, ValueError, TypeError, KeyError, re.error, subprocess.SubprocessError):
        # No payload/output/exception repr here: hooks can contain private text.
        warning = "Cadence evidence unavailable: source verification cannot be claimed from this hook. Report the limitation and inspect the local hook configuration."
        if payload.get("hook_event_name") == "Stop" and not payload.get("stop_hook_active"):
            return {"decision": "block", "reason": warning + " Use an honest pending handoff; do not start a build."}
        return {"systemMessage": warning}


if __name__ == "__main__":
    print(json.dumps(main()))
