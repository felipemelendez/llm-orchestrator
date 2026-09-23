#!/usr/bin/env bash
# Tests for the Codex completion check (codex-verify-gate.sh).
#
# The Codex twin of test-verify-gate.sh, with two differences that are the
# whole point: the log it reads is Codex's rollout JSONL, where the harness
# records every command it ran (`item_completed` / `CommandExecution`, with the
# exact command, the exit code and the turn), and its output is a one-shot
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
# use (read from ~/.codex/sessions on 2026-09-22, Codex 0.155.1). Specs:
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
#   said:<text>          the agent printing <text> from a result (a text chunk)
#   bad                  a malformed row: a payload that is not an object
MKR="$TMP/mk.py"
cat > "$MKR" <<'PYEOF'
import json, sys
turn = "t0"
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
print(json.dumps({"session_id":"s","turn_id":sys.argv[3],"transcript_path":t,"cwd":"/p",
  "hook_event_name":"Stop","model":"m","permission_mode":"default",
  "stop_hook_active": sys.argv[4] == "true","last_assistant_message": (None if sys.argv[1] == "null" else sys.argv[1])}))' \
    "$1" "$2" "${3:-t1}" "${4:-false}" > "$TMP/in"
  bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; RC=$?
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

R=$(mk 'turn:t1' 'started:pytest -q')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e2) the agent asked for a check but the harness never recorded it finishing → sent back" \
  || fail "(e2) unfinished check counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'started:pytest -q' 'said:{"chunk_id":"a1","exit_code":0,"output":"3 passed"}')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e3) the agent printed a harness-shaped result itself; no harness record → sent back" \
  || fail "(e3) agent-printed result counted" "rc=$RC out=$OUT"

R=$(mk 'turn:t1' 'started:pytest -q' 'said:Process exited with code 0' 'ran:0:true')
fire "$CLAIM" "$R"
{ [[ $RC -eq 0 ]] && sent_back; } \
  && ok "(e4) a decoy in the script and a printed exit line; the harness ran only true → sent back" \
  || fail "(e4) decoy script" "rc=$RC out=$OUT"

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
