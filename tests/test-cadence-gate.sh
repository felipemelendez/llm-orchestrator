#!/usr/bin/env bash
# Tests for skills/cadence/scripts/orch-cadence-gate.sh and cadence-detect.sh.
#
# The gate exists to answer one question per changed production file — "does any
# test turn red when this file alone goes back to base?" — and it must answer it
# WITHOUT touching the tree it is pointed at. So the two halves of this suite are:
#
#   1. the verdicts (REVERT_RED / REVERT_STAYS_GREEN / REVERT_RED_BY_LOAD_FAILURE
#      / COMMENT_ONLY / NEW_FILE / NATIVE / RUNNER_UNKNOWN), each proven against a
#      fixture whose fake runner really does go red for the stated reason;
#   2. the safety: the target's every file — its .git/index included — is byte
#      identical after a full run AND after a run killed by INT mid-revert, the
#      throwaway copy is gone, and the positive control is restored cmp-identical.
#
# A gate that mutates the tree it grades is the CATASTROPHIC case; the shasum
# assertions below are the pin for it.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${ROOT}/skills/cadence/scripts/orch-cadence-gate.sh"
DETECT="${ROOT}/skills/cadence/scripts/cadence-detect.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}

command -v git     >/dev/null 2>&1 || skip_suite test-cadence-gate 'git unavailable'
command -v python3 >/dev/null 2>&1 || skip_suite test-cadence-gate 'python3 unavailable (the gate requires it)'
for f in "$GATE" "$DETECT"; do
  [[ -f "$f" ]] || { printf '  %s✗%s missing script: %s\n' "$RED" "$RESET" "$f"; \
    printf '%sFAIL: test-cadence-gate — 0 passed, 1 failed.%s\n' "$RED" "$RESET"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
# An isolated HOME plus GIT_CONFIG_NOSYSTEM keeps a machine's git config
# (hooks path, templates, signing) from deciding what these fixtures do.
export GIT_CONFIG_NOSYSTEM=1
GIT_ID=(-c user.email=cadence@test -c user.name=cadence)
LOG="$TMP/gate.log"

has()   { grep -qF -- "$2" "$1"; }
hasre() { grep -qE -- "$2" "$1"; }

snapshot() { # snapshot <dir> <outfile> — every file, content only
  # A *.lock under .git is transient by git's own contract: automatic
  # background maintenance drops .git/objects/maintenance.lock into a
  # repository mid-run, and counting it would read as a mutation the gate
  # never made.
  ( cd "$1" && find . -type f ! -path '*/.git/*.lock' | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"
    done ) > "$2"
}

# ---------------------------------------------------------------------------
# Fixture A: a repo whose "language" is shell wearing .js names, with a fake
# runner whose grammar the config describes. Nothing here is JavaScript; the
# point is that the gate reads the grammar from cadence.json and nowhere else.
# ---------------------------------------------------------------------------
mkfixture() { # mkfixture <dir>
  local d="$1"
  mkdir -p "$d/src" "$d/tests" "$d/docs/llm-orchestrator"
  cat > "$d/runner.sh" <<'EOS'
#!/usr/bin/env bash
# fake runner: run each suite, count ASSERT_PASS/ASSERT_FAIL, report a summary.
set -uo pipefail
[ "${FIXTURE_SLOW:-0}" = "1" ] && sleep 2
p=0; f=0; loaderr=0; n=0
for s in "$@"; do
  n=$((n+1))
  out=$(bash "$s" 2>&1); rc=$?
  pc=$(printf '%s\n' "$out" | grep -c 'ASSERT_PASS')
  fc=$(printf '%s\n' "$out" | grep -c 'ASSERT_FAIL')
  p=$((p+pc)); f=$((f+fc))
  if [ $rc -ne 0 ] && [ "$fc" -eq 0 ]; then loaderr=$((loaderr+1)); fi
done
echo "Suites: $n total, $loaderr crashed"
echo "Tests: $p passed, $f failed"
[ "$f" -gt 0 ] && exit 1
[ "$loaderr" -gt 0 ] && exit 1
exit 0
EOS
  cat > "$d/typecheck.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
rc=0
for f in src/*.js; do
  if grep -q 'POSITIVE_CONTROL' "$f"; then echo "control error: $f"; rc=1; fi
done
exit $rc
EOS
  printf '%s\n' '# module alpha' 'export ALPHA_MARK=old' > "$d/src/alpha.js"
  printf '%s\n' '# module beta' 'export BETA_MARK=one' > "$d/src/beta.js"
  printf '%s\n' '# module gamma' '# an old note' 'export GAMMA_MARK=one' > "$d/src/gamma.js"
  printf '%s\n' '# module omega' 'export OMEGA_OLD=1' > "$d/src/omega.js"
  printf '%s\n' '# module epsilon' 'export EPSILON_MARK=one' > "$d/src/epsilon.js"
  printf '%s\n' 'set -u' '. ./src/alpha.js' '[ "$ALPHA_MARK" = old ] && echo ASSERT_PASS || echo ASSERT_FAIL' > "$d/tests/alpha.test.js"
  printf '%s\n' 'set -u' '. ./src/omega.js' 'echo ASSERT_PASS' > "$d/tests/omega.test.js"
  # epsilon is PINNED but the pin does not depend on the change: reverting it
  # leaves the suite green. That is the second REVERT_STAYS_GREEN branch — the
  # one where suites really run — and without it the verdict could be produced
  # entirely by the "no suite names this file" path.
  printf '%s\n' 'set -u' '. ./src/epsilon.js' '[ -n "$EPSILON_MARK" ] && echo ASSERT_PASS || echo ASSERT_FAIL' > "$d/tests/epsilon.test.js"
  cat > "$d/docs/llm-orchestrator/cadence.json" <<EOS
{ "schema": 1, "enabled": true, "notes_dir": "docs/llm-orchestrator/notes",
  "ticket_re": "^[A-Z][A-Z0-9]*(-[A-Z0-9]+)+:",
  "runner": { "profile": "fixture", "test_cmd": "bash runner.sh", "summary_re": "^Tests:",
              "fail_count_re": "([0-9]+) failed", "suites_re": "^Suites:" },
  "typecheck_cmd": "bash typecheck.sh", "unused_cmd": "",
  "src_roots": ["src", "tests"],
  "prod_globs": ["*.js"], "test_globs": ["*.test.js"],
  "import_patterns": ["src/{base}\\\\.js"],
  "export_pattern": "^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*",
  "comment_prefixes": ["#"],
  "positive_control": { "file_ext": ".js", "snippet": "# POSITIVE_CONTROL injected", "expect_marker": "control error" },
  "wait_patterns": [], "wait_timeout_s": 5,
  "scratch_dir": "$TMP/scratch", "refuse_paths": [], "lock_extra": [], "install_cmd": "" }
EOS
  ( cd "$d" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
  # the working-tree delta the gate is asked to grade
  printf '%s\n' '# module alpha' 'export ALPHA_MARK=new' > "$d/src/alpha.js"
  printf '%s\n' 'set -u' '. ./src/alpha.js' '[ "$ALPHA_MARK" = new ] && echo ASSERT_PASS || echo ASSERT_FAIL' > "$d/tests/alpha.test.js"
  printf '%s\n' '# module beta' 'export BETA_MARK=two' > "$d/src/beta.js"
  printf '%s\n' '# module gamma' '# a NEW note' 'export GAMMA_MARK=one' > "$d/src/gamma.js"
  printf '%s\n' '# module omega' 'export OMEGA_OLD=1' 'export OMEGA_NEW=1' > "$d/src/omega.js"
  printf '%s\n' 'set -u' '. ./src/omega.js' 'echo "$OMEGA_NEW"' 'echo ASSERT_PASS' > "$d/tests/omega.test.js"
  printf '%s\n' '# module epsilon' 'export EPSILON_MARK=two' > "$d/src/epsilon.js"
  printf '%s\n' '# module delta' 'export DELTA_MARK=1' > "$d/src/delta.js"
}

FX="$TMP/fx"; mkfixture "$FX"
mkdir -p "$TMP/scratch"
BASE=$(git -C "$FX" rev-parse HEAD)
ORPHAN=$(git -C "$FX" "${GIT_ID[@]}" commit-tree "$(git -C "$FX" rev-parse HEAD^{tree})" -m orphan 2>/dev/null)
SNAP0="$TMP/snap0"; snapshot "$FX" "$SNAP0"
IDX0=$(shasum -a 256 "$FX/.git/index" | awk '{print $1}')

printf '%s== the six verdicts, on a fixture whose runner really goes red ==%s\n' "$DIM" "$RESET"
bash "$GATE" "$FX" "$BASE" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "0" ]]; then ok "a clean run exits 0"; else fail "gate exit" "rc=$RC$(printf '\n')$(cat "$LOG")"; fi
[[ "$(tail -n 1 "$LOG")" == "EXIT=0" ]] && ok "EXIT=<n> is the last line" || fail "EXIT last line" "$(tail -n 3 "$LOG")"
hasre "$LOG" '^REVERT_RED src/alpha\.js:' && ok "REVERT_RED: reverting alpha alone turns its pin red" || fail "REVERT_RED" "$(cat "$LOG")"
hasre "$LOG" '^REVERT_STAYS_GREEN src/beta\.js:' && ok "REVERT_STAYS_GREEN: a changed file no suite names" || fail "REVERT_STAYS_GREEN" "$(grep beta "$LOG")"
hasre "$LOG" '^REVERT_STAYS_GREEN src/epsilon\.js: 1 suite\(s\) green with the change reverted' && ok "REVERT_STAYS_GREEN: a pinned file whose suite really runs and stays green" || fail "REVERT_STAYS_GREEN pinned" "$(grep epsilon "$LOG")"
hasre "$LOG" '^REVERT_RED_BY_LOAD_FAILURE src/omega\.js:' && ok "REVERT_RED_BY_LOAD_FAILURE: the consumer needs the new export" || fail "LOAD_FAILURE" "$(grep omega "$LOG")"
hasre "$LOG" '^COMMENT_ONLY src/gamma\.js:' && ok "COMMENT_ONLY: only comment lines changed" || fail "COMMENT_ONLY" "$(grep gamma "$LOG")"
hasre "$LOG" '^NEW_FILE src/delta\.js:' && ok "NEW_FILE: an untracked production file" || fail "NEW_FILE" "$(grep delta "$LOG")"
has "$LOG" 'NEW_EXPORTS src/omega.js' && ok "the export sweep reports an added export" || fail "NEW_EXPORTS" "$(grep -i export "$LOG")"
hasre "$LOG" '^FAMILIES EXIT=' && ok "step 2 runs the touched families and prints the exit" || fail "FAMILIES" "$(grep FAMILIES "$LOG")"
has "$LOG" 'CONTROL_RESTORED cmp-identical' && ok "the typecheck positive control fired and was restored cmp-identical" || fail "control" "$(grep -i control "$LOG")"
has "$LOG" 'control error' && ok "the positive control produced the config's expect_marker" || fail "expect marker" "$(grep -i control "$LOG")"
has "$LOG" 'SHASUMS_RESTORED' && ok "step 5 prints the shasum proof" || fail "SHASUMS_RESTORED" "$(tail -5 "$LOG")"

printf '\n%s== it never mutates the tree it is pointed at ==%s\n' "$DIM" "$RESET"
SNAP1="$TMP/snap1"; snapshot "$FX" "$SNAP1"
if cmp -s "$SNAP0" "$SNAP1"; then ok "every file in the target is byte-identical after a full run"; else fail "target mutated" "$(diff "$SNAP0" "$SNAP1" | head -8)"; fi
IDX1=$(shasum -a 256 "$FX/.git/index" | awk '{print $1}')
[[ "$IDX0" == "$IDX1" ]] && ok "the target's .git/index is byte-identical after a full run" || fail "index mutated" "$IDX0 vs $IDX1"
if [[ -z "$(find "$TMP/scratch" -type d -name copy 2>/dev/null)" ]]; then ok "the throwaway copy is removed at exit"; else fail "copy left behind" "$(find "$TMP/scratch" -type d -name copy)"; fi

printf '\n%s== killed by INT during step 3 ==%s\n' "$DIM" "$RESET"
# A background job started by a non-interactive shell inherits SIGINT as
# IGNORED, and bash cannot trap a signal that was ignored at startup - so a
# plain `... & kill -INT` would prove nothing (measured: the gate ran to
# completion and the assertion passed vacuously). This wrapper restores the
# default disposition and execs, so the gate really is interrupted.
UNIGNORE=(python3 -c 'import signal,os,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])')
FIXTURE_SLOW=1 "${UNIGNORE[@]}" bash "$GATE" "$FX" "$BASE" > "$TMP/int.log" 2>&1 &
GPID=$!
W=0
while [[ $W -lt 300 ]]; do grep -q '== 3 ' "$TMP/int.log" 2>/dev/null && break; sleep 0.2; W=$((W+1)); done
if grep -q '== 3 ' "$TMP/int.log" 2>/dev/null; then
  # step 3 reverts the first file and then sits in the (slowed) runner for 2s,
  # so half a second past the header lands the interrupt with a file ACTUALLY
  # reverted in the copy - which is the state the restore has to survive.
  sleep 0.5
  kill -INT "$GPID" 2>/dev/null
  wait "$GPID" 2>/dev/null; IRC=$?
  SNAP2="$TMP/snap2"; snapshot "$FX" "$SNAP2"
  if cmp -s "$SNAP0" "$SNAP2"; then ok "every file in the target is byte-identical after an INT during step 3"; else fail "target mutated by INT" "$(diff "$SNAP0" "$SNAP2" | head -8)"; fi
  IDX2=$(shasum -a 256 "$FX/.git/index" | awk '{print $1}')
  [[ "$IDX0" == "$IDX2" ]] && ok "the target's .git/index survives an INT" || fail "index mutated by INT" "$IDX0 vs $IDX2"
  has "$TMP/int.log" 'SHASUMS_RESTORED' && ok "the INT trap still prints the shasum proof" || fail "INT proof" "$(tail -6 "$TMP/int.log")"
  hasre "$TMP/int.log" '^RESTORED .* cmp-identical$' && ok "the INT trap put the file it had reverted back, cmp-identical" || fail "INT restore" "$(tail -8 "$TMP/int.log")"
  [[ "$(tail -n 1 "$TMP/int.log")" == "EXIT=130" ]] && ok "the INT path exits 130 and still ends with EXIT=<n>" \
    || fail "INT EXIT line" "wait rc=$IRC last=$(tail -n 1 "$TMP/int.log")"
  [[ "$IRC" == "130" ]] && ok "the interrupted gate reports 130 to its caller" || fail "INT rc" "wait returned $IRC"
  if [[ -z "$(find "$TMP/scratch" -type d -name copy 2>/dev/null)" ]]; then ok "the copy is removed on the INT path too"; else fail "copy left after INT" "$(find "$TMP/scratch" -type d -name copy)"; fi
else
  fail "INT setup" "the gate never reached step 3: $(tail -5 "$TMP/int.log")"
  kill -9 "$GPID" 2>/dev/null; wait "$GPID" 2>/dev/null
fi

printf '\n%s== refusals (exit 9, one line, nothing copied) ==%s\n' "$DIM" "$RESET"
NG="$TMP/notgit"; mkdir -p "$NG"
bash "$GATE" "$NG" "$BASE" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'not inside a git working tree'; then ok "a directory that is not a git working tree is REFUSED (exit 9), for that reason"; else fail "refuse non-git" "rc=$RC $(cat "$LOG")"; fi
bash "$GATE" "$FX/src" "$BASE" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'is not the toplevel'; then ok "a subdirectory of a repo (not its toplevel) is REFUSED, for that reason"; else fail "refuse subdir" "rc=$RC $(cat "$LOG")"; fi
bash "$GATE" "$FX/src/alpha.js" "$BASE" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'is not a directory'; then ok "a file target is REFUSED, for that reason"; else fail "refuse file" "rc=$RC $(cat "$LOG")"; fi
bash "$GATE" "$FX" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'is not a commit'; then ok "a base that is not a commit is REFUSED, for that reason"; else fail "refuse base" "rc=$RC $(cat "$LOG")"; fi
bash "$GATE" "$FX" "$ORPHAN" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'ancestor'; then ok "a base that is not an ancestor of HEAD is REFUSED"; else fail "refuse ancestor" "rc=$RC $(cat "$LOG")"; fi
sed 's|"refuse_paths": \[\]|"refuse_paths": ["*/fx"]|' "$FX/docs/llm-orchestrator/cadence.json" > "$TMP/refuse.json"
bash "$GATE" "$FX" "$BASE" --config "$TMP/refuse.json" > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'refuse_paths'; then ok "a target matching refuse_paths is REFUSED"; else fail "refuse_paths" "rc=$RC $(cat "$LOG")"; fi
SNAP3="$TMP/snap3"; snapshot "$FX" "$SNAP3"
cmp -s "$SNAP0" "$SNAP3" && ok "no refusal touched the target" || fail "refusal mutated" "$(diff "$SNAP0" "$SNAP3" | head -5)"

printf '\n%s== the shasum proof is itself controlled ==%s\n' "$DIM" "$RESET"
# A proof that cannot fail is not a proof: unused_cmd runs after the start
# shasums are taken, so tampering there MUST come back as SHASUMS_CHANGED - and
# the target must still be untouched, because the tampering happened in the copy.
sed 's|"unused_cmd": ""|"unused_cmd": "printf tampered >> src/beta.js"|' "$FX/docs/llm-orchestrator/cadence.json" > "$TMP/tamper.json"
bash "$GATE" "$FX" "$BASE" --config "$TMP/tamper.json" > "$LOG" 2>&1; RC=$?
if has "$LOG" 'SHASUMS_CHANGED' && [[ "$RC" == "4" ]]; then ok "a file changed behind the gate's back comes back as SHASUMS_CHANGED (rc=4)"; else fail "shasum control" "rc=$RC $(grep -i shasum "$LOG")"; fi
SNAPT="$TMP/snapt"; snapshot "$FX" "$SNAPT"
cmp -s "$SNAP0" "$SNAPT" && ok "the tampering stayed inside the copy" || fail "tamper escaped" "$(diff "$SNAP0" "$SNAPT" | head -5)"

printf '\n%s== RUNNER_UNKNOWN is loud and non-zero ==%s\n' "$DIM" "$RESET"
sed 's|"profile": "fixture"|"profile": ""|' "$FX/docs/llm-orchestrator/cadence.json" \
  | sed 's|"test_cmd": "bash runner.sh"|"test_cmd": ""|' > "$TMP/unknown.json"
bash "$GATE" "$FX" "$BASE" --config "$TMP/unknown.json" > "$LOG" 2>&1; RC=$?
[[ "$RC" != "0" ]] && ok "an unknown runner profile exits non-zero (rc=$RC)" || fail "RUNNER_UNKNOWN rc" "$(cat "$LOG")"
has "$LOG" 'RUNNER_UNKNOWN' && ok "RUNNER_UNKNOWN is printed" || fail "RUNNER_UNKNOWN line" "$(cat "$LOG")"
[[ "$(grep -c 'SKIPPED (RUNNER_UNKNOWN)' "$LOG")" == "2" ]] && ok "steps 2 and 3 both print SKIPPED (RUNNER_UNKNOWN)" || fail "skipped lines" "$(grep SKIPPED "$LOG")"
hasre "$LOG" "^EXIT=${RC}$" && ok "EXIT=<n> still closes the RUNNER_UNKNOWN run" || fail "EXIT on unknown" "$(tail -2 "$LOG")"

printf '\n%s== --no-typecheck and --families ==%s\n' "$DIM" "$RESET"
bash "$GATE" "$FX" "$BASE" --no-typecheck > "$LOG" 2>&1
has "$LOG" 'TYPECHECK_SKIPPED (--no-typecheck)' && ok "--no-typecheck skips step 4 loudly" || fail "--no-typecheck" "$(grep -i typecheck "$LOG")"
bash "$GATE" "$FX" "$BASE" --families "tests/alpha.test.js" --no-typecheck > "$LOG" 2>&1
hasre "$LOG" '^families: 1$' && ok "--families overrides the computed family list" || fail "--families" "$(grep -A2 'families:' "$LOG")"

printf '\n%s== a bounded wait loop is loud on expiry ==%s\n' "$DIM" "$RESET"
sleep 987 & SLEEPER=$!
sed 's|"wait_patterns": \[\]|"wait_patterns": ["sleep [9]87"]|' "$FX/docs/llm-orchestrator/cadence.json" \
  | sed 's|"wait_timeout_s": 5|"wait_timeout_s": 1|' > "$TMP/wait.json"
bash "$GATE" "$FX" "$BASE" --config "$TMP/wait.json" --no-typecheck > "$LOG" 2>&1; RC=$?
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
if has "$LOG" 'WAIT_TIMEOUT' && [[ "$RC" != "0" ]]; then ok "a wait loop that expires prints WAIT_TIMEOUT and counts in the exit (rc=$RC)"; else fail "WAIT_TIMEOUT" "rc=$RC $(grep -i wait "$LOG")"; fi

# ---------------------------------------------------------------------------
# Fixture B: this plugin's own shape — the shell-suites profile, detected
# because no cadence.json is present.
# ---------------------------------------------------------------------------
printf '\n%s== the shell-suites profile, via the detector (no cadence.json) ==%s\n' "$DIM" "$RESET"
SS="$TMP/shellsuites"
mkdir -p "$SS/scripts/hooks" "$SS/tests" "$SS/hooks"
printf '%s\n' '#!/usr/bin/env bash' '# run every suite, including the one for scripts/alpha.sh' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$SS/tests/run-all.sh"
mkdir -p "$SS/tests/lib"
printf '%s\n' '#!/usr/bin/env bash' '# helper library named by tests for scripts/alpha.sh' 'helper() { :; }' > "$SS/tests/lib/helper.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ALPHA_MARK=old' 'alpha_fn() { echo alpha; }' > "$SS/scripts/alpha.sh"
printf '%s\n' '#!/usr/bin/env bash' 'beta_fn() { echo beta; }' > "$SS/scripts/hooks/beta.sh"
printf '%s\n' '{ "hooks": { "PreToolUse": [] } }' > "$SS/hooks/hooks.json"
cat > "$SS/tests/test-alpha.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/alpha.sh"
if [ "$ALPHA_MARK" = "new" ]; then echo "PASS: test-alpha (1 checks)"; exit 0; fi
echo "FAIL: test-alpha — 0 passed, 1 failed."
exit 1
EOS
( cd "$SS" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
SSBASE=$(git -C "$SS" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'ALPHA_MARK=new' 'alpha_fn() { echo alpha; }' > "$SS/scripts/alpha.sh"
printf '%s\n' '{ "hooks": { "PreToolUse": [], "Stop": [] } }' > "$SS/hooks/hooks.json"
SSNAP0="$TMP/ssnap0"; snapshot "$SS" "$SSNAP0"
TMPDIR="$TMP/sstmp" bash "$GATE" "$SS" "$SSBASE" > "$LOG" 2>&1; RC=$?
has "$LOG" 'CONFIG_ABSENT: using detected profile shell-suites' && ok "no cadence.json → the detector's proposal is used, loudly" || fail "CONFIG_ABSENT" "$(head -4 "$LOG")"
hasre "$LOG" '^REVERT_RED scripts/alpha\.sh:' && ok "shell-suites: reverting alpha.sh turns test-alpha red" || fail "shell-suites REVERT_RED" "$(cat "$LOG")"
if grep -qE '^  tests/(run-all\.sh|lib/helper\.sh)$' "$LOG"; then fail "runnable subset" "the runner or the helper library was queued as a suite"; else ok "tests/run-all.sh and tests/lib/ are test files but never run as suites"; fi
hasre "$LOG" '^NATIVE hooks/hooks\.json:' && ok "NATIVE: a changed production file outside the runner's language" || fail "NATIVE" "$(grep -i native "$LOG")"
has "$LOG" 'CONTROL_RESTORED cmp-identical' && ok "shell-suites typecheck: bash -n plus a syntax-error control, restored" || fail "shell control" "$(grep -i control "$LOG")"
if hasre "$LOG" '^  .*syntax error' && ! has "$LOG" 'CONTROL_DID_NOT_FIRE'; then
  ok "the shell-suites control really produced a syntax error (the marker is echoed from the typecheck log, not from the did-not-fire message)"
else fail "shell control marker" "$(grep -i -A1 control "$LOG")"; fi
[[ "$RC" == "0" ]] && ok "the shell-suites run exits 0" || fail "shell-suites exit" "rc=$RC$(printf '\n')$(tail -12 "$LOG")"
SSNAP1="$TMP/ssnap1"; snapshot "$SS" "$SSNAP1"
cmp -s "$SSNAP0" "$SSNAP1" && ok "the shell-suites target is byte-identical after the run" || fail "ss target mutated" "$(diff "$SSNAP0" "$SSNAP1" | head -6)"

# ---------------------------------------------------------------------------
# TMPDIR that does not exist yet. Every gate run in this suite sets TMPDIR to a
# directory nobody created. BSD mktemp -d ignores a missing TMPDIR and falls
# back to /var/folders; GNU mktemp -d refuses:
#   mktemp: failed to create directory via template '.../tmp.XXXXXXXXXX'
# so the gate's first mktemp -d dies on a GNU box and every check that runs the
# gate goes red there while the same suite is green on a Mac. The shim below
# gives macOS the GNU rule, so the hole is visible on both.
# ---------------------------------------------------------------------------
echo "== a TMPDIR that does not exist yet (GNU mktemp semantics) =="
REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "$TMP/gnushim"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'if [ -n "${TMPDIR:-}" ] && [ ! -d "$TMPDIR" ]; then'
  printf '%s\n' "  echo \"mktemp: failed to create directory via template '\$TMPDIR/tmp.XXXXXXXXXX': No such file or directory\" >&2"
  printf '%s\n' '  exit 1'
  printf '%s\n' 'fi'
  printf '%s\n' "exec $REAL_MKTEMP \"\$@\""
} > "$TMP/gnushim/mktemp"
chmod +x "$TMP/gnushim/mktemp"
GNUSNAP0="$TMP/gnusnap0"; snapshot "$SS" "$GNUSNAP0"
TMPDIR="$TMP/gnutmp" PATH="$TMP/gnushim:$PATH" bash "$GATE" "$SS" "$SSBASE" --no-typecheck > "$TMP/gnu.log" 2>&1; RC=$?
[ -d "$TMP/gnutmp" ] && ok "the gate creates a missing TMPDIR before its first mktemp, as GNU mktemp requires" || fail "TMPDIR created" "$TMP/gnutmp still does not exist after the run"
has "$TMP/gnu.log" 'GATE Started:' && ok "under GNU mktemp semantics the gate still starts" || fail "GNU mktemp start" "$(head -4 "$TMP/gnu.log")"
[[ "$RC" == "0" ]] && ok "under GNU mktemp semantics the run exits 0, not a refusal" || fail "GNU mktemp exit" "rc=$RC$(printf '\n')$(head -4 "$TMP/gnu.log")"
GNUSNAP1="$TMP/gnusnap1"; snapshot "$SS" "$GNUSNAP1"
cmp -s "$GNUSNAP0" "$GNUSNAP1" && ok "the target is byte-identical after the GNU-mktemp run" || fail "gnu target mutated" "$(diff "$GNUSNAP0" "$GNUSNAP1" | head -6)"

# ---------------------------------------------------------------------------
# Transient git locks. git runs automatic background maintenance on its own and
# drops .git/objects/maintenance.lock into a repository while the gate is
# reading it. A lock is transient by git's own contract, so a byte-snapshot of
# the target must not count one — otherwise the gate is accused of mutating a
# tree it never wrote to. And the gate must not provoke maintenance at all: a gc
# rewriting objects mid-run would invalidate its own shasum proof.
# ---------------------------------------------------------------------------
echo "== transient git locks in the target =="
LKSNAP0="$TMP/lksnap0"; snapshot "$SS" "$LKSNAP0"
mkdir -p "$SS/.git/objects"
: > "$SS/.git/objects/maintenance.lock"
: > "$SS/.git/x.lock"
LKSNAP1="$TMP/lksnap1"; snapshot "$SS" "$LKSNAP1"
cmp -s "$LKSNAP0" "$LKSNAP1" && ok "a transient .git lock appearing mid-run does not fail the snapshot compare" || fail "lock counted as a mutation" "$(diff "$LKSNAP0" "$LKSNAP1" | head -6)"
rm -f "$SS/.git/objects/maintenance.lock" "$SS/.git/x.lock"

# Every git the gate runs — against the target and inside the copy — must carry
# the two switches that keep automatic maintenance from ever starting. A shim on
# PATH records each invocation's argv.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/gitshim"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "$GITARGV_LOG"'
  printf '%s\n' "exec $REAL_GIT \"\$@\""
} > "$TMP/gitshim/git"
chmod +x "$TMP/gitshim/git"
: > "$TMP/gitargv.log"
GITARGV_LOG="$TMP/gitargv.log" TMPDIR="$TMP/mnttmp" PATH="$TMP/gitshim:$PATH" bash "$GATE" "$SS" "$SSBASE" --no-typecheck > "$TMP/mnt.log" 2>&1
[ -s "$TMP/gitargv.log" ] && ok "the git shim recorded the gate's git invocations" || fail "no git recorded" "the shim log is empty; the rest of this block proves nothing"
MNT_BAD="$(grep -v -e 'gc\.auto=0' "$TMP/gitargv.log" | head -3)"
[ -z "$MNT_BAD" ] && ok "every git the gate runs carries -c gc.auto=0" || fail "gc.auto not pinned" "$MNT_BAD"
MNT_BAD2="$(grep -v -e 'maintenance\.auto=false' "$TMP/gitargv.log" | head -3)"
[ -z "$MNT_BAD2" ] && ok "every git the gate runs carries -c maintenance.auto=false" || fail "maintenance.auto not pinned" "$MNT_BAD2"
MNTSNAP="$TMP/mntsnap"; snapshot "$SS" "$MNTSNAP"
cmp -s "$GNUSNAP0" "$MNTSNAP" && ok "the target is byte-identical after the maintenance-pinned run" || fail "mnt target mutated" "$(diff "$GNUSNAP0" "$MNTSNAP" | head -6)"

# ---------------------------------------------------------------------------
# Fixture C: the target is a LINKED worktree, whose index lives in the main
# repository. A copy of it still resolves its index there, so without isolation
# the very first `git diff` writes the index of a tree the gate was told not to
# touch. This is the sharpest form of the CATASTROPHIC case.
# ---------------------------------------------------------------------------
printf '\n%s== a linked worktree: the index lives elsewhere and must survive ==%s\n' "$DIM" "$RESET"
MAINR="$TMP/mainrepo"; mkfixture "$MAINR"
WT="$TMP/linkedwt"
git -C "$MAINR" worktree add -q --detach "$WT" HEAD >/dev/null 2>&1
if [[ -f "$WT/.git" ]]; then
  printf '%s\n' '# module alpha' 'export ALPHA_MARK=new' > "$WT/src/alpha.js"
  printf '%s\n' 'set -u' '. ./src/alpha.js' '[ "$ALPHA_MARK" = new ] && echo ASSERT_PASS || echo ASSERT_FAIL' > "$WT/tests/alpha.test.js"
  WTBASE=$(git -C "$WT" rev-parse HEAD)
  WTIDX="$MAINR/.git/worktrees/$(basename "$WT")/index"
  WI0=$(shasum -a 256 "$WTIDX" | awk '{print $1}')
  MSNAP0="$TMP/msnap0"; snapshot "$MAINR" "$MSNAP0"
  WSNAP0="$TMP/wsnap0"; snapshot "$WT" "$WSNAP0"
  bash "$GATE" "$WT" "$WTBASE" > "$LOG" 2>&1; RC=$?
  has "$LOG" 'INDEX_ISOLATED' && ok "a linked worktree's index is detected as outside the copy and isolated" || fail "INDEX_ISOLATED" "$(head -6 "$LOG")"
  hasre "$LOG" '^REVERT_RED src/alpha\.js:' && ok "the gate still grades correctly inside a linked worktree" || fail "worktree verdict" "$(cat "$LOG")"
  WI1=$(shasum -a 256 "$WTIDX" | awk '{print $1}')
  [[ "$WI0" == "$WI1" ]] && ok "the worktree's index (inside the main repository) is byte-identical" || fail "worktree index mutated" "$WI0 vs $WI1"
  MSNAP1="$TMP/msnap1"; snapshot "$MAINR" "$MSNAP1"
  cmp -s "$MSNAP0" "$MSNAP1" && ok "the main repository is byte-identical after grading its worktree" || fail "main repo mutated" "$(diff "$MSNAP0" "$MSNAP1" | head -6)"
  WSNAP1="$TMP/wsnap1"; snapshot "$WT" "$WSNAP1"
  cmp -s "$WSNAP0" "$WSNAP1" && ok "the linked worktree itself is byte-identical" || fail "worktree mutated" "$(diff "$WSNAP0" "$WSNAP1" | head -6)"
else
  printf '  %s-%s linked-worktree case not exercised: git did not create one\n' "$DIM" "$RESET"
fi

printf '\n%s== the detector proposes, and never writes ==%s\n' "$DIM" "$RESET"
DSNAP0="$TMP/dsnap0"; snapshot "$SS" "$DSNAP0"
bash "$DETECT" --root "$SS" > "$TMP/proposal.json" 2>"$TMP/derr"; RC=$?
[[ "$RC" == "0" ]] && ok "cadence-detect.sh exits 0" || fail "detect rc" "rc=$RC $(cat "$TMP/derr")"
python3 -m json.tool "$TMP/proposal.json" >/dev/null 2>&1 && ok "the proposal is valid JSON" || fail "detect json" "$(cat "$TMP/proposal.json")"
MISSING=""
for k in schema enabled notes_dir ticket_re runner typecheck_cmd unused_cmd src_roots prod_globs test_globs \
         import_patterns export_pattern comment_prefixes positive_control wait_patterns wait_timeout_s \
         scratch_dir refuse_paths lock_extra install_cmd; do
  grep -q "\"$k\"" "$TMP/proposal.json" || MISSING="$MISSING $k"
done
[[ -z "$MISSING" ]] && ok "every cadence.json key is present in the proposal" || fail "detect keys" "missing:$MISSING"
grep -q '"profile": "shell-suites"' "$TMP/proposal.json" && ok "tests/run-all.sh + tests/test-*.sh → shell-suites" || fail "detect shell-suites" "$(grep profile "$TMP/proposal.json")"
DSNAP1="$TMP/dsnap1"; snapshot "$SS" "$DSNAP1"
cmp -s "$DSNAP0" "$DSNAP1" && ok "the detector wrote nothing" || fail "detector wrote" "$(diff "$DSNAP0" "$DSNAP1" | head -5)"

dprofile() { # dprofile <dir> -> the detected profile
  bash "$DETECT" --root "$1" 2>/dev/null | sed -n 's/.*"profile": "\([^"]*\)".*/\1/p' | head -1
}
D="$TMP/d1"; mkdir -p "$D"; : > "$D/vitest.config.ts"
[[ "$(dprofile "$D")" == "vitest" ]] && ok "vitest.config.* → vitest" || fail "detect vitest" "$(dprofile "$D")"
D="$TMP/d2"; mkdir -p "$D"; : > "$D/jest.config.js"
[[ "$(dprofile "$D")" == "jest" ]] && ok "jest.config.* → jest" || fail "detect jest" "$(dprofile "$D")"
D="$TMP/d3"; mkdir -p "$D"; printf '{ "name": "x", "jest": { "testEnvironment": "node" } }\n' > "$D/package.json"
[[ "$(dprofile "$D")" == "jest" ]] && ok "a \"jest\" key in package.json → jest" || fail "detect jest key" "$(dprofile "$D")"
D="$TMP/d4"; mkdir -p "$D"; : > "$D/pytest.ini"
[[ "$(dprofile "$D")" == "pytest" ]] && ok "pytest.ini → pytest" || fail "detect pytest" "$(dprofile "$D")"
D="$TMP/d5"; mkdir -p "$D"; printf '[tool:pytest]\n' > "$D/setup.cfg"
[[ "$(dprofile "$D")" == "pytest" ]] && ok "setup.cfg [tool:pytest] → pytest" || fail "detect pytest cfg" "$(dprofile "$D")"
D="$TMP/d6"; mkdir -p "$D"; printf '[tool.pytest.ini_options]\n' > "$D/pyproject.toml"
[[ "$(dprofile "$D")" == "pytest" ]] && ok "pyproject.toml [tool.pytest → pytest" || fail "detect pytest toml" "$(dprofile "$D")"
D="$TMP/d7"; mkdir -p "$D"; : > "$D/conftest.py"
[[ "$(dprofile "$D")" == "pytest" ]] && ok "conftest.py → pytest" || fail "detect conftest" "$(dprofile "$D")"
D="$TMP/d8"; mkdir -p "$D"; : > "$D/README.md"
[[ "$(dprofile "$D")" == "unknown" ]] && ok "nothing recognised → profile unknown" || fail "detect unknown" "$(dprofile "$D")"
bash "$DETECT" --root "$TMP/d8" 2>/dev/null | grep -q '"test_cmd": ""' && ok "the unknown profile proposes an empty test_cmd" || fail "unknown test_cmd" "$(bash "$DETECT" --root "$TMP/d8" | grep test_cmd)"

# ---------------------------------------------------------------------------
# Round-1 pins. Each is written from the scene it must reproduce and was proven
# red on the tree before the mechanism it names existed.
# ---------------------------------------------------------------------------
printf '\n%s== a symlink is never followed, never reverted, never the control ==%s\n' "$DIM" "$RESET"
SY="$TMP/symfx"; mkfixture "$SY"
( cd "$SY" && ln -s "$SY/src/beta.js" src/aaa_link.js && git "${GIT_ID[@]}" add src/aaa_link.js \
  && git "${GIT_ID[@]}" commit -qm 'add the link' ) >/dev/null 2>&1
SYBASE=$(git -C "$SY" rev-parse HEAD)
rm -f "$SY/src/aaa_link.js"; ln -s "$SY/src/alpha.js" "$SY/src/aaa_link.js"
ALPHA_BEFORE=$(shasum -a 256 "$SY/src/alpha.js" | awk '{print $1}')
SYSNAP0="$TMP/sysnap0"; snapshot "$SY" "$SYSNAP0"
bash "$GATE" "$SY" "$SYBASE" > "$TMP/sym.log" 2>&1; RC=$?
hasre "$TMP/sym.log" '^SYMLINK src/aaa_link\.js: not reverted, not a control candidate' \
  && ok "a changed symlink gets its own SYMLINK verdict" || fail "SYMLINK verdict" "$(grep -i link "$TMP/sym.log")"
if grep -E '^(REVERT_RED|REVERT_STAYS_GREEN|REVERT_RED_BY_LOAD_FAILURE|COMMENT_ONLY) src/aaa_link\.js' "$TMP/sym.log" >/dev/null 2>&1; then
  fail "symlink reverted" "$(grep aaa_link "$TMP/sym.log")"
else ok "the symlink is excluded from the revert entirely"; fi
if hasre "$TMP/sym.log" '^TYPECHECK_CONTROL\(src/alpha\.js\)'; then ok "the positive control lands on a regular file, not on the symlink"; else fail "control candidate" "$(grep -i control "$TMP/sym.log")"; fi
ALPHA_AFTER=$(shasum -a 256 "$SY/src/alpha.js" | awk '{print $1}')
[[ "$ALPHA_BEFORE" == "$ALPHA_AFTER" ]] && ok "the file the symlink points at is byte-identical" || fail "wrote through the link" "$ALPHA_BEFORE vs $ALPHA_AFTER"
SYSNAP1="$TMP/sysnap1"; snapshot "$SY" "$SYSNAP1"
cmp -s "$SYSNAP0" "$SYSNAP1" && ok "the symlink fixture's target is byte-identical after the run" || fail "sym target mutated" "$(diff "$SYSNAP0" "$SYSNAP1" | head -6)"

printf '\n%s== a real red is a real red, in every summary shape this repo prints ==%s\n' "$DIM" "$RESET"
RG="$TMP/redgrammar"
mkdir -p "$RG/scripts" "$RG/tests/handoff"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$RG/tests/run-all.sh"
for m in alpha beta gamma delta; do
  printf '%s\n' '#!/usr/bin/env bash' "${m}_MARK=old" > "$RG/scripts/$m.sh"
done
cat > "$RG/tests/test-alpha.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/alpha.sh"
[ "$alpha_MARK" = "new" ] && { echo "1 passed, 0 failed."; exit 0; }
echo "0 passed, 1 failed."
exit 1
EOS
cat > "$RG/tests/test-beta.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/beta.sh"
[ "$beta_MARK" = "new" ] && { echo "OK"; exit 0; }
echo "FAILED"
exit 1
EOS
cat > "$RG/tests/test-gamma.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/gamma.sh"
[ "$gamma_MARK" = "new" ] && { echo "PASS: test-gamma (1 checks)"; exit 0; }
echo "FAIL: test-gamma — 1 under budget, 1 over."
exit 1
EOS
cat > "$RG/tests/handoff/test-delta.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/delta.sh"
[ "$delta_MARK" = "new" ] && { echo "PASS: test-delta (1 checks)"; exit 0; }
echo "FAIL: test-delta — 0 passed, 1 failed."
exit 1
EOS
( cd "$RG" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
RGBASE=$(git -C "$RG" rev-parse HEAD)
for m in alpha beta gamma delta; do
  printf '%s\n' '#!/usr/bin/env bash' "${m}_MARK=new" > "$RG/scripts/$m.sh"
done
TMPDIR="$TMP/rgtmp" bash "$GATE" "$RG" "$RGBASE" > "$TMP/rg.log" 2>&1; RC=$?
hasre "$TMP/rg.log" '^REVERT_RED scripts/alpha\.sh: 1 failure\(s\)' \
  && ok "a suite printing '0 passed, 1 failed.' is counted as one real failure" || fail "count grammar" "$(grep alpha "$TMP/rg.log")"
hasre "$TMP/rg.log" '^REVERT_RED scripts/beta\.sh: red \(no count parsed\)' \
  && ok "a suite printing 'FAILED' is a real red with no count" || fail "FAILED grammar" "$(grep beta "$TMP/rg.log")"
hasre "$TMP/rg.log" '^REVERT_RED scripts/gamma\.sh: red \(no count parsed\)' \
  && ok "a suite printing 'FAIL: … under budget' is a real red with no count" || fail "FAIL-prefix grammar" "$(grep gamma "$TMP/rg.log")"
if has "$TMP/rg.log" 'REVERT_RED_BY_LOAD_FAILURE'; then fail "load failure misread" "$(grep LOAD_FAILURE "$TMP/rg.log")"; else ok "no real red is misreported as a load failure"; fi
hasre "$TMP/rg.log" '^REVERT_RED scripts/delta\.sh:' \
  && ok "a pin under tests/handoff/ is found: ** spans directories" || fail "nested pin" "$(grep delta "$TMP/rg.log")"
FAMLINE=$(grep '^FAMILIES ' "$TMP/rg.log" | head -1)
if [[ "$(printf '%s\n' "$FAMLINE" | grep -o ' | ' | grep -c . | tr -d ' ')" == "1" ]]; then ok "the FAMILIES line prints the summary once"; else fail "doubled summary" "$FAMLINE"; fi

printf '\n%s== the inventory refuses when git cannot read the copy ==%s\n' "$DIM" "$RESET"
MR2="$TMP/mainrepo2"; mkfixture "$MR2"
WT2="$TMP/linkedwt2"
git -C "$MR2" worktree add -q --detach "$WT2" HEAD >/dev/null 2>&1
if [[ -f "$WT2/.git" ]]; then
  printf '%s\n' '# module alpha' 'export ALPHA_MARK=new' > "$WT2/src/alpha.js"
  WT2BASE=$(git -C "$WT2" rev-parse HEAD)
  rm -f "$MR2/.git/worktrees/$(basename "$WT2")/index"
  bash "$GATE" "$WT2" "$WT2BASE" > "$TMP/idx.log" 2>&1; RC=$?
  if [[ "$RC" == "9" ]] && has "$TMP/idx.log" 'REFUSED'; then ok "an unreadable index is a loud refusal (exit 9), never a green empty inventory"; else fail "index refusal" "rc=$RC $(grep -E 'REFUSED|production changed|EXIT=' "$TMP/idx.log")"; fi
else
  printf '  %s-%s unreadable-index case not exercised: git did not create a linked worktree\n' "$DIM" "$RESET"
fi
bash "$GATE" "$SS" "$SSBASE" --no-typecheck > "$TMP/c1.log" 2>&1 &
C1=$!
bash "$GATE" "$SS" "$SSBASE" --no-typecheck > "$TMP/c2.log" 2>&1 &
C2=$!
wait "$C1" 2>/dev/null; wait "$C2" 2>/dev/null
L1=$(sed -n 's/.*logs=//p' "$TMP/c1.log" | head -1)
L2=$(sed -n 's/.*logs=//p' "$TMP/c2.log" | head -1)
if [[ -n "$L1" && "$L1" != "$L2" ]]; then ok "two runs started together never share a run directory"; else fail "shared rundir" "$L1 vs $L2"; fi
if hasre "$TMP/c1.log" '^REVERT_RED scripts/alpha\.sh:' && hasre "$TMP/c2.log" '^REVERT_RED scripts/alpha\.sh:'; then
  ok "both concurrent runs grade correctly"; else fail "concurrent grading" "$(grep -h REVERT "$TMP/c1.log" "$TMP/c2.log")"; fi

printf '\n%s== a wait_timeout_s that is not a whole number falls back, loudly ==%s\n' "$DIM" "$RESET"
sed 's|"wait_timeout_s": 5|"wait_timeout_s": "30s"|' "$FX/docs/llm-orchestrator/cadence.json" > "$TMP/badwait.json"
bash "$GATE" "$FX" "$BASE" --config "$TMP/badwait.json" --no-typecheck > "$LOG" 2>&1; RC=$?
if has "$LOG" 'wait_timeout_s' && has "$LOG" '1800'; then ok "a non-integer wait_timeout_s is reported and the shipped bound is used"; else fail "wait_timeout validation" "$(grep -i wait "$LOG")"; fi
if has "$LOG" 'integer expression expected'; then fail "wait_timeout errors" "$(grep -i 'integer expression' "$LOG" | head -2)"; else ok "no bash integer-expression error reaches the log"; fi

printf '\n%s== the gate needs its sibling, and says which one ==%s\n' "$DIM" "$RESET"
ALONE="$TMP/alone"; mkdir -p "$ALONE"; cp "$GATE" "$ALONE/orch-cadence-gate.sh"
bash "$ALONE/orch-cadence-gate.sh" "$FX" "$BASE" --no-typecheck > "$LOG" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$LOG" 'NEEDS cadence-detect.sh beside me'; then ok "a gate with no cadence-detect.sh beside it refuses (exit 9), for that reason"; else fail "missing sibling" "rc=$RC $(head -3 "$LOG")"; fi

printf '\n%s== a deleted production file is inventoried and graded ==%s\n' "$DIM" "$RESET"
DEL="$TMP/delfx"; mkfixture "$DEL"
DELBASE=$(git -C "$DEL" rev-parse HEAD)
rm -f "$DEL/src/epsilon.js"
DSNAPD0="$TMP/dsnapd0"; snapshot "$DEL" "$DSNAPD0"
TMPDIR="$TMP/deltmp" bash "$GATE" "$DEL" "$DELBASE" --no-typecheck > "$TMP/del.log" 2>&1; RC=$?
hasre "$TMP/del.log" '^  DELETED src/epsilon\.js$' && ok "a deleted production file appears in the inventory as DELETED" || fail "DELETED inventory" "$(grep -i epsilon "$TMP/del.log")"
hasre "$TMP/del.log" '^REVERT_STAYS_GREEN src/epsilon\.js: 1 suite\(s\) green' && ok "the deletion is restored from base, its pin run, and graded like the others" || fail "DELETED verdict" "$(grep -i epsilon "$TMP/del.log")"
[[ ! -e "$DEL/src/epsilon.js" ]] && ok "the deleted file stays deleted in the target" || fail "deletion undone" "src/epsilon.js came back"
DSNAPD1="$TMP/dsnapd1"; snapshot "$DEL" "$DSNAPD1"
cmp -s "$DSNAPD0" "$DSNAPD1" && ok "the deletion fixture's target is byte-identical after the run" || fail "del target mutated" "$(diff "$DSNAPD0" "$DSNAPD1" | head -6)"

printf '\n%s== the export sweep reads brace re-exports on the base side too ==%s\n' "$DIM" "$RESET"
BE="$TMP/braceexp"; mkfixture "$BE"
printf '%s\n' '# module rex' "export { zeta } from './other.js'" > "$BE/src/rex.js"
( cd "$BE" && git "${GIT_ID[@]}" add src/rex.js && git "${GIT_ID[@]}" commit -qm 'add rex' ) >/dev/null 2>&1
BEBASE=$(git -C "$BE" rev-parse HEAD)
printf '%s\n' '# module rex' 'export REX_MARK=1' > "$BE/src/rex.js"
TMPDIR="$TMP/betmp" bash "$GATE" "$BE" "$BEBASE" --no-typecheck > "$TMP/be.log" 2>&1
if grep -E '^REMOVED_EXPORTS src/rex\.js:.*zeta' "$TMP/be.log" >/dev/null 2>&1; then ok "a name that was a base-side brace re-export is reported as REMOVED"; else fail "base brace re-export" "$(grep -i export "$TMP/be.log" | head -4)"; fi

printf '\n%s== every profile proposes the same keys ==%s\n' "$DIM" "$RESET"
MISSING2=""
for p in jest vitest pytest shell-suites unknown; do
  bash "$DETECT" --profile "$p" > "$TMP/prof.json" 2>/dev/null
  for k in lang_globs suite_globs; do
    grep -q "\"$k\"" "$TMP/prof.json" || MISSING2="$MISSING2 $p:$k"
  done
done
[[ -z "$MISSING2" ]] && ok "lang_globs and suite_globs are emitted by every profile" || fail "profile keys" "missing:$MISSING2"

printf '\n%s== the gate header documents what the gate does not do ==%s\n' "$DIM" "$RESET"
HDR="$TMP/gate_header.txt"; sed -n '1,80p' "$GATE" > "$HDR"
has "$HDR" 'never consults' && ok "the header says the gate never consults \"enabled\"" || fail "header enabled" "$(grep -i enabled "$HDR" | head -3)"
if has "$HDR" 'lang_globs' && has "$HDR" 'suite_globs'; then ok "the header documents lang_globs and suite_globs"; else fail "header globs" "$(grep -i globs "$HDR" | head -3)"; fi
has "$HDR" 'cadence-detect.sh' && ok "the header says the profile table lives in cadence-detect.sh" || fail "header detector" "$(grep -i detect "$HDR" | head -3)"
has "$HDR" 'block comment' && ok "the header records the comment-prefix limitation" || fail "header comment limit" "$(grep -i comment "$HDR" | head -3)"
has "$HDR" 'a red family run and a REVERT_STAYS_GREEN verdict both leave it 0' \
  && ok "the header records what does and does not move the exit code" \
  || fail "header exit rule" "$(sed -n '/EXIT CODES/,/^#$/p' "$HDR")"

# ---------------------------------------------------------------------------
# Round-2 pins (the gate seat's delta). Each is written from its SCENE and was
# proven red before the mechanism it names existed.
# ---------------------------------------------------------------------------
printf '\n%s== the gate does not leak GIT_INDEX_FILE into the suites it runs ==%s\n' "$DIM" "$RESET"
# SCENE: a LINKED WORKTREE as the target (the shape every build worktree has, so
# the gate isolates the index) and a changed production file whose only suite
# does not depend on the change. The verdict must be the one a plain checkout
# gives — and the suite must run with the gate's private index nowhere in its
# environment, or its own `git init` fixtures write into the gate's index.
LWM="$TMP/lwmain"
mkdir -p "$LWM/scripts" "$LWM/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$LWM/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'alpha_MARK=old' > "$LWM/scripts/alpha.sh"
LWSEEN="$TMP/lwseen.txt"; : > "$LWSEEN"
cat > "$LWM/tests/test-alpha.sh" <<EOS
#!/usr/bin/env bash
set -uo pipefail
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
. "\$ROOT/scripts/alpha.sh"
printf 'SUITE_SEES GIT_INDEX_FILE=[%s]\n' "\${GIT_INDEX_FILE:-<unset>}" >> "$LWSEEN"
if [ -n "\${GIT_INDEX_FILE:-}" ]; then echo "0 passed, 1 failed."; exit 1; fi
echo "PASS: test-alpha (1 checks)"
exit 0
EOS
( cd "$LWM" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
LWWT="$TMP/lwlinked"
git -C "$LWM" worktree add -q --detach "$LWWT" HEAD >/dev/null 2>&1
if [[ -f "$LWWT/.git" ]]; then
  printf '%s\n' '#!/usr/bin/env bash' 'alpha_MARK=new' > "$LWWT/scripts/alpha.sh"
  LWBASE=$(git -C "$LWWT" rev-parse HEAD)
  TMPDIR="$TMP/lwtmp" bash "$GATE" "$LWWT" "$LWBASE" --no-typecheck > "$TMP/lw.log" 2>&1
  has "$TMP/lw.log" 'INDEX_ISOLATED' \
    && ok "the linked-worktree target really does take the isolated-index path" \
    || fail "lw not isolated" "$(grep -iE 'INDEX' "$TMP/lw.log" | head -3)"
  hasre "$TMP/lw.log" '^REVERT_STAYS_GREEN scripts/alpha\.sh:' \
    && ok "a linked-worktree target grades an unpinned change exactly as a plain checkout does" \
    || fail "index leak inverts the verdict" "$(grep -E '^REVERT' "$TMP/lw.log")"
  if [[ -s "$LWSEEN" ]] && ! grep -qv 'GIT_INDEX_FILE=\[<unset>\]' "$LWSEEN"; then
    ok "every suite the gate ran saw GIT_INDEX_FILE unset"
  else
    fail "GIT_INDEX_FILE leaked into a suite" "$(sort -u "$LWSEEN" | head -3)"
  fi
else
  printf '  %s-%s GIT_INDEX_FILE leak case not exercised: git did not create a linked worktree\n' "$DIM" "$RESET"
fi

printf '\n%s== the failure count and the summary are read per suite ==%s\n' "$DIM" "$RESET"
# SCENE: two suites in one family run — the first really fails, the second
# passes while printing its own fixture's "0 passed, 2 failed." line. The count
# is the real one, and the summary shown is the FAILING suite's, not whichever
# suite happened to run last.
NF="$TMP/nestedfail"
mkdir -p "$NF/scripts" "$NF/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$NF/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'aaa_MARK=old' > "$NF/scripts/aaa.sh"
printf '%s\n' '#!/usr/bin/env bash' 'zzz_MARK=old' > "$NF/scripts/zzz.sh"
cat > "$NF/tests/test-aaa.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/aaa.sh"
[ "$aaa_MARK" = "old" ] && { echo "PASS: test-aaa (1 checks)"; exit 0; }
echo "FAIL: test-aaa — 0 passed, 1 failed."
exit 1
EOS
cat > "$NF/tests/test-zzz.sh" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/zzz.sh"
echo "  the fixture this suite drives printed:"
echo "  0 passed, 2 failed."
echo "PASS: test-zzz (1 checks)"
exit 0
EOS
( cd "$NF" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
NFBASE=$(git -C "$NF" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'aaa_MARK=new' > "$NF/scripts/aaa.sh"
printf '%s\n' '#!/usr/bin/env bash' 'zzz_MARK=new' > "$NF/scripts/zzz.sh"
TMPDIR="$TMP/nftmp" bash "$GATE" "$NF" "$NFBASE" --no-typecheck > "$TMP/nf.log" 2>&1
NFFAM=$(grep '^FAMILIES ' "$TMP/nf.log" | head -1)
[[ "$NFFAM" == *"failures=1"* ]] \
  && ok "a nested '0 passed, 2 failed.' line inside a passing suite is not counted" \
  || fail "nested output counted" "$NFFAM"
[[ "$NFFAM" == *"FAIL: test-aaa"* ]] \
  && ok "the FAMILIES summary is the failing suite's line, not the last suite's" \
  || fail "summary names the last suite" "$NFFAM"
TMPDIR="$TMP/nftmp2" bash "$GATE" "$NF" "$NFBASE" --no-typecheck --families "tests/test-zzz.sh" > "$TMP/nf2.log" 2>&1
NFFAM2=$(grep '^FAMILIES ' "$TMP/nf2.log" | head -1)
[[ "$NFFAM2" == *"failures=0"* ]] \
  && ok "a family run in which every suite passed reports failures=0" \
  || fail "nested count on an all-green run" "$NFFAM2"

printf '\n%s== a git that cannot read the copy refuses, whatever broke it ==%s\n' "$DIM" "$RESET"
# SCENE: an index that is not missing and not empty — it is unparseable. The
# 0-byte case above is pinned; this is the other half of the same guard, the one
# where `git diff --name-only` itself fails and an empty inventory would read as
# "nothing changed".
CI="$TMP/corruptidx"
mkdir -p "$CI/scripts" "$CI/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$CI/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ci_MARK=old' > "$CI/scripts/ci.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "PASS: test-ci (1 checks)"' > "$CI/tests/test-ci.sh"
( cd "$CI" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
CIBASE=$(git -C "$CI" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'ci_MARK=new' > "$CI/scripts/ci.sh"
printf 'not an index, but not empty either\n' > "$CI/.git/index"
TMPDIR="$TMP/citmp" bash "$GATE" "$CI" "$CIBASE" --no-typecheck > "$TMP/ci.log" 2>&1; RC=$?
if [[ "$RC" == "9" ]] && has "$TMP/ci.log" 'REFUSED: git could not read the copy'; then
  ok "an index git cannot parse is a loud refusal (exit 9), never a green empty inventory"
else
  fail "corrupt index refusal" "rc=$RC $(grep -E 'REFUSED|production changed|EXIT=' "$TMP/ci.log" | head -3)"
fi
[[ "$(tail -1 "$TMP/ci.log")" == "EXIT=9" ]] \
  && ok "that refusal is the last word: EXIT=9" || fail "corrupt index exit line" "$(tail -2 "$TMP/ci.log")"

printf '\n%s== a caller-set GIT_INDEX_FILE never becomes the gate'"'"'s idea of the target'"'"'s index ==%s\n' "$DIM" "$RESET"
# SCENE (the gate seat's G2): a caller whose environment already carries
# GIT_INDEX_FILE — a git hook, or a nested gate — runs the gate on a plain
# checkout. The gate must read the COPY's own index, print "INDEX in the copy",
# and list each changed file once; inheriting the caller's index doubled the
# inventory and printed a false INDEX_ISOLATED line.
CE="$TMP/callerenv"
mkdir -p "$CE/scripts" "$CE/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$CE/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ce_MARK=old' > "$CE/scripts/ce.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "PASS: test-ce (1 checks)"' > "$CE/tests/test-ce.sh"
( cd "$CE" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
CEBASE=$(git -C "$CE" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'ce_MARK=new' > "$CE/scripts/ce.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ce_new=1' > "$CE/scripts/ce_new.sh"
FOREIGN="$TMP/foreign"; mkdir -p "$FOREIGN/scripts"; ( cd "$FOREIGN" && git init -q . && printf 'x\n' > scripts/f.sh && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm f ) >/dev/null 2>&1
GIT_INDEX_FILE="$FOREIGN/.git/index" TMPDIR="$TMP/cetmp" bash "$GATE" "$CE" "$CEBASE" --no-typecheck > "$TMP/ce.log" 2>&1
has "$TMP/ce.log" 'INDEX in the copy' && ! has "$TMP/ce.log" 'INDEX_ISOLATED' \
  && ok "a plain checkout reads its own index even when the caller exported one" \
  || fail "caller index inherited" "$(grep -E 'INDEX' "$TMP/ce.log" | head -2)"
[[ "$(grep -c '^  NEW_FILE scripts/' "$TMP/ce.log")" == "1" ]] && ! has "$TMP/ce.log" 'NEW_FILE scripts/ce.sh' \
  && ok "the inventory lists each file once: the tracked change is not repeated as NEW_FILE" \
  || fail "inventory doubled under a caller index" "$(grep -E 'NEW_FILE|production' "$TMP/ce.log" | head -5)"

printf '\n%s== when the only failing suite prints no summary, FAMILIES says so instead of naming a passing suite ==%s\n' "$DIM" "$RESET"
# SCENE (the gate seat's G3): test-aaa fails without any parseable summary line;
# test-zzz passes later with one. The FAMILIES digest beside EXIT=1 must not be
# the passing suite's line.
NS="$TMP/nosummary"
mkdir -p "$NS/scripts" "$NS/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$NS/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'aaa_MARK=old' > "$NS/scripts/aaa.sh"
printf '%s\n' '#!/usr/bin/env bash' 'zzz_MARK=old' > "$NS/scripts/zzz.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' '. "$ROOT/scripts/aaa.sh"' 'echo "the suite died before it could summarize"' 'exit 1' > "$NS/tests/test-aaa.sh"
printf '%s\n' '#!/usr/bin/env bash' 'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' '. "$ROOT/scripts/zzz.sh"' 'echo "PASS: test-zzz (1 checks)"' > "$NS/tests/test-zzz.sh"
( cd "$NS" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
NSBASE=$(git -C "$NS" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'aaa_MARK=new' > "$NS/scripts/aaa.sh"
printf '%s\n' '#!/usr/bin/env bash' 'zzz_MARK=new' > "$NS/scripts/zzz.sh"
TMPDIR="$TMP/nstmp" bash "$GATE" "$NS" "$NSBASE" --no-typecheck > "$TMP/ns.log" 2>&1
NSFAM=$(grep '^FAMILIES ' "$TMP/ns.log" | head -1)
[[ "$NSFAM" == *"EXIT=1"* && "$NSFAM" == *"no summary line"* && "$NSFAM" != *"PASS: test-zzz"* ]] \
  && ok "a red family run whose failing suite printed no summary is digested as 'no summary line'" \
  || fail "passing suite named beside EXIT=1" "$NSFAM"

printf '\n%s== the gate'"'"'s own LC_ALL=C never reaches the suites it runs ==%s\n' "$DIM" "$RESET"
# SCENE: the gate runs its own greps under LC_ALL=C. A suite it spawns must see
# the CALLER's locale (here: unset), or a Unicode-aware assertion in that suite
# goes silent under C and the family run prints a false red. Same class as the
# GIT_INDEX_FILE leak: gate environment reaching the runner.
LE="$TMP/localeenv"
mkdir -p "$LE/scripts" "$LE/tests"
printf '%s\n' '#!/usr/bin/env bash' 'for t in tests/test-*.sh; do bash "$t" || exit 1; done' > "$LE/tests/run-all.sh"
printf '%s\n' '#!/usr/bin/env bash' 'le_MARK=old' > "$LE/scripts/le.sh"
LESEEN="$TMP/leseen.txt"; : > "$LESEEN"
cat > "$LE/tests/test-le.sh" <<EOS
#!/usr/bin/env bash
ROOT="\$(cd "\$(dirname "\$0")/.." && pwd)"
. "\$ROOT/scripts/le.sh"
printf 'SUITE_SEES LC_ALL=[%s]\n' "\${LC_ALL-<unset>}" >> "$LESEEN"
if [ "\${LC_ALL-}" = "C" ]; then echo "0 passed, 1 failed."; exit 1; fi
echo "PASS: test-le (1 checks)"
EOS
( cd "$LE" && git init -q . && git "${GIT_ID[@]}" add -A && git "${GIT_ID[@]}" commit -qm base ) >/dev/null 2>&1
LEBASE=$(git -C "$LE" rev-parse HEAD)
printf '%s\n' '#!/usr/bin/env bash' 'le_MARK=new' > "$LE/scripts/le.sh"
env -u LC_ALL TMPDIR="$TMP/letmp" bash "$GATE" "$LE" "$LEBASE" --no-typecheck > "$TMP/le.log" 2>&1
if [[ -s "$LESEEN" ]] && ! grep -qv 'LC_ALL=\[<unset>\]' "$LESEEN"; then
  ok "a suite the gate runs sees the caller's locale (unset), not the gate's LC_ALL=C"
else
  fail "LC_ALL=C leaked into a suite" "$(sort -u "$LESEEN" | head -3)"
fi
hasre "$TMP/le.log" '^FAMILIES EXIT=0 ' \
  && ok "no false family red from the gate's own locale" \
  || fail "family red under the gate's locale" "$(grep '^FAMILIES' "$TMP/le.log")"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-gate%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-cadence-gate — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
