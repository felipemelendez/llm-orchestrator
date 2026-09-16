#!/usr/bin/env python3
"""Optional, read-only Claude review dispatch with verifiable local receipts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_output(cwd, *args):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, timeout=20)
    return result.stdout if result.returncode == 0 else None


def source_state(cwd):
    state = {"cwd": str(cwd), "git_head": None}
    try:
        head = git_output(cwd, "rev-parse", "HEAD")
        if head:
            diff = git_output(cwd, "diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--")
            state.update(git_head=head.decode().strip(), tracked_diff_sha256=digest(diff or b""))
    except (OSError, subprocess.TimeoutExpired):
        state["git_state_unavailable"] = True
    # Deliberately do not read arbitrary untracked files or credentials.
    state["scope"] = "git HEAD and tracked diff; prompt and explicit context files separately hashed"
    return state


def preflight(binary):
    executable = shutil.which(binary)
    result = {"provider": "claude", "executable": executable, "available": bool(executable),
              "authenticated": False, "version": None}
    if not executable:
        result["status"] = "unavailable"
        return result
    try:
        version = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15)
        # Version-only output; never print the auth response or identity fields.
        match = re.search(r"\b\d+\.\d+\.\d+\b", version.stdout)
        result["version"] = match.group(0) if match else None
        auth = subprocess.run([executable, "auth", "status", "--json"], capture_output=True,
                              text=True, timeout=15)
        data = json.loads(auth.stdout)
        result["authenticated"] = auth.returncode == 0 and data.get("loggedIn") is True
        result["status"] = "ready" if result["authenticated"] else "unauthenticated"
    except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError):
        result["status"] = "preflight_error"
    return result


def model_matches(requested, served):
    # Alias resolution cannot prove an exact version; record that weaker assurance.
    if requested in ("opus", "sonnet", "haiku", "fable"):
        return bool(re.fullmatch(r"claude-" + requested + r"(?:-[a-zA-Z0-9.]+)+", served))
    return requested == served


def parse_result(path, requested_model):
    models, configured, usage_models, evidence, results = set(), set(), set(), [], []
    try:
        with path.open() as stream:
            for line in stream:
                if not line.strip():
                    continue
                item = json.loads(line)
                if not isinstance(item, dict):
                    raise ValueError("stream event is not an object")
                if item.get("type") == "system" and item.get("subtype") == "init":
                    if isinstance(item.get("model"), str):
                        configured.add(item["model"])
                if item.get("type") == "assistant":
                    model = item.get("message", {}).get("model")
                    if isinstance(model, str) and model:
                        models.add(model)
                        evidence.append({"source": "assistant.message.model", "model": model})
                if item.get("type") == "result":
                    results.append(item)
                    for model in (item.get("modelUsage") or {}):
                        usage_models.add(model)
                        evidence.append({"source": "result.modelUsage", "model": model})
    except (ValueError, OSError, AttributeError, TypeError):
        return {"status": "invalid_output", "reason": "Malformed JSON event stream"}
    record = {"reported_models": sorted(models), "configured_models": sorted(configured),
              "usage_models": sorted(usage_models), "auxiliary_usage_models": sorted(usage_models - models),
              "model_evidence": evidence}
    if len(results) != 1:
        return dict(record, status="invalid_output", reason="Expected exactly one final result")
    result = results[0]
    record["result"] = {"subtype": result.get("subtype"), "is_error": result.get("is_error")}
    record["usage"] = result.get("usage")
    record["model_usage"] = result.get("modelUsage")
    record["session_id"] = result.get("session_id")
    record["total_cost_usd"] = result.get("total_cost_usd")
    if result.get("is_error") is not False or result.get("subtype") != "success":
        return dict(record, status="provider_error", reason="Claude reported an unsuccessful result")
    if not isinstance(result.get("result"), str) or not result["result"].strip():
        return dict(record, status="invalid_output", reason="The final result has no review text")
    record["result"]["text_sha256"] = digest(result["result"].encode())
    if not models:
        return dict(record, status="unverified_model", reason="No assistant response model reported; init and usage alone do not prove the response model")
    if requested_model and any(not model_matches(requested_model, model) for model in models):
        return dict(record, status="model_mismatch", reason="A reported model differs from the explicit request")
    record["model_assurance"] = ("reported-only" if not requested_model else
                                 "alias-family" if requested_model in ("opus", "sonnet", "haiku", "fable") else
                                 "exact-name")
    return dict(record, status="success")


class Cancelled(Exception):
    pass


def cancel(signum, frame):
    raise Cancelled()


def terminate(proc):
    if proc and proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            return proc.communicate(timeout=3)[1] or b""
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            return proc.communicate()[1] or b""
    return b""


def exclusive_artifacts(output, receipt):
    if output.resolve() == receipt.resolve():
        raise ValueError("Output and receipt must be distinct files")
    # No directory creation and no truncation: parents must be selected explicitly.
    out = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        rec = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except BaseException:
        os.close(out)
        output.unlink()
        raise
    return os.fdopen(out, "wb"), os.fdopen(rec, "w")


def run(args):
    output, receipt = Path(args.output).absolute(), Path(args.receipt).absolute()
    try:
        out, rec = exclusive_artifacts(output, receipt)
    except (OSError, ValueError) as exc:
        print("Cannot reserve exclusive artifacts: " + str(exc), file=sys.stderr)
        return 2
    cwd = Path(args.cwd).resolve()
    record = {"schema_version": 1, "provider": "claude", "role": "external-read-only-review",
              "started_at": now(), "status": "runner_error", "process_exit_code": None,
              "requested_model": None, "requested_effort": None, "reported_models": [],
              "evidence_kind": "provider-execution; does not establish test or app verification",
              "source": {"cwd": str(cwd)}}
    proc, stderr = None, b""
    previous = {sig: signal.signal(sig, cancel) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        if not cwd.is_dir():
            raise ValueError("cwd must be an existing directory")
        config_path = Path(args.config) if args.config else cwd / "docs/llm-orchestrator/cadence.json"
        provider_config = {}
        if config_path.is_file():
            config_bytes = config_path.read_bytes()
            provider_config = json.loads(config_bytes).get("codex_providers", {}).get("claude", {})
            record["config"] = {"path": str(config_path.resolve()), "sha256": digest(config_bytes)}
        elif args.config:
            raise ValueError("Explicit provider configuration does not exist")
        model = args.model if args.model is not None else provider_config.get("model", "opus")
        effort = args.effort if args.effort is not None else provider_config.get("effort", "max")
        model = None if model == "default" else model
        effort = None if effort == "default" else effort
        if model is not None and (not isinstance(model, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.\[\]-]*", model)):
            raise ValueError("Invalid configured model")
        if effort not in (None, "low", "medium", "high", "xhigh", "max"):
            raise ValueError("Invalid configured effort")
        record.update(requested_model=model, requested_effort=effort)
        record["source"] = source_state(cwd)
        prompt = sys.stdin.buffer.read() if args.prompt_stdin else Path(args.prompt_file).read_bytes()
        if not prompt.strip():
            raise ValueError("Prompt must not be empty")
        record["prompt_sha256"] = digest(prompt)
        record["context_artifacts"] = []
        for filename in args.context_file:
            path = (cwd / filename).resolve()
            if not path.is_relative_to(cwd) or not path.is_file():
                raise ValueError("Context artifacts must be files inside cwd")
            record["context_artifacts"].append({"path": str(path), "sha256": digest(path.read_bytes())})
        if provider_config.get("enabled", True) is not True:
            record["status"] = "disabled"
        else:
            doctor = preflight(args.claude_bin)
            record["preflight"] = doctor
            if doctor["status"] != "ready":
                record["status"] = doctor["status"]
            else:
                command = [doctor["executable"], "--print", "--verbose", "--output-format", "stream-json",
                           "--safe-mode", "--restricted", "--permission-mode", "plan",
                           "--permission-prompts", "none", "--tools", "Read,Grep,Glob",
                           "--allowedTools", "Read,Grep,Glob", "--disable-slash-commands",
                           "--no-session-persistence", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                           "--no-chrome"]
                if model:
                    command.extend(["--model", model])
                if effort:
                    command.extend(["--effort", effort])
                record["command_argv"] = command
                proc = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=out,
                                        stderr=subprocess.PIPE, start_new_session=True)
                try:
                    _, stderr = proc.communicate(prompt, timeout=args.timeout)
                    record["process_exit_code"] = proc.returncode
                    out.flush()
                    record.update(parse_result(output, model))
                    if proc.returncode != 0:
                        record.update(status="provider_error", reason="Claude exited unsuccessfully")
                except subprocess.TimeoutExpired:
                    stderr = terminate(proc)
                    record["status"] = "timeout"
    except (Cancelled, KeyboardInterrupt):
        # Ignore repeated interrupt signals while preserving the receipt.
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        stderr = terminate(proc)
        record["status"] = "cancelled"
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        record.update(status="runner_error", reason=type(exc).__name__)
        stderr = terminate(proc)
    finally:
        if proc:
            record["process_exit_code"] = proc.poll()
        out.close()
        record["finished_at"] = now()
        record["output"] = {"path": str(output.resolve()), "sha256": digest(output.read_bytes()),
                            "bytes": output.stat().st_size}
        record["stderr"] = {"sha256": digest(stderr), "bytes": len(stderr)}
        # Stderr can contain identity data. Store only its digest, never its content.
        json.dump(record, rec, indent=2, sort_keys=True)
        rec.write("\n")
        rec.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    print(json.dumps({"status": record["status"], "receipt": str(receipt), "output": str(output)}))
    return 0 if record["status"] == "success" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    doctor = commands.add_parser("doctor", help="Report sanitized availability and existing authentication")
    doctor.add_argument("--claude-bin", default="claude")
    dispatch = commands.add_parser("run", help="Run one external review and save a receipt, including dropouts")
    dispatch.add_argument("--cwd", required=True)
    prompt = dispatch.add_mutually_exclusive_group(required=True)
    prompt.add_argument("--prompt-file")
    prompt.add_argument("--prompt-stdin", action="store_true")
    dispatch.add_argument("--output", required=True)
    dispatch.add_argument("--receipt", required=True)
    dispatch.add_argument("--context-file", action="append", default=[])
    dispatch.add_argument("--config")
    dispatch.add_argument("--model", help="Alias or exact model; literal 'default' delegates selection to Claude")
    dispatch.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max", "default"])
    dispatch.add_argument("--claude-bin", default="claude")
    dispatch.add_argument("--timeout", type=float, default=None,
                          help="Optional execution deadline in seconds; no review deadline by default")
    args = parser.parse_args()
    if args.command == "doctor":
        report = preflight(args.claude_bin)
        print(json.dumps(report, indent=2))
        return 0 if report["status"] == "ready" else 1
    if args.timeout is not None and args.timeout <= 0:
        parser.error("timeout must be positive")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
