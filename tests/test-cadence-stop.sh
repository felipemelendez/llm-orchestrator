#!/usr/bin/env bash
# Tests for the cadence Stop hook (orch-cadence-stop.sh).
#
# WHAT IT PINS.
#
#   The soft shape. A Stop hook that wants the MODEL to read something must
#   emit {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":…}}.
#   A payload carrying `reason` with no `decision` is ignored by the harness —
#   a report layer that silently no-ops is worse than none, because everyone
#   downstream believes it ran. `reason` belongs only with decision:"block".
#
#   stop_hook_active. A Stop hook that blocks without honouring that flag puts
#   the session in a loop: the block prompts another turn, the turn stops, the
#   hook blocks again. Nothing else in this repo reads the flag — orch-stop.sh
#   does not even read stdin — so it is written here from scratch and pinned.
#
#   At most once, and only for what THIS session did. Under the strict knob the
#   hook may block one time per session, and only when a changed path is absent
#   from the snapshot session start took. An inherited mutation is reported, not
#   blocked: the session that inherits it did not make it and often cannot fix
#   it.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/orch-cadence-stop.sh"
CHECK="${ROOT}/skills/cadence/scripts/orch-cadence-check.sh"

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

command -v python3 >/dev/null 2>&1 || skip_suite test-cadence-stop 'python3 unavailable'
[[ -f "$CHECK" ]] || skip_suite test-cadence-stop 'the cadence check script is not in this tree'
[[ -f "$HOOK" ]] || { printf '%sFAIL: test-cadence-stop — missing %s%s\n' "$RED" "$HOOK" "$RESET"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/orchhome"
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"; printf '{}\n' > "$FAKE_HOME/.claude/settings.json"
OUT="$TMP/out.txt"; ERRF="$TMP/err.txt"

EV="$TMP/stop.json";        printf '{"session_id":"sess-1","stop_hook_active":false}' > "$EV"
EV_ACTIVE="$TMP/active.json"; printf '{"session_id":"sess-1","stop_hook_active":true}' > "$EV_ACTIVE"
EV_JUNK="$TMP/junk.json";   printf '{ not json at all' > "$EV_JUNK"

mkproj() { # mkproj <dir> [enabled]
  local d="$1"
  mkdir -p "$d/docs/llm-orchestrator" "$d/.claude"
  if [[ -n "${2:-}" ]]; then
    printf '{ "schema": 1, "enabled": %s }\n' "$2" > "$d/docs/llm-orchestrator/cadence.json"
    printf '# Laws\n\nRuling 3 — the cadence is the process.\n' > "$d/docs/llm-orchestrator/LAWS.md"
  fi
  printf '{}\n' > "$d/.claude/settings.json"
  printf '# P\n\n<!-- ORCH:LAWS:START -->\nlaws\n<!-- ORCH:LAWS:END -->\n' > "$d/CLAUDE.md"
  cp "$d/CLAUDE.md" "$d/AGENTS.md"
}
PROJ="$TMP/proj";   mkproj "$PROJ" true
OFF="$TMP/off";     mkproj "$OFF" false
PLAIN="$TMP/plain"; mkproj "$PLAIN"

run_stop() { # run_stop <project> <event-file> [env=val ...]
  local proj="$1" ev="$2"; shift 2
  ( cd "$proj" && env CLAUDE_PROJECT_DIR="$proj" HOME="$FAKE_HOME" ORCH_HOME="$ORCH_HOME" \
      "$@" bash "$HOOK" < "$ev" ) > "$OUT" 2>"$ERRF"
  printf '%s' "$?"
}
snapshot() { # snapshot <project> — take the one session start would have taken
  ( cd "$1" && env CLAUDE_PROJECT_DIR="$1" HOME="$FAKE_HOME" ORCH_HOME="$ORCH_HOME" \
      CLAUDE_PLUGIN_ROOT="$ROOT" bash "${ROOT}/scripts/hooks/session-start.sh" \
      <<< '{"source":"startup","session_id":"sess-1"}' ) >/dev/null 2>&1
}
has_key() { # has_key <dotted path> — true when $OUT carries it
  python3 - "$1" "$OUT" <<'PY' >/dev/null 2>&1
import json, sys
d = json.load(open(sys.argv[2]))
cur = d
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur:
        sys.exit(1)
    cur = cur[k]
sys.exit(0)
PY
}
field() { # field <dotted path>
  python3 - "$1" "$OUT" <<'PY' 2>/dev/null
import json, sys
try:
    cur = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur:
        sys.exit(0)
    cur = cur[k]
sys.stdout.write(cur if isinstance(cur, str) else str(cur))
PY
}
expect() { if [[ "$3" == "$1" ]]; then ok "$2"; else fail "$2" "expected exit $1, got $3: $(head -2 "$ERRF" | tr '\n' ' ')"; fi; }

printf '%s== inert outside cadence mode ==%s\n' "$DIM" "$RESET"
expect 0 "a project with no cadence.json" "$(run_stop "$PLAIN" "$EV")"
[[ ! -s "$OUT" ]] && ok "and it prints nothing at all" || fail "and it prints nothing at all" "$(head -c 120 "$OUT")"
expect 0 'a project with "enabled": false' "$(run_stop "$OFF" "$EV")"
expect 0 "a garbage payload outside cadence mode" "$(run_stop "$PLAIN" "$EV_JUNK")"
expect 0 "strict knob set, but the project never opted in" \
  "$(run_stop "$PLAIN" "$EV" ORCH_STRICT_CADENCE_LOCK=1)"

printf '%s== the unarmed lock, and a clean one ==%s\n' "$DIM" "$RESET"
expect 0 "an unarmed lock reports and does not block" "$(run_stop "$PROJ" "$EV")"
has_key hookSpecificOutput.additionalContext && ok "the soft shape is hookSpecificOutput.additionalContext" \
  || fail "the soft shape is hookSpecificOutput.additionalContext" "stdout: $(head -c 200 "$OUT")"
has_key decision && fail "the soft note carries no decision" "decision present" \
  || ok "the soft note carries no decision"
has_key reason && fail "the soft note carries no bare reason (the harness ignores it)" "reason present" \
  || ok "the soft note carries no bare reason (the harness ignores it)"
[[ -s "$ERRF" ]] && ok "the user sees it on stderr too" || fail "the user sees it on stderr too" "stderr empty"

bash "$CHECK" --root "$PROJ" --lock >/dev/null 2>&1
expect 0 "a lock that matches the tree" "$(run_stop "$PROJ" "$EV")"
[[ ! -s "$OUT" ]] && ok "a clean lock is silent on stdout" || fail "a clean lock is silent on stdout" "$(head -c 200 "$OUT")"
[[ ! -s "$ERRF" ]] && ok "a clean lock is silent on stderr" || fail "a clean lock is silent on stderr" "$(head -c 200 "$ERRF")"

printf '%s== a changed lock ==%s\n' "$DIM" "$RESET"
rm -rf "$ORCH_HOME/state"
snapshot "$PROJ"                                   # snapshot taken while clean
printf '\nRuling 4 — appended in this session.\n' >> "$PROJ/docs/llm-orchestrator/LAWS.md"
expect 0 "a changed lock reports and does not block by default" "$(run_stop "$PROJ" "$EV")"
has_key hookSpecificOutput.additionalContext && ok "the change is reported as additionalContext" \
  || fail "the change is reported as additionalContext" "stdout: $(head -c 200 "$OUT")"
case "$(field hookSpecificOutput.additionalContext)" in
  *"LAWS.md"*) ok "the note names the changed path" ;;
  *) fail "the note names the changed path" "note: $(field hookSpecificOutput.additionalContext)" ;;
esac

printf '%s== stop_hook_active ==%s\n' "$DIM" "$RESET"
expect 0 "stop_hook_active:true exits immediately" "$(run_stop "$PROJ" "$EV_ACTIVE")"
[[ ! -s "$OUT" ]] && ok "and says nothing" || fail "and says nothing" "$(head -c 200 "$OUT")"
expect 0 "stop_hook_active:true under the strict knob still exits 0" \
  "$(run_stop "$PROJ" "$EV_ACTIVE" ORCH_STRICT_CADENCE_LOCK=1)"

printf '%s== the strict knob: at most once, and only for this session ==%s\n' "$DIM" "$RESET"
rm -f "$ORCH_HOME"/state/cadence-stop-blocked.* 2>/dev/null
rc=$(run_stop "$PROJ" "$EV" ORCH_STRICT_CADENCE_LOCK=1)
expect 2 "the first stop after a this-session change blocks" "$rc"
[[ "$(field decision)" == "block" ]] && ok 'the block payload is {"decision":"block"}' \
  || fail 'the block payload is {"decision":"block"}' "stdout: $(head -c 200 "$OUT")"
R=$(field reason)
case "$R" in *"--lock"*) ok "the reason names --lock" ;; *) fail "the reason names --lock" "reason: $R" ;; esac
case "$R" in *"ORCH_CADENCE_UNLOCK"*) ok "the reason names the unlock" ;; *) fail "the reason names the unlock" "reason: $R" ;; esac
[[ -s "$ERRF" ]] && ok "the block reason also reaches stderr" || fail "the block reason also reaches stderr" "stderr empty"
ls "$ORCH_HOME"/state/cadence-stop-blocked.* >/dev/null 2>&1 \
  && ok "a once-per-session marker is left behind" || fail "a once-per-session marker is left behind" "no marker"

expect 0 "the second stop in the same session reports instead of blocking" \
  "$(run_stop "$PROJ" "$EV" ORCH_STRICT_CADENCE_LOCK=1)"
has_key hookSpecificOutput.additionalContext && ok "the second stop is the soft shape" \
  || fail "the second stop is the soft shape" "stdout: $(head -c 200 "$OUT")"

# A change the session INHERITED: session start already saw it, so blocking the
# agent for it would punish the wrong turn.
rm -f "$ORCH_HOME"/state/cadence-stop-blocked.*
snapshot "$PROJ"
expect 0 "an inherited change is reported, not blocked, even under strict" \
  "$(run_stop "$PROJ" "$EV" ORCH_STRICT_CADENCE_LOCK=1)"
has_key decision && fail "an inherited change produces no decision" "decision present" \
  || ok "an inherited change produces no decision"

# Unarmed is not a mutation: there is nothing to compare, so nothing to block.
rm -f "$ORCH_HOME"/state/cadence-stop-blocked.*
rm -f "$PROJ/docs/llm-orchestrator/LOCK.sha256"
rm -rf "$ORCH_HOME/state"; snapshot "$PROJ"
expect 0 "an unarmed lock never blocks, even under strict" \
  "$(run_stop "$PROJ" "$EV" ORCH_STRICT_CADENCE_LOCK=1)"

printf '%s== the disabled list, and a missing helper ==%s\n' "$DIM" "$RESET"
expect 0 "ORCH_DISABLED_HOOKS=orch-cadence-stop turns it off" \
  "$(run_stop "$PROJ" "$EV" ORCH_DISABLED_HOOKS=orch-cadence-stop)"
[[ ! -s "$OUT" ]] && ok "and it prints nothing" || fail "and it prints nothing" "$(head -c 120 "$OUT")"

LONELY="$TMP/lonely/scripts/hooks"; mkdir -p "$LONELY"
cp "$HOOK" "$LONELY/orch-cadence-stop.sh"
( cd "$PROJ" && env CLAUDE_PROJECT_DIR="$PROJ" HOME="$FAKE_HOME" ORCH_HOME="$ORCH_HOME" \
    ORCH_STRICT_CADENCE_LOCK=1 bash "$LONELY/orch-cadence-stop.sh" < "$EV" ) > "$OUT" 2>"$ERRF"
rc=$?
expect 0 "a missing check script never blocks a Stop (a blocking Stop loops the session)" "$rc"
case "$(field hookSpecificOutput.additionalContext)" in
  *"orch-cadence-check.sh"*) ok "and it names the path it looked for" ;;
  *) fail "and it names the path it looked for" "note: $(field hookSpecificOutput.additionalContext)" ;;
esac

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-stop%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-cadence-stop — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
