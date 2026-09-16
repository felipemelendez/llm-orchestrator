#!/usr/bin/env bash
# Tests for the dispatch-model guard (guard-dispatch-model.sh).
#
# WHAT IT PINS. In cadence mode a dispatch that names no model is refused: the
# laws say one model for every seat and a different one only for the plain-
# language adversarial seat, and a dispatch with no `model` silently inherits
# whatever the session happens to be running. No native permission rule can
# express "this parameter is absent", so this has to be a hook.
#
# THE ASYMMETRY THAT MATTERS. The lock guard fails CLOSED on a payload it cannot
# read; this one fails OPEN. A wrong block here stops every dispatch in the
# session, which is a worse failure than an unnamed model — so garbage, a
# missing python3, and anything that does not decode all exit 0.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/guard-dispatch-model.sh"

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

command -v python3 >/dev/null 2>&1 || skip_suite test-dispatch-model-guard 'python3 unavailable'
[[ -f "$HOOK" ]] || { printf '%sFAIL: test-dispatch-model-guard — missing %s%s\n' "$RED" "$HOOK" "$RESET"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/payload.json"
ERR="$TMP/stderr.txt"

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
  printf '{}\n' > "$1/.claude/settings.json"
}
PROJ="$TMP/proj"; mkproj "$PROJ" true
OFF="$TMP/off";   mkproj "$OFF" false
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"; printf '{}\n' > "$FAKE_HOME/.claude/settings.json"

j_agent() { # j_agent <tool_name> [model]
  python3 - "$@" > "$PAYLOAD" <<'PY'
import json, sys
ti = {"description": "one seat", "prompt": "do the thing", "subagent_type": "general-purpose"}
if len(sys.argv) > 2:
    ti["model"] = sys.argv[2]
print(json.dumps({"tool_name": sys.argv[1], "tool_input": ti}))
PY
}
j_raw() { printf '%s' "$1" > "$PAYLOAD"; }

rc_in() { # rc_in <proj> [env=val ...]
  local proj="$1"; shift
  env CLAUDE_PROJECT_DIR="$proj" HOME="$FAKE_HOME" "$@" \
    bash "$HOOK" < "$PAYLOAD" >/dev/null 2>"$ERR"
  printf '%s' "$?"
}
rc_nopy() {
  local proj="$1"; shift
  env -i PATH="$NOPY" CLAUDE_PROJECT_DIR="$proj" HOME="$FAKE_HOME" "$@" \
    "$NOPY/bash" "$HOOK" < "$PAYLOAD" >/dev/null 2>"$ERR"
  printf '%s' "$?"
}
expect() { if [[ "$3" == "$1" ]]; then ok "$2"; else fail "$2" "expected exit $1, got $3: $(head -2 "$ERR" | tr '\n' ' ')"; fi; }

printf '%s== inert outside cadence mode ==%s\n' "$DIM" "$RESET"
j_agent Agent
expect 0 "a modelless dispatch in a project with no cadence.json" "$(rc_in "$PLAIN")"
expect 0 'a modelless dispatch with "enabled": false' "$(rc_in "$OFF")"
j_raw '{ not json '
expect 0 "garbage payload outside cadence mode" "$(rc_in "$PLAIN")"
if [[ "$HAVE_NOPY" == "1" ]]; then
  expect 0 "garbage payload, outside cadence mode, no python3" "$(rc_nopy "$PLAIN")"
else
  ok "SKIP no-python3 inert probe (could not build a python3-free PATH)"
fi

printf '%s== in cadence mode ==%s\n' "$DIM" "$RESET"
j_agent Agent
expect 2 "Agent with no model named" "$(rc_in "$PROJ")"
for want in 'name the model' 'LAWS.md'; do
  grep -q -- "$want" "$ERR" && ok "the refusal says '$want'" \
    || fail "the refusal says '$want'" "stderr: $(tr '\n' ' ' < "$ERR")"
done
j_agent Task
expect 2 "Task (the legacy alias) with no model named" "$(rc_in "$PROJ")"
j_agent Agent opus
expect 0 "Agent with model: opus" "$(rc_in "$PROJ")"
j_agent Agent fable
expect 0 "Agent with model: fable" "$(rc_in "$PROJ")"
j_agent Agent ""
expect 2 "Agent with an empty model string" "$(rc_in "$PROJ")"

printf '%s== it fails OPEN, unlike the lock guard ==%s\n' "$DIM" "$RESET"
j_raw '{ not json at all'
expect 0 "an undecodable payload in cadence mode" "$(rc_in "$PROJ")"
j_raw 'null'
expect 0 "a payload that decodes to something that is not an object" "$(rc_in "$PROJ")"
j_raw '{"tool_name":"Agent"}'
expect 0 "a payload with no tool_input at all" "$(rc_in "$PROJ")"
# R-10: `tool_input` present but not an OBJECT is a structurally malformed
# payload, which decision 8 puts on the fail-open side — orch_json_has_field is
# true for any value, so this needs its own test.
j_raw '{"tool_name":"Agent","tool_input":["a"]}'
expect 0 "tool_input as an array (structurally malformed) fails open" "$(rc_in "$PROJ")"
j_raw '{"tool_name":"Agent","tool_input":"a string"}'
expect 0 "tool_input as a string fails open" "$(rc_in "$PROJ")"
j_raw '{"tool_name":"Agent","tool_input":42}'
expect 0 "tool_input as a number fails open" "$(rc_in "$PROJ")"
j_raw '{"tool_name":"Agent","tool_input":null}'
expect 0 "tool_input as null fails open" "$(rc_in "$PROJ")"
j_raw '{"tool_name":"Agent","tool_input":{"description":"x"}}'
expect 2 "a real modelless object is still refused" "$(rc_in "$PROJ")"
if [[ "$HAVE_NOPY" == "1" ]]; then
  j_agent Agent
  expect 0 "a modelless dispatch with python3 gone (cannot read, must not block)" "$(rc_nopy "$PROJ")"
else
  ok "SKIP no-python3 fail-open probe (could not build a python3-free PATH)"
fi

printf '%s== the unlock ==%s\n' "$DIM" "$RESET"
j_agent Agent
expect 0 "ORCH_CADENCE_UNLOCK=1 allows a modelless dispatch" \
  "$(rc_in "$PROJ" ORCH_CADENCE_UNLOCK=1)"
printf '{ "env": { "ORCH_CADENCE_UNLOCK": "1" } }\n' > "$PROJ/.claude/settings.json"
expect 2 "the unlock is refused when a settings file persists the token" \
  "$(rc_in "$PROJ" ORCH_CADENCE_UNLOCK=1)"
printf '{}\n' > "$PROJ/.claude/settings.json"

printf '%s== the disabled list ==%s\n' "$DIM" "$RESET"
expect 0 "ORCH_DISABLED_HOOKS=orch-dispatch-model turns it off" \
  "$(rc_in "$PROJ" ORCH_DISABLED_HOOKS=orch-dispatch-model)"
expect 2 "an unrelated name in ORCH_DISABLED_HOOKS does not" \
  "$(rc_in "$PROJ" ORCH_DISABLED_HOOKS=orch-handoff-nudge)"

printf '%s== the wiring (a guard that is not in hooks.json is in no session) ==%s\n' "$DIM" "$RESET"
WIRE=$(python3 - "$ROOT/hooks/hooks.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
pre = d.get("hooks", {}).get("PreToolUse", []) or []
out = []
for m in pre:
    if (m.get("matcher") or "") == "Agent|Task":
        out += [h.get("command", "") for h in (m.get("hooks") or [])]
print("DISPATCH_AGENT_TASK=%s" % ("yes" if any("guard-dispatch-model.sh" in c for c in out) else "no"))
PY
)
case "$WIRE" in
  *DISPATCH_AGENT_TASK=yes*) ok "the dispatch guard is under PreToolUse Agent|Task" ;;
  *) fail "the dispatch guard is under PreToolUse Agent|Task" "hooks/hooks.json: $(printf '%s' "$WIRE" | tr '\n' ' ')" ;;
esac

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-dispatch-model-guard%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-dispatch-model-guard — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
