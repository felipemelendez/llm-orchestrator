#!/usr/bin/env bash
# Tests for the worktree reaper SubagentStop hook (orch-worktree-reaper.sh).
#
# The invariant under test: a path MENTIONED in a final message is not a path
# the agent HELD. Releasing a mutex a live sibling is writing is the exact
# corruption the mutex exists to prevent, so ownership must come from evidence
# — the agent's own CWD, or an unambiguous single mention — never from "this
# slug appeared somewhere in the text".
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-worktree-reaper.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

command -v python3 >/dev/null 2>&1 || { printf '%sPASS: test-worktree-reaper (skipped — python3 unavailable)%s\n' "$DIM" "$RESET"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/home"

fire() { # fire <cwd> <last_assistant_message>
  python3 -c "
import json, sys
print(json.dumps({'hook_event_name':'SubagentStop','session_id':'reap-test','agent_id':'a1',
                  'cwd':sys.argv[1],'last_assistant_message':sys.argv[2]}))" "$1" "$2" \
  | bash "$HOOK" 2>&1
}
held()  { [[ -d "$1/.orch-active" ]]; }
mkwt()  { mkdir -p "$1/.orch-active"; }

printf '%s== a named sibling is never reaped ==%s\n' "$DIM" "$RESET"
W="$TMP/a"; mkwt "$W/.worktrees/mine"; mkwt "$W/.worktrees/sibling"
OUT=$(fire "$W" 'Status: DONE
Summary: finished in .worktrees/mine. I left .worktrees/sibling alone because another implementer is still writing there.')
held "$W/.worktrees/sibling" && ok "sibling mutex intact (releasing it would put two writers in one tree)" \
  || fail "sibling reaped" "$OUT"
held "$W/.worktrees/mine" && ok "own mutex also untouched when ownership is ambiguous" \
  || fail "own reaped on ambiguity" "$OUT"
printf '%s' "$OUT" | grep -q 'names 2 worktrees' && ok "ambiguity is reported, not guessed" || fail "no ambiguity report" "$OUT"

printf '\n%s== CWD proves ownership: reap own, leave the sibling ==%s\n' "$DIM" "$RESET"
W="$TMP/b"; mkwt "$W/.worktrees/mine"; mkwt "$W/.worktrees/sibling"
OUT=$(fire "$W/.worktrees/mine" 'Status: DONE
Summary: done. .worktrees/sibling is held by another agent.')
held "$W/.worktrees/mine"    && fail "own not reaped" "$OUT" || ok "own mutex released (CWD is inside it)"
held "$W/.worktrees/sibling" && ok "sibling mutex intact"    || fail "sibling reaped" "$OUT"

printf '\n%s== a single unambiguous mention is reaped ==%s\n' "$DIM" "$RESET"
W="$TMP/c"; mkwt "$W/.worktrees/only"
OUT=$(fire "$W" 'Status: DONE
Summary: finished the task in .worktrees/only')
held "$W/.worktrees/only" && fail "single mention not reaped" "$OUT" || ok "single named worktree released"

printf '\n%s== PARTIAL is a success shape too ==%s\n' "$DIM" "$RESET"
W="$TMP/d"; mkwt "$W/.worktrees/only"
OUT=$(fire "$W" 'Status: PARTIAL
Progress: half of it
Remaining: the rest
Notes: worked in .worktrees/only')
held "$W/.worktrees/only" && fail "PARTIAL not reaped" "$OUT" || ok "PARTIAL releases the mutex"

printf '\n%s== BLOCKED never reaps (it routinely names a live sibling) ==%s\n' "$DIM" "$RESET"
W="$TMP/e"; mkwt "$W/.worktrees/only"
OUT=$(fire "$W" 'Status: BLOCKED
Need: .worktrees/only is locked by another writer')
held "$W/.worktrees/only" && ok "BLOCKED leaves the mutex alone" || fail "BLOCKED reaped" "$OUT"

printf '\n%s== a non-empty mutex directory is never removed ==%s\n' "$DIM" "$RESET"
W="$TMP/f"; mkwt "$W/.worktrees/only"; : > "$W/.worktrees/only/.orch-active/owner"
OUT=$(fire "$W" 'Status: DONE
Summary: finished in .worktrees/only')
held "$W/.worktrees/only" && ok "non-empty mutex refused (inspect by hand)" || fail "removed non-empty mutex" "$OUT"

printf '\n%s== no worktree named → nothing reaped, state reported ==%s\n' "$DIM" "$RESET"
W="$TMP/g"; mkwt "$W/.worktrees/only"
OUT=$(fire "$W" 'Status: DONE
Summary: all good')
held "$W/.worktrees/only" && ok "unnamed worktree left alone" || fail "reaped without evidence" "$OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-worktree-reaper%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-worktree-reaper — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
