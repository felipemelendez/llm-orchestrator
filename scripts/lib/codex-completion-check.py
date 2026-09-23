#!/usr/bin/env python3
"""Codex's completion check: the same one question, asked of Codex's own log.

Reads a Codex Stop payload on stdin. The reply says Verification: PASS; did a
command matching the shared check pattern (ORCH_SIG_VERIFY_CMD, from
orch-signals.sh) run in this turn and finish with exit code 0? If so, or if the
reply says anything else, nothing is printed. If not, the agent is sent back to
work once with the same note the Claude side uses, and nothing is shown to the
person. Always exits 0.

Why the agent and not the person: Codex's Stop hook has two outputs and no
third. `systemMessage` is a warning in the person's UI, which is an interruption
about an agent's problem. `decision: block` with a `reason` is not a rejection:
Codex keeps the turn going and gives the agent the reason as its next prompt
(learn.chatgpt.com/docs/hooks). On that continuation `stop_hook_active` is true
and this check stays quiet, so it fires at most once per turn.

What it reads: only the records Codex itself writes for every command it runs,
`event_msg` / `item_completed` with an item of type `CommandExecution`. Each
carries the exact command (as an argv list), the exit code, and the turn it
belongs to. Nothing the agent wrote is read: not the JavaScript it sent to the
exec tool, not the text it chose to print from a result. An earlier version
parsed those and every one of its false passes came from there. The recorded
command's text is judged the plain way orch-completion-check.py documents,
its limits (`cmd &`, heredoc bodies, `|| true`, quoted text) included.

The label, the fence rule, the command pattern and the note come from
orch-completion-check.py, so both harnesses say the same thing for the same
reason.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def shared():
    spec = importlib.util.spec_from_file_location(
        "orch_completion_check", os.path.join(HERE, "orch-completion-check.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def command_text(value):
    """The shell text of a recorded command. Codex records an argv list;
    `["/bin/zsh", "-lc", "npm test"]` is the script inside, not the shell."""
    if isinstance(value, list) and value and all(isinstance(x, str) for x in value):
        shell = value[0].rsplit("/", 1)[-1]
        if len(value) >= 3 and shell in ("bash", "sh", "zsh", "dash") and value[1] in ("-c", "-lc", "-ic", "-lic"):
            return value[2]
        # A raw argv runs one program; an argument holding shell punctuation
        # is data to that program, not a second command.
        if any(ch in arg for arg in value for ch in ";|&\n"):
            return None
        return " ".join(value)
    return None


def records(entries):
    """(index, turn_id, command text, exit code) for every command Codex
    recorded as finished. A record missing any of those is not a record."""
    out = []
    for index, entry in enumerate(entries):
        if entry.get("type") != "event_msg":
            continue
        payload = entry.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "item_completed":
            continue
        item = payload.get("item")
        if not isinstance(item, dict) or item.get("type") != "CommandExecution":
            continue
        command = command_text(item.get("command"))
        code = item.get("exit_code")
        if command is None or isinstance(code, bool) or not isinstance(code, int):
            continue
        # Codex writes status "completed" for exit 0 and "failed" otherwise; a
        # record that disagrees with itself is not a pass.
        if code == 0 and item.get("status") != "completed":
            code = 1
        out.append((index, payload.get("turn_id"), command, code))
    return out


def this_turn(entries, found, turn_id):
    """The records of this turn. Each record names its turn; the payload's
    turn_id selects them. When no record names that turn, the turn is the
    slice after the last marker where the turn_id changed."""
    if turn_id and any(r[1] == turn_id for r in found):
        return [r for r in found if r[1] == turn_id]
    start = 0
    marked = None
    for index, entry in enumerate(entries):
        payload = entry.get("payload")
        if not isinstance(payload, dict) or not payload.get("turn_id"):
            continue
        if entry.get("type") == "turn_context" or (
                entry.get("type") == "event_msg" and payload.get("type") == "task_started"):
            # A turn starts where the turn_id changes. After a compaction Codex
            # re-emits the same turn's marker mid-turn; that is not a new turn.
            if payload["turn_id"] != marked:
                start = index
                marked = payload["turn_id"]
    # A record after the marker that names ANOTHER turn belongs to that turn.
    return [r for r in found if r[0] >= start and r[1] in (None, marked)]


def main():
    shared_check = shared()
    if not shared_check.RUNS or "[:" in shared_check.RUNS + shared_check.NONRUN:
        return 0            # no usable shared pattern: say nothing rather than guess

    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or shared_check.active(payload):
        return 0            # the continuation this check asked for: never twice

    message = payload.get("last_assistant_message")
    if not isinstance(message, str):
        return 0
    found = shared_check.LABEL.findall(shared_check.FENCE.sub("", message))
    if not found or found[-1].strip().upper() != "PASS":
        return 0

    transcript = payload.get("transcript_path")
    if not isinstance(transcript, str) or not os.path.isfile(transcript):
        return 0

    entries = []
    with open(transcript, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)

    for _, _, command, code in this_turn(entries, records(entries), payload.get("turn_id")):
        if code == 0 and shared_check.ran_a_check(command):
            return 0

    if os.environ.get("ORCH_HOOK_DRY_RUN") == "1":
        print("orch-dry-run[codex-verify-gate]: would send the agent back once - "
              + shared_check.NOTE, file=sys.stderr)
        return 0
    # Codex's only route to the agent. It is a continuation, not a rejection,
    # and stop_hook_active makes it a single one.
    print(json.dumps({"decision": "block", "reason": shared_check.NOTE}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)     # a malformed log must never cost the turn
