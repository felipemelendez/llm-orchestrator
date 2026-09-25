#!/usr/bin/env bash
# Tests for the completion check Stop hook (orch-verify-gate.sh).
#
# The hook it tests was rewritten: it warns and NEVER blocks, it reads only the
# explicit `Verification:` label (never the reply's prose), and it decides from
# the transcript whether a check actually ran and succeeded in THIS turn.
# The case that matters most is (c): the old gate searched the prose for
# phrases like "tests pass", so an audit QUOTING a passing result was treated
# as claiming one, and the audit got blocked for citing its own evidence.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-verify-gate.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# A skipped suite is NOT a passed suite: smoke.sh greps the `PASS:` prefix, so
# printing PASS on a skip would read as green in exactly the environment where
# the hook is weakest. Under ORCH_REQUIRE_DEPS=1 (CI) a missing dep is fatal.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"; exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"; exit 0
}
command -v python3 >/dev/null 2>&1 || skip_suite test-verify-gate 'python3 unavailable'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Transcript fixtures: one JSON object per line. Specs are
#   user:<text>              a real user turn (message.content is a plain string)
#   bash:<id>:<command>      an assistant tool_use block for Bash
#   bgbash:<id>:<command>    the same with run_in_background: true
#   result:<id>:ok|error     the matching tool_result (is_error false/true)
#   ack:<id>                 a tool_result that is Claude Code's own launch
#                            acknowledgement (the harness backgrounded the command)
MKT="$TMP/mk.py"
cat > "$MKT" <<'PYEOF'
import json, sys
with open(sys.argv[1], 'w') as out:
    for spec in sys.argv[2:]:
        kind, _, rest = spec.partition(':')
        if kind == 'user':
            entry = {'type': 'user', 'message': {'role': 'user', 'content': rest}}
        elif kind == 'bash':
            tid, _, cmd = rest.partition(':')
            entry = {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': tid, 'name': 'Bash', 'input': {'command': cmd}}]}}
        elif kind == 'bgbash':
            tid, _, cmd = rest.partition(':')
            entry = {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': tid, 'name': 'Bash', 'input': {'command': cmd, 'run_in_background': True}}]}}
        elif kind == 'ack':
            entry = {'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': rest, 'is_error': False,
                 'content': 'Command running in background with ID: 123. Output is being written to: /tmp/123.output'}]}}
        elif kind == 'result':
            tid, _, state = rest.partition(':')
            entry = {'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': tid, 'is_error': state == 'error'}]}}
        else:
            raise SystemExit('unknown spec: ' + spec)
        out.write(json.dumps(entry) + '\n')
PYEOF

mk() { # mk <spec>... → transcript path
  local f="$TMP/t.$$.$RANDOM.jsonl"
  python3 "$MKT" "$f" "$@" && printf '%s' "$f"
}

# Every fire is also an invariant sample: the hook must never exit non-zero and
# never emit a `decision` on stdout. A gate that can block is the thing removed.
ANY_RC=0; ANY_BLOCK=0; ANY_STDERR=0; RC=0; ERR=""
fire() { # fire <last_assistant_message> <transcript> → sets RC and ERR
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop",
"session_id":"vg","last_assistant_message":sys.argv[1],"transcript_path":sys.argv[2]}))' \
    "$1" "$2" > "$TMP/in"
  # The project whose cadence.json may name a test_cmd; none unless PROJ_DIR is set.
  CLAUDE_PROJECT_DIR="${PROJ_DIR:-$TMP/no-project}" bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; RC=$?
  ERR=$(cat "$TMP/err")
  [[ -n "$ERR" ]] && ANY_STDERR=1
  [[ $RC -ne 0 ]] && ANY_RC=1
  grep -q '"decision"' "$TMP/out" && ANY_BLOCK=1
  return 0
}
# The note is delivered as additionalContext for the model, and only there.
warned() { grep -q 'additionalContext' "$TMP/out" && grep -q 'no check ran and passed' "$TMP/out"; }

CLAIM='Changed:
- scripts/hooks/orch-verify-gate.sh:1 — rewrote the gate.

Verification: PASS — the suite is green.'

printf '%s== the explicit PASS label, and only it, is checked ==%s\n' "$DIM" "$RESET"

# (a) PASS claimed, but the only command in the turn was not a check.
T=$(mk 'user:tidy the hook' 'bash:t1:ls -la scripts/hooks' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(a) PASS with no check in the turn → a note for the model, exit 0" \
  || fail "(a) PASS with no check" "rc=$RC err=$ERR"

# (b) PASS claimed and a real check ran and succeeded → nothing to say.
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && -z "$ERR" && ! -s "$TMP/out" ]]; } \
  && ok "(b) PASS with a passing check in the turn → silent, exit 0" \
  || fail "(b) PASS with a passing check" "rc=$RC err=$ERR out=$(cat "$TMP/out")"

# (b2) A check that was started and never finished is not a passed check.
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(b2) a check with no result in the transcript (interrupted or still running) → note" \
  || fail "(b2) unfinished check counted" "rc=$RC out=$(cat "$TMP/out")"

# (c) THE REGRESSION. An audit QUOTING a passing result is not claiming one.
# The old gate read prose, so this reply was blocked for citing its evidence.
QUOTED='Found:
- docs/MEASUREMENTS.md records 200 runs: warn and block both scored 100/100.
- The report says the tests pass, and it is not itself making that claim.'
T=$(mk 'user:audit the measurements')
fire "$QUOTED" "$T"
{ [[ $RC -eq 0 && -z "$ERR" ]]; } \
  && ok "(c) prose quoting \"tests pass\" / \"100/100\" with no label → silent" \
  || fail "(c) quoted evidence treated as a claim" "rc=$RC err=$ERR"

# (d) Any verdict other than PASS, and no label at all, are both none of the
# hook's business — PENDING is the honest answer it tells people to give.
T=$(mk 'user:start the port')
fire 'Status: PARTIAL

Verification: PENDING — the device is unavailable.' "$T"
{ [[ $RC -eq 0 && -z "$ERR" ]]; } && ok "(d1) Verification: PENDING → silent" \
  || fail "(d1) PENDING" "rc=$RC err=$ERR"
fire 'Changed:
- README.md:4 — a typo.' "$T"
{ [[ $RC -eq 0 && -z "$ERR" ]]; } && ok "(d2) no Verification: label at all → silent" \
  || fail "(d2) no label" "rc=$RC err=$ERR"

# (b3)/(b4) A launch is not a finish. Two harness facts say "launch": the
# call asked for run_in_background, or the harness backgrounded it itself and
# wrote its launch acknowledgement as the result. Neither is read from the
# command's text.
T=$(mk 'user:fix the gate' 'bgbash:t1:npm test' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(b3) a Bash call with run_in_background: a launch is not a finished check → note" \
  || fail "(b3) background launch" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh' 'ack:t1')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(b4) a result that is Claude Code's launch acknowledgement is a start, not a finish → note" \
  || fail "(b4) launch acknowledgement counted" "rc=$RC out=$(cat "$TMP/out")"

# (b5)-(b9) Honest shapes stay silent. The check reads the harness's record
# and splits the text on operators; it does not read shell syntax, so none of
# these ordinary forms can be mistaken for "no run".
T=$(mk 'user:fix the gate' 'bash:t1:cd repo && npm test && echo ok' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } \
  && ok "(b5) an && list around a real check → silent" \
  || fail "(b5) and-list" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' 'bash:t1:npm test > check.log 2>&1' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } \
  && ok "(b6) a check with 2>&1 → silent" \
  || fail "(b6) fd redirection" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' "bash:t1:python3 tests/test-pass.py && printf '%s\\n' 'A&B'" 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } \
  && ok "(b7) a check followed by a quoted ampersand → silent" \
  || fail "(b7) quoted ampersand" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' "bash:t1:bash tests/test-pass.sh 'one
two'" 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } \
  && ok "(b8) a check with a multi-line quoted argument → silent" \
  || fail "(b8) multi-line argument" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' "bash:t1:cat <<< 'hello'
python3 tests/test-pass.py" 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } \
  && ok "(b9) a here-string, then a check on the next line → silent" \
  || fail "(b9) here-string" "rc=$RC out=$(cat "$TMP/out")"

# (b10) A reply padded with blank lines must not take the hook past its time
# limit: the fence rule scans each line once. 20 000 whitespace-only lines took
# seven seconds with the old `^\s*`; the budget is ten.
PADDED=$(python3 -c 'print("    \n" * 20000 + "Verification: PASS", end="")')
T=$(mk 'user:tidy the hook' 'bash:t1:ls' 'result:t1:ok')
START=$(python3 -c 'import time; print(time.time())')
fire "$PADDED" "$T"
ELAPSED=$(python3 -c 'import time,sys; print(time.time()-float(sys.argv[1]))' "$START")
{ [[ $RC -eq 0 ]] && warned && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 else 1)' "$ELAPSED"; } \
  && ok "(b10) 20000 blank lines before the label: judged in ${ELAPSED%.*}s, the note still sent" \
  || fail "(b10) padded reply time" "rc=$RC elapsed=$ELAPSED out=$(cat "$TMP/out")"

# (e) A check the harness reported as failed is not a check that passed.
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh' 'result:t1:error')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(e) a check that ran and FAILED does not count as a check" \
  || fail "(e) failed check counted" "rc=$RC err=$ERR"

# (f) The turn boundary is the last real user message: a check from an earlier
# turn is stale, and staleness counted as passing is the catastrophic class.
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh' 'result:t1:ok' \
       'user:now write the summary')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(f) a check from a PREVIOUS turn does not satisfy this turn's PASS" \
  || fail "(f) stale check counted" "rc=$RC err=$ERR"

printf '\n%s== real test commands count; printing does not ==%s\n' "$DIM" "$RESET"

# counts <label> <command>: a finished, passing run of <command> satisfies PASS.
counts() {
  local T; T=$(mk 'user:fix the gate' "bash:t1:$2" 'result:t1:ok')
  fire "$CLAIM" "$T"
  { [[ $RC -eq 0 && ! -s "$TMP/out" ]]; } && ok "$1: $2 → silent" \
    || fail "$1: $2 should count as a check" "rc=$RC out=$(cat "$TMP/out")"
}
# ignored <label> <command>: a passing run of <command> is not a check.
ignored() {
  local T; T=$(mk 'user:fix the gate' "bash:t1:$2" 'result:t1:ok')
  fire "$CLAIM" "$T"
  { [[ $RC -eq 0 ]] && warned; } && ok "$1: $2 → note" \
    || fail "$1: $2 should not count as a check" "rc=$RC out=$(cat "$TMP/out")"
}

counts  "(k1) a runner named by a path" '.ve/bin/pytest zapgram/src/zg/test/unit'
counts  "(k1)" './node_modules/.bin/vitest run'
counts  "(k1)" 'venv/bin/pytest -q'
counts  "(k1)" '.ve/bin/python -m pytest -q'
counts  "(k2) a path-named runner after cd" 'cd zapgram && .ve/bin/pytest src/zg/test/unit'
counts  "(k3) a runner after a wrapper that ends its options with --" \
        'aws-vault exec --prompt=osascript testing-felipe -- .ve/bin/pytest src/zg/test/unit'
counts  "(k3)" 'cd zapgram && aws-vault exec --prompt=osascript testing-felipe -- pytest -q'
counts  "(k4) a runner through the package manager" 'pnpm vitest run'
counts  "(k4)" 'pnpm jest'
counts  "(k4)" 'yarn vitest run'
counts  "(k4)" 'yarn jest --ci'
counts  "(k4)" 'npx vitest run'
counts  "(k4)" 'npx jest'
ignored "(k5) a command that only prints" 'echo pytest'
ignored "(k5)" 'echo .ve/bin/pytest'
ignored "(k5) a runner's version, behind a wrapper" 'aws-vault exec testing-felipe -- .ve/bin/pytest --version'
ignored "(k5) a path after git's --" 'git diff -- tests/test-verify-gate.sh'
ignored "(k5) a config file after git's --" 'git diff -- pytest.ini'
ignored "(k5) installing a runner" 'pnpm add -D vitest'

printf '\n%s== the project'"'"'s own test_cmd counts ==%s\n' "$DIM" "$RESET"

# A project whose cadence.json names a test command the shared pattern does
# not know.
PROJ="$TMP/project"; mkdir -p "$PROJ/docs/llm-orchestrator"
printf '{ "schema": 1, "enabled": true,\n  "runner": { "profile": "custom", "test_cmd": "bin/suite --fast" } }\n' \
  > "$PROJ/docs/llm-orchestrator/cadence.json"
ignored "(l1) no cadence.json: a command the pattern does not know" 'bin/suite --fast unit'
PROJ_DIR="$PROJ" counts  "(l2) it starts with runner.test_cmd" 'bin/suite --fast unit'
PROJ_DIR="$PROJ" counts  "(l2)" 'bin/suite --fast'
PROJ_DIR="$PROJ" counts  "(l2) after cd" 'cd sub && bin/suite --fast'
PROJ_DIR="$PROJ" ignored "(l3) the same text continuing into another word" 'bin/suite --fastest'
PROJ_DIR="$PROJ" ignored "(l3) the text in the middle of a command" 'echo bin/suite --fast'
PROJ_DIR="$PROJ" ignored "(l3) test_cmd asked only for its help" 'bin/suite --fast --help'
T=$(mk 'user:fix the gate' 'bash:t1:bin/suite --fast' 'result:t1:error')
PROJ_DIR="$PROJ" fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } && ok "(l4) test_cmd that FAILED does not count" \
  || fail "(l4) failed test_cmd counted" "rc=$RC out=$(cat "$TMP/out")"
T=$(mk 'user:fix the gate' 'bgbash:t1:bin/suite --fast' 'result:t1:ok')
PROJ_DIR="$PROJ" fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } && ok "(l4) test_cmd launched in the background does not count" \
  || fail "(l4) background test_cmd counted" "rc=$RC out=$(cat "$TMP/out")"
# A test_cmd that holds its own operators is matched against the whole command.
printf '{ "runner": { "test_cmd": "cd app && ./check" } }\n' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" counts  "(l5) a test_cmd with && in it" 'cd app && ./check -q'
# An unreadable cadence.json is the same as none.
printf '{ not json' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ignored "(l6) a cadence.json that is not JSON: as if there were none" 'bin/suite --fast'
PROJ_DIR="$PROJ" counts  "(l6)" 'pytest -q'

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
# pattern; it does not switch the whole check off.
python3 -c 'print("[" * 100000)' > "$PROJ/docs/llm-orchestrator/cadence.json"
PROJ_DIR="$PROJ" ignored "(m5) a cadence.json too deep to read: the check still runs" 'ls -la'

printf '\n%s== it warns; it never blocks ==%s\n' "$DIM" "$RESET"
(( ANY_RC == 0 ))    && ok "no fixture made the hook exit non-zero" \
  || fail "the hook exited non-zero" "a warn-only gate must always exit 0"
(( ANY_BLOCK == 0 )) && ok "no fixture made the hook print a decision" \
  || fail "the hook printed a decision" "it emitted blocking JSON on stdout"
(( ANY_STDERR == 0 )) && ok "no fixture wrote to stderr: the note is for the model, not the person" \
  || fail "the hook wrote to stderr" "the person's transcript view would show it"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-verify-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-verify-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
