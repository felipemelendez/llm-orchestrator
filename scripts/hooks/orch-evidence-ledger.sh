#!/usr/bin/env bash
# LLM Orchestrator PostToolUse hook (matcher: Bash) — verification evidence ledger.
#
# The one place verification becomes unfakeable. When the executed Bash command
# is verify-shaped (test/lint/typecheck/build — ORCH_SIG_VERIFY_CMD), this hook
# records <stamp, exit, epoch, substance, command> in a session ledger that only
# this hook writes. The Stop-hook verify gate then asks the ledger — not the
# model — whether a verify command actually ran green in this turn.
#
# APPEND-ONLY BY DEFAULT. The hook does not modify tool output. Earlier versions
# rewrote stdout via hookSpecificOutput.updatedToolOutput to append a citable
# "[orch-evidence <stamp>]" marker; that had three costs and no benefit the
# ledger does not already provide:
#   1. When tool_response did not carry a literal `stdout` string (list-shaped
#      or differently-keyed responses), the rewrite REPLACED the command's real
#      output with the marker alone — destroying the evidence it existed to
#      attest.
#   2. The marker carried an imperative ("cite this line..."). Instruction-shaped
#      text arriving through a data channel is indistinguishable from prompt
#      injection, so well-behaved agents correctly refuse it — the mechanism
#      selected against its own adoption.
#   3. It reached every agent, including reviewer/explorer/debugger seats whose
#      prompts never explain the stamp, which spent review cycles escalating it.
# The gate's turn-window check is also STRICTLY STRONGER than citation: a model
# cannot opt out by declining to cite, and cannot cite a stale stamp from an
# earlier turn.
#
# Set ORCH_EVIDENCE_MARKER=1 to restore an INERT marker (no imperative) for
# cross-agent evidence transport. Even then the rewrite is emitted only when the
# response carries a real stdout string, so output loss is impossible.
#
# It also records writer-mutex claims/releases (mkdir/rmdir .orch-active) with
# the acting agent_id, so the worktree reaper can release a mutex abandoned by
# a dead implementer without guessing.
#
# Non-verify commands are ignored entirely. Gated by ORCH_HOOK_PROFILE (off
# under minimal) and ORCH_DISABLED_HOOKS=orch-evidence-ledger. Needs python3;
# degrades silently.

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

# Guarded on a non-tty stdin: run interactively without a redirect, a bare
# `cat` blocks forever. A hook that can hang is worse than one that learns less.
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
HASH="default"
declare -f orch_project_hash >/dev/null 2>&1 && HASH=$(orch_project_hash 2>/dev/null || echo default)
STATE_DIR="${HOME_DIR}/state/${HASH}"

# One python3 pass: parse input, classify the command, write ledger/mutex-map
# entries, and (only under ORCH_EVIDENCE_MARKER=1) emit an inert marker. The
# hook input goes through a temp file — a heredoc already owns python3's stdin.
IN_FILE=$(mktemp) || exit 0
# trap, not just a trailing rm: killed at the hook timeout, a plain rm never runs.
trap 'rm -f "${IN_FILE}" 2>/dev/null' EXIT
printf '%s' "${INPUT}" > "${IN_FILE}"
ORCH_STATE_DIR="${STATE_DIR}" \
ORCH_VERIFY_RE="${ORCH_SIG_VERIFY_CMD}" \
ORCH_NONRUN_RE="${ORCH_SIG_VERIFY_NONRUN:-}" \
ORCH_MARKER="${ORCH_EVIDENCE_MARKER:-0}" \
python3 - "${IN_FILE}" <<'PYEOF' 2>/dev/null
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
#
# `have_stdout` tracks whether we hold the command's REAL output as a string.
# Every downstream decision that could discard output is gated on it.
event = data.get("hook_event_name") or "PostToolUse"
resp = data.get("tool_response")
stdout = stderr = ""
have_stdout = False
if isinstance(resp, dict):
    if isinstance(resp.get("stdout"), str):
        stdout = resp["stdout"]
        have_stdout = True
    stderr = resp.get("stderr") if isinstance(resp.get("stderr"), str) else ""
elif isinstance(resp, str):
    stdout = resp
    have_stdout = True
elif isinstance(resp, list):
    # Content-block shape: text lives in blocks. Readable for substance
    # classification, but not a stdout string we may safely rewrite.
    parts = []
    for b in resp:
        if isinstance(b, dict) and isinstance(b.get("text"), str):
            parts.append(b["text"])
        elif isinstance(b, str):
            parts.append(b)
    stdout = "\n".join(parts)

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
        append_line(os.path.join(state_dir, "mutex-map.%s.tsv" % sid),
                    "claim\t%s\t%s\t%d" % (agent_id or "unknown", m.group(1), int(time.time())))
    m = re.search(r"rmdir\s+[\"']?([^\s\"']*\.orch-active)", cmd)
    if m:
        append_line(os.path.join(state_dir, "mutex-map.%s.tsv" % sid),
                    "release\t%s\t%s\t%d" % (agent_id or "unknown", m.group(1), int(time.time())))


# --- command classification -----------------------------------------------
def strip_quoted(s):
    """Blank out single/double-quoted spans.

    ORCH_SIG_VERIFY_CMD anchors an invocation on `^` or `[;&|]`. A `|` inside a
    quoted ARGUMENT looks identical to a shell pipe, so `grep -rn "tsc|eslint"
    pkg.json` was classified as a typecheck run and recorded as passing
    verification — the ledger manufacturing the fabrication it exists to
    prevent. Quoted text is data, never an invocation site.

    Trade-off: `bash -c "npm test"` no longer mints a stamp. A missed stamp is
    quiet (the gate's soft path); a fabricated one is not.
    """
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in ("'", '"'):
            q = c
            i += 1
            while i < n and s[i] != q:
                if s[i] == "\\" and q == '"':
                    i += 1
                i += 1
            i += 1
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def strip_heredocs(s):
    """Drop heredoc BODIES.

    With re.MULTILINE every line start is a command position, and a heredoc body
    is not code — it is the text being written. So

        cat >> CHANGELOG.md <<'EOF'
        - fixed the null deref
        pytest -q now passes
        EOF

    minted a green verification row for a command that wrote a changelog entry.
    Chained with a real red run earlier in the same turn, that LAUNDERS the
    failure: the gate's window sees a later green and goes quiet. Writing a
    changelog that names the test command is ordinary post-fix behaviour.
    """
    out, lines = [], s.split("\n")
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        out.append(line)
        # The delimiter need not end the line: `cat <<EOF > CHANGELOG.md` and
        # `cat <<EOF | tee` both put a redirect after it, and requiring `$`
        # left those bodies in place — where a line like "pytest -q now passes"
        # minted a green verification row for a command that wrote a changelog.
        m = re.search(r"<<-?\s*(?:\"([A-Za-z_]\w*)\"|\'([A-Za-z_]\w*)\'|([A-Za-z_]\w*))", line)
        i += 1
        if not m:
            continue
        delim = m.group(1) or m.group(2) or m.group(3)
        j = i
        while j < n and lines[j].strip() != delim:
            j += 1
        if j >= n:
            # No terminator: this was not a heredoc (e.g. the text `<<EOF`
            # inside a quoted string). Dropping to end-of-input here would hide
            # a REAL verify command that follows — the direction that turns a
            # genuine run invisible. Leave everything in place.
            continue
        i = j + 1           # body and terminator dropped
    return "\n".join(out)


# ORCH_SIG_VERIFY_CMD is written in POSIX ERE (grep). Python's re has no POSIX
# character classes, so translate [[:space:]] mechanically before compiling.
verify_re = (os.environ.get("ORCH_VERIFY_RE", "")
             .replace("[[:space:]]", r"\s")   # standalone POSIX class
             .replace("[:space:]", r"\s"))    # POSIX class inside a bracket expression
# re.MULTILINE is load-bearing. The pattern anchors a command position on
# `(^|[;&|])`, and a newline is not in that class — so without MULTILINE, `^`
# matches only offset 0 and a verify tool on line 2+ of a heredoc-style command
# is never seen. `cd /tmp && npm test` recorded a row; the identical two-line
# form recorded nothing, silently exempting multi-line commands from the whole
# mechanism.
try:
    is_verify = bool(verify_re) and bool(re.search(verify_re, strip_quoted(strip_heredocs(cmd)), re.M))
except re.error:
    is_verify = False

# A flag that makes the tool print instead of run vetoes classification.
nonrun_re = os.environ.get("ORCH_NONRUN_RE", "").replace("[[:space:]]", r"\s")
if is_verify and nonrun_re:
    try:
        if re.search(nonrun_re, cmd):
            is_verify = False
    except re.error:
        pass

if not is_verify or exit_code is None:
    sys.exit(0)  # not a verify command, or no recorded exit — nothing to record

# --- substance ------------------------------------------------------------
# exit 0 is not evidence that anything was verified. `swift test` exits 0 on
# "Test run with 0 tests in 0 suites passed"; jest exits 0 when a path filter
# matches nothing. Recording WHY a run was green lets the gate distinguish
# "2178 tests passed" from "nothing ran".
NO_TESTS = re.compile(r"""(
      no\s+tests?\s+(ran|were\s+run|found|executed|to\s+run|matched)
    | (ran|executed)\s+0\s+tests?
    | collected\s+0\s+items
    | test\s+run\s+with\s+0\s+tests?
    | \b0\s+tests?\b[^\n]{0,40}\b(passed|ok|succeeded|completed)
    | \b0\s+passing\b
    | \b0\s+examples?\b
    | no\s+test\s+files?\s+(found|match)
    | \b0\s+tests?\s+(ran|executed|found|collected)
    | running\s+0\s+tests?
    | test\s+result:\s*ok\.\s*0\s+passed
    | \[no\s+test\s+files\]
    | \b0\s+(tests?|specs?|examples?),\s*0\s+(failures?|errors?)
    | no\s+tests?\s+executed
    | no\s+tests?\s+collected
    | no\s+test\s+matches
    | test\s+files\s+no\s+tests
    | \b0\s+runs?,\s*0\s+assertions?
    | \b0\s+(tests?|specs?|examples?)\s+(completed|executed|total)\b
)""", re.I | re.X)

# Empty output is NOT evidence of a hollow run. `tsc --noEmit` and `eslint .`
# — both named in ORCH_SIG_VERIFY_CMD's own tool list — print nothing on
# success by design. Classifying silence as "verified nothing" put a false note
# on every clean typecheck, which is precisely the fire-when-we-know-nothing
# behaviour the gate exists to avoid. Only an explicit zero-test statement in
# the output counts against a green run.
# A zero-test phrase somewhere in a long log does NOT mean the run was hollow.
# This repo's own suite prints the string "collected 0 items" as a test FIXTURE
# label while passing 32 checks, and was classified `none` — the gate then told
# a correct, fully-verified turn that it had run no tests. A monorepo whose
# first package has no tests ("0 passing") and whose second has fifty hit the
# same thing. Positive evidence that tests ran wins.
RAN_TESTS = re.compile(r"""(
      \b[1-9][0-9]*\s+(tests?|examples?|assertions?|checks?|specs?)\b
    | \b[1-9][0-9]*\s+(passed|passing|ok|succeeded)\b
    | \bpassed[:=]?\s*[1-9][0-9]*\b
    | \bok\b.*\b[1-9][0-9]*\s+passed
)""", re.I | re.X)

blob = (stdout + "\n" + stderr)
if exit_code != 0:
    substance = "red"
elif RAN_TESTS.search(blob):
    substance = "ok"
elif NO_TESTS.search(blob):
    substance = "none"
else:
    substance = "ok"

tail = blob[-2000:]
stamp = hashlib.sha1(
    ("%s|%s|%s|%s|%s|%s" % (sid, cmd, exit_code, tail, time.time(), os.getpid())).encode()
).hexdigest()[:12]

ledger = os.path.join(state_dir, "evidence.%s.tsv" % sid)
append_line(ledger,
            "%s\t%d\t%d\t%s\t%s" % (stamp, exit_code, int(time.time()), substance,
                                    cmd.replace("\t", " ").replace("\n", " ")[:400]))

# Bound the ledger. A long session with a tight test loop should not grow an
# unbounded file; the gate only ever reads the current turn's window.
# Written to a temp file and os.replace'd, never truncated in place. A sibling
# hook appending between the read and the truncate would be silently dropped —
# and losing the turn's only RED row turns the gate's hard verdict into silence,
# the one error direction that matters. os.replace is atomic on POSIX, so a
# concurrent reader sees either the old file or the new one, never an empty one.
try:
    if os.path.getsize(ledger) > 400_000:
        with open(ledger) as f:
            rows = f.readlines()
        tmp = ledger + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.writelines(rows[-2000:])
        os.replace(tmp, ledger)
except Exception:
    pass

# --- optional inert marker ------------------------------------------------
# Off by default. The gate reads the ledger directly; nothing needs to travel
# through the model. When enabled, the marker states a fact and issues no
# instruction, and is emitted ONLY when we hold the real stdout — a rewrite we
# cannot faithfully reproduce is never worth the output it would destroy.
if os.environ.get("ORCH_MARKER", "0") != "1":
    sys.exit(0)
if event != "PostToolUse" or not have_stdout:
    sys.exit(0)

marker = "[orch-evidence %s exit=%d %s]" % (stamp, exit_code, substance)
new_stdout = stdout
LIMIT = 30000
if len(new_stdout) > LIMIT:
    new_stdout = "[orch-evidence-ledger: stdout truncated to final %d chars]\n...%s" % (LIMIT, new_stdout[-LIMIT:])
new_stdout = new_stdout + ("\n" if new_stdout and not new_stdout.endswith("\n") else "") + marker

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "updatedToolOutput": {
            "stdout": new_stdout,
            "stderr": stderr,
            "interrupted": False,
            "isImage": False,
        },
    }
}))
PYEOF
rm -f "${IN_FILE}" 2>/dev/null
exit 0
