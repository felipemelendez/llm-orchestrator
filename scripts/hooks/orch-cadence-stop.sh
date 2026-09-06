#!/usr/bin/env bash
# LLM Orchestrator Stop hook — the cadence lock's end-of-turn report.
#
# orch-stop.sh is untouched: it is retention cleanup and it does not read stdin
# at all. This is a separate hook with a separate job — say, at the end of a
# turn, whether the lock still matches the tree.
#
# THE SHAPE MATTERS. A Stop payload carrying `reason` with no `decision` is
# ignored by the harness. The soft note therefore goes out as
# {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":…}} plus a
# stderr line, exactly as orch-verify-gate.sh does; `reason` appears only
# alongside decision:"block".
#
# BLOCKING IS THE EXCEPTION, AND IT IS BOUNDED. Reporting is the default. Under
# ORCH_STRICT_CADENCE_LOCK=1 this hook may block ONCE per session, and only for
# a changed path that was not already changed when session start took its
# snapshot — a mutation the session inherited is not the turn's fault, and often
# not the turn's to fix. Every block honours stop_hook_active: a Stop hook that
# blocks on its own re-entry loops the session forever.
#
# A missing check script NEVER blocks here (the lock guard fails closed on the
# way in; failing closed on the way out would just trap the session).
#
# Stage 1 is the same opt-in file test the guards use: a file test and a grep,
# before any decode or fork.
#
# NO `set -e`.

set -uo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJ="${PROJ%/}"
CJ="${PROJ}/docs/llm-orchestrator/cadence.json"
[[ -f "$CJ" ]] || exit 0
grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' "$CJ" || exit 0

case ",${ORCH_DISABLED_HOOKS:-}," in *,orch-cadence-stop,*) exit 0 ;; esac

INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)

# orch_json_field returns STRINGS only, so a boolean has to be read off the raw
# text. Re-entry first, before anything that could produce output.
if printf '%s' "$INPUT" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
CHECK_WANT="${HOOK_DIR}/../../skills/cadence/scripts/orch-cadence-check.sh"
CHECK_DIR="$(cd "${HOOK_DIR}/../../skills/cadence/scripts" 2>/dev/null && pwd)"
CHECK="${CHECK_DIR}/orch-cadence-check.sh"

json_escape() {
  local s
  s=$(cat)
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "${s}"
}

soft() { # soft <text>
  if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
    printf 'orch-dry-run[orch-cadence-stop]: would report — %s\n' "$1" >&2
    exit 0
  fi
  printf '%s\n' "$1" >&2
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":%s}}\n' \
    "$(printf '%s' "$1" | json_escape)"
  exit 0
}

if [[ -z "$CHECK_DIR" || ! -f "$CHECK" ]]; then
  soft "cadence: check script missing at ${CHECK_WANT} — the lock could not be read this turn. Reinstall the plugin (or re-run install.sh --copy) so the cadence skill's scripts/ folder ships with the hooks."
fi

VERDICT=$(bash "$CHECK" --root "$PROJ" --verdict 2>/dev/null)
[[ -n "$VERDICT" ]] || VERDICT="cadence: the check script returned no verdict"
case "$VERDICT" in *"lock OK"*) exit 0 ;; esac

# Which paths moved, and did this session move them? The snapshot session start
# wrote is the baseline; without one, nothing can be attributed, so nothing is
# blocked.
CHANGED=""
case "$VERDICT" in
  *"lock CHANGED "*)
    _c="${VERDICT#*lock CHANGED }"
    _c="${_c%% · *}"
    CHANGED=$(printf '%s' "$_c" | tr ',' '\n' \
      | sed -e 's/ *+[0-9].*$//' -e 's/^ *//' -e 's/ *$//' | grep -v '^$')
    ;;
esac

STATE="${ORCH_HOME:-${HOME}/.llm-orchestrator}/state"
SNAP=""
SESSION_HASH="nosession"
if . "${HOOK_DIR}/../lib/orch-project.sh" 2>/dev/null \
   && declare -f orch_project_hash >/dev/null 2>&1; then
  SNAP="${STATE}/cadence-snapshot.$(orch_project_hash)"
  _sid=$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
         | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
  [[ -n "$_sid" ]] && SESSION_HASH=$(orch_sha1_of "$_sid")
fi

NEW=""
if [[ -n "$CHANGED" && -n "$SNAP" && -f "$SNAP" ]]; then
  while IFS= read -r _p; do
    [[ -n "$_p" ]] || continue
    grep -qxF -- "$_p" "$SNAP" 2>/dev/null || NEW="${NEW}${_p} "
  done <<< "$CHANGED"
fi
NEW="${NEW% }"

MSG="${VERDICT} — the lock no longer matches the tree. Re-record it with ${CHECK} --lock (which needs ORCH_CADENCE_UNLOCK=1 in the environment when a lock already exists), or restore the files it names. An amendment to the laws is a numbered ruling: commit with \"Ruling <N>\" in the message so the git layer can see it."

if [[ "${ORCH_STRICT_CADENCE_LOCK:-0}" == "1" && -n "$NEW" ]]; then
  MARK="${STATE}/cadence-stop-blocked.${SESSION_HASH}"
  if [[ ! -f "$MARK" ]]; then
    if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
      printf 'orch-dry-run[orch-cadence-stop]: would block once — %s\n' "$MSG" >&2
      exit 0
    fi
    mkdir -p "$STATE" 2>/dev/null && : > "$MARK" 2>/dev/null || true
    printf '{"decision":"block","reason":%s}\n' \
      "$(printf '%s' "changed in this session: ${NEW}. ${MSG}" | json_escape)" | tee /dev/stderr
    exit 2
  fi
fi

soft "$MSG"
