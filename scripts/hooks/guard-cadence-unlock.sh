#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard — in cadence mode an agent's own Bash
# command may not NAME one of the cadence's four environment switches. A
# MENTION RULE, not a parser: the decoded command, continued lines joined, is
# searched for ORCH_CADENCE_UNLOCK, ORCH_DISABLED_HOOKS, ORCH_HOOK_PROFILE and
# ORCH_ALLOW_; a hit is refused. No assignment spelling can be missed, because
# no spelling is described.
# THE COST, stated in the refusal and accepted: not to set, not to read, not to
# search, not to mention — `echo $ORCH_CADENCE_UNLOCK`, `grep -rn
# ORCH_HOOK_PROFILE docs/`, a comment and a longer name containing one are all
# refused. They belong in the person's own shell, where these are set at launch.
# THE RESIDUAL: a name assembled at runtime or split by a quote is invisible
# here — the alarm names the changed manifest afterwards. NO HATCH: the switch
# it refuses is the switch that would turn it off. Stage 1 is the cadence's
# opt-in file test, before any decode or fork. Exit 0 or 2. NO `set -e`.
set -uo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJ="${PROJ%/}"; CJ="${PROJ}/docs/llm-orchestrator/cadence.json"
[[ -f "$CJ" ]] || exit 0
grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' "$CJ" || exit 0
INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
[[ -n "$INPUT" ]] || exit 0
NAMES='ORCH_CADENCE_UNLOCK|ORCH_DISABLED_HOOKS|ORCH_HOOK_PROFILE|ORCH_ALLOW_'

refuse() { # refuse [first-line]
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" >&2
  cat <<'MSG' >&2
LLM Orchestrator cadence guard: this command names one of the cadence's environment switches.
ORCH_CADENCE_UNLOCK, ORCH_DISABLED_HOOKS, ORCH_HOOK_PROFILE and the ORCH_ALLOW_* hatches are set by a person at launch, in their own shell, for the one session that needs them; a command an agent runs may not name them — not to set one, not to read one, not to search for one. Do it in your own shell. The re-lock line the init prints is for the person's shell: ask for a session started with it.
MSG
  exit 2
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${HOOK_DIR}/../lib/orch-json.sh" ]] && source "${HOOK_DIR}/../lib/orch-json.sh"
if ! command -v python3 >/dev/null 2>&1 || ! declare -f orch_json_field >/dev/null 2>&1; then
  RAW=$(printf '%s' "$INPUT" | tr -d '\n')
  # The same join the precise path makes: in the JSON-encoded payload a
  # continued line is the four characters backslash backslash backslash n.
  SEQ='\\\n'; RAW=${RAW//"$SEQ"/}
  [[ "$RAW" =~ (${NAMES}) ]] || exit 0
  refuse "python3 is absent, so this hook cannot read the command precisely, and a call naming one of these switches is refused."
fi
TOOL=$(orch_json_field "$INPUT" tool_name)
CMD=$(orch_json_field "$INPUT" tool_input.command)
[[ -n "$CMD" ]] || exit 0
[[ -z "$TOOL" || "$TOOL" == "Bash" ]] || exit 0
BS='\'; NL=$'\n'; JOINED=${CMD//"${BS}${NL}"/}
[[ "$JOINED" =~ (${NAMES}) ]] && refuse ""
exit 0
