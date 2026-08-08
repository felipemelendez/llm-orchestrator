#!/usr/bin/env bash
# Tests that the verify gate's claim extractor behaves identically whatever
# locale the harness happens to hand the hook.
#
# Why this suite exists. The extractor normalizes the ways a command gets
# pasted into a Verify: block — a bullet, an arrow, a checkmark, a shell
# prompt. Several of those decorations are multi-byte characters. A POSIX
# bracket expression (`[-*+•]`) matches BYTES, not characters, under a C
# locale, so the shared lead byte of `•` (E2 80 A2) also matched the lead byte
# of `→` (E2 86 92): the arrow was truncated mid-character, the arrow-strip
# that follows no longer recognised it, and the anchored command regex found
# nothing. The gate then had no claimed command to check and stayed SILENT —
# a fabricated "Verify: → pytest -q → 40 passed" passed the gate on any machine
# whose locale was not UTF-8. Developer machines are UTF-8; hooks are spawned
# with whatever environment the harness passes, so the hole was invisible where
# it was authored and open where it ran.
#
# The invariant: a decoration is a decoration in every locale. Same reply, same
# verdict. Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-verify-gate.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# A skipped suite is not a passed suite — same contract as test-verify-gate.sh.
skip_suite() { # <suite-name> <reason>
  if [[ "${ORCH_REQUIRE_DEPS:-0}" == "1" ]]; then
    printf '%sFAIL: %s — %s (ORCH_REQUIRE_DEPS=1)%s\n' "$RED" "$1" "$2" "$RESET"
    exit 1
  fi
  printf '%sSKIP: %s (%s)%s\n' "$DIM" "$1" "$2" "$RESET"
  exit 0
}

command -v python3 >/dev/null 2>&1 || skip_suite test-evidence-locale 'python3 unavailable'
command -v git     >/dev/null 2>&1 || skip_suite test-evidence-locale 'git unavailable'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Clean committed repo so the work-in-progress escape never fires on a warn case.
CLEAN="$TMP/clean"; mkdir -p "$CLEAN"
( cd "$CLEAN" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > f && git add f && git commit -qm "initial" )

mk_transcript() {
  local text="$1" f="$TMP/t.$RANDOM.jsonl"
  printf '{"role":"user","content":"go"}\n' > "$f"
  printf '{"role":"assistant","content":%s}\n' "$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" >> "$f"
  printf '%s' "$f"
}
run() { # run <transcript> [env assignments...]: prints "rc|stderr"
  local tr="$1"; shift
  local err rc
  err=$(printf '{"transcript_path":"%s","session_id":"loc-test"}' "$tr" \
        | env "$@" ORCH_HOME="$TMP/orch-home" CLAUDE_PROJECT_DIR="$CLEAN" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}

# Ledger at the exact path the gate computes, plus a turn-start in the past so
# the whole ledger is inside the current turn's window.
LEDGER=$(ORCH_HOME="$TMP/orch-home" bash -c '
  source "'"$ROOT"'/scripts/lib/orch-project.sh"
  source "'"$ROOT"'/scripts/lib/orch-evidence.sh"
  orch_evidence_ledger_path loc-test')
TURNSTART="$(dirname "$LEDGER")/turn-start.loc-test"
mkdir -p "$(dirname "$LEDGER")"
NOW=$(date +%s)
printf '%s' "$((NOW - 60))" > "$TURNSTART"

# Locales to run every case under. C is the one that broke; a UTF-8 locale is
# added when the machine has one, so the suite asserts agreement rather than
# just "works under C".
LOCALES="C"
if locale -a 2>/dev/null | grep -qiE '^C\.(utf-?8)$'; then
  LOCALES="$LOCALES $(locale -a 2>/dev/null | grep -iE '^C\.(utf-?8)$' | head -1)"
fi

# Every decoration the extractor claims to normalize. The multi-byte ones are
# the regression risk; the ASCII ones are here so a fix that reaches for
# byte-blind matching can't quietly drop them.
DECORATIONS='- |* |+ |• |1. |$ |> |→ |-> |=> |✓ |✔ |» '

printf '%s== A fabricated claim warns in every locale, whatever the paste form ==%s\n' "$DIM" "$RESET"
for loc in $LOCALES; do
  : > "$LEDGER"   # nothing ran this turn: every claim below is fabricated
  _old_ifs="$IFS"; IFS='|'
  for dec in $DECORATIONS; do
    IFS="$_old_ifs"
    tr=$(mk_transcript "Changed:
- p.py:1 — fix
Verify:
${dec}pytest -q → 40 passed")
    out=$(run "$tr" LC_ALL="$loc"); rc=${out%%|*}; err=${out#*|}
    if [[ -n "$err" ]]; then
      ok "LC_ALL=$loc  '${dec}' → warns (nothing ran)"
    else
      fail "LC_ALL=$loc  '${dec}' → warns (nothing ran)" "gate stayed silent on a fabricated claim; rc=$rc"
    fi
    IFS='|'
  done
  IFS="$_old_ifs"
done

printf '\n%s== A real run stays silent in every locale, whatever the paste form ==%s\n' "$DIM" "$RESET"
for loc in $LOCALES; do
  printf 'aaaa11112222\t0\t%d\tok\tpytest -q\n' "$NOW" > "$LEDGER"
  _old_ifs="$IFS"; IFS='|'
  for dec in $DECORATIONS; do
    IFS="$_old_ifs"
    tr=$(mk_transcript "Changed:
- p.py:1 — fix
Verify:
${dec}pytest -q → 40 passed")
    out=$(run "$tr" LC_ALL="$loc"); rc=${out%%|*}; err=${out#*|}
    if [[ "$rc" == "0" && -z "$err" ]]; then
      ok "LC_ALL=$loc  '${dec}' → silent (pytest -q is in the ledger)"
    else
      fail "LC_ALL=$loc  '${dec}' → silent (pytest -q is in the ledger)" "rc=$rc err=${err:0:110}"
    fi
    IFS='|'
  done
  IFS="$_old_ifs"
done

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '%sPASS: test-evidence-locale%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-evidence-locale — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
