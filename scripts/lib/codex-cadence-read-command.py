#!/usr/bin/env python3
"""Recognize trusted entry points that only read cadence's protected inputs.

This is an allowlist, not a shell interpreter. Anything with shell composition
falls through to the existing guard. The recognized command is never executed.
"""

import os
import json
from pathlib import Path
import shlex
import sys


def provider_read(args):
    """Only the trusted provider may read locked inputs; artifacts stay outside them."""
    if not args or args.pop(0) != "run":
        return False
    values = {}
    flags = {"--cwd", "--config", "--prompt-file", "--output", "--receipt",
             "--context-file", "--model", "--effort", "--timeout"}
    while args:
        option = args.pop(0)
        if option == "--prompt-stdin":
            if option in values:
                return False
            values[option] = True
            continue
        if option not in flags or not args or args[0].startswith("-"):
            return False
        if option in values and option != "--context-file":
            return False
        values[option] = args.pop(0)
    if not all(k in values for k in ("--cwd", "--output", "--receipt")):
        return False
    if ("--prompt-file" in values) == ("--prompt-stdin" in values):
        return False
    root = Path(os.environ.get("CODEX_PROJECT_DIR", os.getcwd())).resolve()
    protected = ["docs/llm-orchestrator/LAWS.md", "docs/llm-orchestrator/cadence.json",
                 "docs/llm-orchestrator/LOCK.sha256", ".claude/settings.json",
                 ".githooks/commit-msg", ".githooks/orch-cadence-check.sh"]
    try:
        config = json.loads((root / protected[1]).read_text())
        protected.extend(config.get("lock_extra", []))
        targets = {(root / p).resolve() for p in protected}
    except (OSError, ValueError, TypeError):
        return False
    for option in ("--output", "--receipt"):
        path = Path(values[option])
        if (not path.is_absolute() or path.resolve() in targets
                or path.name.lower() in {"laws.md", "cadence.json", "lock.sha256", "orch-cadence-check.sh"}
                or os.path.lexists(path)):
            return False
    return values["--output"] != values["--receipt"]


def allowed(command):
    command = command.strip()
    if not command or any(c in command for c in "\n\r;|&<>`$(){}"):
        return False
    try:
        args = shlex.split(command)
    except ValueError:
        return False
    python = {"python3", "/usr/bin/python3", sys.executable}
    provider = Path(__file__).resolve().parents[1] / "providers/claude-review.py"
    if len(args) >= 2 and args[0] in python and Path(args[1]).resolve() == provider.resolve():
        return provider.is_file() and provider_read(args[2:])
    if args and args[0] in ("bash", "/bin/bash", "/usr/bin/bash"):
        args = args[1:]
    if not args:
        return False
    invoked = Path(os.path.expanduser(args[0])).resolve()
    roots = [Path(__file__).resolve().parents[2] / "skills/cadence/scripts"]
    names = ("orch-cadence-check.sh", "orch-cadence-gate.sh")
    candidates = {str((root / name).resolve()): name
                  for root in roots for name in names if (root / name).is_file()}
    name = candidates.get(str(invoked))
    if not name:
        return False
    args = args[1:]
    if name == "orch-cadence-gate.sh":
        if len(args) < 2 or any(a.startswith("-") for a in args[:2]):
            return False
        args = args[2:]
        modes = 1
        flags = {"--no-typecheck": 0, "--families": 1, "--config": 1}
    else:
        modes = 0
        flags = {"--root": 1, "--base": 1, "--verdict": 0,
                 "--version": 0, "--landing": 1, "--audit": 1}
    while args:
        option = args.pop(0)
        if option not in flags:
            return False
        if option in ("--verdict", "--version", "--landing", "--audit"):
            modes += 1
        if flags[option]:
            if not args or args[0].startswith("-"):
                return False
            args.pop(0)
    return modes == 1


if __name__ == "__main__":
    sys.exit(0 if len(sys.argv) == 2 and allowed(sys.argv[1]) else 1)
