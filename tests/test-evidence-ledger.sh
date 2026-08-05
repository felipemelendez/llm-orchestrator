#!/usr/bin/env bash
# Tests for the evidence-ledger PostToolUse hook (orch-evidence-ledger.sh) and
# the shared validator/window helpers (scripts/lib/orch-evidence.sh).
#
# The input fixtures encode the REAL platform contract, verified live against
# Claude Code v2.1.220 on 2026-07-28:
#   - PostToolUse fires ONLY when the tool call succeeds (a failing Bash
#     command emits PostToolUseFailure), so a firing event implies exit 0;
#   - tool_response = {stdout, stderr, interrupted, isImage, noOutputExpected}
#     — there is NO exit-code field.
#
# The hook is APPEND-ONLY by default: it records to the ledger and emits no
# stdout at all, so it cannot modify or destroy tool output. ORCH_EVIDENCE_MARKER=1
# restores an inert (non-imperative) marker for cross-agent evidence transport.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-evidence-ledger.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# A skipped suite is NOT a passed suite. This used to print `PASS: <name>
# (skipped — ...)`, and smoke.sh greps the `PASS:` prefix, so a missing
# dependency read as green — in precisely the environment where orch-json.sh
# degrades and the guards are weakest. Under ORCH_REQUIRE_DEPS=1 (set in CI) a
# missing dependency is a hard failure instead: CI is the instrument every
# other claim is measured on, so it must never quietly under-run.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}


command -v python3 >/dev/null 2>&1 || skip_suite test-evidence-ledger 'python3 unavailable'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/home"

# event <command> [stdout] [agent_id] — a REAL-shape PostToolUse event on stdout
event() {
  python3 -c "
import json, sys
d = {'session_id': 'ev-test', 'hook_event_name': 'PostToolUse', 'tool_name': 'Bash',
     'tool_input': {'command': sys.argv[1]},
     'tool_response': {'stdout': sys.argv[2], 'stderr': '', 'interrupted': False,
                       'isImage': False, 'noOutputExpected': False}}
if sys.argv[3]:
    d['agent_id'] = sys.argv[3]
print(json.dumps(d))" "$1" "${2-ok}" "${3:-}"   # ${2-ok}: an explicitly EMPTY stdout stays empty
}
fire()        { event "$@" | bash "$HOOK"; }
fire_marker() { event "$@" | ORCH_EVIDENCE_MARKER=1 bash "$HOOK"; }

# A FAILURE event. On this platform Bash's tool_response carries no exit code —
# success and failure are distinguished by WHICH EVENT FIRES — so the failure
# arm needs its own fixture. Without one the entire red path was untested:
# forcing exit_code = 0 there left all 37 ledger checks and all 43 verify-gate
# checks green, which means a verify command that FAILED was recorded as green
# evidence and the completion claim shipped. That is Layer 7 inverted.
event_fail() { # <command> [stderr]
  python3 -c "
import json, sys
print(json.dumps({'session_id': 'ev-test', 'hook_event_name': 'PostToolUseFailure',
                  'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]},
                  'tool_response': {'stdout': '', 'stderr': sys.argv[2],
                                    'interrupted': False, 'isImage': False,
                                    'noOutputExpected': False}}))" "$1" "${2:-1 failing}"
}
fire_fail() { event_fail "$@" | bash "$HOOK"; }
ledger()  { cat "$ORCH_HOME"/state/*/evidence.ev-test.tsv 2>/dev/null; }
mutexmap(){ cat "$ORCH_HOME"/state/*/mutex-map.ev-test.tsv 2>/dev/null; }

printf '%s== append-only by default: records, emits nothing ==%s\n' "$DIM" "$RESET"
OUT=$(fire "npm test" "142 passed")
[[ -z "$OUT" ]] && ok "verify command emits NO stdout (cannot modify tool output)" || fail "append-only" "out=$OUT"
if ledger | grep -qE '^[0-9a-f]{12}	0	[0-9]+	ok	npm test$'; then
  ok "ledger row recorded: stamp, exit 0, epoch, substance=ok, command"
else fail "ledger row" "$(ledger)"; fi
STAMP=$(ledger | head -1 | cut -f1)

printf '\n%s== a FAILED verify run must record as failed, never as green ==%s\n' "$DIM" "$RESET"
# Mutation-found gap: forcing the failure arm's exit_code to 0 left every check
# in this file AND in test-verify-gate.sh green. The ledger is the only thing
# standing between "the model says it verified" and "a verify command actually
# ran green this turn", so recording a red run as green defeats the layer
# outright — the gate then confirms a completion claim the run refutes.
fire_fail "npm test" "1 failing" >/dev/null
if ledger | grep -qE '	1	[0-9]+	red	npm test$'; then
  ok "PostToolUseFailure records exit 1 with substance=red"
else
  fail "failed run recorded as failed" "ledger rows: $(ledger | tail -3 | tr '\n' '|')"
fi
if ledger | grep -E 'npm test$' | grep -qE '	0	[0-9]+	(ok|none)	npm test$' \
   && ! ledger | grep -qE '	1	[0-9]+	red	npm test$'; then
  fail "failed run recorded as green" "a red run produced a green ledger row"
else
  ok "no green row was manufactured for the failed run"
fi
# A non-verify command that fails must still record nothing.
before_nv=$(ledger | wc -l | tr -d ' ')
fire_fail "git add tests/x.sh" "fatal: pathspec" >/dev/null
after_nv=$(ledger | wc -l | tr -d ' ')
[[ "$before_nv" == "$after_nv" ]] && ok "a failed NON-verify command records nothing" \
  || fail "non-verify failure recorded" "rows went $before_nv -> $after_nv"

printf '\n%s== REGRESSION: a quoted pipe is an argument, not an invocation ==%s\n' "$DIM" "$RESET"
# `grep -rn "tsc|eslint" pkg.json` used to be classified as a typecheck run and
# recorded as PASSING verification — the ledger manufacturing the fabrication it
# exists to prevent.
before=$(ledger | wc -l | tr -d ' ')
fp_ok=1
for cmd in \
  'grep -rn "tsc|eslint" package.json' \
  'grep -rn "vitest|jest" .' \
  'rg "npm run test|pytest" src/' \
  'git commit -m "chore: silence eslint|mypy noise"' \
  "echo 'ruff check'"; do
  OUT=$(fire "$cmd" "some matches")
  [[ -z "$OUT" ]] || { fp_ok=0; fail "quoted-pipe" "'$cmd' emitted output"; }
done
after=$(ledger | wc -l | tr -d ' ')
if [[ "$fp_ok" == "1" && "$before" == "$after" ]]; then
  ok "greps whose PATTERN contains a pipe + tool name record NOTHING"
else fail "quoted-pipe ledger" "rows went $before → $after: $(ledger)"; fi

printf '\n%s== substance: exit 0 is not proof that anything was verified ==%s\n' "$DIM" "$RESET"
fire "npm test" "Test run with 0 tests in 0 suites passed." >/dev/null
ledger | grep -q '	none	' && ok "zero-test green run recorded substance=none" || fail "substance none" "$(ledger)"
fire "pytest -q" "collected 0 items" >/dev/null
[[ $(ledger | grep -c '	none	') -ge 2 ]] && ok "pytest 'collected 0 items' recorded substance=none" || fail "pytest none" "$(ledger)"
fire "pytest -q" "5 passed, 0 failed in 0.4s" >/dev/null
ledger | grep -q '	ok	pytest -q$' && ok "'5 passed, 0 failed' is NOT mistaken for a zero-test run" || fail "substance ok" "$(ledger)"
# Silence is SUCCESS for tsc and eslint — both named in the verify-command regex
# itself. Calling an empty-but-green run "verified nothing" put a false note on
# every clean typecheck, which is the fire-when-we-know-nothing behaviour the
# gate exists to avoid.
fire "tsc --noEmit" "" >/dev/null
ledger | grep -q '	ok	tsc --noEmit$' && ok "tsc with no output → substance=ok, not a false 'verified nothing'" || fail "tsc silent" "$(ledger)"
fire "eslint ." "" >/dev/null
ledger | grep -q '	ok	eslint .$' && ok "eslint with no output → substance=ok" || fail "eslint silent" "$(ledger)"

printf '\n%s== REGRESSION: multi-line commands are classified too ==%s\n' "$DIM" "$RESET"
# The verify regex anchors a command position on `(^|[;&|])`, but it was
# compiled without re.MULTILINE — so `^` matched only offset 0 and a newline is
# not in that class. A verify tool on line 2+ was invisible, silently exempting
# every multi-line command from the whole mechanism.
before=$(ledger | wc -l | tr -d ' ')
fire 'cd /tmp
npm test' "142 passed" >/dev/null
after=$(ledger | wc -l | tr -d ' ')
[[ "$after" -gt "$before" ]] && ok "a verify command on line 2 of a multi-line command is recorded" || fail "multiline" "rows $before → $after"

printf '\n%s== REGRESSION: a response shape we cannot read is never rewritten ==%s\n' "$DIM" "$RESET"
# A list-shaped (content-block) tool_response used to make the hook emit
# updatedToolOutput carrying ONLY the marker — deleting the command's real output.
OUT=$(python3 -c "
import json
print(json.dumps({'session_id':'ev-shape','hook_event_name':'PostToolUse','tool_name':'Bash',
 'tool_input':{'command':'npm test'},
 'tool_response':[{'type':'text','text':'2178 tests passed'}]}))" | ORCH_EVIDENCE_MARKER=1 bash "$HOOK")
[[ -z "$OUT" ]] && ok "list-shaped response: no rewrite even with the marker ON" || fail "list rewrite" "out=$OUT"
cat "$ORCH_HOME"/state/*/evidence.ev-shape.tsv 2>/dev/null | grep -q '	ok	npm test' \
  && ok "...but it is still classified and recorded in the ledger" || fail "list ledger" "not recorded"
OUT=$(python3 -c "
import json
print(json.dumps({'session_id':'ev-shape2','hook_event_name':'PostToolUse','tool_name':'Bash',
 'tool_input':{'command':'npm test'},
 'tool_response':{'output':'2178 tests passed','interrupted':False}}))" | ORCH_EVIDENCE_MARKER=1 bash "$HOOK")
[[ -z "$OUT" ]] && ok "differently-keyed response: no rewrite (output cannot be lost)" || fail "keyed rewrite" "out=$OUT"

printf '\n%s== opt-in marker is inert: states a fact, issues no instruction ==%s\n' "$DIM" "$RESET"
OUT=$(fire_marker "npm test" "142 passed")
if printf '%s' "$OUT" | grep -q '"updatedToolOutput"' \
   && printf '%s' "$OUT" | grep -qE 'orch-evidence [0-9a-f]{12} exit=0 ok'; then
  ok "ORCH_EVIDENCE_MARKER=1 appends a stamp"
else fail "marker on" "out=$OUT"; fi
if printf '%s' "$OUT" | grep -qi 'cite this line'; then
  fail "marker imperative" "marker still carries an instruction — agents correctly refuse instruction-shaped text in a data channel"
else ok "marker carries NO imperative"; fi
printf '%s' "$OUT" | grep -q '142 passed' && ok "marker preserves the real stdout" || fail "marker preserves" "out=$OUT"

printf '\n%s== command-position anchoring: no stamps for non-verify commands ==%s\n' "$DIM" "$RESET"
anchored_ok=1
# `shellcheck tests/x.sh` is deliberately NOT here: shellcheck is a linter, so a
# real invocation of it is a verification run and belongs in the ledger.
for cmd in "git add tests/smoke.sh" "echo pytest passed" "chmod +x tests/foo.sh" "cat tests/x.sh" "ls -la"; do
  OUT=$(fire_marker "$cmd" "whatever")
  [[ -z "$OUT" ]] || { anchored_ok=0; fail "anchoring" "'$cmd' minted a stamp"; }
done
[[ $anchored_ok -eq 1 ]] && ok "git add/echo/chmod/shellcheck over test paths mint NOTHING"
for cmd in "cd sub && npm test" "pytest -q" "./tests/smoke.sh" "make check"; do
  OUT=$(fire_marker "$cmd" "green")
  printf '%s' "$OUT" | grep -q 'orch-evidence' || fail "anchoring positive" "'$cmd' minted no stamp"
done
ok "real verify invocations (incl. after &&) still mint stamps"

printf '\n%s== turn window: the gate asks the ledger, not the model ==%s\n' "$DIM" "$RESET"
source "${ROOT}/scripts/lib/orch-project.sh"
source "${ROOT}/scripts/lib/orch-evidence.sh"
WDIR=$(orch_evidence_state_dir); mkdir -p "$WDIR"
WL="$WDIR/evidence.win-test.tsv"
NOW=$(date +%s); OLD=$((NOW - 5000))

: > "$WL"
R=$(orch_evidence_window win-test "$NOW"); rc=$?
[[ $rc -eq 2 ]] && ok "no rows in window → rc 2 (soft, gate stays silent)" || fail "window empty" "rc=$rc r=$R"

printf 'aaaa11112222\t0\t%d\tok\tnpm test\n' "$OLD" > "$WL"
R=$(orch_evidence_window win-test "$NOW"); rc=$?
[[ $rc -eq 2 ]] && ok "a green run from an EARLIER turn does not count → rc 2" || fail "window stale" "rc=$rc r=$R"

printf 'bbbb11112222\t0\t%d\tok\tnpm test\n' "$NOW" >> "$WL"
R=$(orch_evidence_window win-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "green run inside the window → rc 0 (silent)" || fail "window green" "rc=$rc r=$R"

printf 'cccc11112222\t1\t%d\tred\tnpm test\n' "$((NOW + 1))" >> "$WL"
R=$(orch_evidence_window win-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "latest run in window FAILED → rc 1 (hard)"
else fail "window red" "rc=$rc r=$R"; fi

printf 'dddd11112222\t0\t%d\tnone\tnpm test\n' "$((NOW + 2))" >> "$WL"
R=$(orch_evidence_window win-test "$NOW"); rc=$?
if [[ $rc -eq 3 ]] && printf '%s' "$R" | grep -q 'no tests'; then
  ok "green-but-zero-tests → rc 3 (soft substance note)"
else fail "window none" "rc=$rc r=$R"; fi

R=$(orch_evidence_window win-test ""); rc=$?
[[ $rc -eq 2 ]] && ok "unknown turn start → rc 2, never a false accusation" || fail "window unknown" "rc=$rc"

printf '\n%s== REGRESSION: a failed COMPOUND is healed via its verify-shaped component ==%s\n' "$DIM" "$RESET"
# Observed live, three times: an integrate chain — `git worktree add … &&
# git merge … && bash tests/run-all.sh 2>&1 | tail -1 && git push … &&
# git worktree remove …` — exited 128 at the worktree-remove step, AFTER the
# suite inside it had passed; `bash tests/run-all.sh` was then re-run
# standalone, green, the same turn. The gate still flagged the reply: red/green
# matching keyed on the whole compound string (runner `git`), so no green could
# ever answer that red. The red row's verification content is its verify-shaped
# COMPONENT, and a later green of that component is what "re-ran it" looks like.
source "${ROOT}/scripts/lib/orch-signals.sh"
CL="$WDIR/evidence.comp-test.tsv"
COMPOUND='git worktree add .worktrees/fix main && git merge --no-ff fix -m msg && bash tests/run-all.sh 2>&1 | tail -1 && git push origin main && git worktree remove .worktrees/fix'

# (a) failed compound + later standalone green of the component → resolved.
printf 'aaaa00000001\t1\t%s\tred\t%s\n' "$NOW" "$COMPOUND" > "$CL"
printf 'aaaa00000002\t0\t%s\tok\tbash tests/run-all.sh\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "failed compound + standalone green of its verify component → rc 0 (healed)" \
  || fail "compound healed by component green" "rc=$rc r=$R"

# (b) failed compound + NO later green → still the hard verdict. The heal must
# not soften the gate's whole point.
printf 'bbbb00000001\t1\t%s\tred\t%s\n' "$NOW" "$COMPOUND" > "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "failed compound with NO later green → rc 1 (hard)"
else fail "compound no-green still warns" "rc=$rc r=$R"; fi

# (c) failed standalone + later green of the SAME command → resolved (the
# behaviour that already existed must survive the componentization).
printf 'cccc00000001\t1\t%s\tred\tbash tests/run-all.sh\n' "$NOW" > "$CL"
printf 'cccc00000002\t0\t%s\tok\tbash tests/run-all.sh\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "failed standalone + green re-run of the same command → rc 0 (unchanged)" \
  || fail "standalone heal regressed" "rc=$rc r=$R"

# (d) precision guard: a green row that merely MENTIONS the component — quoted
# as data, or echoed alongside a different runner — heals nothing. (The real
# ledger writer would not record the grep row at all — quoted spans are blanked
# before classification — but the healing side must apply the same rules
# rather than substring-match the mention.)
printf 'dddd00000001\t1\t%s\tred\t%s\n' "$NOW" "$COMPOUND" > "$CL"
printf 'dddd00000002\t0\t%s\tok\tgrep -c "bash tests/run-all.sh" docs/notes.md\n' "$((NOW + 1))" >> "$CL"
printf 'dddd00000003\t0\t%s\tok\tpytest -q && echo "bash tests/run-all.sh"\n' "$((NOW + 2))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "mention-only greens (quoted grep pattern, echoed string) heal NOTHING → rc 1"
else fail "mention-only green healed a red" "rc=$rc r=$R"; fi

# (e) REGRESSION: a same-runner multi-component red must have EVERY component
# healed. Red `pytest tests/unit -q && pytest tests/integration -q` produces
# two pytest components from one row; keying reds by runner alone let the later
# component overwrite the earlier (last-wins by sort order), so a green of ONLY
# one twin silently resolved the pair — tests/integration never re-ran and the
# gate said nothing. Which twin escaped depended on sort order, so BOTH
# directions are pinned here.
MULTI='pytest tests/unit -q && pytest tests/integration -q'
printf 'eeee00000001\t1\t%s\tred\t%s\n' "$NOW" "$MULTI" > "$CL"
printf 'eeee00000002\t0\t%s\tok\tpytest tests/unit -q\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "multi-component red + green of ONLY the unit leg → rc 1 (integration never re-ran)"
else fail "green unit leg alone resolved a two-leg red" "rc=$rc r=$R"; fi

printf 'eeee00000003\t1\t%s\tred\t%s\n' "$NOW" "$MULTI" > "$CL"
printf 'eeee00000004\t0\t%s\tok\tpytest tests/integration -q\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "multi-component red + green of ONLY the integration leg → rc 1 (mirror direction)"
else fail "green integration leg alone resolved a two-leg red" "rc=$rc r=$R"; fi

printf 'eeee00000005\t1\t%s\tred\t%s\n' "$NOW" "$MULTI" > "$CL"
printf 'eeee00000006\t0\t%s\tok\tpytest tests/unit -q\n' "$((NOW + 1))" >> "$CL"
printf 'eeee00000007\t0\t%s\tok\tpytest tests/integration -q\n' "$((NOW + 2))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "multi-component red + greens of BOTH legs → rc 0 (healed)" \
  || fail "both-leg greens did not heal" "rc=$rc r=$R"

printf 'eeee00000008\t1\t%s\tred\t%s\n' "$NOW" "$MULTI" > "$CL"
printf 'eeee00000009\t0\t%s\tok\tpytest -q\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "multi-component red + one pathless broad green → rc 0 (covers all pytest ground)" \
  || fail "broad green did not heal both legs" "rc=$rc r=$R"

# (f) REGRESSION: a heredoc body in a GREEN row is data being written, not an
# invocation. The ledger stores commands newline-flattened, so the body of
# `cat > notes.sh <<'EOS' … EOS` sits inline — and a `&&` inside that body
# reified a segment anchor, minting `bash tests/run-all.sh …` as a green
# component that healed a genuinely failed suite. (Executed reviewer fixture.)
HD="pytest -q && cat > notes.sh <<'EOS' echo setup && bash tests/run-all.sh EOS"
printf 'ffff00000001\t1\t%s\tred\tbash tests/run-all.sh\n' "$NOW" > "$CL"
printf 'ffff00000002\t0\t%s\tok\t%s\n' "$((NOW + 1))" "$HD" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "a green heredoc BODY mentioning the failed suite heals NOTHING → rc 1"
else fail "heredoc body minted a healing component" "rc=$rc r=$R"; fi

# (g) REGRESSION: a backslash-escaped quote must not derail pair-blanking. In
# `echo "a\" && bash tests/run-all.sh -x"` the naive pair-match closed the
# string at `\"`, leaving the tail unblanked — a quoted MENTION minted a green
# component for a genuinely failed suite. (Executed reviewer fixture.)
EQ='pytest -q && echo "a\" && bash tests/run-all.sh -x"'
printf 'gggg00000001\t1\t%s\tred\tbash tests/run-all.sh\n' "$NOW" > "$CL"
printf 'gggg00000002\t0\t%s\tok\t%s\n' "$((NOW + 1))" "$EQ" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "an escaped-quote string mentioning the failed suite heals NOTHING → rc 1"
else fail "escaped-quote mention minted a healing component" "rc=$rc r=$R"; fi
rm -f "$CL"

# (h) REGRESSION: heredoc truncation is GREEN-ONLY. On a red row, truncating
# at `<<` drops a verify leg that ran AFTER the heredoc — a genuinely failed
# `pytest … && python - <<EOF … EOF && mypy .` was then healed by re-running
# only the pytest leg, a false all-clear. The red side must keep the mypy
# component; healing needs BOTH legs green.
# Fixture fidelity note: the real writer flattens a heredoc BODY after the
# whole operator line (`… <<EOF && mypy . print(1) EOF`), where the red mypy
# component absorbs body words and only a pathless `mypy` green heals —
# the design-accepted spurious-warn direction. This fixture places the body
# first so the healing direction is testable with an exact-args green.
HDRED='pytest tests/x -q && python - <<EOF print(1) EOF && mypy .'
printf 'hhhh00000001\t1\t%s\tred\t%s\n' "$NOW" "$HDRED" > "$CL"
printf 'hhhh00000002\t0\t%s\tok\tpytest tests/x -q\n' "$((NOW + 1))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
if [[ $rc -eq 1 ]] && printf '%s' "$R" | grep -q 'FAILED'; then
  ok "red with post-heredoc mypy leg + green pytest only → rc 1 (mypy never re-ran)"
else fail "post-heredoc red leg was truncated away and healed" "rc=$rc r=$R"; fi

printf 'hhhh00000003\t1\t%s\tred\t%s\n' "$NOW" "$HDRED" > "$CL"
printf 'hhhh00000004\t0\t%s\tok\tpytest tests/x -q\n' "$((NOW + 1))" >> "$CL"
printf 'hhhh00000005\t0\t%s\tok\tmypy .\n' "$((NOW + 2))" >> "$CL"
R=$(orch_evidence_window comp-test "$NOW"); rc=$?
[[ $rc -eq 0 ]] && ok "same red + greens of BOTH legs → rc 0 (healed)" \
  || fail "both-leg greens did not heal the heredoc-bearing red" "rc=$rc r=$R"
rm -f "$CL"

printf '\n%s== cited-stamp validator (secondary path) ==%s\n' "$DIM" "$RESET"
L=$(ls "$ORCH_HOME"/state/*/evidence.ev-test.tsv)
CITED=$(orch_evidence_stamp_of "Verify: npm test → 142 passed [orch-evidence ${STAMP} exit=0]")
[[ "$CITED" == "$STAMP" ]] && ok "orch_evidence_stamp_of extracts the minted stamp" || fail "stamp roundtrip" "cited='$CITED' minted='$STAMP'"
orch_evidence_check "Verify: ok [orch-evidence ${STAMP} exit=0]" "$L" >/dev/null
[[ $? -eq 0 ]] && ok "validator accepts the minted stamp" || fail "validator accept" ""
orch_evidence_check "Verify: ok [orch-evidence deadbeef0123 exit=0]" "$L" >/dev/null
[[ $? -eq 1 ]] && ok "validator rejects a fabricated stamp (rc 1)" || fail "validator reject" ""
orch_evidence_check "Verify: ./custom-check.sh → ok" "$L" >/dev/null
[[ $? -eq 0 ]] && ok "no stamp cited → rc 0 (no nag; the window is the real check)" || fail "no-nag" ""

printf '\n%s== REGRESSION: a heredoc body is not a command ==%s\n' "$DIM" "$RESET"
# With re.MULTILINE every line start is a command position, and a heredoc body is
# the text being WRITTEN. `cat <<EOF > CHANGELOG.md` whose body said "pytest -q
# now passes" minted a green verification row — and chained after a real red run,
# that launders the failure. The delimiter is not always at end-of-line.
before=$(ledger | wc -l | tr -d ' ')
fire "$(printf 'cat <<EOF > CHANGELOG.md\n- fixed it\npytest -q now passes\nEOF')" "" >/dev/null
fire "$(printf 'cat <<EOF | tee -a notes.md\nnpm test is now green\nEOF')" "" >/dev/null
[[ "$(ledger | wc -l | tr -d ' ')" == "$before" ]] && ok "heredoc bodies (redirected and piped) record nothing" \
  || fail "heredoc" "$(ledger | tail -2)"
# But a FALSE heredoc match must not swallow a real command that follows.
fire "$(printf 'echo "the heredoc form is <<EOF"\npytest -q')" "32 passed" >/dev/null
ledger | grep -q 'pytest -q' && ok "an unterminated <<EOF inside quotes does not hide the real run" \
  || fail "false heredoc" "real run swallowed"

printf '\n%s== REGRESSION: printing is not running ==%s\n' "$DIM" "$RESET"
# `pytest --version` and `pytest --collect-only` exit 0 having verified nothing,
# and minted green rows that satisfied a claim of "40 passed".
before=$(ledger | wc -l | tr -d ' ')
for c in "pytest --version" "npm test --help" "pytest --collect-only -q" "jest --listTests"; do
  fire "$c" "output" >/dev/null
done
[[ "$(ledger | wc -l | tr -d ' ')" == "$before" ]] && ok "--version / --help / --collect-only / --listTests record nothing" \
  || fail "non-run flags" "$(ledger | tail -3)"
# Nor are dependency installs and build steps verification.
for c in "npm ci" "go build ./..." "npm run build"; do fire "$c" "done" >/dev/null; done
[[ "$(ledger | wc -l | tr -d ' ')" == "$before" ]] && ok "installs and builds record nothing" \
  || fail "build steps" "$(ledger | tail -3)"

printf '\n%s== substance: runners that report zero execution ==%s\n' "$DIM" "$RESET"
fire "pytest -q" "no tests collected" >/dev/null
fire "dotnet test" "No test matches the given testcasefilter" >/dev/null
fire "bundle exec rspec" "0 runs, 0 assertions, 0 failures" >/dev/null
[[ $(ledger | grep -c '	none	') -ge 5 ]] && ok "pytest/dotnet/minitest zero-execution output flagged" \
  || fail "NO_TESTS gaps" "$(ledger | grep -c '	none	') none-rows"

printf '\n%s== mutex map: success-only, plain mkdir only ==%s\n' "$DIM" "$RESET"
fire 'mkdir ".worktrees/task-a/.orch-active"' "" "agent-1" >/dev/null
mutexmap | grep -q 'claim	agent-1	.worktrees/task-a/.orch-active' && ok "successful plain mkdir records a claim" || fail "claim" "$(mutexmap)"
fire 'mkdir -p .worktrees/task-b/.orch-active' "" "agent-2" >/dev/null
mutexmap | grep -q 'agent-2' && fail "-p exclusion" "mkdir -p recorded a claim ($(mutexmap))" || ok "mkdir -p records NOTHING (exits 0 on an existing dir — proves no ownership)"
fire 'rmdir ".worktrees/task-a/.orch-active"' "" "agent-1" >/dev/null
mutexmap | grep -q 'release	agent-1' && ok "rmdir records a release" || fail "release" "$(mutexmap)"

printf '\n%s== mutex map: a claim only when success ENTAILS mkdir success ==%s\n' "$DIM" "$RESET"
# "PostToolUse fires only on success" is a fact about the WHOLE command. The
# polite losing form of the race — `mkdir X || echo BLOCKED` — exits 0 for the
# LOSER, and recording a claim for it hands the reaper a false ownership proof:
# the reaper then releases a mutex a LIVE sibling is holding — two writers in
# one tree, the exact corruption the mutex exists to prevent.
for c in \
  'mkdir ".worktrees/task-l/.orch-active" || echo BLOCKED' \
  'mkdir .worktrees/task-l/.orch-active || true' \
  'mkdir .worktrees/task-l/.orch-active; echo done' \
  'if mkdir .worktrees/task-l/.orch-active; then echo mine; else echo BLOCKED; fi' \
  '! mkdir .worktrees/task-l/.orch-active' \
  'mkdir .worktrees/task-l/.orch-active &' \
  'mkdir .worktrees/task-l/.orch-active && rm -f x || echo BLOCKED'; do
  fire "$c" "" "loser-agent" >/dev/null
done
if mutexmap | grep -q 'claim	loser-agent'; then
  fail "polite-loser form recorded a claim" "success does not entail mkdir success: $(mutexmap | grep loser-agent | head -2 | tr '\n' '|')"
else
  ok "no claim for any form whose success does not entail mkdir success (||, ;, if, !, &)"
fi
# Being stricter must not lose the forms whose success DOES entail the mkdir's.
fire 'cd /repo && mkdir .worktrees/task-m/.orch-active' "" "winner-agent" >/dev/null
mutexmap | grep -q 'claim	winner-agent	.worktrees/task-m/.orch-active' \
  && ok "an &&-chained mkdir (success entails mkdir success) still records a claim" \
  || fail "entailing && claim lost" "$(mutexmap)"
fire 'mkdir .worktrees/task-n/.orch-active 2>/dev/null' "" "winner-agent" >/dev/null
mutexmap | grep -q 'claim	winner-agent	.worktrees/task-n/.orch-active' \
  && ok "a redirect-suffixed plain mkdir still records a claim" \
  || fail "redirect claim lost" "$(mutexmap)"

printf '\n%s== profile / disable gates ==%s\n' "$DIM" "$RESET"
# stderr is dropped: a gated hook exits before reading stdin, so the writer
# takes a harmless SIGPIPE. That is correct hook behaviour, not a defect.
OUT=$(event "npm test" "x" 2>/dev/null | ORCH_EVIDENCE_MARKER=1 ORCH_HOOK_PROFILE=minimal bash "$HOOK" 2>/dev/null)
[[ -z "$OUT" ]] && ok "minimal profile → inert" || fail "minimal gate" "out=$OUT"
OUT=$(event "npm test" "x" 2>/dev/null | ORCH_EVIDENCE_MARKER=1 ORCH_DISABLED_HOOKS=orch-evidence-ledger bash "$HOOK" 2>/dev/null)
[[ -z "$OUT" ]] && ok "ORCH_DISABLED_HOOKS → inert" || fail "disable gate" "out=$OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-evidence-ledger%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-evidence-ledger — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
