#!/usr/bin/env bash
# Tests for the verification gate Stop hook (orch-verify-gate.sh).
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-verify-gate.sh"

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


if ! command -v python3 >/dev/null 2>&1; then
  skip_suite test-verify-gate 'python3 unavailable'
fi
if ! command -v git >/dev/null 2>&1; then
  skip_suite test-verify-gate 'git unavailable'
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A clean committed git repo to act as CLAUDE_PROJECT_DIR (so the WIP escape
# does not fire on the warn cases).
CLEAN="$TMP/clean"; mkdir -p "$CLEAN"
( cd "$CLEAN" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "initial" )

# Build a transcript whose last assistant message is $1.
mk_transcript() {
  local text="$1" f="$TMP/t.$RANDOM.jsonl"
  printf '{"role":"user","content":"go"}\n' > "$f"
  printf '{"role":"assistant","content":%s}\n' "$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" >> "$f"
  printf '%s' "$f"
}
run() { # run <transcript> [env assignments...]: prints "rc|stderr"
  local tr="$1"; shift
  local err rc
  err=$(printf '{"transcript_path":"%s","session_id":"vg-test"}' "$tr" | env "$@" ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$CLEAN" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}

printf '%s== Completion claim without Verify: → warns (default, non-blocking) ==%s\n' "$DIM" "$RESET"
tr=$(mk_transcript "Changed: fixed the parser. All tests passing now.")
out=$(run "$tr"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-verify-gate'; then
  ok "claim + no Verify + clean tree → warn, exit 0"
else fail "warn case" "rc=$rc err=$err"; fi

printf '\n%s== Same, ORCH_STRICT_VERIFY=1 → blocks (exit 2) ==%s\n' "$DIM" "$RESET"
out=$(run "$tr" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
if [[ "$rc" == "2" ]]; then ok "strict mode → exit 2"; else fail "strict block" "rc=$rc"; fi

printf '\n%s== Completion claim WITH Verify: line → silent ==%s\n' "$DIM" "$RESET"
tr2=$(mk_transcript "Changed: fixed the parser.
Verify: pytest -q → 5 passed")
out=$(run "$tr2"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "evidence present → no warning"; else fail "evidence case" "rc=$rc err=$err"; fi

printf '\n%s== No Changed: block → silent ==%s\n' "$DIM" "$RESET"
tr3=$(mk_transcript "Found: the parser lives in src/parse.ts:42.")
out=$(run "$tr3"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "no Changed: → no warning"; else fail "no-claim case" "rc=$rc err=$err"; fi

printf '\n%s== False-positive prose in non-Changed: replies → silent (strict too) ==%s\n' "$DIM" "$RESET"
fp_ok=1
for prose in \
  "Found: the bug is in the parser. I have not fixed it yet." \
  "Plan: 1. add the test 2. once that is done, refactor the loop" \
  "Status: blocked. The login flow is still passing the wrong token." \
  "Issues: the migration has not been verified against staging."; do
  trx=$(mk_transcript "$prose")
  out=$(run "$trx" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
  if [[ "$rc" != "0" || -n "$err" ]]; then fp_ok=0; fail "false-positive guard" "prose nagged/blocked: '$prose' (rc=$rc)"; fi
done
[[ "$fp_ok" == "1" ]] && ok "negated/descriptive prose in Found:/Plan:/Status:/Issues: never fires (even strict)"

printf '\n%s== WIP escape narrowed: dirty tree ALONE still warns ==%s\n' "$DIM" "$RESET"
DIRTY="$TMP/dirty"; mkdir -p "$DIRTY"
( cd "$DIRTY" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm initial && echo change >> f )
err=$(printf '{"transcript_path":"%s","session_id":"vg-test"}' "$tr" | ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$DIRTY" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-verify-gate'; then
  ok "dirty tree alone (the normal mid-task state) → still warns"
else fail "dirty-alone warns" "rc=$rc err=$err"; fi

printf '\n%s== WIP escape narrowed: clean tree + wip subject still warns ==%s\n' "$DIM" "$RESET"
WIP="$TMP/wip"; mkdir -p "$WIP"
( cd "$WIP" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "wip: halfway" )
err=$(printf '{"transcript_path":"%s","session_id":"vg-test"}' "$tr" | ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$WIP" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-verify-gate'; then
  ok "clean tree + wip subject → still warns (work is committed, claim needs evidence)"
else fail "clean+wip warns" "rc=$rc err=$err"; fi

printf '\n%s== WIP escape: dirty tree AND wip subject → silent ==%s\n' "$DIM" "$RESET"
BOTH="$TMP/both"; mkdir -p "$BOTH"
( cd "$BOTH" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "wip: halfway" && echo change >> f )
err=$(printf '{"transcript_path":"%s","session_id":"vg-test"}' "$tr" | ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$BOTH" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
if [[ "$rc" == "0" ]] && [[ -z "$err" ]]; then ok "dirty + wip subject → WIP escape, no warning"; else fail "dirty+wip escape" "rc=$rc err=$err"; fi

printf '\n%s== Evidence ledger: cited stamp validated against the hook-written ledger ==%s\n' "$DIM" "$RESET"
# Build a ledger at the exact path the gate computes (same libs, same env).
LEDGER=$(ORCH_HOME="$TMP/orch-home" bash -c '
  source "'"$ROOT"'/scripts/lib/orch-project.sh"
  source "'"$ROOT"'/scripts/lib/orch-evidence.sh"
  orch_evidence_ledger_path vg-test')
TURNSTART="$(dirname "$LEDGER")/turn-start.vg-test"
mkdir -p "$(dirname "$LEDGER")"
printf 'aaaa11112222\t0\t1700000000\tok\tnpm test\nbbbb33334444\t1\t1700000001\tred\tpytest -q\n' > "$LEDGER"

tr_good=$(mk_transcript "Changed: fixed it.
Verify: npm test → 142 passed [orch-evidence aaaa11112222 exit=0]")
out=$(run "$tr_good"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" && -z "$err" ]]; then ok "valid stamp (exit 0) → silent"; else fail "valid stamp" "rc=$rc err=$err"; fi

tr_fab=$(mk_transcript "Changed: fixed it.
Verify: npm test → 142 passed [orch-evidence deadbeef0123 exit=0]")
out=$(run "$tr_fab"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'not in the evidence ledger'; then
  ok "fabricated stamp → warns (not recorded by the hook)"
else fail "fabricated stamp" "rc=$rc err=$err"; fi
out=$(run "$tr_fab" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
if [[ "$rc" == "2" ]]; then ok "fabricated stamp + strict → blocks (exit 2)"; else fail "fabricated strict" "rc=$rc"; fi

tr_failing=$(mk_transcript "Changed: fixed it.
Verify: pytest -q → all good [orch-evidence bbbb33334444 exit=1]")
out=$(run "$tr_failing"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'FAILED'; then
  ok "stamp recorded with exit=1 → warns (cited run actually failed)"
else fail "failing stamp" "rc=$rc err=$err"; fi

tr_stampless=$(mk_transcript "Changed: fixed it.
Verify: ./custom-check.sh → ok")
out=$(run "$tr_stampless" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" && -z "$err" ]]; then
  ok "stampless Verify: → SILENT (a project may verify with a command the regex does not know)"
else fail "stampless silent" "rc=$rc err=$err"; fi
rm -f "$LEDGER"

printf '\n%s== Turn window: the gate asks the ledger, the model cites nothing ==%s\n' "$DIM" "$RESET"
tr_plain=$(mk_transcript "Changed: fixed the parser.
Verify: npm test → 142 passed")
NOW=$(date +%s)
printf '%s' "$NOW" > "$TURNSTART"

# The reply NAMES `npm test`, a command the harness would have recorded. No
# record of it running this turn ⇒ the claim has no evidence behind it. This is
# the check that makes this a verification gate rather than a contradiction
# detector: without it, a wholly invented Verify: block passed silently.
printf 'aaaa11112222\t0\t%d\tok\tnpm test\n' "$((NOW - 5000))" > "$LEDGER"
out=$(run "$tr_plain"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'no command it names was recorded'; then
  ok "a named verify command with no record this turn → warns (stale green does not carry over)"
else fail "unbacked claim" "rc=$rc err=$err"; fi
out=$(run "$tr_plain" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
[[ "$rc" == "2" ]] && ok "...and blocks under strict" || fail "unbacked strict" "rc=$rc"

# But a Verify: naming a command the regex cannot know stays silent — there we
# genuinely know nothing, and nagging those turns is how a gate gets tuned out.
tr_custom=$(mk_transcript "Changed: fixed the parser.
Verify: ./scripts/my-own-check --all → ok")
out=$(run "$tr_custom" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" && -z "$err" ]]; then
  ok "a custom verify command outside the regex → silent, even under strict"
else fail "custom silent" "rc=$rc err=$err"; fi

printf 'cccc11112222\t0\t%d\tok\tnpm test\n' "$NOW" >> "$LEDGER"
out=$(run "$tr_plain" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" && -z "$err" ]]; then ok "green run inside the window → silent"; else fail "window green" "rc=$rc err=$err"; fi

# The claim contradicts recorded reality: says Changed:, ledger says the run failed.
printf 'dddd11112222\t1\t%d\tred\tnpm test\n' "$((NOW + 1))" >> "$LEDGER"
out=$(run "$tr_plain"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'FAILED'; then
  ok "last run this turn FAILED → warns, without the model citing anything"
else fail "window red warn" "rc=$rc err=$err"; fi
out=$(run "$tr_plain" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
[[ "$rc" == "2" ]] && ok "...and blocks under strict" || fail "window red strict" "rc=$rc"

# Green, but it verified nothing. This is the swift-test / empty-filter hole.
printf 'eeee11112222\t0\t%d\tnone\tnpm test\n' "$((NOW + 2))" >> "$LEDGER"
out=$(run "$tr_plain"); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'no tests'; then
  ok "green run that executed ZERO tests → substance note"
else fail "window substance" "rc=$rc err=$err"; fi
out=$(run "$tr_plain" ORCH_STRICT_VERIFY=1); rc=${out%%|*}
[[ "$rc" == "0" ]] && ok "...and never blocks, even under strict (soft findings stay soft)" || fail "substance strict" "rc=$rc"

# Cosmetic exemption outranks every check.
tr_cos=$(mk_transcript "Changed: renamed a variable.
Verify: no verification needed (cosmetic)")
out=$(run "$tr_cos" ORCH_STRICT_VERIFY=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" && -z "$err" ]]; then ok "cosmetic exemption honoured over a red window"; else fail "cosmetic" "rc=$rc err=$err"; fi
rm -f "$LEDGER" "$TURNSTART"

printf '\n%s== Claim extraction: the ways a command is actually pasted ==%s\n' "$DIM" "$RESET"
# The extractor is the load-bearing surface: it decides what counts as a CLAIM.
# It under-matched the header (`**Verify:**` extracted nothing), under-matched
# the command line (`$ pytest -q` — the commonest paste form — extracted
# nothing), and over-matched the body (an honestly-disclosed skipped suite, and
# the recipe lines `make` echoes into its own output, were read as claims and
# BLOCKED). Each row below is one of those.
printf '%s' "$NOW" > "$TURNSTART"
: > "$LEDGER"

_claim() { # _claim <speak|silent> <label> <reply>
  local tr err got
  tr=$(mk_transcript "$3"); err=$(run "$tr"); err=${err#*|}
  [[ -z "$err" ]] && got=silent || got=speak
  if [[ "$got" == "$1" ]]; then ok "$2"; else fail "$2" "want=$1 got=$got ${err:0:110}"; fi
}

# Fabricated, in each paste form — the ledger is empty, so all must speak.
_claim speak "backticked claim, nothing ran" 'Changed:
- p.py:1 — fix
Verify: `pytest -q` → 40 passed'
_claim speak "shell-prompt paste, nothing ran" 'Changed:
- p.py:1 — fix
Verify:
$ pytest -q
40 passed in 1.24s'
_claim speak "arrow paste, nothing ran" 'Changed:
- p.py:1 — fix
Verify:
→ pytest -q → 40 passed'
_claim speak "**Verify:** decorated header, nothing ran" 'Changed:
- p.py:1 — fix
**Verify:** `pytest -q` → 40 passed'

# Real runs. Warn only when NOTHING named in the section is backed.
printf 'aaaa11112222\t0\t%d\tok\tmake test\n' "$NOW" > "$LEDGER"
_claim silent "make test green; its output echoes the recipe line 'pytest -q'" 'Changed:
- p.py:1 — fix
Verify:
`make test` →
pytest -q
32 passed in 1.20s'

printf 'bbbb11112222\t0\t%d\tok\tpytest -q\n' "$NOW" > "$LEDGER"
_claim silent "honestly disclosing a suite that was NOT run" 'Changed:
- p.py:1 — fix
Verify:
- `pytest -q` → 32 passed in 1.20s
- `npm test` not run — no node toolchain in this repo'

# Scope collapse: a trivial filtered run must not back a whole-suite claim.
printf 'cccc11112222\t0\t%d\tok\tnpm test -- --testPathPattern=trivial.test.ts\n' "$NOW" > "$LEDGER"
_claim speak "1-test run cited as 'npm test:integration → 480 passed'" 'Changed:
- api.ts:1 — fix
Verify: `npm test:integration` → 480 passed, full suite green'

# A quoted marker example is documentation, not a citation. Any turn editing
# scripts/lib/orch-evidence.sh used to be accused of a fabricated stamp.
printf 'dddd11112222\t0\t%d\tok\tbash tests/test-evidence-ledger.sh\n' "$NOW" > "$LEDGER"
_claim silent "reply quotes an [orch-evidence ...] example in prose" 'Changed:
- scripts/lib/orch-evidence.sh:1 — docs
The ledger emits `[orch-evidence a1b2c3d4e5f6 exit=0 ok]` when the marker is on.
Verify: `bash tests/test-evidence-ledger.sh` → PASS (32 checks)'
rm -f "$LEDGER" "$TURNSTART"

source "${ROOT}/scripts/lib/orch-project.sh" 2>/dev/null || true
source "${ROOT}/scripts/lib/orch-evidence.sh" 2>/dev/null || true

printf '\n%s== Red phase: a test never seen failing has not been shown to test anything ==%s\n' "$DIM" "$RESET"
# "If you didn't watch the test fail, you don't know if it tests the right
# thing" is stated in every TDD guide and enforced by none of them, because
# checking it needs a record of what ran. The ledger already has one; nothing
# was reading it as a SEQUENCE. Scoped to turns that changed a test file — a
# docs or config turn has no red phase to skip — and soft, because a test that
# legitimately passes first is a real thing.
RP_REPO="$TMP/rp"; mkdir -p "$RP_REPO/tests" "$RP_REPO/docs"
( cd "$RP_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm initial ) >/dev/null 2>&1

rp_run() { # rp_run <cmd> <epoch> <exit>
  printf '%s\t%s\t%s\tok\t%s\n' "$(printf 'r%s' "$RANDOM")" "$3" "$2" "$1" >> "$LEDGER"
}
rp_gate() { # rp_gate <reply> → stderr
  local tr; tr=$(mk_transcript "$1")
  printf '{"transcript_path":"%s","session_id":"vg-test"}' "$tr" \
    | ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$RP_REPO" bash "$HOOK" 2>&1 1>/dev/null
}
rp_reset() { rm -f "$LEDGER"; rm -rf "$RP_REPO/tests" "$RP_REPO/docs"; mkdir -p "$RP_REPO/tests" "$RP_REPO/docs"; printf '%s' "$NOW" > "$TURNSTART"; }

RP_REPLY='Changed:
- src/calc.py:3 — fixed mul
Verify: `pytest -q` → 12 passed'

rp_reset; echo "def test_x(): assert 1" > "$RP_REPO/tests/test_calc.py"
rp_run "pytest -q" "$NOW" 0
err=$(rp_gate "$RP_REPLY")
if printf '%s' "$err" | grep -q 'without ever being seen red'; then
  ok "test file changed + suite only ever green → red-phase note"
else fail "red-phase note" "err=${err:0:120}"; fi

rp_reset; echo "def test_x(): assert 1" > "$RP_REPO/tests/test_calc.py"
rp_run "pytest -q" "$NOW" 1
rp_run "pytest -q" "$((NOW + 1))" 0
err=$(rp_gate "$RP_REPLY")
[[ -z "$err" ]] && ok "watched it fail, then pass → silent" || fail "red-then-green" "err=${err:0:120}"

rp_reset; echo "notes" > "$RP_REPO/docs/notes.md"
rp_run "pytest -q" "$NOW" 0
err=$(rp_gate "$RP_REPLY")
[[ -z "$err" ]] && ok "docs-only turn → silent (no red phase to skip)" || fail "docs-only" "err=${err:0:120}"

# Never blocks, even under strict — the honest exceptions are real.
rp_reset; echo "def test_x(): assert 1" > "$RP_REPO/tests/test_calc.py"
rp_run "pytest -q" "$NOW" 0
_rptr=$(mk_transcript "$RP_REPLY")
rc=$(printf '{"transcript_path":"%s","session_id":"vg-test"}' "$_rptr" \
  | ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$RP_REPO" ORCH_STRICT_VERIFY=1 bash "$HOOK" >/dev/null 2>&1; echo $?)
[[ "$rc" == "0" ]] && ok "red-phase finding never blocks, even under strict" || fail "red-phase strict" "rc=$rc"

printf '\n%s== Test-path recognition ==%s\n' "$DIM" "$RESET"
rp_paths_ok=1
for p in "tests/test_calc.py" "src/foo.test.ts" "spec/models/user_spec.rb" "__tests__/App.tsx" \
         "internal/handler_test.go" "src/UserTests.java" "test/helpers.sh"; do
  orch_touches_tests "$p" || { rp_paths_ok=0; fail "test path" "not recognised: $p"; }
done
[[ $rp_paths_ok -eq 1 ]] && ok "python/js/ruby/go/java/shell test paths all recognised"
rp_fp_ok=1
for p in "README.md" "src/main.py" "docs/latest.md" "package.json" "src/contest.py"; do
  orch_touches_tests "$p" && { rp_fp_ok=0; fail "test path" "false positive: $p"; }
done
[[ $rp_fp_ok -eq 1 ]] && ok "ordinary source and docs paths are not mistaken for tests"
rm -f "$LEDGER" "$TURNSTART"

printf '\n%s== decorated Changed: headers are the same claim ==%s\n' "$DIM" "$RESET"
# Mutation-found gap: dropping the heading/bold prefix from the Changed: regex
# left every check green — `**Changed:**` with no Verify: passed silently, so
# the BETTER-formatted reply was the one that escaped the gate. Each form below
# is a completion claim with no evidence and must be warned about.
for _hdr in 'Changed:' '**Changed:**' '## Changed:' '### Changed:' '  Changed:'; do
  _t=$(mk_transcript "$(printf '%s\n- src/a.ts:1 — edit with no evidence\n' "$_hdr")")
  out=$(run "$_t"); rc=${out%%|*}; err=${out#*|}
  if printf '%s' "$err" | grep -q 'Verify'; then
    ok "decorated header warns without Verify:  ${_hdr}"
  else
    fail "decorated header ignored: ${_hdr}" "rc=$rc err=$(printf '%s' "$err" | head -1)"
  fi
done
# ...and the same forms with a real Verify: section must stay silent.
_t=$(mk_transcript "$(printf '**Changed:**\n- src/a.ts:1 — edit\n\n**Verify:**\n- bash tests/smoke.sh → 79 passed\n')")
out=$(run "$_t"); rc=${out%%|*}; err=${out#*|}
[[ "$rc" == "0" ]] && ok "decorated Changed: WITH a decorated Verify: is accepted" \
  || fail "decorated pair rejected" "rc=$rc err=$(printf '%s' "$err" | head -1)"

printf '\n%s== Dry-run logs intent, never blocks ==%s\n' "$DIM" "$RESET"
out=$(run "$tr" ORCH_STRICT_VERIFY=1 ORCH_HOOK_DRY_RUN=1); rc=${out%%|*}; err=${out#*|}
if [[ "$rc" == "0" ]] && printf '%s' "$err" | grep -q 'orch-dry-run\[orch-verify-gate\]'; then
  ok "dry-run: logs intent, exit 0 even with strict"
else fail "dry-run" "rc=$rc err=$err"; fi

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-verify-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-verify-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
