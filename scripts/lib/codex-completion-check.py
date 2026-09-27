#!/usr/bin/env python3
"""Codex's completion check: the same one question, asked of Codex's own log.

Reads a Codex Stop payload on stdin. The reply says Verification: PASS; did a
command that runs a check (by the lists in orch-completion-check.py), or that
starts with the project's runner.test_cmd, run in this turn and finish with
exit code 0? If so, or if the
reply says anything else, nothing is printed. If not, the agent is sent back to
work once with the same note the Claude side uses, plus a line asking it to
repeat its full answer, and nothing is shown to the person. Always exits 0.

Why the agent and not the person: Codex's Stop hook has two outputs and no
third. `systemMessage` is a warning in the person's UI, which is an interruption
about an agent's problem. `decision: block` with a `reason` is not a rejection:
Codex keeps the turn going and gives the agent the reason as its next prompt
(learn.chatgpt.com/docs/hooks). On that continuation `stop_hook_active` is true
and this check stays quiet, so it fires at most once per turn.

What it reads: only records Codex itself writes when a command finishes. There
are two kinds (docs/specs/codex-completion-check.md says which builds write
which):
- `event_msg` / `item_completed` with an item of type `CommandExecution`: the
  command as an argv list, the exit code and the turn. Written for every
  command, including those a code-mode `exec` script runs, when the thread's
  history mode is paginated (Codex 0.147.0 and later).
- a direct `exec_command` or `write_stdin` function call and its output, whose
  header (above the `Output:` line) says `Process exited with code N`. Written
  in every history mode; the only record in legacy-history threads.
Nothing the agent wrote is read beyond the command it asked for: not the
JavaScript it sent to the exec tool, not the text it chose to print from a
result, not the program's output below the header. An earlier version parsed
those and every one of its false passes came from there. In a legacy-history
thread a code-mode `exec` script's commands leave no record at all, so a turn
with such a script, in a log with no `CommandExecution` record, is not judged.
The recorded command is judged by orch-completion-check.py's word rules, its
limits (`cmd &`, `|| true`, `false && cmd`) included.

The label, the fence rule, the command rules and the note come from
orch-completion-check.py, so both harnesses say the same thing for the same
reason.
"""
import importlib.util
import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTINUE = ("Your reply to this becomes the final answer, so repeat your full answer "
            "with the Verification line updated to match what you ran.")


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
        # A raw argv runs one program; quoting keeps each argument one word,
        # so `-m "Fix gate (pytest)"` is data to that program.
        return shlex.join(value)
    return None


def command_records(entries):
    """(index, turn_id, command text, exit code) for every `CommandExecution`
    record. A record missing any of those is not a record."""
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


EXIT_LINE = re.compile(r"Process exited with code (-?[0-9]+)")
RUNNING_LINE = re.compile(r"Process running with session ID ([0-9]+)")
OTHER_HEADER_LINE = re.compile(r"(Chunk ID|Wall time|Original token count): .*")


def exec_header(output):
    """(exit code, running session id) from the header Codex writes above an
    exec_command or write_stdin result. Only the lines above `Output:` are
    read; below it is the program's own output. Anything else is (None, None)."""
    if not isinstance(output, str):
        return None, None
    code = session = None
    for line in output.split("\n"):
        if line == "Output:":
            return code, session
        exited = EXIT_LINE.fullmatch(line)
        running = RUNNING_LINE.fullmatch(line)
        if exited:
            code = int(exited.group(1))
        elif running:
            session = running.group(1)
        elif not OTHER_HEADER_LINE.fullmatch(line):
            return None, None
    return None, None


def turn_of(payload):
    meta = payload.get("internal_chat_message_metadata_passthrough")
    return meta.get("turn_id") if isinstance(meta, dict) else None


def exec_call_records(entries):
    """(index, turn_id, command text, exit code) for every direct exec_command
    call whose output header says it exited, or whose write_stdin poll says so.
    The turn is the one the finishing call was made in."""
    calls = {}      # call_id -> (turn_id, command text or None, polled session or None)
    sessions = {}   # running session id -> command text
    out = []
    for index, entry in enumerate(entries):
        payload = entry.get("payload")
        if entry.get("type") != "response_item" or not isinstance(payload, dict):
            continue
        if payload.get("type") == "function_call":
            name = payload.get("name")
            if name not in ("exec_command", "write_stdin") or payload.get("namespace"):
                continue    # a namespaced tool is an MCP or plugin tool, not Codex's own
            try:
                arguments = json.loads(payload.get("arguments") or "")
            except (TypeError, ValueError):
                continue
            if not isinstance(arguments, dict):
                continue
            command = arguments.get("cmd") if name == "exec_command" else None
            session = arguments.get("session_id") if name == "write_stdin" else None
            if isinstance(command, str) or (isinstance(session, int) and not isinstance(session, bool)):
                calls[payload.get("call_id")] = (turn_of(payload), command, None if session is None else str(session))
        elif payload.get("type") == "function_call_output" and payload.get("call_id") in calls:
            turn_id, command, polled = calls.pop(payload.get("call_id"))
            if command is None:
                command = sessions.get(polled)
            code, running = exec_header(payload.get("output"))
            if command is None:
                continue
            if running is not None and code is None:
                sessions[running] = command
            elif code is not None:
                out.append((index, turn_id, command, code))
    return out


def code_mode_calls(entries):
    """(index, turn_id) of every code-mode `exec` script the agent sent."""
    out = []
    for index, entry in enumerate(entries):
        payload = entry.get("payload")
        if (entry.get("type") == "response_item" and isinstance(payload, dict)
                and payload.get("type") == "custom_tool_call" and payload.get("name") == "exec"):
            out.append((index, turn_of(payload)))
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

    # The project: the payload's cwd, else CODEX_PROJECT_DIR, else where the hook runs.
    cwd = payload.get("cwd")
    project = cwd if isinstance(cwd, str) and cwd else os.environ.get("CODEX_PROJECT_DIR") or os.getcwd()
    test_cmd = shared_check.configured_test_cmd(project)
    turn_id = payload.get("turn_id")
    recorded = command_records(entries)
    if not recorded and this_turn(entries, code_mode_calls(entries), turn_id):
        # A legacy-history thread: this turn's code-mode commands left no
        # record, so whether a check ran cannot be read. Say nothing.
        return 0
    found = recorded + exec_call_records(entries)
    for _, _, command, code in this_turn(entries, found, turn_id):
        if code == 0 and shared_check.ran_a_check(command, test_cmd):
            return 0

    if os.environ.get("ORCH_HOOK_DRY_RUN") == "1":
        print("orch-dry-run[codex-verify-gate]: would send the agent back once - "
              + shared_check.NOTE, file=sys.stderr)
        return 0
    # Codex's only route to the agent. It is a continuation, not a rejection,
    # and stop_hook_active makes it a single one. The reply to it becomes the
    # turn's final answer, so the agent is told to repeat that answer in full.
    print(json.dumps({"decision": "block", "reason": shared_check.NOTE + " " + CONTINUE}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)     # a malformed log must never cost the turn
