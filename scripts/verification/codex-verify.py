#!/usr/bin/env python3
"""Run one explicit non-build verifier and write exclusive private evidence.

Codex 0.154 hooks omit exec workdir and exit metadata. This runner owns the
subprocess so its receipt can record both, without interpreting stdout as
harness control data. It is a local guardrail, not tamper-proof attestation.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time


HOOK = Path(__file__).resolve().parents[1] / "hooks/codex-evidence.py"
SPEC = importlib.util.spec_from_file_location("cadence_evidence", HOOK)
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


def exclusive(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)


def atomic_receipt(path, receipt):
    fd, name = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(receipt, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def stop_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    except ProcessLookupError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.command[1:] if args.command[:1] == ["--"] else args.command
    request = evidence.wrapper_request(shlex.join([
        "python3", str(Path(__file__).resolve()), "--cwd", args.cwd,
        "--receipt", args.receipt, "--output", args.output, "--", *argv]))
    if not request:
        parser.error("use absolute cwd/receipt/output paths and one direct verifier after --")
    found = evidence.project({"cwd": request["cwd"]})
    if not found:
        parser.error("cwd must belong to a project with Codex verification enabled")
    root, config, policy, cwd = found
    kind = evidence.classification(shlex.join(argv), policy, cwd)
    if not kind:
        parser.error("command is not an allowed direct non-build verifier")
    if Path(argv[0]).name == "npx" and "--no-install" not in argv[1:]:
        parser.error("npx requires --no-install; dependency installation is not verification")
    configured_timeout = policy.get("timeout_seconds")
    timeout = float(configured_timeout) if configured_timeout is not None else None
    if timeout is not None and (not math.isfinite(timeout) or timeout <= 0):
        parser.error("timeout_seconds must be a positive finite number when set")
    receipt_path, output_path = Path(request["receipt"]), Path(request["output"])
    claim_path = Path(request["receipt"] + ".request.json")
    if os.path.lexists(claim_path):
        info = claim_path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            parser.error("hook request must be a private regular file")
        claim = json.loads(claim_path.read_text())
        if claim.get("schema") != 1 or claim.get("invocation_sha256") != request["invocation_sha256"] or not isinstance(claim.get("hook_nonce"), str):
            parser.error("hook request does not match this invocation")
        request["hook_nonce"] = claim["hook_nonce"]
    else:
        request["hook_nonce"] = None
    if any(os.path.lexists(p) for p in (receipt_path, output_path)):
        parser.error("receipt and output paths must both be new; use a fresh run ID")
    receipt_fd = exclusive(receipt_path)
    with os.fdopen(receipt_fd, "w") as stream:
        json.dump({"schema": 1, "state": "reserved"}, stream)
    output_fd = exclusive(output_path)
    started = time.time()
    before = evidence.snapshot(root, config, policy)
    receipt = dict(request, schema=1, state="running", kind=kind,
                   started_at=started, before_fingerprint=before["fingerprint"],
                   worktree=str(root), head_before=before["head"])
    atomic_receipt(receipt_path, receipt)
    code, interrupted = 127, False
    with os.fdopen(output_fd, "wb") as output:
        proc = None
        def interrupt(_signum, _frame):
            raise KeyboardInterrupt
        previous_term = signal.signal(signal.SIGTERM, interrupt)
        try:
            proc = subprocess.Popen(argv, cwd=cwd, stdout=output,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                stop_group(proc)
                code, interrupted = 124, True
                output.write(b"\nCadence verifier timed out.\n")
            except KeyboardInterrupt:
                stop_group(proc)
                code, interrupted = 130, True
                output.write(b"\nCadence verifier interrupted.\n")
        except OSError:
            output.write(b"Cadence could not start the requested verifier.\n")
        finally:
            if proc is not None and proc.poll() is None:
                stop_group(proc)
            signal.signal(signal.SIGTERM, previous_term)
    raw = output_path.read_bytes()
    after = evidence.snapshot(root, config, policy)
    receipt.update(state="completed", finished_at=time.time(), exit_code=code,
                   interrupted=interrupted, after_fingerprint=after["fingerprint"],
                   head_after=after["head"], output_sha256=evidence.digest(raw),
                   output_bytes=len(raw))
    atomic_receipt(receipt_path, receipt)
    sys.stdout.buffer.write(raw)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError):
        print("Cadence verifier could not finish a valid receipt; verification remains pending.", file=sys.stderr)
        sys.exit(2)
