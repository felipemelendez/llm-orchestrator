#!/usr/bin/env bash
# Tests for the unlock guard (guard-cadence-unlock.sh) — a MENTION RULE.
#
# WHAT IT PINS. In cadence mode a Bash command whose decoded text (continued
# lines joined) CONTAINS one of the four cadence switch names is refused with
# exit 2 — whatever the verb. The switches are set by a person at launch in
# their own shell; a command an agent runs may not name them, not to set one,
# not to read one, not to search for one. Because no assignment spelling is
# described, no assignment spelling can be missed: `=`, `+=`, `${:=}`,
# `declare`, `read -r -p ""`, `printf -v`, a line continuation between the name
# and its `=` — all one check.
#
# THE COST, pinned as a cost and not as a bug: a read (`echo $NAME`), a search
# (`grep -rn NAME docs/`), a comment naming one, an `unset`, and a longer name
# that contains one are all refused too.
#
# WHAT IT MUST NOT PIN. A payload for any other tool passes; outside cadence
# mode the hook is inert; ordinary work is untouched. The residual is a name
# split by a quote or assembled at runtime: pinned here as allowed, so the day
# it changes the pin says so.
#
# WITHOUT python3 the hook has no decoder and searches the raw payload the same
# way.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/guard-cadence-unlock.sh"

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

command -v python3 >/dev/null 2>&1 || skip_suite test-cadence-unlock-guard 'python3 unavailable'
[[ -f "$HOOK" ]] || { printf '%sFAIL: test-cadence-unlock-guard — missing %s%s\n' "$RED" "$HOOK" "$RESET"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ERR="$TMP/stderr.txt"
RCS="$TMP/rcs.txt"; : > "$RCS"

# A PATH with no python3 on it, to prove the hook still searches the raw payload.
NOPY="$TMP/nopy"; mkdir -p "$NOPY"
for b in bash sh cat grep sed awk dirname basename head tr env printf test; do
  _p=$(command -v "$b" 2>/dev/null) && ln -sf "$_p" "$NOPY/$b" 2>/dev/null
done
if [[ -x "$NOPY/bash" ]] && ! env PATH="$NOPY" command -v python3 >/dev/null 2>&1; then
  HAVE_NOPY=1
else
  HAVE_NOPY=0
fi

mkproj() { # mkproj <dir> <enabled>
  mkdir -p "$1/docs/llm-orchestrator" "$1/.claude"
  printf '{ "schema": 1, "enabled": %s }\n' "$2" > "$1/docs/llm-orchestrator/cadence.json"
}
ON="$TMP/on";   mkproj "$ON" true
OFF="$TMP/off"; mkproj "$OFF" false
BARE="$TMP/bare"; mkdir -p "$BARE"

# payload <command-text> -> a Bash PreToolUse event, JSON-encoded by python3 so
# a quote, a backslash or a newline in the command reaches the hook intact.
# Every payload this suite sends is written to a file first and fed from it.
payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# run <project-dir> <payload-file> [PATH-override] -> prints rc, records it
run() {
  local proj="$1" pf="$2" pathov="${3:-}" rc
  if [[ -n "$pathov" ]]; then
    env PATH="$pathov" CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" < "$pf" >/dev/null 2>"$ERR"; rc=$?
  else
    CLAUDE_PROJECT_DIR="$proj" bash "$HOOK" < "$pf" >/dev/null 2>"$ERR"; rc=$?
  fi
  printf '%s\n' "$rc" >> "$RCS"
  printf '%s' "$rc"
}

expect() { # expect <label> <project> <command-text> <want-rc>
  local pf="$TMP/p.json" rc
  payload "$3" > "$pf"
  rc=$(run "$2" "$pf")
  if [[ "$rc" == "$4" ]]; then ok "$1"; else fail "$1" "rc=$rc, wanted $4"; fi
}

expect_np() { # expect_np <label> <command-text> <want-rc> — hook run with no python3
  local pf="$TMP/np.json" rc
  payload "$2" > "$pf"
  rc=$(run "$ON" "$pf" "$NOPY")
  if [[ "$rc" == "$3" ]]; then ok "$1"; else fail "$1" "rc=$rc, wanted $3"; fi
}

printf '%s== The four names, however they are spelled (refused) ==%s\n' "$DIM" "$RESET"
for n in ORCH_CADENCE_UNLOCK ORCH_DISABLED_HOOKS ORCH_HOOK_PROFILE ORCH_ALLOW_DESTRUCTIVE_GIT; do
  expect "inline prefix: $n"   "$ON" "$n=1 bash script.sh"          2
  expect "append prefix: $n"   "$ON" "$n+=1 bash script.sh"         2
  expect "brace default: $n"   "$ON" ": \${$n:=1}; bash script.sh"  2
  expect "export: $n"          "$ON" "export $n=1"                  2
done
expect "declare -x"        "$ON" 'declare -x ORCH_CADENCE_UNLOCK=1'          2
expect "typeset"           "$ON" 'typeset ORCH_HOOK_PROFILE=minimal'        2
expect "printf -v"         "$ON" 'printf -v ORCH_ALLOW_DESTRUCTIVE_GIT 1'   2
# Round 2's second catastrophe: an assigning word whose flag takes an argument,
# so the name is not the next word. The rule does not care what the verb is.
expect "read with an argument-taking flag" "$ON" \
  'set -a; read -r -p "" ORCH_CADENCE_UNLOCK <<< 1; bash check.sh --lock'   2
expect "read -d"           "$ON" 'set -a; read -r -d "" ORCH_DISABLED_HOOKS <<< 1' 2
expect "set -a then assign" "$ON" 'set -a; ORCH_CADENCE_UNLOCK+=1; bash check.sh --lock' 2
expect "eval"              "$ON" 'eval "ORCH_CADENCE_UNLOCK=1"; bash check.sh --lock'    2
expect "assignment inside a compound command" "$ON" \
  'cd /tmp && export ORCH_CADENCE_UNLOCK=1 && bash check.sh --lock'         2

printf '\n%s== Round 2'"'"'s first catastrophe: the line continuation ==%s\n' "$DIM" "$RESET"
# `\` + newline is removed by bash BEFORE a word is tested for assignment shape,
# so this is an ordinary assignment. The hook joins continued lines first.
expect "continuation between the name and its =" "$ON" \
  $'ORCH_CADENCE_UNLOCK\\\n=1 bash check.sh --lock'                         2
expect "continuation before the name" "$ON" \
  $'export \\\nORCH_CADENCE_UNLOCK=1'                                       2
# DEVIATION from the brief's pin list, named in the report: the brief pinned a
# name split INSIDE by a continuation as the allowed residual, while the same
# brief has the hook join continued lines. Joining welds this back into the
# name, so it is refused — the strict side of the contradiction, and round 2's
# CAT-1 second shape closed rather than left live.
expect "continuation INSIDE the name (welded by the join, so refused)" "$ON" \
  $'ORCH_CADENCE_UN\\\nLOCK=1 bash check.sh --lock'                         2

printf '\n%s== The scene the constitution names ==%s\n' "$DIM" "$RESET"
expect "the manifest rewrite under an inline unlock" "$ON" \
  'ORCH_CADENCE_UNLOCK=1 bash .githooks/orch-cadence-check.sh --lock'       2

printf '\n%s== The accepted cost: reads, searches, mentions (refused too) ==%s\n' "$DIM" "$RESET"
expect "reading the value"       "$ON" 'echo $ORCH_CADENCE_UNLOCK'                    2
expect "a defaulted read"        "$ON" 'echo "${ORCH_CADENCE_UNLOCK:-unset}"'         2
expect "searching for the name"  "$ON" 'grep -rn ORCH_HOOK_PROFILE docs/'             2
expect "naming one in a comment" "$ON" '# ORCH_HOOK_PROFILE is described in the docs' 2
expect "unsetting a switch"      "$ON" 'unset ORCH_DISABLED_HOOKS'                    2
# A longer name that merely contains one is refused as well. This is the cost
# of a mention rule with no grammar; the refusal tells the agent where to go.
expect "a longer name containing one" "$ON" 'MY_ORCH_HOOK_PROFILE=1 bash script.sh'   2

printf '\n%s== Ordinary work, untouched ==%s\n' "$DIM" "$RESET"
i=0
for c in 'npm test' 'git status --porcelain' 'ls -la' 'cat docs/install.md' \
         'python3 -m pytest -q' 'make build' 'bash tests/run-all.sh' 'git log --oneline -5' \
         'rg --files' 'sed -n 1,40p README.md' 'printenv | sort' 'echo "the environment of the session"' \
         'FOO=1 bash script.sh' 'export PATH="$PATH:/opt/bin"' 'mkdir -p build && cd build' \
         'git diff --stat' 'shasum -a 256 file.txt' 'awk "{print \$1}" f.txt' \
         'node -e "console.log(1)"' 'tar -czf out.tgz dir/'; do
  i=$((i+1))
  expect "ordinary $i: ${c%% *}" "$ON" "$c" 0
done

printf '\n%s== The stated residual (allowed — the alarm names it afterwards) ==%s\n' "$DIM" "$RESET"
expect "residual: a name split by a quote" "$ON" \
  'ORCH_CADENCE_"UNLOCK"=1 bash check.sh --lock'                            0
expect "residual: a name assembled at runtime" "$ON" \
  'V=ORCH_CADENCE_; export ${V}UNLOCK=1; bash check.sh --lock'              0

printf '\n%s== Inert outside cadence mode, and on what it cannot read ==%s\n' "$DIM" "$RESET"
expect "no cadence.json"       "$BARE" 'ORCH_CADENCE_UNLOCK=1 bash check.sh --lock'   0
expect "cadence.json disabled" "$OFF"  'ORCH_CADENCE_UNLOCK=1 bash check.sh --lock'   0

printf '{}\n' > "$TMP/empty.json"
rc=$(run "$ON" "$TMP/empty.json");   [[ "$rc" == "0" ]] && ok "an event with no command" || fail "an event with no command" "rc=$rc"
printf 'not json at all\n' > "$TMP/garbage.json"
rc=$(run "$ON" "$TMP/garbage.json"); [[ "$rc" == "0" ]] && ok "garbage on stdin" || fail "garbage on stdin" "rc=$rc"
: > "$TMP/blank.json"
rc=$(run "$ON" "$TMP/blank.json");   [[ "$rc" == "0" ]] && ok "empty stdin" || fail "empty stdin" "rc=$rc"

python3 -c 'import json,sys; sys.stdout.write(json.dumps({"tool_name":"Edit","tool_input":{"file_path":"a.md","new_string":"ORCH_CADENCE_UNLOCK=1"}}))' > "$TMP/edit.json"
rc=$(run "$ON" "$TMP/edit.json");    [[ "$rc" == "0" ]] && ok "the name in a payload that is not Bash" || fail "the name in a payload that is not Bash" "rc=$rc"
# The tool_name re-check, pinned: a decoded command field under a tool that is
# not Bash. Remove the check and this one goes red.
python3 -c 'import json,sys; sys.stdout.write(json.dumps({"tool_name":"Edit","tool_input":{"file_path":"a.md","command":"ORCH_CADENCE_UNLOCK=1 bash check.sh --lock"}}))' > "$TMP/edit2.json"
rc=$(run "$ON" "$TMP/edit2.json");   [[ "$rc" == "0" ]] && ok "a command field under a tool that is not Bash" || fail "a command field under a tool that is not Bash" "rc=$rc"

printf '\n%s== The refusal itself ==%s\n' "$DIM" "$RESET"
payload 'ORCH_CADENCE_UNLOCK=1 bash check.sh --lock' > "$TMP/p.json"
rc=$(run "$ON" "$TMP/p.json")
if grep -q "set by a person at launch" "$ERR"; then ok "the refusal says who sets the switch"; else fail "the refusal says who sets the switch" "$(head -c 200 "$ERR")"; fi
if grep -q "Do it in your own shell" "$ERR"; then ok "the refusal names the person's shell"; else fail "the refusal names the person's shell" "$(head -c 200 "$ERR")"; fi
if grep -q "not to read one, not to search for one" "$ERR"; then ok "the refusal states the cost"; else fail "the refusal states the cost" "$(head -c 200 "$ERR")"; fi
if grep -q "ORCH_CADENCE_UNLOCK" "$ERR"; then ok "the refusal names the switches"; else fail "the refusal names the switches" "$(head -c 200 "$ERR")"; fi

printf '\n%s== Without python3 on the PATH: the same search, on the raw payload ==%s\n' "$DIM" "$RESET"
if (( HAVE_NOPY )); then
  expect_np "no decoder: the plain spelling"       'ORCH_CADENCE_UNLOCK=1 bash check.sh --lock' 2
  expect_np "no decoder: the name split by a continuation inside it" $'ORCH_CADENCE_UN\\\nLOCK=1 bash check.sh --lock' 2
  if grep -q "python3 is absent" "$ERR"; then ok "the refusal names the missing decoder"; else fail "the refusal names the missing decoder" "$(head -c 200 "$ERR")"; fi
  expect_np "no decoder: ordinary work still runs" 'npm test'                                   0
else
  ok "python3-off-the-PATH probe unavailable on this machine (skipped)"
fi

printf '\n%s== Exit codes and wiring ==%s\n' "$DIM" "$RESET"
BADRC=$(sort -u "$RCS" | grep -vE '^(0|2)$' | tr '\n' ' ')
if [[ -z "$BADRC" ]]; then ok "every run exited 0 or 2"; else fail "every run exited 0 or 2" "also saw: $BADRC"; fi
grep -q 'set -e$' "$HOOK" && fail "no set -e" "the hook sets -e" || ok "no set -e"

WIRE=$(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = []
for m in d.get("hooks", {}).get("PreToolUse", []):
    if (m.get("matcher") or "") == "Bash":
        out += [h.get("command", "") for h in (m.get("hooks") or [])]
print("UNLOCK_BASH=%s" % ("yes" if any("guard-cadence-unlock.sh" in c for c in out) else "no"))
PY
)
case "$WIRE" in
  *UNLOCK_BASH=yes*) ok "the unlock guard is under PreToolUse Bash" ;;
  *) fail "the unlock guard is under PreToolUse Bash" "hooks/hooks.json: $(printf '%s' "$WIRE" | tr '\n' ' ')" ;;
esac

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-unlock-guard%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-cadence-unlock-guard — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
