#!/usr/bin/env python3
"""Find or remove the hook entries an earlier `install.sh --codex` wrote.

Usage: codex-old-hooks.py count|remove <hooks.json>

`count` prints how many entries are this plugin's; `remove` deletes them,
keeps the first backup of the file as it was, and prints what it did. Exit 2
means the file is not a hooks file this script can read, and nothing was
written.
"""
import json
import os
import re
import shlex
import sys
import tempfile

# The scripts earlier releases registered in ~/.codex/hooks.json, recognised
# by the script the entry runs, by its name AND by where it lives (the
# plugin's hooks are under scripts/hooks). A person's own
# my-hooks/codex-verify-gate.sh, or a hook whose PATH merely contains the
# plugin's name, is theirs.
OWN = {"codex-cadence-adapter.sh", "codex-verify-gate.sh", "orch-task-cleanup.sh",
       "codex-evidence.py", "codex-verify.py"}
INTERPRETERS = {"bash", "sh", "zsh", "python", "python3", "env"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def invoked(words, depth=0):
    """The script a hook command runs: the first word that is neither an
    interpreter (`bash /path/x.sh`, `env LANG=C python3 x.py`) nor a
    VAR=value assignment. `bash -c '<snippet>'` runs the snippet's own first
    word. An argument later on the line is never the script."""
    words = [w for w in words if not ASSIGNMENT.match(w)]
    for index, word in enumerate(words[:3]):
        base = word.rsplit("/", 1)[-1]
        if base == "-c":
            if depth or index + 1 >= len(words):
                return None
            try:
                inner = shlex.split(words[index + 1])
            except ValueError:
                return None
            return invoked(inner, depth + 1)
        if base in INTERPRETERS or base.startswith("python3."):
            continue
        return word
    return None


def ours(entry):
    if not isinstance(entry, dict):
        return False
    command = entry.get("command", "")
    if not isinstance(command, str):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    script = invoked(words)
    if not script:
        return False
    directory, _, base = script.rpartition("/")
    return base in OWN and (directory == "scripts/hooks" or directory.endswith("/scripts/hooks"))


def load(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict) or not all(isinstance(v, list) for v in hooks.values()):
        return None
    return data


def strip(hooks):
    """Remove our entries in place; return how many were removed."""
    removed = 0
    for event, groups in list(hooks.items()):
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            keep = [h for h in group["hooks"] if not ours(h)]
            removed += len(group["hooks"]) - len(keep)
            if len(keep) == len(group["hooks"]):
                kept.append(group)
            elif keep:
                kept.append(dict(group, hooks=keep))
        if kept or not groups:
            hooks[event] = kept
        else:
            del hooks[event]
    return removed


def exclusive(name):
    # O_EXCL never follows a link someone planted under this name.
    return os.fdopen(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644), "w")


def main():
    mode, path = sys.argv[1:3]
    data = load(path)
    if data is None:
        return 2
    removed = strip(data.get("hooks", {}))
    if mode == "count":
        print(removed)
        return 0
    if not removed:
        return 0
    with open(path) as fh:
        old = fh.read()
    # The backup is the state BEFORE this installer ever touched the file.
    bak = path + ".bak"
    n = 1
    while os.path.lexists(bak):
        bak = "%s.bak.%d" % (path, n)
        n += 1
    with exclusive(bak) as fh:
        fh.write(old)
    fd, tmp = tempfile.mkstemp(prefix=".hooks.json.orch-merge.", dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "w") as fh:
        fh.write(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    print("removed %d hook entries an earlier --codex wrote from %s (backup %s)" % (removed, path, bak))
    return 0


if __name__ == "__main__":
    sys.exit(main())
