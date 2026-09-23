#!/usr/bin/env python3
"""Did a check actually run and pass this turn?

Reads a Stop / SubagentStop payload on stdin. Prints one note, or nothing.
Always exits 0: this warns, it never blocks. See orch-verify-gate.sh for why.

It reads what the harness recorded, never the command's text cleverly. A
command counts when the harness wrote a finished, non-error result for it (on
Codex: its own record, exit code 0) and the command's text, split at `;`, `&`,
`|` and newlines, has a segment that matches the shared check pattern. On
Claude Code a Bash call made with run_in_background, or whose result is the
harness's launch acknowledgement ("Command running in background with ID:"),
is a launch, not a finish.

Limits, by construction, the same on both harnesses: `npm test &` (the shell
reports 0 before the check has finished), a check named only inside a heredoc
body or a quoted string (`printf 'npm test'`), and `npm test || true` are all
accepted. Those are disguises. The laws leave honesty to the agent: this check
catches the careless false claim, not the deliberate one. Earlier versions
tried to read shell syntax for them (a tokenizer, heredoc and background rules)
and every rule mis-judged an honest command somewhere else: `2>&1`, a
multi-line quoted argument, a here-string. Shell syntax has no bottom. Do not
add those rules back; a note that is wrong gets ignored, which is worse than
no note.

What it does NOT catch, on purpose: a green run that tested nothing, a suite
that does not cover the change, and anything deliberately dressed up to look
like a pass. Watching commands cannot catch those.
"""
import json
import os
import re
import sys

# Which commands count as a check is described once, in orch-signals.sh. The
# shell writes POSIX classes; Python spells them differently.
RUNS = os.environ.get("ORCH_VERIFY_CMD_RE") or ""
NONRUN = os.environ.get("ORCH_VERIFY_NONRUN_RE") or ""
for _posix, _py in ((r"[[:space:]]", r"\s"), (r"[[:alnum:]]", r"[0-9A-Za-z]")):
    RUNS, NONRUN = RUNS.replace(_posix, _py), NONRUN.replace(_posix, _py)

LABEL = re.compile(r"(?im)^[ \t]*(?:[-*+][ \t]*)?(?:#{1,6}[ \t]*)?[*_]{0,3}Verification[*_]{0,3}:"
                   r"[ \t]*[*_]{0,3}[ \t]*(PASS|PENDING|BLOCKED|NOT APPLICABLE)")
# [ \t]*, not \s*: with \s* a run of blank lines is re-scanned from every
# line start, and a reply padded with them takes the hook past its time limit.
FENCE = re.compile(r"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[^\n]*")
# `CI=1 pytest`, `timeout 300 pytest`, `cd repo && pytest` — the tool is still
# the tool. Stripped before matching so a prefix does not hide a real run.
PREFIX = re.compile(r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+|time\s+|env\s+|timeout\s+\S+\s+|cd\s+\S+\s+)*")
# A user entry the person did not type: an agent returning, a slash command, a
# compaction summary. Counting one as the turn start throws away real checks.
MACHINE = ("<task-notification>", "<local-command-", "<bash-", "<command-name>", "<system-reminder>")
# What Claude Code writes as the result of a command it decided to background
# itself. The command was started; nothing says it finished.
LAUNCH = "Command running in background with ID:"

NOTE = ("Cadence: this reply says Verification: PASS, but no check ran and passed in this turn. "
        "Run the project's test command as one plain foreground command, or say PENDING instead.")


def blocks(entry):
    content = (entry.get("message") or {}).get("content")
    return content if isinstance(content, list) else []


def is_person(entry):
    if entry.get("type") != "user" or entry.get("isSidechain") or entry.get("isMeta"):
        return False
    if entry.get("isCompactSummary"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip()) and not content.lstrip().startswith(MACHINE)
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def result_text(block):
    """The text of a tool_result: a string, or text blocks."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(b.get("text", "")) for b in content if isinstance(b, dict))
    return ""


def finished_ok(block):
    """A tool_result the harness wrote for a command that ran to the end
    without error. A launch acknowledgement is not that."""
    if not isinstance(block, dict) or block.get("type") != "tool_result" or block.get("is_error"):
        return False
    return not result_text(block).lstrip().startswith(LAUNCH)


def ran_a_check(command):
    """Any segment of the command that runs a check and is not a --version."""
    for segment in re.split(r"[;&|\n]+", command):
        segment = PREFIX.sub("", segment)
        if re.search(RUNS, segment, re.M) and not (NONRUN and re.search(NONRUN, segment, re.M)):
            return True
    return False


def active(payload):
    """stop_hook_active as Codex and Claude Code send it: a boolean. A string
    "false" is not true."""
    value = payload.get("stop_hook_active")
    return value is True or (isinstance(value, str) and value.strip().lower() == "true")


def main():
    if not RUNS:
        return 0            # no shared pattern: say nothing rather than guess
    if "[:" in RUNS + NONRUN:
        return 0            # a POSIX class survived conversion; it would match nothing

    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        return 0
    if active(payload):
        return 0            # already spoke this turn; do not nag on every re-entry

    # A label inside a code fence is being quoted, not claimed. The last verdict
    # in the reply is the verdict.
    found = LABEL.findall(FENCE.sub("", payload.get("last_assistant_message") or ""))
    if not found or found[-1].strip().upper() != "PASS":
        return 0

    # On SubagentStop the harness names the child's own file; judging a child by
    # its parent's commands is worse than silence.
    transcript = payload.get("transcript_path")
    if payload.get("hook_event_name") == "SubagentStop":
        transcript = payload.get("agent_transcript_path") or child_file(transcript, payload)
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

    start = 0
    for index, entry in enumerate(entries):
        if is_person(entry):
            start = index
    recent = entries[start:]

    # A call counts only when the harness wrote a finished, non-error result
    # for it. A call with no result was interrupted or is still running, and a
    # launch acknowledgement is a start, not a finish.
    finished = {b.get("tool_use_id") for e in recent for b in blocks(e) if finished_ok(b)}
    for entry in recent:
        for b in blocks(entry):
            if (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"
                    and isinstance(b.get("input"), dict)
                    and isinstance(b["input"].get("command"), str)
                    and not b["input"].get("run_in_background")   # a launch is not a finish
                    and isinstance(b.get("id"), str) and b["id"] in finished
                    and ran_a_check(b["input"]["command"])):
                return 0

    if os.environ.get("ORCH_HOOK_DRY_RUN") == "1":
        print("orch-dry-run[orch-verify-gate]: would report - " + NOTE, file=sys.stderr)
        return 0
    # additionalContext is the one route to the model on this harness; stderr
    # would only reach the person's transcript view, and the person is not the
    # audience for an agent's missing check.
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": payload.get("hook_event_name") or "Stop", "additionalContext": NOTE}}))
    return 0


def child_file(transcript, payload):
    """Fallback for harness versions without agent_transcript_path."""
    agent = payload.get("agent_id")
    if not agent or not isinstance(transcript, str):
        return None
    stem = transcript[:-len(".jsonl")] if transcript.endswith(".jsonl") else transcript
    for name in ("agent-%s.jsonl" % agent, "%s.jsonl" % agent):
        candidate = os.path.join(stem, "subagents", name)
        if os.path.isfile(candidate):
            return candidate
    return None


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)     # a malformed transcript must never cost the turn
