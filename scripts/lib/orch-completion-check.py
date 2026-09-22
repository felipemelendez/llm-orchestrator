#!/usr/bin/env python3
"""Did a check actually run and pass this turn?

Reads a Stop / SubagentStop payload on stdin. Prints one note, or nothing.
Always exits 0: this warns, it never blocks. See orch-verify-gate.sh for why.

Deliberately small. Rules for quoted text, pipes and "didn't really run" flags
were measured catching zero evasions while wrongly rejecting ordinary commands,
so they are not here: a note that is wrong often gets ignored, which is worse
than no note.

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
FENCE = re.compile(r"(?ms)^\s*(```|~~~).*?^\s*\1[^\n]*")
# `CI=1 pytest`, `timeout 300 pytest`, `cd repo && pytest` — the tool is still
# the tool. Stripped before matching so a prefix does not hide a real run.
PREFIX = re.compile(r"^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+|time\s+|env\s+|timeout\s+\S+\s+|cd\s+\S+\s+)*")
# A user entry the person did not type: an agent returning, a slash command, a
# compaction summary. Counting one as the turn start throws away real checks.
MACHINE = ("<task-notification>", "<local-command-", "<bash-", "<command-name>", "<system-reminder>")

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


def ran_a_check(command):
    """Any segment of the command that runs a check and is not a --version."""
    for segment in re.split(r"[;&|\n]+", command):
        segment = PREFIX.sub("", segment)
        if re.search(RUNS, segment, re.M) and not (NONRUN and re.search(NONRUN, segment, re.M)):
            return True
    return False


def main():
    if not RUNS:
        return 0            # no shared pattern: say nothing rather than guess
    if "[:" in RUNS + NONRUN:
        return 0            # a POSIX class survived conversion; it would match nothing

    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        return 0
    if payload.get("stop_hook_active"):
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

    failed = {b.get("tool_use_id") for e in recent for b in blocks(e)
              if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error")}
    for entry in recent:
        for b in blocks(entry):
            if (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"
                    and isinstance(b.get("input"), dict)
                    and isinstance(b["input"].get("command"), str)
                    and b.get("id") not in failed
                    and ran_a_check(b["input"]["command"])):
                return 0

    if os.environ.get("ORCH_HOOK_DRY_RUN") == "1":
        print("orch-dry-run[orch-verify-gate]: would report - " + NOTE, file=sys.stderr)
        return 0
    print(NOTE, file=sys.stderr)
    # stderr alone is not delivered to the model on this harness (CHANGELOG.md:769).
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
