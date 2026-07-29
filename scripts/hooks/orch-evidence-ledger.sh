#!/usr/bin/env bash
# LLM Orchestrator PostToolUse hook (matcher: Bash) — verification evidence ledger.
#
# The one place verification becomes unfakeable. When the executed Bash command
# is verify-shaped (test/lint/typecheck/build — ORCH_SIG_VERIFY_CMD), this hook:
#   1. records <stamp, exit, epoch, command> in a session ledger that only this
#      hook writes, and
#   2. rewrites the tool output via hookSpecificOutput.updatedToolOutput to
#      append "[orch-evidence <stamp> exit=<code>]" — so the model receives the
#      stamp WITH the output and can cite it in its Verify: line.
#
# The Stop-hook verify gate and the SubagentStop validator then check cited
# stamps against the ledger. The model no longer sits between the check and the
# verdict: a fabricated Verify: line has no recorded stamp and fails lookup.
#
# It also records writer-mutex claims/releases (mkdir/rmdir .orch-active) with
# the acting agent_id, so the worktree reaper can release a mutex abandoned by
# a dead implementer without guessing.
#
# Non-verify commands pass through untouched (no output rewrite, no record).
# Gated by ORCH_HOOK_PROFILE (off under minimal) and
# ORCH_DISABLED_HOOKS=orch-evidence-ledger. Needs python3; degrades silently.

set -uo pipefail

PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"

if [[ ",${DISABLED}," == *",orch-evidence-ledger,"* ]] || [[ "${PROFILE}" == "minimal" ]]; then
  exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SIG_LIB="${HOOK_DIR}/../lib/orch-signals.sh"
PROJ_LIB="${HOOK_DIR}/../lib/orch-project.sh"
[[ -f "${SIG_LIB}" ]] || exit 0
# shellcheck source=scripts/lib/orch-signals.sh
source "${SIG_LIB}"
# shellcheck source=scripts/lib/orch-project.sh
[[ -f "${PROJ_LIB}" ]] && source "${PROJ_LIB}"

INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
HASH="default"
declare -f orch_project_hash >/dev/null 2>&1 && HASH=$(orch_project_hash 2>/dev/null || echo default)
STATE_DIR="${HOME_DIR}/state/${HASH}"

# One python3 pass: parse input, classify the command, write ledger/mutex-map
# entries, and emit updatedToolOutput when a stamp was minted. The hook input
# goes through a temp file — a heredoc already owns python3's stdin.
IN_FILE=$(mktemp) || exit 0
printf '%s' "${INPUT}" > "${IN_FILE}"
ORCH_STATE_DIR="${STATE_DIR}" ORCH_VERIFY_RE="${ORCH_SIG_VERIFY_CMD}" python3 - "${IN_FILE}" <<'PYEOF' 2>/dev/null
import hashlib, json, os, re, sys, time

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

tool = data.get("tool_name") or ""
if tool != "Bash":
    sys.exit(0)

ti = data.get("tool_input") or {}
cmd = ti.get("command") or ""
if not cmd:
    sys.exit(0)

sid = data.get("session_id") or "default"
agent_id = data.get("agent_id") or ""
state_dir = os.environ.get("ORCH_STATE_DIR", "")
if not state_dir:
    sys.exit(0)

# Platform contract, verified live against v2.1.220 (2026-07-28): PostToolUse
# fires ONLY when the tool call succeeds — a failing Bash command fires
# PostToolUseFailure instead — and tool_response carries {stdout, stderr,
# interrupted, isImage, noOutputExpected}, no exit-code field. So the event
# name itself carries the verdict: PostToolUse ⇒ exit 0, PostToolUseFailure ⇒
# non-zero (recorded as 1; the true code is not exposed). An interrupted run
# proves nothing and records nothing.
event = data.get("hook_event_name") or "PostToolUse"
resp = data.get("tool_response")
stdout = stderr = ""
if isinstance(resp, dict):
    stdout = resp.get("stdout") or ""
    stderr = resp.get("stderr") or ""
elif isinstance(resp, str):
    stdout = resp
if isinstance(resp, dict) and resp.get("interrupted") is True:
    exit_code = None
elif event == "PostToolUseFailure":
    exit_code = 1
else:
    exit_code = 0

def append_line(path, line):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(line + "\n")

# --- writer-mutex map (for the worktree reaper) ---------------------------
# Success-only events make this sound: a LOST mutex race (mkdir fails, exit 1)
# fires no PostToolUse, so no claim is recorded for the loser. `mkdir -p` is
# deliberately excluded — it exits 0 on an EXISTING dir, so a -p "claim" says
# nothing about who owns the mutex. Paths with spaces or unexpanded variables
# don't match; the map then just knows less (the reaper is fail-safe on less).
if exit_code == 0:
    m = re.search(r"mkdir\s+[\"']?([^\s\"']*\.orch-active)[\"']?(\s|;|&|$)", cmd)
    if m and not re.search(r"mkdir\s+-", cmd):
        append_line(os.path.join(state_dir, f"mutex-map.{sid}.tsv"),
                    "claim\t%s\t%s\t%d" % (agent_id or "unknown", m.group(1), int(time.time())))
    m = re.search(r"rmdir\s+[\"']?([^\s\"']*\.orch-active)", cmd)
    if m:
        append_line(os.path.join(state_dir, f"mutex-map.{sid}.tsv"),
                    "release\t%s\t%s\t%d" % (agent_id or "unknown", m.group(1), int(time.time())))

# --- evidence stamp -------------------------------------------------------
# ORCH_SIG_VERIFY_CMD is written in POSIX ERE (grep). Python's re has no POSIX
# character classes, so translate [[:space:]] mechanically before compiling.
verify_re = (os.environ.get("ORCH_VERIFY_RE", "")
             .replace("[[:space:]]", r"\s")   # standalone POSIX class
             .replace("[:space:]", r"\s"))    # POSIX class inside a bracket expression
try:
    is_verify = bool(verify_re) and bool(re.search(verify_re, cmd))
except re.error:
    is_verify = False

if not is_verify or exit_code is None:
    sys.exit(0)  # not a verify command, or no recorded exit (e.g. background) — no stamp

tail = (stdout + "\n" + stderr)[-2000:]
stamp = hashlib.sha1(
    ("%s|%s|%s|%s|%s|%s" % (sid, cmd, exit_code, tail, time.time(), os.getpid())).encode()
).hexdigest()[:12]

append_line(os.path.join(state_dir, f"evidence.{sid}.tsv"),
            "%s\t%d\t%d\t%s" % (stamp, exit_code, int(time.time()), cmd.replace("\t", " ").replace("\n", " ")[:160]))

# The replacement value MUST match the Bash tool's output schema — an object
# with {stdout, stderr, interrupted, isImage}; a plain string is silently
# ignored and the original output is used (verified live: the string form
# never reached the model). Only the success event rewrites output — the
# failure event's result shape is different, and a failing run needs no stamp
# (there is nothing green to cite).
if event != "PostToolUse":
    sys.exit(0)

marker = "[orch-evidence %s exit=%d] (cite this line in your Verify: block)" % (stamp, exit_code)
new_stdout = stdout
# Keep the rewrite bounded so a huge test log is not re-injected past the
# harness's own truncation. Tail wins — test runners put the verdict last.
LIMIT = 30000
if len(new_stdout) > LIMIT:
    new_stdout = "[orch-evidence-ledger: stdout truncated to final %d chars]\n...%s" % (LIMIT, new_stdout[-LIMIT:])
new_stdout = new_stdout + ("\n" if new_stdout and not new_stdout.endswith("\n") else "") + marker

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "updatedToolOutput": {
            "stdout": new_stdout,
            "stderr": stderr if isinstance(stderr, str) else "",
            "interrupted": False,
            "isImage": False,
        },
    }
}))
PYEOF
rm -f "${IN_FILE}" 2>/dev/null
exit 0
