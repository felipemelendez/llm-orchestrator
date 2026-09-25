#!/usr/bin/env python3
"""Print the hooks and cadence skills a Codex app server lists for one folder.

Usage: codex-app-server-list.py <codex binary> <cwd>

One line per hook: `hook <event> <matcher> <source> <script>`, then one line
per cadence skill: `skill <name> <path>`. Runs `codex app-server` with the
caller's CODEX_HOME and makes no model call.
"""
import json
import subprocess
import sys
import threading

codex, cwd = sys.argv[1:3]
server = subprocess.Popen([codex, "app-server"], cwd=cwd, text=True, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
timer = threading.Timer(60, server.kill)
timer.start()


def call(number, method, params):
    server.stdin.write(json.dumps({"id": number, "method": method, "params": params}) + "\n")
    server.stdin.flush()
    for line in server.stdout:
        message = json.loads(line)
        if message.get("id") == number:
            if "error" in message:
                sys.exit("%s failed: %s" % (method, message["error"]))
            return message["result"]
    sys.exit("the app server stopped before answering %s" % method)


try:
    call(1, "initialize", {"clientInfo": {"name": "llm-orchestrator-tests", "version": "0"}})
    server.stdin.write(json.dumps({"method": "initialized"}) + "\n")
    hooks = call(2, "hooks/list", {"cwds": [cwd]})
    skills = call(3, "skills/list", {"cwds": [cwd], "forceReload": True})
finally:
    timer.cancel()
    server.kill()

for entry in hooks["data"]:
    for hook in entry["hooks"]:
        script = hook.get("command", "").strip().strip('"').rsplit("/", 1)[-1]
        print("hook", hook["eventName"], hook.get("matcher"), hook["source"], script)
    for error in entry.get("errors", []):
        print("hook-error", error.get("path"), error.get("message"))
for entry in skills["data"]:
    for skill in entry["skills"]:
        if skill["name"].rsplit(":", 1)[-1] == "cadence":
            print("skill", skill["name"], skill["path"])
