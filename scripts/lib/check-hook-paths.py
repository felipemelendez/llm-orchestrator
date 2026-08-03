#!/usr/bin/env python3
"""Verify every type:"command" hook in a hooks.json resolves to a real script.

Two modes:

  check-hook-paths.py <hooks.json>
      Installed mode. Every command must contain at least one script path that
      is absolute and exists on disk, and no unexpanded variable text of any
      spelling (${CLAUDE_PLUGIN_ROOT}, $CLAUDE_PLUGIN_ROOT, or anything else
      with a '$'). This is the positive property install.sh --copy must
      deliver; asserting the absence of one spelling of a placeholder is how
      the rewrite shipped broken for its whole life.

  check-hook-paths.py <hooks.json> --root <dir>
      Source-checkout mode (used by install.sh --check). Plugin-root
      placeholders are resolved against <dir> first; every resolved script
      must exist under it.

Prints one line per problem; exits 0 only when every command hook resolves.
type:"prompt" hooks carry no path and are skipped.
"""
import json
import os
import shlex
import sys


def main(argv):
    if len(argv) < 2:
        print("usage: check-hook-paths.py <hooks.json> [--root <dir>]", file=sys.stderr)
        return 2
    path = argv[1]
    root = None
    if len(argv) >= 4 and argv[2] == "--root":
        root = argv[3]

    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as e:  # unparseable JSON is a failure, not a skip
        print("unparseable hooks.json (%s): %s" % (path, e))
        return 1

    problems = []
    n_commands = 0
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        print("hooks.json has no top-level 'hooks' object")
        return 1

    for event, matchers in hooks.items():
        if not isinstance(matchers, list):
            problems.append("%s: matcher list is not a list" % event)
            continue
        for m in matchers:
            for h in m.get("hooks", []):
                if h.get("type") != "command":
                    continue
                n_commands += 1
                cmd = h.get("command", "")
                if root is not None:
                    cmd = cmd.replace("${CLAUDE_PLUGIN_ROOT}", root)
                    cmd = cmd.replace("$CLAUDE_PLUGIN_ROOT", root)
                if "$" in cmd:
                    problems.append("%s: unexpanded variable text in: %s" % (event, cmd))
                    continue
                try:
                    tokens = shlex.split(cmd)
                except ValueError as e:
                    problems.append("%s: unparseable command (%s): %s" % (event, e, cmd))
                    continue
                scripts = [t for t in tokens if t.endswith(".sh")]
                if not scripts:
                    problems.append("%s: no script path in command: %s" % (event, cmd))
                    continue
                for t in scripts:
                    if root is None and not os.path.isabs(t):
                        problems.append("%s: script path not absolute: %s" % (event, t))
                    elif not os.path.isfile(t):
                        problems.append("%s: script does not exist: %s" % (event, t))

    if n_commands == 0:
        problems.append("no command hooks found in %s" % path)

    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
