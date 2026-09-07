#!/usr/bin/env bash
# Codex adapter tests — the adapter is Codex's substitute for Claude Code's
# native file-deny rules and nothing more, so this suite pins exactly that:
# a Bash command or an apply_patch header that names a locked FILE and is not
# one plain read is refused; everything else passes.
#
# Payload fixtures are written to FILES and fed with `< file`, never piped: a
# pipe hides the exit code behind the writer's and makes an assertion of "2" an
# assertion of nothing. Every check runs inside an armed mktemp -d fixture with
# HOME pointed at a temp directory, so the real HOME is never a party to it.
#
# Covers:
#   A1 stage-1 inertness (no cadence.json, enabled false, garbage payload)
#   A2 the decode fallback with no python3 on PATH
#   A3 every lock file against six writer verbs
#   A4 the plain reads that must keep working, and the pipe that is refused
#   A5 ordinary work that names nothing
#   A6 lock_extra, the absolute-path spelling, the case fold, the basename
#   A7 apply_patch headers in every position
#   A8 the unlock, and the persisted-unlock refusal
#   A9 hygiene: the size ceiling, no reference to the deleted guard, HOME clean
#
# Bash 3.2 compatible. Exits non-zero on any failure.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$ROOT/scripts/hooks/codex-cadence-adapter.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi

PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
section() { printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RESET"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$ADAPTER" ]]; then
  printf 'FAIL: test-codex-adapter — missing %s\n' "$ADAPTER"
  exit 1
fi

have_python3=0
command -v python3 >/dev/null 2>&1 && have_python3=1
if [[ $have_python3 -eq 0 ]]; then
  printf 'FAIL: test-codex-adapter — python3 is required to build the payload fixtures\n'
  exit 1
fi

# ------------------------------------------------------------
# Fixtures. Four project roots: armed, opted out, never opted in, and armed
# with a lock_extra entry. HOME is a temp directory for every run.
# ------------------------------------------------------------
arm() {  # arm <dir> [lock_extra-json]
  mkdir -p "$1/docs/llm-orchestrator/notes" "$1/.claude" "$1/.githooks" "$1/src"
  if [[ -n "${2:-}" ]]; then
    printf '{ "schema": 1, "enabled": true, "lock_extra": %s }\n' "$2" \
      > "$1/docs/llm-orchestrator/cadence.json"
  else
    printf '{ "schema": 1, "enabled": true }\n' > "$1/docs/llm-orchestrator/cadence.json"
  fi
  printf '# Laws\n' > "$1/docs/llm-orchestrator/LAWS.md"
  printf 'abc  docs/llm-orchestrator/LAWS.md\n' > "$1/docs/llm-orchestrator/LOCK.sha256"
  printf '{}\n' > "$1/.claude/settings.json"
  printf '#!/bin/sh\n' > "$1/.githooks/commit-msg"
  printf '#!/bin/sh\n' > "$1/.githooks/orch-cadence-check.sh"
  printf '# Project\n' > "$1/CLAUDE.md"
  printf 'note\n' > "$1/docs/llm-orchestrator/notes/a.md"
}
CAD="$TMP/cad";   arm "$CAD"
XTRA="$TMP/xtra"; arm "$XTRA" '["docs/llm-orchestrator/PLAN.md"]'
OFF="$TMP/off";   arm "$OFF"
printf '{ "schema": 1, "enabled": false }\n' > "$OFF/docs/llm-orchestrator/cadence.json"
BARE="$TMP/bare"; mkdir -p "$BARE/docs/llm-orchestrator"

HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR/.claude" "$HOMEDIR/.codex"
home_state() { find "$HOMEDIR" | sort | shasum | awk '{print $1}'; }
HOME_BEFORE=$(home_state)

# A PATH with no python3 on it, carrying only the tools the fallback needs.
NOPY="$TMP/nopy"; mkdir -p "$NOPY"
for t in tr sed grep cat bash; do ln -sf "$(command -v "$t")" "$NOPY/$t"; done

N=0
# payload <tool_name> <field> <value> -> path of the payload FILE
payload() {
  N=$((N+1))
  local f="$TMP/payload-$N.json"
  TOOLN="$1" FIELD="$2" VAL="$3" python3 -c 'import json, os, sys
json.dump({"session_id": "s", "cwd": ".", "hook_event_name": "PreToolUse",
           "tool_name": os.environ["TOOLN"],
           "tool_input": {os.environ["FIELD"]: os.environ["VAL"]}},
          open(sys.argv[1], "w"))' "$f"
  printf '%s' "$f"
}

# payload_raw <tool_name> <field> <raw-json-value> -> path of the payload FILE
# The value is spliced in as JSON, so command can be an array, a number or null.
payload_raw() {
  N=$((N+1))
  local f="$TMP/payload-$N.json"
  TOOLN="$1" FIELD="$2" RAW="$3" python3 -c 'import json, os, sys
json.dump({"session_id": "s", "cwd": ".", "hook_event_name": "PreToolUse",
           "tool_name": os.environ["TOOLN"],
           "tool_input": {os.environ["FIELD"]: json.loads(os.environ["RAW"])}},
          open(sys.argv[1], "w"))' "$f"
  printf '%s' "$f"
}

# run_adapter <root> <payload-file> [env assignments...] -> exit code
run_adapter() {
  local root="$1" pf="$2"; shift 2
  local rc
  ( cd "$root" && env HOME="$HOMEDIR" "$@" bash "$ADAPTER" < "$pf" ) \
    > "$TMP/out.txt" 2> "$TMP/err.txt"
  rc=$?
  printf '%s' "$rc"
}

# expect <rc> <root> <tool> <field> <value> <label> [env...]
expect() {
  local want="$1" root="$2" tool="$3" field="$4" val="$5" label="$6"; shift 6
  local pf rc
  pf=$(payload "$tool" "$field" "$val")
  rc=$(run_adapter "$root" "$pf" "$@")
  if [[ "$rc" == "$want" ]]; then
    ok "$label"
  else
    fail "$label" "exit $rc (expected $want): $(head -2 "$TMP/err.txt" | tr '\n' ' ')"
  fi
}
bash_pin()  { expect "$1" "${4:-$CAD}" Bash command "$2" "Bash → $1: $3"; }
patch_pin() { expect "$1" "$CAD" apply_patch command "$2" "apply_patch → $1: $3"; }

LOCKFILES=(docs/llm-orchestrator/LAWS.md docs/llm-orchestrator/cadence.json \
           docs/llm-orchestrator/LOCK.sha256 .claude/settings.json \
           .githooks/commit-msg .githooks/orch-cadence-check.sh)

# ------------------------------------------------------------
section "A1 — stage-1 inertness"
bash_pin 0 'echo x > docs/llm-orchestrator/LAWS.md' 'no cadence.json at all' "$BARE"
bash_pin 0 'echo x > docs/llm-orchestrator/LAWS.md' 'cadence.json says enabled false' "$OFF"
printf 'not json at all' > "$TMP/garbage.json"
rc=$(run_adapter "$CAD" "$TMP/garbage.json")
[[ "$rc" == 0 ]] && ok "garbage payload → 0" || fail "garbage payload → 0" "exit $rc"

# ------------------------------------------------------------
section "A2 — the decode fallback with no python3 on PATH"
pf=$(payload Bash command 'echo x > docs/llm-orchestrator/LAWS.md')
rc=$(run_adapter "$CAD" "$pf" PATH="$NOPY")
[[ "$rc" == 2 ]] && ok "no python3: a lock write is still refused" || fail "no python3: a lock write is still refused" "exit $rc"
pf=$(payload Bash command 'npm test')
rc=$(run_adapter "$CAD" "$pf" PATH="$NOPY")
[[ "$rc" == 0 ]] && ok "no python3: ordinary work still passes" || fail "no python3: ordinary work still passes" "exit $rc"
rc=$(run_adapter "$CAD" "$TMP/garbage.json" PATH="$NOPY")
[[ "$rc" == 0 ]] && ok "no python3: garbage → 0" || fail "no python3: garbage → 0" "exit $rc"

# ------------------------------------------------------------
section "A3 — every lock file against six writer verbs"
for lf in "${LOCKFILES[@]}"; do
  bash_pin 2 "echo x > $lf"            "echo > $lf"
  bash_pin 2 "cp x $lf"                "cp x $lf"
  bash_pin 2 "sed -i '' s/a/b/ $lf"    "sed -i $lf"
  bash_pin 2 "tee $lf"                 "tee $lf"
  bash_pin 2 "curl -o$lf http://x/y"   "curl -o glued to $lf"
  bash_pin 2 "rm $lf"                  "rm $lf"
done

# ------------------------------------------------------------
section "A4 — the plain reads, and the pipe that is refused"
bash_pin 0 'cat docs/llm-orchestrator/LAWS.md'          'cat a lock file'
bash_pin 0 'grep -n x docs/llm-orchestrator/LAWS.md'    'grep a lock file'
bash_pin 0 'git diff HEAD -- docs/llm-orchestrator/LAWS.md' 'git diff a lock file'
bash_pin 0 'shasum docs/llm-orchestrator/LOCK.sha256'   'shasum a lock file'
bash_pin 0 'cat .claude/settings.json'                  'cat the settings file'
pf=$(payload Bash command 'cat docs/llm-orchestrator/LAWS.md | jq .')
rc=$(run_adapter "$CAD" "$pf")
[[ "$rc" == 2 ]] && ok "a read inside a pipeline is refused (the accepted cost)" \
                 || fail "a read inside a pipeline is refused (the accepted cost)" "exit $rc"
if grep -q 'cat docs/llm-orchestrator/laws.md' "$TMP/err.txt" && grep -q 'ORCH_CADENCE_UNLOCK=1' "$TMP/err.txt"; then
  ok "the refusal prints both ways out (one plain read, or the unlock)"
else
  fail "the refusal prints both ways out (one plain read, or the unlock)" "$(cat "$TMP/err.txt")"
fi

# ------------------------------------------------------------
section "A5 — ordinary work that names nothing"
bash_pin 0 'npm test'                              'npm test'
bash_pin 0 'rm -rf build'                          'rm -rf build'
bash_pin 0 'echo x > docs/README.md'               'a write under docs/'
bash_pin 0 'cat CLAUDE.md'                         'cat CLAUDE.md'
bash_pin 0 'rm docs/llm-orchestrator/notes/a.md'   'rm a note beside the lock set'
bash_pin 0 'echo x > CLAUDE.md'                    'a write to CLAUDE.md (the alarm owns the section)'

# ------------------------------------------------------------
section "A6 — lock_extra and the three spellings"
bash_pin 2 'echo x > docs/llm-orchestrator/PLAN.md' 'a lock_extra entry is locked' "$XTRA"
bash_pin 0 'echo x > docs/llm-orchestrator/PLAN.md' 'the same path is free without lock_extra'
bash_pin 2 "echo x > $CAD/docs/llm-orchestrator/LAWS.md" 'the absolute-path spelling'
bash_pin 2 'echo x > DOCS/LLM-ORCHESTRATOR/LAWS.MD'      'the case-folded spelling'
bash_pin 2 'rm LAWS.md'                                  'the bare basename LAWS.md'
bash_pin 2 'rm lock.sha256'                              'the bare basename LOCK.sha256'
bash_pin 0 'cat LAWS.md'                                 'the basename read is still a read'

# ------------------------------------------------------------
section "A7 — apply_patch headers"
for h in 'Add File' 'Delete File' 'Update File' 'Move to'; do
  patch_pin 2 "*** Begin Patch
*** ${h}: docs/llm-orchestrator/LAWS.md
*** End Patch" "${h} on a lock file"
done
for lf in docs/llm-orchestrator/cadence.json docs/llm-orchestrator/LOCK.sha256 \
          .claude/settings.json .githooks/commit-msg .githooks/orch-cadence-check.sh; do
  patch_pin 2 "*** Begin Patch
*** Update File: $lf
+x
*** End Patch" "Update File $lf"
done
patch_pin 0 "*** Begin Patch
*** Update File: src/a.ts
+x
*** End Patch" 'Update File src/a.ts'
patch_pin 0 "*** Begin Patch
*** Update File: CLAUDE.md
+x
*** End Patch" 'Update File CLAUDE.md'
patch_pin 0 "*** Begin Patch
*** Delete File: .githooks/x
*** End Patch" 'Delete File .githooks/x (not in the lock set)'
patch_pin 0 "*** Begin Patch
*** Update File: src/a.ts
+ the text mentions docs/llm-orchestrator/LAWS.md in a comment
*** End Patch" 'a hunk that only mentions a lock file (no hunk analysis)'
expect 2 "$CAD" apply_patch patch "*** Begin Patch
*** Update File: docs/llm-orchestrator/LAWS.md
*** End Patch" 'apply_patch → 2: the patch arrives in tool_input.patch'

# ------------------------------------------------------------
section "A8 — the unlock and the persisted-unlock refusal"
pf=$(payload Bash command 'echo x > docs/llm-orchestrator/LAWS.md')
rc=$(run_adapter "$CAD" "$pf" ORCH_CADENCE_UNLOCK=1)
[[ "$rc" == 0 ]] && ok "the unlock frees a lock write" || fail "the unlock frees a lock write" "exit $rc"
pf2=$(payload apply_patch command "*** Begin Patch
*** Update File: docs/llm-orchestrator/LAWS.md
*** End Patch")
rc=$(run_adapter "$CAD" "$pf2" ORCH_CADENCE_UNLOCK=1)
[[ "$rc" == 0 ]] && ok "the unlock frees a patch too" || fail "the unlock frees a patch too" "exit $rc"

PERS="$TMP/pers"; arm "$PERS"
printf '{ "env": { "ORCH_CADENCE_UNLOCK": "1" } }\n' > "$PERS/.claude/settings.json"
pfp=$(payload Bash command 'echo x > docs/llm-orchestrator/LAWS.md')
rc=$(run_adapter "$PERS" "$pfp" ORCH_CADENCE_UNLOCK=1)
[[ "$rc" == 2 ]] && ok "a settings file that persists the unlock disarms it" \
                 || fail "a settings file that persists the unlock disarms it" "exit $rc"
grep -q 'persisted unlock is a disarmed lock' "$TMP/err.txt" \
  && ok "the refusal names the file that persists the unlock" \
  || fail "the refusal names the file that persists the unlock" "$(cat "$TMP/err.txt")"

PERS2="$TMP/pers2"; arm "$PERS2"; mkdir -p "$PERS2/.codex"
printf 'ORCH_CADENCE_UNLOCK = "1"\n' > "$PERS2/.codex/config.toml"
rc=$(run_adapter "$PERS2" "$pfp" ORCH_CADENCE_UNLOCK=1)
[[ "$rc" == 2 ]] && ok "the project Codex config persists it too" || fail "the project Codex config persists it too" "exit $rc"

HOME2="$TMP/home2"; mkdir -p "$HOME2/.codex"
printf 'ORCH_CADENCE_UNLOCK = "1"\n' > "$HOME2/.codex/config.toml"
rc=$( ( cd "$CAD" && env HOME="$HOME2" ORCH_CADENCE_UNLOCK=1 bash "$ADAPTER" < "$pfp" ) >/dev/null 2>&1; printf '%s' "$?" )
[[ "$rc" == 2 ]] && ok "the home Codex config persists it too" || fail "the home Codex config persists it too" "exit $rc"

rc=$(run_adapter "$PERS" "$pfp")
[[ "$rc" == 2 ]] && ok "with the unlock unset, a persisting file changes nothing" \
                 || fail "with the unlock unset, a persisting file changes nothing" "exit $rc"
pfo=$(payload Bash command 'npm test')
rc=$(run_adapter "$PERS" "$pfo")
[[ "$rc" == 0 ]] && ok "and ordinary work under it still passes" || fail "and ordinary work under it still passes" "exit $rc"

# ------------------------------------------------------------
section "A10 — an interior newline is an operator"
bash_pin 2 "cat CLAUDE.md
cp /tmp/x docs/llm-orchestrator/LAWS.md" 'a reader on line 1, a lock-file write on line 2'
bash_pin 2 "cat docs/llm-orchestrator/LAWS.md
rm docs/llm-orchestrator/LAWS.md" 'a read of a lock file, then a delete of it'
bash_pin 2 "cat CLAUDE.md$(printf '\r')
cp /tmp/x docs/llm-orchestrator/LAWS.md" 'the same payload with CRLF line endings'
bash_pin 0 "cat docs/llm-orchestrator/LAWS.md
" 'one plain read with a single trailing newline'
bash_pin 0 "npm test
npm run build" 'two ordinary lines that name nothing'

# ------------------------------------------------------------
section "A11 — with no python3 the hook fails closed on a named lock file"
# nopy_pin <want> <tool> <field> <value> <label>
nopy_pin() {
  local want="$1" pf rc
  pf=$(payload "$2" "$3" "$4")
  rc=$(run_adapter "$CAD" "$pf" PATH="$NOPY")
  if [[ "$rc" == "$want" ]]; then ok "no python3 → $want: $5"
  else fail "no python3 → $want: $5" "exit $rc"; fi
}
nopy_pin 2 Bash command "cat CLAUDE.md
cp /tmp/x docs/llm-orchestrator/LAWS.md" 'the two-line payload that names a lock file'
nopy_pin 2 Bash command 'cat docs/llm-orchestrator/LAWS.md' 'even one plain read (the accepted cost)'
if grep -q 'python3 is not on the PATH' "$TMP/err.txt"; then
  ok "no python3: the refusal says why it cannot read the command"
else
  fail "no python3: the refusal says why it cannot read the command" "$(cat "$TMP/err.txt")"
fi
nopy_pin 0 Bash command 'npm test' 'ordinary work still passes'
nopy_pin 2 apply_patch patch "*** Begin Patch
*** Update File: docs/llm-orchestrator/LAWS.md
*** End Patch" 'a patch that names a lock file'

# ------------------------------------------------------------
section "A12 — patch headers after leading blanks"
patch_pin 2 "*** Begin Patch
  *** Update File: docs/llm-orchestrator/LAWS.md
+x
*** End Patch" 'a space-indented Update File header on a lock file'
patch_pin 2 "*** Begin Patch
	*** Delete File: .claude/settings.json
*** End Patch" 'a tab-indented Delete File header on the settings file'
patch_pin 0 "*** Begin Patch
  *** Update File: src/a.ts
+x
*** End Patch" 'an indented header on an ordinary file'

# ------------------------------------------------------------
section "A13 — a non-string command is judged on its JSON text"
# raw_pin <want> <raw-json-value> <label>
raw_pin() {
  local want="$1" pf rc
  pf=$(payload_raw Bash command "$2")
  rc=$(run_adapter "$CAD" "$pf")
  if [[ "$rc" == "$want" ]]; then ok "non-string → $want: $3"
  else fail "non-string → $want: $3" "exit $rc"; fi
}
raw_pin 2 '["cp","x","docs/llm-orchestrator/LAWS.md"]' 'an argv array that writes a lock file'
if grep -qF 'cadence lock: "cp"' "$TMP/err.txt"; then
  ok "the refusal quotes the joined argv, not the JSON punctuation"
else
  fail "the refusal quotes the joined argv, not the JSON punctuation" "$(head -1 "$TMP/err.txt")"
fi
raw_pin 0 '["npm","test"]' 'an argv array that names nothing'
raw_pin 0 '42' 'a number'
raw_pin 0 'null' 'a null command'
raw_pin 0 '["cat","docs/llm-orchestrator/LAWS.md"]' 'an argv array that plainly reads a lock file'
raw_pin 2 '["bash","-lc","rm docs/llm-orchestrator/LAWS.md"]' 'an argv array whose joined text writes a lock file'
raw_pin 2 '{"a":"docs/llm-orchestrator/LAWS.md"}' 'an object naming a lock file'
if grep -qF '{"a"' "$TMP/err.txt"; then
  ok "a shape that is no list of strings still quotes the JSON text, not a Python repr"
else
  fail "a shape that is no list of strings still quotes the JSON text, not a Python repr" "$(head -1 "$TMP/err.txt")"
fi

# ------------------------------------------------------------
section "A14 — a bare basename matches only as a whole path component"
bash_pin 0 'rm docs/outlaws.md'                              'laws.md inside a longer name'
bash_pin 0 'rm dist/lock.sha256.txt'                         'lock.sha256 with a longer extension'
bash_pin 0 'echo x > vendor/tool/orch-cadence-check.sh.orig' 'a .orig copy of the check script'
bash_pin 0 'cp /tmp/a docs/llm-orchestrator/plans/laws.md.tpl' 'a template named after a lock file'
bash_pin 0 'rm build/cadence.json.bak'                       'cadence.json.bak is a longer token'
bash_pin 0 'curl -olaws.md u'                                'a bare basename glued into an option'
bash_pin 2 'curl -odocs/llm-orchestrator/laws.md u'          'the relative path glued into an option'
bash_pin 2 'rm LAWS.md'                                      'the whole-component basename still refuses'
bash_pin 2 'rm .cache/cadence.json'                          'a same-named file elsewhere in the tree'
# A quoted word is bounded exactly like a path operand, so these two stay at 2:
# with no tokenizer the hook cannot tell a message from an operand.
bash_pin 2 "git commit -m 'update the laws.md doc link'"     'a basename inside a quoted commit message'
bash_pin 2 "echo 'see LAWS.md' >> README.md"                 'a basename inside a quoted echo'

# ------------------------------------------------------------
section "A15 — a trailing CR is stripped before the verdict"
CR=$(printf '\r')
bash_pin 0 "cat docs/llm-orchestrator/LAWS.md${CR}
" 'one plain read terminated by CRLF'
bash_pin 0 "cat docs/llm-orchestrator/LAWS.md${CR}" 'one plain read terminated by a bare CR'

# ------------------------------------------------------------
section "A9 — hygiene"
lines=$(wc -l < "$ADAPTER" | tr -d ' ')
if [[ "$lines" -le 95 ]]; then ok "the adapter is $lines lines (ceiling 95)"
else fail "the adapter is $lines lines (ceiling 95)" "it grew back"; fi
if grep -q 'guard-cadence-lock' "$ADAPTER"; then
  fail "the adapter names no deleted guard" "it still references guard-cadence-lock"
else ok "the adapter names no deleted guard"; fi
if [[ "$(home_state)" == "$HOME_BEFORE" ]]; then ok "the temp HOME is byte-identical after every run"
else fail "the temp HOME is byte-identical after every run" "the adapter wrote into HOME"; fi

# ------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-codex-adapter%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-codex-adapter — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
