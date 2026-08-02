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

command -v python3 >/dev/null 2>&1 || { printf '%sPASS: test-guard-no-verify (skipped — python3 unavailable)%s\n' "$DIM" "$RESET"; exit 0; }

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
