#!/usr/bin/env python3
"""The report a finished subagent sent its caller, from a SubagentStop payload.

In auto mode a subagent sends its report as the SubagentHandback tool's
`message`, and last_assistant_message holds only its closing text ("Report
delivered to caller." in a captured payload). So the last SubagentHandback
call in the subagent's own transcript wins, unless its tool result was an
error. A later prompt from a person (a resumed agent) discards it; entries the
harness injects (isMeta, tool results, <task-notification> and similar tagged
text) do not. Without one, last_assistant_message is the report.

Run as `orch-subagent-report.py <payload_file>`, it prints the report behind a
one-character sentinel: "1" means a report source existed (so an empty report
is a real observation), "0" means an old harness sent neither source.
orch_subagent_report in orch-protocol.sh calls it this way;
orch-completion-check.py imports subagent_report.
"""

import json
import os
import sys

# Tags the harness puts at the start of text it injects; the same list as
# MACHINE in orch-completion-check.py.
MACHINE = ("<task-notification>", "<local-command-", "<bash-", "<command-name>", "<system-reminder>")


def person_prompt(obj, content):
    """True when a user entry is a prompt typed by a person or a caller."""
    if obj.get("isMeta"):
        return False
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return False
        texts = [b.get("text") or "" for b in content
                 if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return False
    text = "".join(texts).lstrip()
    return bool(text) and not text.startswith(MACHINE)


def subagent_report(data):
    """Returns the report for a decoded payload, or None when it has no source."""
    if not isinstance(data, dict):
        return None
    path = data.get("agent_transcript_path") or ""
    main = data.get("transcript_path") or ""
    if not isinstance(path, str) or not isinstance(main, str):
        path, main = "", ""
    if not path and main.endswith(".jsonl") and data.get("agent_id"):
        path = "%s/subagents/agent-%s.jsonl" % (main[:-len(".jsonl")], data["agent_id"])
    report = None   # the last handback not answered by an error
    pending = {}    # tool_use id -> (message, report before that call)
    if path and os.path.isfile(path):
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(obj, dict) or not isinstance(obj.get("message"), dict):
                        continue
                    content = obj["message"].get("content")
                    if obj.get("type") == "user":
                        if person_prompt(obj, content):
                            report, pending = None, {}
                            continue
                        for b in content if isinstance(content, list) else []:
                            if (isinstance(b, dict) and b.get("type") == "tool_result"
                                    and b.get("is_error") and b.get("tool_use_id") in pending):
                                report = pending.pop(b["tool_use_id"])[1]
                    elif obj.get("type") == "assistant" and isinstance(content, list):
                        for b in content:
                            if not (isinstance(b, dict) and b.get("type") == "tool_use"
                                    and b.get("name") == "SubagentHandback"):
                                continue
                            inp = b.get("input")
                            if isinstance(inp, dict) and isinstance(inp.get("message"), str):
                                pending[b.get("id")] = (inp["message"], report)
                                report = inp["message"]
        except OSError:
            report = None
    if report is not None:
        return report
    if "last_assistant_message" in data:
        lam = data.get("last_assistant_message")
        return lam if isinstance(lam, str) else ""
    return None


def main():
    try:
        with open(sys.argv[1]) as f:
            data = json.load(f)
    except Exception:
        data = None
    report = subagent_report(data)
    sys.stdout.write("0" if report is None else "1" + report)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.stdout.write("0")
