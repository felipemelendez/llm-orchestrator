#!/usr/bin/env bash
# Tests for the --no-verify PreToolUse guard (guard-no-verify.sh).
#
# The invariant: block the FLAG, never the mention. This guard used to grep the
# whole event payload, so it hard-blocked `grep -rn -- '--no-verify' scripts/`
# — a read-only search, and the single most likely benign hit — and blocked a
# clean commit whose model-written `description` field named the flag. A guard
# that punishes looking for the thing it guards against gets switched off.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/guard-no-verify.sh"

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


command -v python3 >/dev/null 2>&1 || skip_suite test-guard-no-verify 'python3 unavailable'

PAYLOAD=$(mktemp)
trap 'rm -f "$PAYLOAD"' EXIT
# Written to a file, not piped: a gated hook exits before reading stdin, and
# under `pipefail` the writer's SIGPIPE would masquerade as a hook failure.
rc_for() { # rc_for <command> [description] [env-assignment...]
  local cmd="$1" desc="${2:-run a command}"; shift 2 2>/dev/null || shift $#
  python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1],'description':sys.argv[2]}}))
" "$cmd" "$desc" > "$PAYLOAD"
  env "$@" bash "$HOOK" < "$PAYLOAD" >/dev/null 2>&1
  echo $?
}
blocks() { [[ "$(rc_for "$1" "${2:-}")" == "2" ]] && ok "BLOCK: $1" || fail "BLOCK: $1" "expected exit 2"; }
allows() { [[ "$(rc_for "$1" "${2:-}")" == "0" ]] && ok "ALLOW: $1" || fail "ALLOW: $1" "expected exit 0"; }

# --- Fallback parity: cross the two axes the suite never crossed --------------
# The spelling cases below used to run ONLY through the classifier's confident
# path; the fallback cases ONLY with canonical spellings the raw rules happened
# to cover. `nice ` (a launcher word) and a trailing `$?` each force the
# classifier off its confident path, so the same spelling must also block via
# the paranoid re-parse. Measured pre-fix: `nice git commit --no-verif -m x`
# was rc=0 while committing past a failing pre-commit hook.
blocks_fallback() {
  local cmd="$1"
  [[ "$(rc_for "nice ${cmd}")" == "2" ]] && ok "FB-launcher BLOCK: $cmd" \
    || fail "FB-launcher BLOCK: nice $cmd" "expected exit 2"
  [[ "$(rc_for "${cmd} && echo \$?")" == "2" ]] && ok "FB-dollar BLOCK: $cmd" \
    || fail "FB-dollar BLOCK: $cmd && echo \$?" "expected exit 2"
}
allows_fallback() {
  local cmd="$1"
  [[ "$(rc_for "nice ${cmd}")" == "0" ]] && ok "FB-launcher ALLOW: $cmd" \
    || fail "FB-launcher ALLOW: nice $cmd" "expected exit 0"
  [[ "$(rc_for "${cmd} && echo \$?")" == "0" ]] && ok "FB-dollar ALLOW: $cmd" \
    || fail "FB-dollar ALLOW: $cmd && echo \$?" "expected exit 0"
}

printf '%s== real bypasses still block ==%s\n' "$DIM" "$RESET"
blocks 'git commit --no-verify -m x'
blocks 'git commit -m x --no-verify'
blocks 'git push --no-verify'
blocks 'git commit --no-gpg-sign -m x'
blocks 'git -c commit.gpgsign=false commit -m x'

printf '\n%s== REGRESSION: reading about the flag is not using it ==%s\n' "$DIM" "$RESET"
allows 'grep -rn -- "--no-verify" scripts/'
allows "git log --grep='--no-verify'"
allows 'rg "no-gpg-sign" docs/'
allows 'cat scripts/hooks/guard-no-verify.sh'

printf '\n%s== REGRESSION: the description field never decides ==%s\n' "$DIM" "$RESET"
RC=$(rc_for 'git commit -m fix' 'commit the fix without --no-verify')
[[ "$RC" == "0" ]] && ok "flag only in the model-written description → allowed" || fail "description-only block" "expected 0, got $RC"

printf '\n%s== REGRESSION: one wrapper word must not disarm the rule ==%s\n' "$DIM" "$RESET"
# The rule required argv[0] to be `git`, so any launcher in front of it turned
# the guard off. Measured against a failing pre-commit hook: each of these
# committed successfully with hooks bypassed.
blocks 'caffeinate git commit --no-verify -m x'
blocks 'arch git commit --no-verify -m x'
blocks 'xcrun git commit --no-verify -m x'
blocks 'stdbuf -o0 git commit --no-verify -m x'
blocks "git -c alias.nv='commit --no-verify' nv -m x"

printf '\n%s== REGRESSION: a newline separates commands ==%s\n' "$DIM" "$RESET"
# shlex drops newlines, so a non-git first line became argv[0] for the whole
# thing and the git invocation on line 2 was never examined.
blocks "$(printf 'echo hi\ngit commit --no-verify -m x')"
blocks "$(printf 'cd /tmp\ngit commit --no-verify -m x')"
blocks "$(printf 'npm test\ngit commit --no-verify -m x')"
allows "$(printf 'echo hi\ngit commit -m ok')"
blocks 'git {commit,--no-verify,-m,x}'

printf '\n%s== spellings git accepts that the flag-text guard missed ==%s\n' "$DIM" "$RESET"
# Git takes any unambiguous long-option prefix, so this guard's whole purpose —
# the project's pre-commit hook — was bypassable by dropping one character.
# Measured against git 2.54: `git commit --no-verif` committed past a FAILING
# pre-commit hook. A line continuation is the normal way to write a long
# command and defeated the newline rewrite the same way.
blocks 'git commit --no-verif -m x'
blocks 'git commit --no-veri -m x'
blocks 'git commit --no-ver -m x'
blocks 'git commit --no-gpg -m x'
blocks 'git commit --no-gpg-sig -m x'
blocks "$(printf 'git commit \\\n--no-verify -m x')"
blocks 'git --no-pager commit --no-verify -m x'
blocks 'git -P commit --no-verif -m x'

printf '\n%s== FALLBACK PARITY: the same spellings must block off the confident path ==%s\n' "$DIM" "$RESET"
blocks_fallback 'git commit --no-verify -m x'
blocks_fallback 'git commit --no-verif -m x'
blocks_fallback 'git commit --no-veri -m x'
blocks_fallback 'git commit --no-ver -m x'
blocks_fallback 'git commit --no-gpg -m x'
blocks_fallback 'git commit --no-gpg-sig -m x'
blocks_fallback 'git push --no-verify'
blocks_fallback 'git commit -a -n -m x'
blocks_fallback 'git commit -an -m x'
blocks_fallback 'git -c commit.gpgsign=false commit -m x'
blocks_fallback 'git -c commit.gpgSign=false commit -m x'
allows_fallback 'git commit -m x'
allows_fallback 'git log -n 5'
allows_fallback 'git push --dry-run'
allows_fallback 'git status --short'

printf '\n%s== the PERMANENT bypass: git config core.hooksPath / commit.gpgsign ==%s\n' "$DIM" "$RESET"
# One `git config core.hooksPath /dev/null` and every later plain commit
# passes a failing pre-commit hook FOREVER while looking clean to this guard
# (proven end-to-end). The transient `-c` form was covered; the permanent form
# was not. Config keys are case-insensitive; the read form is blocked too —
# a rare `--get` costs one round-trip, missing the write costs the guard.
blocks 'git config core.hooksPath /dev/null'
blocks 'git config core.hookspath /dev/null'
blocks 'git config CORE.HOOKSPATH /dev/null'
blocks 'git config --global core.hooksPath /dev/null'
blocks 'git config commit.gpgsign false'
blocks 'git config --global commit.gpgsign false'
blocks 'git config set core.hooksPath /dev/null'
blocks 'git config unset core.hooksPath'
blocks_fallback 'git config core.hooksPath /dev/null'
blocks_fallback 'git config commit.gpgsign false'
# the -c (transient) form, in every case git accepts
blocks 'git -c core.hooksPath=/dev/null commit -m x'
blocks 'git -c core.hookspath=/dev/null commit -m x'
blocks_fallback 'git -c core.hooksPath=/dev/null commit -m x'
# ...but config keys OUTSIDE the bypass set stay free, or the guard is noise
allows 'git config user.name Felipe'
allows 'git config --get core.abbrev'
allows 'git config core.autocrlf false'
allows 'git config --global user.email f@x.y'

printf '\n%s== the alias rule runs even when the classifier is confident ==%s\n' "$DIM" "$RESET"
# Regression found by cold review: gating the raw `-c alias.` scan on "the
# classifier decided" made the classifier's blind spots into the guard's. An
# env-assignment prefix stopped the interpreter from being recognised, so the
# classifier reported a confident allow and the alias rule — which exists
# precisely because tokenization hides an alias body — never ran. This form
# was BLOCKED at the f867f7a baseline and allowed after the gate was added.
blocks "FOO=1 bash -c \"git -c alias.zz='commit --no-verify' zz\""
blocks "bash -c \"git -c alias.zz='commit --no-verify' zz\""
blocks 'X=1 sh -c "git commit --no-verify -m x"'

printf '\n%s== false positives ==%s\n' "$DIM" "$RESET"
allows 'git commit --help'
allows 'git log -n 5'
allows 'git push --dry-run'
allows 'git commit -m x'

printf '\n%s== variables and quoted mentions: block the flag, never the mention ==%s\n' "$DIM" "$RESET"
# A `$` used to bail the classifier into a raw-payload scan, which blocked a
# commit whose MESSAGE mentioned the bypass and a read-only search carrying
# "$DIR". A token that is nothing but a variable reference, in argument
# position, is data — the command is still fully classifiable around it.
allows 'git commit -m "chore: stop using the bypass flag in CI" -m "$BODY"'
allows 'grep -rn -- "--no-verify" "$DIR"'
allows 'git log --grep="--no-verify" -- "$FILE"'
allows 'MSG="do not pass --no-verify" git commit -m ok'
# A script that merely QUOTES the flag is a mention: a python heredoc carrying
# the literal `--no-verify` inside a string is a documentation edit, not a
# commit (measured pre-fix: rc=2, two wasted round-trips). A shell heredoc
# that IS a bypassing invocation still blocks.
allows "$(printf 'python3 - <<PY\ntext = "--no-verify is blocked by policy"\nprint(text)\nPY')"
allows "$(printf 'python3 - <<PY\ndoc = "guards: never bypass hooks"\nprint(doc)\nPY')"
blocks "$(printf 'bash - <<SH\ngit commit --no-verify -m x\nSH')"
blocks 'bash -c "git commit --no-verify -m x"'

printf '\n%s== opt-in and profile gates ==%s\n' "$DIM" "$RESET"
RC=$(rc_for 'git commit --no-verify -m x' 'x' ORCH_ALLOW_NO_VERIFY=1)
[[ "$RC" == "0" ]] && ok "ORCH_ALLOW_NO_VERIFY=1 → allowed" || fail "opt-in" "expected 0, got $RC"
RC=$(rc_for 'git commit --no-verify -m x' 'x' ORCH_HOOK_PROFILE=minimal)
[[ "$RC" == "0" ]] && ok "minimal profile → inert" || fail "profile gate" "expected 0, got $RC"
RC=$(rc_for 'git commit --no-verify -m x' 'x' ORCH_DISABLED_HOOKS=orch-guard)
[[ "$RC" == "0" ]] && ok "ORCH_DISABLED_HOOKS=orch-guard → inert" || fail "disable gate" "expected 0, got $RC"

printf '\n%s== fail-closed when the command cannot be decoded ==%s\n' "$DIM" "$RESET"
printf 'not json at all --no-verify' > "$PAYLOAD"
RC=$(bash "$HOOK" < "$PAYLOAD" >/dev/null 2>&1; echo $?)
[[ "$RC" == "2" ]] && ok "undecodable payload falls back to a raw scan (never fail-open)" || fail "fail-closed" "expected 2, got $RC"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-guard-no-verify%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-guard-no-verify — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
