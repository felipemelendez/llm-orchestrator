#!/usr/bin/env bash
# Tests for the cadence half of the SessionStart hook.
#
# TWO OBLIGATIONS, PULLING OPPOSITE WAYS.
#
#   1. In cadence mode the session must OPEN with the verdict: whether the lock
#      still matches the tree, which ruling the laws are on, and an 8-character
#      hash of the guard scripts so a swapped guard is visible. It has to appear
#      on the startup path AND on the post-compaction path AND when the compact
#      path falls through under the minimal profile — and it has to survive the
#      8000-char budget, which truncates the TAIL, so it is PREPENDED.
#      It also has to appear when the meta-skill body is empty, which is where
#      the hook used to exit 0 without printing anything at all.
#
#   2. For everyone else the output must be byte-identical to what the hook
#      printed before the cadence existed. That is pinned literally: the hook as
#      of the commit before this change is fetched out of git and run on the
#      same fixtures, and the two outputs are compared byte for byte.
#
# The verdict is a REPORT, never enforcement: this hook already exits early on
# ORCH_DISABLED_HOOKS=orch-session-start, so nothing may depend on it.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${ROOT}/scripts/hooks/session-start.sh"
BASE_REV="ee28065"

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

command -v python3 >/dev/null 2>&1 || skip_suite test-cadence-session-start 'python3 unavailable'
CHECK="${ROOT}/skills/cadence/scripts/orch-cadence-check.sh"
[[ -f "$CHECK" ]] || skip_suite test-cadence-session-start 'the cadence check script is not in this tree'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/orchhome"
mkdir -p "$ORCH_HOME"
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"; printf '{}\n' > "$FAKE_HOME/.claude/settings.json"

STARTUP="$TMP/startup.json"; printf '{"source":"startup","session_id":"s1"}' > "$STARTUP"
COMPACT="$TMP/compact.json"; printf '{"source":"compact","session_id":"s1"}' > "$COMPACT"
RESUME="$TMP/resume.json";  printf '{"source":"resume","session_id":"s1"}'  > "$RESUME"

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
PLAIN="$TMP/plain"; mkproj "$PLAIN"

run_hook() { # run_hook <hook> <project> <event-file> [env=val ...] ; stdout to $OUT, stderr to $ERRF
  local h="$1" proj="$2" ev="$3"; shift 3
  ( cd "$proj" && env CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$proj" \
      HOME="$FAKE_HOME" ORCH_HOME="$ORCH_HOME" "$@" bash "$h" < "$ev" ) > "$OUT" 2>"$ERRF"
  printf '%s' "$?"
}
OUT="$TMP/out.txt"; ERRF="$TMP/err.txt"

ctx() { # the additionalContext string out of $OUT, or empty
  python3 - "$OUT" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
sys.stdout.write(((d.get("hookSpecificOutput") or {}).get("additionalContext")) or "")
PY
}

GUARD_HASH=$(cat "${ROOT}/scripts/hooks/"guard-*.sh 2>/dev/null | { \
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
  else openssl dgst -sha256 | awk '{print $NF}'; fi; } | cut -c1-8)

# =============================================================================
printf '%s== byte identity for a project that never opted in ==%s\n' "$DIM" "$RESET"
# =============================================================================
OLD="$TMP/session-start.old.sh"
if git -C "$ROOT" show "${BASE_REV}:scripts/hooks/session-start.sh" > "$OLD" 2>/dev/null \
   && [[ -s "$OLD" ]]; then
  for pair in "startup:$STARTUP" "compact:$COMPACT" "resume:$RESUME"; do
    label="${pair%%:*}"; ev="${pair#*:}"
    run_hook "$OLD" "$PLAIN" "$ev" >/dev/null; cp "$OUT" "$TMP/old.out"; cp "$ERRF" "$TMP/old.err"
    run_hook "$HOOK" "$PLAIN" "$ev" >/dev/null
    if cmp -s "$TMP/old.out" "$OUT" && cmp -s "$TMP/old.err" "$ERRF"; then
      ok "source=${label}: output identical to ${BASE_REV}"
    else
      fail "source=${label}: output identical to ${BASE_REV}" \
           "$(cmp "$TMP/old.out" "$OUT" 2>&1 | head -1)"
    fi
  done
  for prof in minimal strict; do
    run_hook "$OLD" "$PLAIN" "$COMPACT" ORCH_HOOK_PROFILE="$prof" >/dev/null; cp "$OUT" "$TMP/old.out"
    run_hook "$HOOK" "$PLAIN" "$COMPACT" ORCH_HOOK_PROFILE="$prof" >/dev/null
    cmp -s "$TMP/old.out" "$OUT" && ok "compact under ${prof}: output identical to ${BASE_REV}" \
      || fail "compact under ${prof}: output identical to ${BASE_REV}" "outputs differ"
  done
  run_hook "$OLD" "$PLAIN" "$STARTUP" ORCH_HOOK_DRY_RUN=1 >/dev/null; cp "$ERRF" "$TMP/old.err"
  run_hook "$HOOK" "$PLAIN" "$STARTUP" ORCH_HOOK_DRY_RUN=1 >/dev/null
  cmp -s "$TMP/old.err" "$ERRF" && ok "dry-run: stderr identical to ${BASE_REV}" \
    || fail "dry-run: stderr identical to ${BASE_REV}" "$(head -1 "$ERRF")"
else
  ok "SKIP byte-identity pin (${BASE_REV} not reachable from this checkout)"
fi

# =============================================================================
printf '%s== the verdict, in cadence mode ==%s\n' "$DIM" "$RESET"
# =============================================================================
rc=$(run_hook "$HOOK" "$PROJ" "$STARTUP")
C=$(ctx)
[[ "$rc" == "0" ]] && ok "startup exits 0" || fail "startup exits 0" "exit $rc"
case "$C" in
  "cadence: LAWS.md (ruling 3) · lock UNARMED · guards: "*) ok "startup opens with the verdict and the guard hash" ;;
  *) fail "startup opens with the verdict and the guard hash" "context starts: $(printf '%s' "$C" | head -1)" ;;
esac
case "$C" in
  *"guards: ${GUARD_HASH}"*) ok "the guard hash is the sha256 of the concatenated guards" ;;
  *) fail "the guard hash is the sha256 of the concatenated guards" "wanted ${GUARD_HASH}" ;;
esac
case "$C" in
  *"You are running LLM Orchestrator"*) ok "the meta-skill preamble still follows it" ;;
  *) fail "the meta-skill preamble still follows it" "preamble missing" ;;
esac

run_hook "$HOOK" "$PROJ" "$COMPACT" >/dev/null
C=$(ctx)
case "$C" in
  "cadence: LAWS.md (ruling 3)"*) ok "the compact path opens with the verdict too" ;;
  *) fail "the compact path opens with the verdict too" "context starts: $(printf '%s' "$C" | head -1)" ;;
esac
case "$C" in
  *"Post-compaction recovery"*) ok "the compact recovery note is still there" ;;
  *) fail "the compact recovery note is still there" "note missing" ;;
esac

run_hook "$HOOK" "$PROJ" "$COMPACT" ORCH_HOOK_PROFILE=minimal >/dev/null
C=$(ctx)
case "$C" in
  "cadence: LAWS.md (ruling 3)"*) ok "compact under minimal falls through and still carries the verdict" ;;
  *) fail "compact under minimal falls through and still carries the verdict" "context starts: $(printf '%s' "$C" | head -1)" ;;
esac

# The hook used to exit 0 with no output when the meta body was empty; the
# verdict has to survive that path, which is exactly where a broken plugin
# install would leave a cadence project with no report at all.
EMPTY_ROOT="$TMP/emptyroot"; mkdir -p "$EMPTY_ROOT/skills"
rc=$(run_hook "$HOOK" "$PROJ" "$STARTUP" CLAUDE_PLUGIN_ROOT="$EMPTY_ROOT")
C=$(ctx)
[[ "$rc" == "0" ]] && ok "an empty meta body still exits 0" || fail "an empty meta body still exits 0" "exit $rc"
case "$C" in
  "cadence: LAWS.md (ruling 3)"*) ok "an empty meta body still emits the verdict" ;;
  *) fail "an empty meta body still emits the verdict" "context: $(printf '%s' "$C" | head -1)" ;;
esac
run_hook "$HOOK" "$PLAIN" "$STARTUP" CLAUDE_PLUGIN_ROOT="$EMPTY_ROOT" >/dev/null
[[ ! -s "$OUT" ]] && ok "an empty meta body outside cadence mode still prints nothing" \
  || fail "an empty meta body outside cadence mode still prints nothing" "printed: $(head -c 120 "$OUT")"

# =============================================================================
printf '%s== the snapshot the stop hook reads ==%s\n' "$DIM" "$RESET"
# =============================================================================
rm -rf "$ORCH_HOME/state"
run_hook "$HOOK" "$PROJ" "$STARTUP" >/dev/null
SNAP=$(ls "$ORCH_HOME"/state/cadence-snapshot.* 2>/dev/null | head -1)
if [[ -n "$SNAP" ]]; then
  ok "a snapshot is written for this project"
  grep -q 'UNARMED' "$SNAP" && ok "the snapshot records the unarmed state" \
    || fail "the snapshot records the unarmed state" "content: $(head -2 "$SNAP" | tr '\n' ' ')"
else
  fail "a snapshot is written for this project" "nothing under $ORCH_HOME/state"
  fail "the snapshot records the unarmed state" "no snapshot"
fi

bash "$CHECK" --root "$PROJ" --lock >/dev/null 2>&1
rm -rf "$ORCH_HOME/state"
run_hook "$HOOK" "$PROJ" "$STARTUP" >/dev/null
C=$(ctx)
case "$C" in "cadence: LAWS.md (ruling 3) · lock OK"*) ok "a locked project reports lock OK" ;;
  *) fail "a locked project reports lock OK" "context: $(printf '%s' "$C" | head -1)" ;;
esac
SNAP=$(ls "$ORCH_HOME"/state/cadence-snapshot.* 2>/dev/null | head -1)
[[ -n "$SNAP" ]] && grep -qx 'OK' "$SNAP" && ok "the snapshot of a clean lock is OK" \
  || fail "the snapshot of a clean lock is OK" "content: $(head -2 "${SNAP:-/dev/null}" | tr '\n' ' ')"

printf '\nRuling 4 — appended without a ruling.\n' >> "$PROJ/docs/llm-orchestrator/LAWS.md"
rm -rf "$ORCH_HOME/state"
run_hook "$HOOK" "$PROJ" "$STARTUP" >/dev/null
C=$(ctx)
case "$C" in *"lock CHANGED"*) ok "an edited law is reported as CHANGED" ;;
  *) fail "an edited law is reported as CHANGED" "context: $(printf '%s' "$C" | head -1)" ;;
esac
SNAP=$(ls "$ORCH_HOME"/state/cadence-snapshot.* 2>/dev/null | head -1)
[[ -n "$SNAP" ]] && grep -qx 'docs/llm-orchestrator/LAWS.md' "$SNAP" \
  && ok "the snapshot names the changed path, one per line" \
  || fail "the snapshot names the changed path, one per line" "content: $(tr '\n' ' ' < "${SNAP:-/dev/null}")"

# =============================================================================
printf '%s== the drifting .githooks copy, and a missing helper ==%s\n' "$DIM" "$RESET"
# =============================================================================
mkdir -p "$PROJ/.githooks"
cp "$CHECK" "$PROJ/.githooks/orch-cadence-check.sh"
run_hook "$HOOK" "$PROJ" "$STARTUP" >/dev/null
C=$(ctx)
case "$C" in *"hook copy differs"*) fail "an identical .githooks copy is not reported as drift" "reported drift" ;;
  *) ok "an identical .githooks copy is not reported as drift" ;;
esac
printf '\n# drifted\n' >> "$PROJ/.githooks/orch-cadence-check.sh"
run_hook "$HOOK" "$PROJ" "$STARTUP" >/dev/null
C=$(ctx)
case "$C" in *"hook copy differs"*) ok "a drifted .githooks copy is reported" ;;
  *) fail "a drifted .githooks copy is reported" "context: $(printf '%s' "$C" | head -1)" ;;
esac
rm -rf "$PROJ/.githooks"

LONELY="$TMP/lonely/scripts/hooks"; mkdir -p "$LONELY"
cp "$HOOK" "$LONELY/session-start.sh"
run_hook "$LONELY/session-start.sh" "$PROJ" "$STARTUP" >/dev/null
C=$(ctx)
case "$C" in "cadence: check script missing at "*) ok "a missing check script is said out loud" ;;
  *) fail "a missing check script is said out loud" "context: $(printf '%s' "$C" | head -1)" ;;
esac

# =============================================================================
printf '%s== the verdict is a report, never enforcement ==%s\n' "$DIM" "$RESET"
# =============================================================================
rc=$(run_hook "$HOOK" "$PROJ" "$STARTUP" ORCH_DISABLED_HOOKS=orch-session-start)
[[ "$rc" == "0" && ! -s "$OUT" ]] && ok "ORCH_DISABLED_HOOKS=orch-session-start still silences the whole hook" \
  || fail "ORCH_DISABLED_HOOKS=orch-session-start still silences the whole hook" "exit $rc, output $(head -c 80 "$OUT")"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-cadence-session-start%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-cadence-session-start — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
