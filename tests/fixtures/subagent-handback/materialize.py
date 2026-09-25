#!/usr/bin/env python3
"""Write a captured SubagentStop payload and its subagent transcript into a
temporary directory with real paths, and print the payload JSON on stdout.

Usage: materialize.py <auto|default> <out-dir> [--agent-type T] [--report TEXT]
                      [--no-agent-path] [--repeat-tool N] [--handback-error]
                      [--handback-input JSON] [--append JSON]...

The fixtures come from Claude Code 2.1.282 runs dispatching
llm-orchestrator:orch-explorer, in auto mode (report sent through
SubagentHandback) and in default mode (report is the final text).
"""

import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["auto", "default"])
parser.add_argument("out")
parser.add_argument("--agent-type")
parser.add_argument("--report", help="replace the report the agent sent")
parser.add_argument("--no-agent-path", action="store_true",
                    help="drop agent_transcript_path, as older harnesses did")
parser.add_argument("--repeat-tool", type=int, default=0,
                    help="repeat the first tool call N extra times in a row")
parser.add_argument("--handback-error", action="store_true",
                    help="mark the SubagentHandback tool result as an error")
parser.add_argument("--handback-input",
                    help="replace the SubagentHandback input with this JSON value")
parser.add_argument("--append", action="append", default=[],
                    help="append this raw JSON line to the subagent transcript")
args = parser.parse_args()

projects = os.path.join(args.out, "projects")
repo = os.path.join(args.out, "repo")
os.makedirs(repo, exist_ok=True)


def fill(text):
    return text.replace("__PROJECTS__", projects).replace("__REPO__", repo)


with open(os.path.join(HERE, "%s-subagent-stop.json" % args.mode)) as f:
    payload = json.loads(fill(f.read()))
with open(os.path.join(HERE, "%s-agent.jsonl" % args.mode)) as f:
    entries = [json.loads(fill(line)) for line in f if line.strip()]

handback_id = None
for entry in entries:
    content = entry["message"]["content"]
    if not isinstance(content, list):
        continue
    for block in content:
        if args.report is not None:
            if block.get("type") == "tool_use" and block.get("name") == "SubagentHandback":
                block["input"]["message"] = args.report
            elif args.mode == "default" and block.get("type") == "text":
                block["text"] = args.report
        if block.get("type") == "tool_use" and block.get("name") == "SubagentHandback":
            if args.handback_input is not None:
                block["input"] = json.loads(args.handback_input)
            handback_id = block["id"]
        if (args.handback_error and block.get("type") == "tool_result"
                and block.get("tool_use_id") == handback_id):
            block["is_error"] = True
if args.report is not None and args.mode == "default":
    payload["last_assistant_message"] = args.report

if args.repeat_tool:
    first = next(i for i, e in enumerate(entries)
                 if e["type"] == "assistant" and e["message"]["content"][0]["type"] == "tool_use")
    entries[first + 1:first + 1] = [entries[first]] * args.repeat_tool

if args.agent_type:
    payload["agent_type"] = args.agent_type

agent_path = payload["agent_transcript_path"]
os.makedirs(os.path.dirname(agent_path), exist_ok=True)
with open(payload["transcript_path"], "w") as f:
    f.write("")
with open(agent_path, "w") as f:
    f.write("".join(json.dumps(e) + "\n" for e in entries))
    f.write("".join(line + "\n" for line in args.append))
if args.no_agent_path:
    del payload["agent_transcript_path"]

print(json.dumps(payload))
