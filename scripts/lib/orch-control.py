#!/usr/bin/env python3
"""Inspect project policy or launch a configured model without enabling Cadence."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


policy_module = module("orch-policy")


def installation_parity(installed):
    prefixes = ("scripts", "skills", "hooks", "agents", "commands", "templates", "output-styles",
                ".claude-plugin", ".codex-plugin")
    paths = []
    for prefix in prefixes:
        paths.extend(path for path in (ROOT / prefix).rglob("*") if path.is_file()
                     and "__pycache__" not in path.parts and path.suffix != ".pyc")
    different = []
    source_names = {str(path.relative_to(ROOT)) for path in paths}
    installed_names = {str(path.relative_to(installed)) for prefix in prefixes
                       for path in (installed / prefix).rglob("*") if path.is_file()
                       and "__pycache__" not in path.parts and path.suffix != ".pyc"}
    different.extend(sorted(installed_names - source_names))
    for path in paths:
        target = installed / path.relative_to(ROOT)
        if not target.is_file() or target.read_bytes() != path.read_bytes():
            different.append(str(path.relative_to(ROOT)))
    return {"path": str(installed), "status": "different" if different else "byte-parity",
            "compared_files": len(paths), "different": different}


def doctor(policy, installed_root=None):
    catalogs, errors = {}, []
    if policy.enabled:
        for provider in policy.data.get("roles", {}):
            try:
                catalogs[provider] = policy.catalog(provider)[1]
            except policy_module.PolicyError as error:
                errors.append(str(error))
        try:
            policy.validate_launches()
        except policy_module.PolicyError as error:
            if str(error) not in errors:
                errors.append(str(error))
    installs = [Path(installed_root).expanduser().resolve()] if installed_root else []
    if not installed_root:
        for directory in (Path.home() / ".codex/plugins/cache", Path.home() / ".claude/plugins/cache"):
            installs.extend(sorted(directory.glob("llm-orchestrator/llm-orchestrator/*")))
    cadence_path = policy.project / "docs/llm-orchestrator/cadence.json"
    cadence = {"present": cadence_path.is_file(), "enabled": False}
    if cadence_path.is_file():
        try:
            data = json.loads(cadence_path.read_text())
            cadence["enabled"] = isinstance(data, dict) and data.get("enabled") is True
        except (ValueError, OSError):
            cadence["status"] = "malformed"
    head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"], capture_output=True, text=True)
    return {"enabled": policy.enabled, "project": str(policy.project), "project_id": policy.project_id(),
            "config_valid": True, "catalogs": catalogs, "errors": errors, "cadence": cadence,
            "source": {"path": str(ROOT), "revision": head.stdout.strip() if head.returncode == 0 else None,
                       "dirty": bool(dirty.stdout.strip()) if dirty.returncode == 0 else None},
            "installations": [installation_parity(path) for path in installs],
            "installation_status": "inspected" if installs else "unknown: installed copy not located",
            "hooks": {"declarations": [str(path.relative_to(ROOT)) for path in
                                      (ROOT / "hooks/hooks.json", ROOT / ".codex-plugin/plugin.json") if path.is_file()],
                      "observed_trust": "unknown: inspect /hooks in the target fresh host session",
                      "explicit_api_requires_trusted_hook": False},
            "capacity_unit": "managed_outer_cli_process",
            "capacity": policy_module.Capacity(policy.data.get("capacity", {}), policy.project,
                                                "codex", "lead").diagnostics(),
            "uncontrolled": ["native host subagents", "manual CLI launches", "provider/native nested fanout"],
            "governance": "review counts, WIP, final verification and GitHub delivery remain coordinator obligations"}


def review_profiles_missing(policy):
    """Signed-in providers a review may plan a role on that this policy gives no profile for."""
    review = module("orch-review")
    checks = {"claude": review.Review.check_claude, "codex": review.Review.check_codex}
    ready = [name for name in ("claude", "codex") if checks[name]()["ready"]]
    needed = set()
    for path in ("standard", "full"):
        for writer in ("claude", "codex"):
            plan = review.review_plan(path, writer, ready)
            needed |= review.policy_roles(plan) if plan else set()
    missing = set()
    for provider, role in needed:
        try:
            policy.intended(provider, role)
        except policy_module.PolicyError:
            missing.add(provider)
    return sorted(missing)


def launch(args, policy):
    if not policy.enabled:
        raise policy_module.PolicyError("launch needs opt-in .llm-orchestrator.json; existing launch paths remain unchanged")
    settings = policy.resolve(args.provider, args.role)
    policy.capacity(args.provider, args.role)
    review = module("orch-review")
    provider = review.Review.check_codex() if args.provider == "codex" else review.Review.check_claude()
    if not provider["ready"]:
        raise policy_module.PolicyError(f"{args.provider}: {provider['state']}")
    manager = review.resources.Manager(args.state_dir)
    task = manager.start(policy.project, f"configured-{args.role}")
    lease = manager.acquire(task["id"], "configured-cli")
    run_dir = Path(lease["scratch"])
    launch_dir = run_dir / "launch"
    launch_dir.mkdir()
    attempt = {"row": "launch", "run_id": uuid.uuid4().hex, "delivery_id": args.delivery_id,
               "project": str(policy.project), "project_id": policy.project_id(), "date": review.now(),
               "provider": args.provider, "role": args.role, "requested_model": settings["model"],
               "requested_effort": settings["effort"], "policy_settings": settings,
               "status": "dropout", "cost_usd": None, "tokens": None}
    try:
        schema = json.dumps({"type": "object", "properties": {"results": {"type": "array", "items": {"type": "string"}}},
                             "required": ["results"], "additionalProperties": False})
        prompt = args.prompt + "\nReturn your response as a JSON object with a results array of strings."
        if args.provider == "codex":
            attempt.update(review.run_codex(policy.project, prompt, schema, launch_dir, settings["model"],
                                            provider.get("mcp_servers", []), args.role, policy=policy,
                                            project_docs=True))
        else:
            attempt.update(review.run_claude(policy.project, prompt, schema, launch_dir, run_dir,
                                             args.role, policy=policy))
        if (attempt.get("capacity") or {}).get("cleanup_status") == "pending":
            attempt["preserved_task"] = {"id": task["id"], "scratch": str(run_dir),
                                         "reason": "process shutdown unconfirmed; consumer lease retained"}
        output = review.read_json(launch_dir / "output.json")
        review.append_outcome(attempt)
        print(json.dumps({"attempt": attempt, "output": output}))
        return 0 if attempt["status"] == "complete" else 2
    except (policy_module.PolicyError, review.Failure, OSError) as error:
        attempt["reason"] = str(error)
        review.append_outcome(attempt)
        raise
    finally:
        if (attempt.get("capacity") or {}).get("cleanup_status") != "pending":
            manager.release(task["id"], lease["token"], stopped=True)
            manager.finish(task["id"])


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in {"check", "report", "usage"}:
        if argv[0] == "usage":
            argv[0] = "report"
        return module("orch-evidence").main(argv)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "session", "doctor", "launch", "capacity"):
        item = commands.add_parser(name)
        item.add_argument("--project", default=".")
        if name == "capacity":
            item.add_argument("action", choices=["status", "reconcile"])
            item.add_argument("--expect-max-processes", type=int)
            item.add_argument("--expect-external-slots", type=int)
        if name == "doctor":
            item.add_argument("--installed-root")
        if name == "launch":
            item.add_argument("--provider", choices=sorted(policy_module.PROVIDERS), required=True)
            item.add_argument("--role", choices=["lead", "writer", "reviewer", "debugger", "clerical"], required=True)
            item.add_argument("--prompt", required=True)
            item.add_argument("--delivery-id")
            item.add_argument("--state-dir", help="private task-resource state outside the repository")
    args = parser.parse_args(argv)
    try:
        policy = policy_module.Policy(args.project)
        if args.command == "launch":
            return launch(args, policy)
        if args.command == "capacity":
            if not policy.enabled:
                raise policy_module.PolicyError("capacity commands require configured project policy")
            ledger = policy_module.Capacity(policy.data.get("capacity", {}), policy.project, "codex", "lead")
            if args.action == "reconcile":
                if args.expect_max_processes is None or args.expect_external_slots is None:
                    parser.error("capacity reconcile requires both observed --expect-* budget values")
                result = ledger.reconcile(args.expect_max_processes, args.expect_external_slots)
            else:
                result = ledger.diagnostics()
            print(json.dumps(result))
            return 0
        if args.command == "doctor":
            result = doctor(policy, args.installed_root)
            print(json.dumps(result))
            return 2 if result["errors"] else 0
        result = {"enabled": policy.enabled, "project": str(policy.project), "project_id": policy.project_id(),
                  "policy_context": policy.policy_context()}
        if args.command == "validate":
            result["roles"] = policy.validate_launches()
            if policy.enabled:
                result["review_profiles_missing"] = review_profiles_missing(policy)
                result["review_note"] = ("orch-review can plan reviewers, the prover, the refuter and the Claude "
                                         "runner on every installed and signed-in CLI, so each such provider needs a "
                                         "profile for every role it may get, and a catalog, committed at the review's "
                                         "base; otherwise the review stops at preflight. No other model is chosen "
                                         "in its place.")
        else:
            result["coordinator_obligations"] = policy.data.get("project_rules", {})
            result["hook_execution_observed"] = False
        print(json.dumps(result))
        return 0
    except (policy_module.PolicyError, OSError) as error:
        print(f"orch-control: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
