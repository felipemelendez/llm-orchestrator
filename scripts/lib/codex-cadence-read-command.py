#!/usr/bin/env python3
"""Recognize trusted entry points that only read cadence's protected inputs.

This is an allowlist, not a shell interpreter. Anything with shell composition
falls through to the existing guard. The recognized command is never executed.
"""

import os
from pathlib import Path
import shlex
import sys


def allowed(command):
    command = command.strip()
    if not command or any(c in command for c in "\n\r;|&<>`$(){}"):
        return False
    try:
        args = shlex.split(command)
    except ValueError:
        return False
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
