#!/usr/bin/env bash
# Tests for the retry-storm circuit breaker Stop hook (orch-retry-cap.sh).
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-retry-cap.sh"

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
  skip_suite test-retry-cap 'python3 unavailable'
fi

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

mk_transcript() { # mk_transcript <text> -> path
  local text="$1" f="$BASE/t.$RANDOM.jsonl"
  printf '{"role":"assistant","content":%s}\n' "$(printf '%s' "$text" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" > "$f"
  printf '%s' "$f"
}
# fire <fresh-home> <transcript> [env...] -> "rc|stderr"
fire() {
  local home="$1" tr="$2"; shift 2
  local err rc
  err=$(printf '{"transcript_path":"%s"}' "$tr" | env ORCH_HOME="$home" "$@" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}

SAME=$(mk_transcript "Status: trying the same fix again. It still fails the same way.")
DIFF=$(mk_transcript "Status: a different approach this time, exploring the parser.")

printf '%s== Default ON: warns at the 3rd identical reply with no env set ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
d1=$(fire "$H" "$SAME"); d2=$(fire "$H" "$SAME"); d3=$(fire "$H" "$SAME")
if [[ "${d1#*|}" == "" && "${d2#*|}" == "" ]] && printf '%s' "${d3#*|}" | grep -q 'orch-retry-cap'; then
  ok "ORCH_RETRY_CAP unset → enabled by default, warns on the 3rd identical reply"
else fail "default on" "d1='$d1' d2='$d2' d3='$d3'"; fi

printf '\n%s== ORCH_RETRY_CAP=0 disables ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d); off_ok=1
for i in 1 2 3 4 5; do
  out=$(fire "$H" "$SAME" ORCH_RETRY_CAP=0); [[ "${out#*|}" == "" ]] || off_ok=0
done
[[ "$off_ok" == "1" ]] && ok "ORCH_RETRY_CAP=0 → silent across 5 identical replies" || fail "explicit off" "warned while disabled"

printf '\n%s== Enabled, N=3: warns on the 3rd identical reply, not before ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
o1=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3); o2=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)
o3=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)
if [[ "${o1#*|}" == "" && "${o2#*|}" == "" ]]; then ok "1st and 2nd identical replies are silent"
else fail "pre-threshold silent" "o1='$o1' o2='$o2'"; fi
if [[ "${o3%%|*}" == "0" ]] && printf '%s' "${o3#*|}" | grep -q 'orch-retry-cap'; then ok "3rd identical reply warns (exit 0)"
else fail "threshold warn" "o3='$o3'"; fi

printf '\n%s== A different reply resets the counter ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3 >/dev/null
fire "$H" "$DIFF" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3 >/dev/null   # reset
r2=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)         # count=1 again
r3=$(fire "$H" "$SAME" ORCH_RETRY_CAP=1 ORCH_RETRY_CAP_N=3)         # count=2, still silent
if [[ "${r2#*|}" == "" && "${r3#*|}" == "" ]]; then ok "varied reply between repeats prevents a false trip"
else fail "reset" "r2='$r2' r3='$r3'"; fi

printf '\n%s== Strict mode blocks (exit 2) at the threshold ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 >/dev/null
s2=$(fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2)
if [[ "${s2%%|*}" == "2" ]]; then ok "ORCH_STRICT_RETRY=1 → exit 2 at threshold"; else fail "strict block" "s2='$s2'"; fi

printf '\n%s== Dry-run logs intent, never blocks ==%s\n' "$DIM" "$RESET"
H=$(mktemp -d)
fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 ORCH_HOOK_DRY_RUN=1 >/dev/null
d2=$(fire "$H" "$SAME" ORCH_STRICT_RETRY=1 ORCH_RETRY_CAP_N=2 ORCH_HOOK_DRY_RUN=1)
if [[ "${d2%%|*}" == "0" ]] && printf '%s' "${d2#*|}" | grep -q 'orch-dry-run\[orch-retry-cap\]'; then
  ok "dry-run: logs intent, exit 0 even under strict"
else fail "dry-run" "d2='$d2'"; fi

printf '\n%s== SubagentStop: consecutive identical tool actions in the agent transcript ==%s\n' "$DIM" "$RESET"
# Layout mirrors the real harness: main transcript <dir>/main.jsonl, subagent
# file at <dir>/main/subagents/agent-<id>.jsonl.
mk_agent_jsonl() { # <path> <mode: repeat|varied>
  local path="$1" mode="$2"
  python3 - "$path" "$mode" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
def turn(name, inp):
    return json.dumps({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "tool_use", "name": name, "input": inp}]}})
lines = []
if mode == "repeat":
    for _ in range(4):
        lines.append(turn("Bash", {"command": "npm test"}))
else:
    lines.append(turn("Bash", {"command": "npm test"}))
    lines.append(turn("Read", {"file_path": "/x/a.ts"}))
    lines.append(turn("Bash", {"command": "npm test"}))
    lines.append(turn("Bash", {"command": "npm run lint"}))
open(path, "w").write("\n".join(lines) + "\n")
PY
}
SUBBASE=$(mktemp -d)
: > "$SUBBASE/main.jsonl"
mkdir -p "$SUBBASE/main/subagents"
mk_agent_jsonl "$SUBBASE/main/subagents/agent-a123.jsonl" repeat
mk_agent_jsonl "$SUBBASE/main/subagents/agent-b456.jsonl" varied

sub_fire() { # <agent_id> [env...]
  local aid="$1"; shift
  local err rc
  err=$(printf '{"hook_event_name":"SubagentStop","transcript_path":"%s","agent_id":"%s"}' "$SUBBASE/main.jsonl" "$aid" \
        | env ORCH_HOME="$(mktemp -d)" "$@" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"
}
out=$(sub_fire a123)
if [[ "${out%%|*}" == "0" ]] && printf '%s' "${out#*|}" | grep -q 'step repetition'; then
  ok "4× identical Bash action → step-repetition warn (exit 0)"
else fail "subagent repeat warn" "out='$out'"; fi
out=$(sub_fire a123 ORCH_STRICT_RETRY=1)
if [[ "${out%%|*}" == "2" ]]; then ok "same under strict → exit 2 (reason fed back to the agent)"
else fail "subagent strict" "out='$out'"; fi
out=$(sub_fire b456)
if [[ "${out%%|*}" == "0" && "${out#*|}" == "" ]]; then
  ok "varied actions (interleaved repeats, no consecutive run) → silent"
else fail "subagent varied" "out='$out'"; fi
rm -rf "$SUBBASE"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-retry-cap%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"; exit 0
else
  printf '%sFAIL: test-retry-cap — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
fi
