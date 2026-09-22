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
#   result:<id>:ok|error     the matching tool_result (is_error false/true)
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
ANY_RC=0; ANY_BLOCK=0; RC=0; ERR=""
fire() { # fire <last_assistant_message> <transcript> → sets RC and ERR
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop",
"session_id":"vg","last_assistant_message":sys.argv[1],"transcript_path":sys.argv[2]}))' \
    "$1" "$2" > "$TMP/in"
  bash "$HOOK" < "$TMP/in" > "$TMP/out" 2> "$TMP/err"; RC=$?
  ERR=$(cat "$TMP/err")
  [[ $RC -ne 0 ]] && ANY_RC=1
  grep -q '"decision"' "$TMP/out" && ANY_BLOCK=1
  return 0
}
warned() { printf '%s' "$ERR" | grep -q 'no check ran and passed'; }

CLAIM='Changed:
- scripts/hooks/orch-verify-gate.sh:1 — rewrote the gate.

Verification: PASS — the suite is green.'

printf '%s== the explicit PASS label, and only it, is checked ==%s\n' "$DIM" "$RESET"

# (a) PASS claimed, but the only command in the turn was not a check.
T=$(mk 'user:tidy the hook' 'bash:t1:ls -la scripts/hooks' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 ]] && warned; } \
  && ok "(a) PASS with no check in the turn → warns on stderr, exit 0" \
  || fail "(a) PASS with no check" "rc=$RC err=$ERR"

# (b) PASS claimed and a real check ran and succeeded → nothing to say.
T=$(mk 'user:fix the gate' 'bash:t1:bash tests/test-verify-gate.sh' 'result:t1:ok')
fire "$CLAIM" "$T"
{ [[ $RC -eq 0 && -z "$ERR" ]]; } \
  && ok "(b) PASS with a passing check in the turn → silent, exit 0" \
  || fail "(b) PASS with a passing check" "rc=$RC err=$ERR"

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

printf '\n%s== it warns; it never blocks ==%s\n' "$DIM" "$RESET"
(( ANY_RC == 0 ))    && ok "no fixture made the hook exit non-zero" \
  || fail "the hook exited non-zero" "a warn-only gate must always exit 0"
(( ANY_BLOCK == 0 )) && ok "no fixture made the hook print a decision" \
  || fail "the hook printed a decision" "it emitted blocking JSON on stdout"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-verify-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-verify-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
