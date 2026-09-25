#!/usr/bin/env bash
# Tests for the Codex completion check (codex-verify-gate.sh).
#
# The Codex twin of test-verify-gate.sh, with two differences that are the
# whole point: the log it reads is Codex's rollout JSONL, where the harness
# records the commands it ran (`item_completed` / `CommandExecution`, or the
# exit-code header of an `exec_command` output), and its output is a one-shot
# continuation to the AGENT ({"decision":"block","reason":...}), never a
# message to the person. Nothing the agent wrote is read.
#
# Every fixture is also an invariant sample: the hook must never exit non-zero,
# never print a systemMessage, and never say anything on stderr outside a dry
# run.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/codex-verify-gate.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"; exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"; exit 0
}
command -v python3 >/dev/null 2>&1 || skip_suite test-codex-verify-gate 'python3 unavailable'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Rollout fixtures, one JSON object per line, in the shapes real Codex logs
# use (read from ~/.codex/sessions on 2026-09-22 and 2026-09-25; scrubbed real
# lines of each kind are in tests/fixtures/codex-rollouts/). Specs:
#   turn:<id>            a turn start: task_started event + turn_context (the
#                        current turn for the records that follow)
#   ctx                  a bare turn_context with no turn_id
#   ran:<code>:<cmd>     the harness's record of a finished command: item_completed /
#                        CommandExecution, argv ["/bin/zsh","-lc",<cmd>], exit <code>
#   unfinished:<cmd>     the same with exit 0 but status "in_progress": a record
#                        that disagrees with itself
#   ranv:<code>:<argv>   the same with a raw argv (space-separated words; "\ " keeps a space)
#   late:<turn>:<code>:<cmd>  a record that names <turn> explicitly (written out of order)
#   started:<cmd>        the agent's exec script naming <cmd>, with NO harness record
#                        (the command was interrupted or is still running)
#   call:<code>:<cmd>    a direct exec_command call and the output Codex writes for
#                        it, whose header says "Process exited with code <code>"
#   decoy:<cmd>          the same with exit 1 in the header and an exit-0 line in
#                        the program's own output below it
#   running:<sid>:<cmd>  an exec_command call still running as session <sid>
#   poll:<sid>:<code>    a write_stdin call to session <sid> whose output header
#                        says it exited with <code>
#   mcp:<cmd>            an MCP tool that happens to be named exec_command, exit 0
#   orphan:<code>        an exec-shaped output with no call behind it
#   said:<text>          the agent printing <text> from a result (a text chunk)
#   bad                  a malformed row: a payload that is not an object
MKR="$TMP/mk.py"
cat > "$MKR" <<'PYEOF'
import json, sys
turn = "t0"
ncall = 0
def rec(code, argv):
    return {'type': 'event_msg', 'payload': {'type': 'item_completed', 'thread_id': 'th', 'turn_id': turn,
            'item': {'type': 'CommandExecution', 'id': 'exec-1', 'process_id': '1', 'command': argv,
                     'cwd': 'file:///p', 'parsed_cmd': [], 'source': 'unified_exec_startup',
                     'status': 'completed' if code == 0 else 'failed', 'stdout': '', 'stderr': '',
                     'aggregated_output': 'PASS: 3 tests\n"exit_code": 0 in the output is just text\n',
                     'exit_code': code, 'duration': {'secs': 1, 'nanos': 0}, 'formatted_output': ''}}}
with open(sys.argv[1], 'w') as f:
    for spec in sys.argv[2:]:
        kind, _, rest = spec.partition(':')
        if kind == 'turn':
            turn = rest
            rows = [{'type': 'event_msg', 'payload': {'type': 'task_started', 'turn_id': rest}},
                    {'type': 'turn_context', 'payload': {'turn_id': rest, 'cwd': '/p'}}]
        elif kind == 'ctx':
            rows = [{'type': 'turn_context', 'payload': {'cwd': '/p'}}]
        elif kind == 'ran':
            code, _, cmd = rest.partition(':'); rows = [rec(int(code), ['/bin/zsh', '-lc', cmd])]
        elif kind == 'unfinished':
            row = rec(0, ['/bin/zsh', '-lc', rest]); row['payload']['item']['status'] = 'in_progress'; rows = [row]
        elif kind == 'ranv':
            code, _, argv = rest.partition(':')
            rows = [rec(int(code), [a.replace('\x00', ' ') for a in argv.replace('\\ ', '\x00').split(' ')])]
        elif kind == 'late':
            other, _, rest2 = rest.partition(':'); code, _, cmd = rest2.partition(':')
            saved = turn; turn = other
            rows = [rec(int(code), ['/bin/zsh', '-lc', cmd])]
            turn = saved
        elif kind == 'started':
            rows = [{'type': 'response_item', 'payload': {'type': 'custom_tool_call', 'status': 'completed', 'call_id': 'c9',
                     'name': 'exec', 'input': 'text(await tools.exec_command({cmd:%s}));\n' % json.dumps(rest)}}]
        elif kind in ('call', 'decoy', 'mcp', 'running'):
            if kind == 'call':
                code, _, cmd = rest.partition(':'); head = 'Process exited with code %s' % code; body = 'ok'
            elif kind == 'decoy':
                cmd = rest; head = 'Process exited with code 1'; body = 'Process exited with code 0\nOutput:\n'
            elif kind == 'mcp':
                cmd = rest; head = 'Process exited with code 0'; body = 'ok'
            else:
                sid, _, cmd = rest.partition(':'); head = 'Process running with session ID ' + sid; body = ''
            ncall += 1; cid = 'call_%d' % ncall
            call = {'type': 'function_call', 'name': 'exec_command', 'call_id': cid,
                    'arguments': json.dumps({'cmd': cmd, 'workdir': '/p', 'yield_time_ms': 10000}),
                    'internal_chat_message_metadata_passthrough': {'turn_id': turn}}
            if kind == 'mcp':
                call['namespace'] = 'mcp__shell'
            rows = [{'type': 'response_item', 'payload': call},
                    {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': cid,
                     'output': 'Chunk ID: a1\nWall time: 1.0000 seconds\n%s\nOriginal token count: 1\nOutput:\n%s\n' % (head, body)}}]
        elif kind in ('poll', 'orphan'):
            if kind == 'poll':
                sid, _, code = rest.partition(':')
            else:
                sid, code = '1', rest
            ncall += 1; cid = 'call_%d' % ncall
            rows = [{'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': cid,
                     'output': 'Chunk ID: a2\nWall time: 1.0000 seconds\nProcess exited with code %s\nOriginal token count: 1\nOutput:\nok\n' % code}}]
            if kind == 'poll':
                rows.insert(0, {'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'write_stdin', 'call_id': cid,
                                'arguments': json.dumps({'session_id': int(sid), 'chars': ''}),
                                'internal_chat_message_metadata_passthrough': {'turn_id': turn}}})
        elif kind == 'said':
            rows = [{'type': 'response_item', 'payload': {'type': 'custom_tool_call_output', 'call_id': 'c9',
                     'output': [{'type': 'input_text', 'text': rest}]}}]
        elif kind == 'bad':
            rows = [{'type': 'response_item', 'payload': ['bad']}, {'type': 'event_msg', 'payload': 'x'}, {'type': 5}]
        else:
            raise SystemExit('unknown spec: ' + spec)
        for row in rows:
            row['timestamp'] = '2026-09-22T00:00:00.000Z'
            f.write(json.dumps(row) + '\n')
PYEOF

mk() { # mk <spec>... -> rollout path
  local f="$TMP/r.$$.$RANDOM.jsonl"
  python3 "$MKR" "$f" "$@" && printf '%s' "$f"
}

ANY_RC=0; ANY_PERSON=0; ANY_ERR=0; RC=0; OUT=""; ERR=""
# fire <last_assistant_message> <rollout|null> [turn_id] [stop_hook_active]
fire() {
  python3 -c 'import json,sys
t = None if sys.argv[2] == "null" else sys.argv[2]
print(json.dumps({"session_id":"s","turn_id":sys.argv[3],"transcript_path":t,"cwd":sys.argv[5],
  "hook_event_name":"Stop","model":"m","permission_mode":"default",
  "stop_hook_active": sys.argv[4] == "true","last_assistant_message": (None if sys.argv[1] == "null" else sys.argv[1])}))' \
    "$1" "$2" "${3:-t1}" "${4:-false}" "${PROJ_DIR:-$TMP/no-project}" > "$TMP/in"
  # The project whose cadence.json may name a test_cmd; none unless PROJ_DIR is
  # set. It goes in the payload's cwd and, unless ENV_PROJ_DIR says otherwise,
  # in CODEX_PROJECT_DIR.
  CODEX_PROJECT_DIR="${ENV_PROJ_DIR:-${PROJ_DIR:-$TMP/no-project}}" bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; RC=$?
  OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err")
  [[ $RC -ne 0 ]] && ANY_RC=1
  grep -q 'systemMessage' "$TMP/out" && ANY_PERSON=1
  [[ -n "$ERR" && "${ORCH_HOOK_DRY_RUN:-0}" != "1" ]] && ANY_ERR=1
  return 0
}
sent_back() { printf '%s' "$OUT" | grep -q '"decision": "block"' && printf '%s' "$OUT" | grep -q 'no check ran and passed'; }
silent()    { [[ -z "$OUT" ]]; }

CLAIM='Changed:
- scripts/hooks/codex-verify-gate.sh:1 — the Codex check.

Verification: PASS — the suite is green.'

printf '%s== the explicit PASS label, and only it, is checked ==%s\n' "$DIM" "$RESET"

R=$(mk 'turn:t1' 'ran:0:ls -la scripts/hooks')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(a) PASS with no check in the turn → the agent is sent back once, exit 0" \
  || fail "(a) PASS with no check" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'ran:0:bash tests/test-codex-verify-gate.sh')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(b) PASS with a check the harness recorded at exit 0 → silent" \
  || fail "(b) passing check" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'ranv:0:npm test')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(b2) a raw argv record (no shell wrapper) → silent" \
  || fail "(b2) raw argv" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'ran:0:python3 tests/test-claude-provider.py')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(b3) a direct python test script, the form LAWS.md names → silent" \
  || fail "(b3) python test script" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'ran:1:cat missing.txt' 'ran:0:bash tests/run-all.sh' 'ran:1:rg nothing .')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(b4) unrelated commands failed, the check passed → silent" \
  || fail "(b4) per-command records" "rc=$RC out=$OUT"

QUOTED='Found:
- docs/MEASUREMENTS.md records 200 runs: warn and block both scored 100/100.
- The report says the tests pass, and it is not itself making that claim.'
R=$(mk 'turn:t1')
fire "$QUOTED" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(c) prose quoting \"tests pass\" with no label → silent" \
  || fail "(c) quoted evidence treated as a claim" "rc=$RC out=$OUT"

fire 'Status: PARTIAL

Verification: PENDING — the device is unavailable.' "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(d1) Verification: PENDING → silent" \
  || fail "(d1) PENDING" "rc=$RC out=$OUT"
fire 'Changed:
- README.md:4 — a typo.' "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(d2) no Verification: label at all → silent" \
  || fail "(d2) no label" "rc=$RC out=$OUT"
fire 'The template ends like this:

```
Verification: PASS — example
```' "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(d3) a PASS label only inside a code fence is quoted, not claimed → silent" \
  || fail "(d3) fenced label" "rc=$RC out=$OUT"
fire 'Verification: PENDING — earlier draft.

Verification: PASS — final.' "$R"
{ [[ $RC -eq 0 ]] && sent_back; } && ok "(d4) the LAST label is the verdict: PENDING then PASS → sent back" \
  || fail "(d4) last label wins (PASS last)" "rc=$RC out=$OUT"
fire 'Verification: PASS — earlier draft.

Verification: PENDING — final.' "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(d5) the LAST label is the verdict: PASS then PENDING → silent" \
  || fail "(d5) last label wins (PENDING last)" "rc=$RC out=$OUT"

printf '\n%s== only the harness record counts ==%s\n' "$DIM" "$RESET"

R=$(mk 'turn:t1' 'ran:1:bash tests/test-codex-verify-gate.sh')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e1) the check ran and the harness recorded exit 1 → sent back" \
  || fail "(e1) failed check counted" "rc=$RC out=$OUT"

# A record from an earlier turn shows this log is one that Codex writes
# command records into; without one, see (m1).
R=$(mk 'turn:t0' 'ran:0:true' 'turn:t1' 'started:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e2) the agent asked for a check but the harness never recorded it finishing → sent back" \
  || fail "(e2) unfinished check counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t0' 'ran:0:true' 'turn:t1' 'started:pytest -q' 'said:{"chunk_id":"a1","exit_code":0,"output":"3 passed"}')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e3) the agent printed a harness-shaped result itself; no harness record → sent back" \
  || fail "(e3) agent-printed result counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'started:pytest -q' 'said:Process exited with code 0' 'ran:0:true')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e4) a decoy in the script and a printed exit line; the harness ran only true → sent back" \
  || fail "(e4) decoy script" "rc=$RC out=$OUT"

FIX="$ROOT/tests/fixtures/codex-rollouts"
printf '\n%s== each kind of log Codex writes (real session lines, scrubbed) ==%s\n' "$DIM" "$RESET"

fire "$CLAIM" "$FIX/0.157.0-exec-paginated-code-mode.jsonl" 00000000-0000-7000-8000-00000000157a
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(m0) 0.157.0, paginated history: the CommandExecution record of a code-mode command is read → silent" \
  || fail "(m0) CommandExecution record" "rc=$RC out=$OUT"

fire "$CLAIM" "$FIX/0.146.0-tui-exec-command.jsonl" 00000000-0000-7000-8000-00000000146a
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(m2) 0.146.0: the exit code Codex writes in an exec_command output's header is read → silent" \
  || fail "(m2) exec_command output header" "rc=$RC out=$OUT"

fire "$CLAIM" "$FIX/0.146.0-tui-write-stdin.jsonl" 00000000-0000-7000-8000-00000000146a
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(m3) a command that finished in a later write_stdin poll counts as the command it polled → silent" \
  || fail "(m3) write_stdin finish" "rc=$RC out=$OUT"

fire "$CLAIM" "$FIX/0.154.0-desktop-legacy-code-mode.jsonl" 00000000-0000-7000-8000-00000000154a
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(m1) legacy history, code-mode exec, no command record in the log: unreadable → silent, not sent back" \
  || fail "(m1) unreadable log sent the agent back" "rc=$RC out=$OUT"

R="$TMP/legacy-next-turn.jsonl"
{ cat "$FIX/0.154.0-desktop-legacy-code-mode.jsonl"; python3 "$MKR" /dev/stdout 'turn:t9'; } > "$R"
fire "$CLAIM" "$R" t9
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(m4) the same log, a later turn with no exec call at all: nothing could have run → sent back" \
  || fail "(m4) quiet beyond the unreadable turn" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'started:pytest -q' 'said:{"chunk_id":"a1","exit_code":0,"output":"3 passed"}' 'call:0:ls')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(m5) a code-mode call in this turn and no CommandExecution record in the log: unreadable, even beside an exec_command record → silent" \
  || fail "(m5) code-mode turn judged without CommandExecution records" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'call:1:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n1) exec_command header says exit 1 → sent back" \
  || fail "(n1) failed exec_command counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'call:0:ls -la')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n2) exec_command exit 0 but not a check → sent back" \
  || fail "(n2) non-check counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'decoy:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n3) an exit-0 line in the program's own output below the header is not read → sent back" \
  || fail "(n3) output body read as the header" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'running:77:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n4) a check still running, never polled to its end → sent back" \
  || fail "(n4) running check counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'running:77:pytest -q' 'poll:78:0')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n5) a poll of a different session is not the check's finish → sent back" \
  || fail "(n5) wrong session counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'running:77:pytest -q' 'poll:77:0')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(n6) the poll of the check's own session exits 0 → silent" \
  || fail "(n6) polled finish missed" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'mcp:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n7) an MCP tool named exec_command is not Codex's own → sent back" \
  || fail "(n7) namespaced tool counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'orphan:0')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n8) an exec-shaped output with no exec_command call behind it → sent back" \
  || fail "(n8) orphan output counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t0' 'call:0:pytest -q' 'turn:t1' 'call:0:ls')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(n9) an exec_command check from an earlier turn does not count for this one → sent back" \
  || fail "(n9) earlier turn counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'unfinished:bash tests/test-codex-verify-gate.sh')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e1b) exit 0 with a status that is not completed: the record disagrees with itself → sent back" \
  || fail "(e1b) status mismatch" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'ran:0:pytest --version')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e5) pytest --version prints, it does not run → sent back" \
  || fail "(e5) --version counted as a run" "rc=$RC out=$OUT"

# (e8)-(e12) Honest shapes stay silent. The check reads the harness's record
# and splits the text on operators; it does not read shell syntax. (`npm test
# &`, a heredoc body and `|| true` are accepted on purpose: the spec's limits.)
R=$(mk 'turn:t1' 'ran:0:npm test && echo done')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e8) an && list around a real check → silent" \
  || fail "(e8) and-list" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ran:0:npm test > check.log 2>&1')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e9) a check with 2>&1 → silent" \
  || fail "(e9) fd redirection" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' "ran:0:cat <<< 'hello'
python3 tests/test-pass.py")
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e10) a here-string, then a check on the next line → silent" \
  || fail "(e10) here-string" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' "ran:0:python3 tests/test-pass.py && printf '%s\\n' 'A&B'")
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e11) a check followed by a quoted ampersand → silent" \
  || fail "(e11) quoted ampersand" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' "ran:0:bash tests/test-pass.sh 'one
two'")
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e12) a check with a multi-line quoted argument → silent" \
  || fail "(e12) multi-line argument" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ranv:0:/bin/echo hello;\ npm\ test')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e13) a raw argv whose argument holds shell punctuation is one program, not two → sent back" \
  || fail "(e13) raw argv punctuation" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ran:1:bash tests/test-a.sh' 'bad' 'ran:0:ls')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e6) malformed rows beside a failed check → the rows are skipped, the failure stands → sent back" \
  || fail "(e6) malformed rows" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'bad' 'ran:0:bash tests/test-a.sh')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(e7) malformed rows beside a passing check → silent" \
  || fail "(e7) malformed rows, passing" "rc=$RC out=$OUT"

printf '\n%s== real test commands count; printing does not ==%s\n' "$DIM" "$RESET"

# counts <label> <command>: a record of <command> at exit 0 satisfies PASS.
counts() {
  local R; R=$(mk 'turn:t1' "ran:0:$2")
  fire "$CLAIM" "$R"
  { [[ $RC -eq 0 ]] && silent; } && ok "$1: $2 → silent" \
    || fail "$1: $2 should count as a check" "rc=$RC out=$OUT"
}
# ignored <label> <command>: a record of <command> at exit 0 is not a check.
ignored() {
  local R; R=$(mk 'turn:t1' "ran:0:$2")
  fire "$CLAIM" "$R"
  { [[ $RC -eq 0 ]] && sent_back; } && ok "$1: $2 → sent back" \
    || fail "$1: $2 should not count as a check" "rc=$RC out=$OUT"
}

counts  "(k1) a runner named by a path" '.ve/bin/pytest zapgram/src/zg/test/unit'
counts  "(k1)" './node_modules/.bin/vitest run'
counts  "(k1)" 'venv/bin/pytest -q'
counts  "(k1)" '.ve/bin/python -m pytest -q'
counts  "(k2) a path-named runner after cd" 'cd zapgram && .ve/bin/pytest src/zg/test/unit'
counts  "(k3) a runner after a wrapper that ends its options with --" \
        'aws-vault exec --prompt=osascript testing-felipe -- .ve/bin/pytest src/zg/test/unit'
counts  "(k4) a runner through the package manager" 'pnpm vitest run'
counts  "(k4)" 'pnpm jest'
counts  "(k4)" 'yarn vitest run'
counts  "(k4)" 'yarn jest --ci'
counts  "(k4)" 'npx vitest run'
counts  "(k4)" 'npx jest'
ignored "(k5) a command that only prints" 'echo pytest'
ignored "(k5)" 'echo .ve/bin/pytest'
ignored "(k5) a runner's version, behind a wrapper" 'aws-vault exec testing-felipe -- .ve/bin/pytest --version'
ignored "(k5) a path after git's --" 'git diff -- tests/test-codex-verify-gate.sh'
ignored "(k5) installing a runner" 'pnpm add -D vitest'
R=$(mk 'turn:t1' 'ran:1:aws-vault exec testing-felipe -- .ve/bin/pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } && ok "(k6) a wrapped runner the harness recorded at exit 1 → sent back" \
  || fail "(k6) failed wrapped runner counted" "rc=$RC out=$OUT"

printf '\n%s== the project'"'"'s own test_cmd counts ==%s\n' "$DIM" "$RESET"

PROJ="$TMP/project"; mkdir -p "$PROJ/docs/llm-orchestrator"
printf '{ "schema": 1, "enabled": true,\n  "runner": { "profile": "custom", "test_cmd": "bin/suite --fast" } }\n' \
  > "$PROJ/docs/llm-orchestrator/cadence.json"
ignored "(l1) no cadence.json: a command the lists do not know" 'bin/suite --fast unit'
PROJ_DIR="$PROJ" counts  "(l2) it starts with runner.test_cmd" 'bin/suite --fast unit'
PROJ_DIR="$PROJ" counts  "(l2) after cd" 'cd sub && bin/suite --fast'
PROJ_DIR="$PROJ" ignored "(l3) the same text continuing into another word" 'bin/suite --fastest'
PROJ_DIR="$PROJ" ignored "(l3) the text in the middle of a command" 'echo bin/suite --fast'
R=$(mk 'turn:t1' 'ran:1:bin/suite --fast')
PROJ_DIR="$PROJ" fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } && ok "(l4) test_cmd recorded at exit 1 does not count → sent back" \
  || fail "(l4) failed test_cmd counted" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ranv:0:bin/suite --fast')
PROJ_DIR="$PROJ" fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(l5) test_cmd as a raw argv record → silent" \
  || fail "(l5) raw argv test_cmd" "rc=$RC out=$OUT"
printf '{ not json' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ignored "(l6) a cadence.json that is not JSON: as if there were none" 'bin/suite --fast'

printf '\n%s== review fixes: what ends a runner name, named wrappers, options ==%s\n' "$DIM" "$RESET"

# A runner name is the whole last part of a path and ends the word; a path
# that only passes through a directory named like a runner is not a run.
# After `--`, only a named wrapper runs the rest; git, rm and ls take paths.
for c in 'git diff -- tests/pytest/conftest.py' 'git diff -- config/jest/setup.js' \
         'git show HEAD -- config/jest/setup.js' 'git checkout -- src/eslint/' \
         'git log -- mypy/' 'git diff --stat -- pytest' 'git ls-files -- node_modules/.bin/jest' \
         'rm -rf -- .ve/bin/pytest' 'ls -- node_modules/.bin/jest' 'scripts/eslint/build-rules.sh' \
         'tools/tsc/emit.sh' './node_modules/mocha/package.json' 'echo x -- pytest'; do
  ignored "(m1) not a run" "$c"
done
# Every runner may be named by a path, and options may come between the
# package manager and the runner.
for c in '/usr/bin/make test' '/usr/local/bin/go test ./...' '~/.cargo/bin/cargo test' \
         'pnpm --filter web vitest run' 'pnpm -C connections vitest run' 'yarn --cwd web jest' \
         'npx --yes vitest run' 'uv run --with x pytest' '$HOME/.ve/bin/pytest x' \
         'doppler run -- bash tests/test-a.sh'; do
  counts "(m2) a real run" "$c"
done
# The named wrappers. These already counted under the looser rule; they pin the list.
for c in 'aws-vault exec testing-felipe -- .ve/bin/pytest -q' 'doppler run -- pytest' \
         'op run --env-file=.env -- npm test' 'dotenvx run -f .env -- vitest run' \
         'infisical run --env=dev -- pytest' 'mise exec -- pytest'; do
  counts "(m3) a named wrapper" "$c"
done
# A test_cmd with its own && still counts after the usual prefixes.
printf '{ "runner": { "test_cmd": "cd app && ./check" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" counts "(m4) test_cmd after cd" 'cd /repo && cd app && ./check -q'
PROJ_DIR="$PROJ" counts "(m4) test_cmd after an assignment" 'FOO=1 cd app && ./check'
# A cadence.json nested too deeply for the JSON reader falls back to the
# lists; it does not switch the whole check off.
python3 -c 'print("[" * 100000)' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ignored "(m5) a cadence.json too deep to read: the check still runs" 'ls -la'
# The project is the payload's cwd first, then CODEX_PROJECT_DIR.
printf '{ "runner": { "test_cmd": "bin/suite --fast" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ENV_PROJ_DIR="$TMP/no-project" counts "(m6) the payload's cwd names the project" 'bin/suite --fast'

printf '\n%s== round 2: options, the first --, redirections, time ==%s\n' "$DIM" "$RESET"

# A package manager's own subcommands, and a runner named only as an option's
# value, are not runs.
for c in 'pnpm -w add -D vitest' 'pnpm -r add -D eslint' 'yarn -W add -D jest' 'pnpm -r remove eslint' \
         'pnpm -r update vitest' 'pnpm --recursive why jest' 'npx -y install jest' \
         'npx --package jest /bin/echo done' 'npx -p jest echo hi' 'uv run --with pytest python script.py' \
         "uv run --with mypy python -c 'print(1)'" 'pnpm --filter jest build' 'yarn --cwd tsc build'; do
  ignored "(n1) not a run" "$c"
done
# A wrapper runs what follows its FIRST --; later ones belong to that program.
for c in 'aws-vault exec p -- git ls-files -- node_modules/.bin/jest' 'aws-vault exec p -- git diff -- tests/x.sh' \
         'op run -- git log -- tests/test-verify-gate.sh' 'op run --env-file=.env -- git diff -- pytest' \
         'aws-vault exec p -- echo -- pytest' 'doppler run -- echo -- pytest' 'op run -- echo -- pytest' \
         'dotenvx run -- echo -- pytest' 'infisical run -- echo -- pytest' 'mise exec -- echo -- pytest'; do
  ignored "(n2) not a run" "$c"
done
counts "(n3) npm exec before --" 'npm exec -- vitest run'
# A redirection ends test_cmd's last word.
printf '{ "runner": { "test_cmd": "bin/suite --fast" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" counts "(n4) test_cmd then a redirection" 'bin/suite --fast</dev/null'
PROJ_DIR="$PROJ" counts "(n4)" 'bin/suite --fast>check.log'

budget_case() { # <label> <python expression for the command>
  local cmd base big R
  cmd=$(python3 -c "print($2, end='')")
  R=$(mk 'turn:t1' 'ran:0:ls')
  base=$(python3 -c 'import time; print(time.time())'); fire "$CLAIM" "$R"
  base=$(python3 -c 'import time,sys; print(time.time()-float(sys.argv[1]))' "$base")
  R=$(mk 'turn:t1' "ran:0:$cmd")
  big=$(python3 -c 'import time; print(time.time())'); fire "$CLAIM" "$R"
  big=$(python3 -c 'import time,sys; print(time.time()-float(sys.argv[1]))' "$big")
  { [[ $RC -eq 0 ]] && sent_back && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) - float(sys.argv[2]) < 0.1 else 1)' "$big" "$base"; } \
    && ok "(n5) $1: 200 KB judged within 100 ms of a one-word command, sent back" \
    || fail "(n5) $1 time" "rc=$RC big=${big}s base=${base}s out=$OUT"
}
budget_case "wrapper and repeated options" '"aws-vault exec " + "-- npx -a " * 20000'
budget_case "repeated option values" '"pnpm " + "--filter a " * 20000'
budget_case "repeated path parts" '"a/" * 100000'

printf '\n%s== round 3: comments, heredocs, descriptors, prefixes, dry runs ==%s\n' "$DIM" "$RESET"

for c in 'npm exec -p /bin/echo jest' 'make test -n' 'make -n test' 'cargo test --no-run' \
         'mvn -DskipTests test' 'mvn -Dmaven.test.skip=true test' 'echo done # ; pytest' \
         $'cat <<EOF\npytest\nEOF' $'cat <<\'EOF\'\npytest -q\nEOF' $'cat <<-EOF\n\tpytest\n\tEOF'; do
  ignored "(p1) not a run" "$c"
done
for c in '2>/dev/null pytest' 'make 2>/dev/null test' 'time -p pytest' 'env -i pytest' 'env -u X pytest' \
         'timeout -k 5 300 pytest' 'timeout --signal=KILL 300 pytest' \
         $'cat <<EOF\nnotes\nEOF\npytest -q'; do
  counts "(p2) a real run" "$c"
done
# The command -c names is not read, so it is never a check.
ignored "(p2) npx -c" 'npx -c "vitest run"'
printf '{ "runner": { "test_cmd": "bin/suite --fast" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" counts "(p3) test_cmd behind a named wrapper" 'aws-vault exec p -- bin/suite --fast'
PROJ_DIR="$PROJ" counts "(p3) test_cmd with a redirection between its words" 'bin/suite 2>/dev/null --fast'
python3 -c 'import json; print(json.dumps({"runner": {"test_cmd": "a= " * 32500 + "bin/suite"}}))' \
  > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" budget_case "a long test_cmd against a long command" '"a= " * 65000 + "true"'

printf '\n%s== round 4: other spaces, non-run modes, env forms, later targets ==%s\n' "$DIM" "$RESET"

# Any whitespace separates words, and no character stops the reader.
for expr in '"git commit -m x y 2>&1"' '"printf \x27%s\\n\x27 hello world"' \
            '"echo a b 2>&1"' '"echo a　b > x"' '"echo a\vb 2>&1"' '"echo a\fb 2>&1"'; do
  ignored "(q1) an unusual space, not a run" "$(python3 -c "print($expr, end='')")"
done
counts "(q1) an unusual space between words" "$(python3 -c 'print("pytest -q 2>&1", end="")')"
# Modes of a runner that inspect instead of running.
for c in 'ruff rule F401' 'ruff config' 'ruff format .' 'pytest --markers' 'pytest --fixtures' \
         'pytest --collect-only' 'pytest --co' 'jest --clearCache' 'jest --listTests'; do
  ignored "(q2) not a run" "$c"
done
counts "(q2) ruff format --check is a check" 'ruff format --check .'
for c in '/usr/bin/env make test' 'env -- make test' 'mvn clean test' './gradlew clean test' \
         './gradlew :app:test' 'make -C app test' 'yarn -s test' 'npx --no-install jest'; do
  counts "(q3) a real run" "$c"
done
ignored "(q3) a target after -- belongs to the program" 'cargo run -- test'

printf '\n%s== targets: first word for subcommand tools, no option values ==%s\n' "$DIM" "$RESET"
for c in './gradlew build -x test' 'gradle build -x test' './gradlew assemble -x check' \
         'go build -o test ./cmd/server' 'go build -tags test ./...' 'cargo run --bin check' \
         'cargo build --features test' 'dotnet run --project test' 'make -C test build' \
         'bazel build //app:test' 'just --justfile check build' 'task -d test build' \
         'swift build --product test' 'go mod why test'; do
  ignored "(r1) not a run" "$c"
done
for c in 'cargo +nightly test' 'go -C app test ./...' 'bazel test //app:test' 'just -f ci.just check'; do
  counts "(r2) a real run" "$c"
done
for c in 'python -m ruff rule F401' 'python3 -m ruff check --show-files' 'ruff check --show-settings'; do
  ignored "(r3) not a run" "$c"
done
for c in 'python3 -u -m pytest -q' 'python -X dev -W error -m pytest' 'bash -e tests/test-verify-gate.sh' \
         'sh -o errexit tests/test-a.sh'; do
  counts "(r4) interpreter options before a real run" "$c"
done
for c in 'bash -n tests/test-a.sh' 'sh -n tests/test-a.sh' 'bash --noexec tests/test-a.sh' 'bash -en tests/test-a.sh'; do
  ignored "(r5) parse only, not a run" "$c"
done
for c in 'bash -euo pipefail tests/test-a.sh' 'bazel --output_base /tmp/bazel test //...'; do
  counts "(r6) a real run" "$c"
done
printf '{ "runner": { "test_cmd": "/usr/bin/make test" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ignored "(q4) test_cmd with a dry-run option" '/usr/bin/make test -n -f /dev/stdin'
# A raw argv is one program; its arguments keep their boundaries.
R=$(mk 'turn:t1' 'ranv:0:git commit -m Fix\ gate\ (pytest)')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } && ok "(p4) a raw argv whose argument holds (pytest) → sent back" \
  || fail "(p4) raw argv parenthesis" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ranv:0:/bin/echo (pytest)')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } && ok "(p4) /bin/echo (pytest) as a raw argv → sent back" \
  || fail "(p4) raw argv echo" "rc=$RC out=$OUT"

printf '\n%s== the turn boundary is this turn ==%s\n' "$DIM" "$RESET"

R=$(mk 'turn:t1' 'ran:0:bash tests/test-codex-verify-gate.sh' 'turn:t2' 'ran:0:ls')
fire "$CLAIM" "$R" t2
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(f1) a check from a PREVIOUS turn does not satisfy this turn's PASS" \
  || fail "(f1) stale check counted" "rc=$RC out=$OUT"
fire "$CLAIM" "$R" t1
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(f2) the payload's turn_id selects the turn: judged as t1, the check counts" \
  || fail "(f2) turn_id selection" "rc=$RC out=$OUT"
fire "$CLAIM" "$R" unknown-turn
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(f3) an unknown turn_id falls back to the last turn in the log (t2, no check)" \
  || fail "(f3) turn fallback" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ran:0:ls' 'turn:t2' 'ran:0:bash tests/test-a.sh')
fire "$CLAIM" "$R" unknown-turn
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(f4) the fallback turn is the last marked one, and its check counts" \
  || fail "(f4) fallback with check" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ran:0:bash tests/test-a.sh' 'ctx')
fire "$CLAIM" "$R" unknown-turn
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(f5) a turn_context with no turn_id is not a new turn, even in the fallback" \
  || fail "(f5) bare turn_context" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'ran:0:bash tests/test-a.sh' 'turn:t1' 'ran:0:ls')
fire "$CLAIM" "$R" unknown-turn
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(f6) the same turn's marker re-emitted after a compaction is not a new turn" \
  || fail "(f6) compaction marker" "rc=$RC out=$OUT"
R=$(mk 'turn:t1' 'turn:t2' 'late:t1:0:npm test')
fire "$CLAIM" "$R" t2
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(f7) a record that names an earlier turn, written after this turn's marker → not this turn → sent back" \
  || fail "(f7) late record, matched id" "rc=$RC out=$OUT"
fire "$CLAIM" "$R" unknown-turn
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(f8) the same on the fallback path → sent back" \
  || fail "(f8) late record, fallback" "rc=$RC out=$OUT"

printf '\n%s== it speaks once, to the agent, and never to the person ==%s\n' "$DIM" "$RESET"

R=$(mk 'turn:t1' 'ran:0:ls')
fire "$CLAIM" "$R" t1 true
{ [[ $RC -eq 0 ]] && silent; } \
  && ok "(g) stop_hook_active (the continuation it asked for) → silent; it cannot loop" \
  || fail "(g) loop guard" "rc=$RC out=$OUT"
python3 -c 'import json,sys; print(json.dumps({"session_id":"s","turn_id":"t1","transcript_path":sys.argv[1],"cwd":"/p","hook_event_name":"Stop","model":"m","permission_mode":"default","stop_hook_active":"false","last_assistant_message":sys.argv[2]}))' "$R" "$CLAIM" > "$TMP/in"
bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; rc=$?
{ [[ $rc -eq 0 ]] && grep -q '"decision": "block"' "$TMP/out"; } \
  && ok "(g2) stop_hook_active as the string \"false\" is not active → sent back" \
  || fail "(g2) string false" "rc=$rc out=$(cat "$TMP/out")"

fire "$CLAIM" null
{ [[ $RC -eq 0 ]] && silent; } && ok "(h1) transcript_path null → silent" \
  || fail "(h1) null transcript" "rc=$RC out=$OUT"
fire "$CLAIM" "$TMP/does-not-exist.jsonl"
{ [[ $RC -eq 0 ]] && silent; } && ok "(h2) transcript_path missing on disk → silent" \
  || fail "(h2) missing transcript" "rc=$RC out=$OUT"
fire null "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(h3) last_assistant_message null → silent" \
  || fail "(h3) null message" "rc=$RC out=$OUT"
printf 'not json at all' > "$TMP/in"
bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; rc=$?
{ [[ $rc -eq 0 && ! -s "$TMP/out" && ! -s "$TMP/err" ]]; } && ok "(h4) a garbage payload → silent, exit 0" \
  || fail "(h4) garbage payload" "rc=$rc out=$(cat "$TMP/out")"

ORCH_DISABLED_HOOKS=codex-verify-gate fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(i1) ORCH_DISABLED_HOOKS names it → silent" \
  || fail "(i1) disabled" "rc=$RC out=$OUT"
ORCH_HOOK_PROFILE=minimal fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent; } && ok "(i2) the minimal profile → silent" \
  || fail "(i2) minimal profile" "rc=$RC out=$OUT"
ORCH_HOOK_DRY_RUN=1 fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && silent && printf '%s' "$ERR" | grep -q 'orch-dry-run\[codex-verify-gate\]'; } \
  && ok "(i3) a dry run reports on stderr and sends nothing" \
  || fail "(i3) dry run" "rc=$RC out=$OUT err=$ERR"

NOTE=$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("c", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.NOTE)' \
  "$ROOT/scripts/lib/orch-completion-check.py")
fire "$CLAIM" "$R"
REASON=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))')
[[ "$REASON" == "$NOTE" ]] && ok "(j) the reason handed to the agent is the Claude check's note, byte for byte" \
  || fail "(j) same note on both harnesses" "codex='$REASON' claude='$NOTE'"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(d)=={"decision","reason"}, d' 2>/dev/null \
  && ok "(j2) the output carries only decision and reason (Codex rejects unknown fields)" \
  || fail "(j2) output shape" "$OUT"

printf '\n%s== invariants over every fixture ==%s\n' "$DIM" "$RESET"
(( ANY_RC == 0 ))     && ok "no fixture made the hook exit non-zero" \
  || fail "the hook exited non-zero" "a hook that can fail the turn is worse than one that says less"
(( ANY_PERSON == 0 )) && ok "no fixture printed a systemMessage: the person is never the audience" \
  || fail "the hook addressed the person" "it emitted systemMessage"
(( ANY_ERR == 0 ))    && ok "no fixture wrote to stderr outside a dry run" \
  || fail "the hook wrote to stderr" "stderr reaches the person's terminal"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-codex-verify-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-codex-verify-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
