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


command -v python3 >/dev/null 2>&1 || skip_suite test-worktree-reaper 'python3 unavailable'

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

printf '%s== mutex map: ownership is keyed on agent_id ==%s\n' "$DIM" "$RESET"
# Mutation-found gap: deleting the agent_id read left every check green,
# because NO test exercised the mutex-map path at all — the map is the
# reaper's PRIMARY and strongest ownership proof (PostToolUse only records a
# claim for a command that SUCCEEDED, so a lost mkdir race records nothing).
# Without the agent_id match the reaper releases whatever any agent claimed,
# which puts two writers in one tree — the failure this hook exists to prevent.
fire_as() { # fire_as <agent_id> <cwd> <last_assistant_message>
  python3 -c "
import json, sys
print(json.dumps({'hook_event_name':'SubagentStop','session_id':'reap-test','agent_id':sys.argv[1],
                  'cwd':sys.argv[2],'last_assistant_message':sys.argv[3]}))" "$1" "$2" "$3" \
  | bash "$HOOK" 2>&1
}
# The map lives under the project hash of the repo the hook resolves from.
map_for() { # map_for <repo-dir>
  local h="default"
  h=$(cd "$1" && bash -c '. "'"$ROOT"'/scripts/lib/orch-project.sh"; orch_project_hash' 2>/dev/null) || h="default"
  printf '%s/state/%s/mutex-map.reap-test.tsv' "$ORCH_HOME" "$h"
}
W="$TMP/map"; mkdir -p "$W"
( cd "$W" && git init -q && git config user.email t@t.t && git config user.name t \
  && echo s > s.txt && git add s.txt && git commit -qm s ) >/dev/null 2>&1
mkwt "$W/.worktrees/agent-one"; mkwt "$W/.worktrees/agent-two"
MAP="$(map_for "$W")"; mkdir -p "$(dirname "$MAP")"
printf 'claim\ta1\t%s\t%s\n' "$W/.worktrees/agent-one/.orch-active" "$(date +%s)" >  "$MAP"
printf 'claim\ta2\t%s\t%s\n' "$W/.worktrees/agent-two/.orch-active" "$(date +%s)" >> "$MAP"
OUT=$(cd "$W" && fire_as a1 "$W" 'Status: DONE
Summary: finished')
held "$W/.worktrees/agent-one" && fail "own mapped claim not reaped" "$OUT" \
  || ok "agent a1's own mapped claim is released"
held "$W/.worktrees/agent-two" && ok "agent a2's claim is NOT released by a1's stop (no cross-agent reap)" \
  || fail "cross-agent reap" "a1's stop released a LIVE sibling's mutex — two writers in one tree. $OUT"

printf '\n%s== mutex map: a released claim is not re-reaped ==%s\n' "$DIM" "$RESET"
W2="$TMP/map2"; mkdir -p "$W2"
( cd "$W2" && git init -q && git config user.email t@t.t && git config user.name t \
  && echo s > s.txt && git add s.txt && git commit -qm s ) >/dev/null 2>&1
mkwt "$W2/.worktrees/done-already"
MAP2="$(map_for "$W2")"; mkdir -p "$(dirname "$MAP2")"
printf 'claim\ta1\t%s\t%s\n'   "$W2/.worktrees/done-already/.orch-active" "$(date +%s)" >  "$MAP2"
printf 'release\ta1\t%s\t%s\n' "$W2/.worktrees/done-already/.orch-active" "$(date +%s)" >> "$MAP2"
OUT=$(cd "$W2" && fire_as a1 "$W2" 'Status: DONE
Summary: finished')
held "$W2/.worktrees/done-already" \
  && ok "a claim already released is left alone (a later claimant's mutex is safe)" \
  || fail "released claim re-reaped" "$OUT"

printf '\n%s== a named sibling is never reaped ==%s\n' "$DIM" "$RESET"
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

# REMOVED: the end-to-end case that drove the real orch-evidence-ledger.sh.
# It asserted the LEDGER wrote honest claims into the mutex map — that a
# politely losing `mkdir X || echo BLOCKED` recorded nothing, and that the
# winner's claim was recorded and later reaped. The ledger is gone (retired to
# a stub that exits 0), so nothing writes the map in production and there is no
# ledger behaviour left to assert. The reaper still READS the map, and the
# handwritten-map cases at the top of this file pin that reading: own claim
# reaped, another agent's claim never reaped, a released claim not re-reaped.
# The reaper's other evidence sources — the agent's CWD and a single
# unambiguous mention in a success-shaped message — are covered below.

printf '\n%s== no worktree named → nothing reaped, state reported ==%s\n' "$DIM" "$RESET"
W="$TMP/g"; mkwt "$W/.worktrees/only"
OUT=$(fire "$W" 'Status: DONE
Summary: all good')
held "$W/.worktrees/only" && ok "unnamed worktree left alone" || fail "reaped without evidence" "$OUT"

printf '\n%s== the report the implementer sent its caller is read ==%s\n' "$DIM" "$RESET"
# Captured Claude Code 2.1.282 payloads. In auto mode the report is the
# SubagentHandback message and last_assistant_message is "Report delivered to
# caller."; in default mode the report is last_assistant_message.
MAT="${ROOT}/tests/fixtures/subagent-handback/materialize.py"
fire_captured() { # fire_captured <out-dir> <materialize args...>
  local dir="$1"; shift
  python3 "$MAT" "$@" --agent-type llm-orchestrator:orch-implementer "$dir" | bash "$HOOK" 2>&1
}
DONE_REPORT='Status: DONE
Summary: finished in .worktrees/only
Verify: bash tests/test-a.sh → 3 passed'
W="$TMP/h"; mkwt "$W/repo/.worktrees/only"
OUT=$(fire_captured "$W" auto --report "$DONE_REPORT")
held "$W/repo/.worktrees/only" && fail "auto mode: DONE in the SubagentHandback report not read" "$OUT" \
  || ok "auto mode: the one worktree named in a DONE handback report is reaped"
W="$TMP/i"; mkwt "$W/repo/.worktrees/only"
OUT=$(fire_captured "$W" auto --report "$DONE_REPORT" --handback-error)
held "$W/repo/.worktrees/only" && ok "auto mode: a SubagentHandback answered by an error is not the report" \
  || fail "auto mode: reaped from an errored handback" "$OUT"
W="$TMP/j"; mkwt "$W/repo/.worktrees/only"
OUT=$(fire_captured "$W" default --report "$DONE_REPORT")
held "$W/repo/.worktrees/only" && fail "default mode: DONE in last_assistant_message not read" "$OUT" \
  || ok "default mode: the one worktree named in a DONE last_assistant_message is reaped"
W="$TMP/k"; mkwt "$W/repo/.worktrees/only"
OUT=$(fire_captured "$W" default --report 'Status: BLOCKED
Need: .worktrees/only is held')
held "$W/repo/.worktrees/only" && ok "default mode: a BLOCKED report reaps nothing" \
  || fail "default mode: reaped on BLOCKED" "$OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-worktree-reaper%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-worktree-reaper — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
