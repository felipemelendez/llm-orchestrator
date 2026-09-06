#!/usr/bin/env bash
# LLM Orchestrator PreToolUse guard — a dispatch must name its model.
# Matcher: Agent|Task (Task is the legacy alias for the same tool).
#
# WHY A HOOK. The laws of a cadence project fix the model per seat: one model
# for every seat, a different one only for the plain-language adversarial seat,
# so a finding's rank means the same thing in every report. A dispatch that
# names no model silently inherits whatever the session happens to be running,
# and the seat's verdict is then not comparable with any other. No native
# permission rule can match an ABSENT parameter, so this cannot be a deny rule.
#
# WHY IT FAILS OPEN. A wrong block here stops every dispatch in the session,
# while an unnamed model costs one comparison — so the cheap failure is the
# open one. An undecodable payload, a missing python3, and anything else this
# hook cannot read with confidence all exit 0.
#
# Stage 1 is the cadence's usual opt-in test: a file test and a grep, before
# any decode or fork.
#
# NO `set -e` — a guard that aborts exits non-zero-but-not-2, which the harness
# reads as a hook error.

set -uo pipefail

PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJ="${PROJ%/}"
CJ="${PROJ}/docs/llm-orchestrator/cadence.json"
[[ -f "$CJ" ]] || exit 0
grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' "$CJ" || exit 0

# This is a process rule, not a data-loss guard, so it is nameable in
# ORCH_DISABLED_HOOKS. It is not profile-gated: cadence mode
# is already an explicit opt-in, and the profile is about noise, not process.
case ",${ORCH_DISABLED_HOOKS:-}," in *,orch-dispatch-model,*) exit 0 ;; esac

# The cadence's own unlock, refused on the same terms the check script uses: a
# settings file that persists the token would disarm every future session
# invisibly.
if [[ "${ORCH_CADENCE_UNLOCK:-}" == "1" ]]; then
  _carrier=""
  for _f in "${PROJ}/.claude/settings.json" "${PROJ}/.claude/settings.local.json" \
            "${HOME:-/nonexistent}/.claude/settings.json"; do
    [[ -f "$_f" ]] || continue
    if grep -q 'ORCH_CADENCE_UNLOCK' "$_f" 2>/dev/null; then _carrier="$_f"; break; fi
  done
  if [[ -z "$_carrier" ]]; then exit 0; fi
  printf 'LLM Orchestrator cadence guard: ORCH_CADENCE_UNLOCK is set, but %s persists that token; a persisted unlock is a disarmed lock, so the unlock is refused here.\n' \
    "$_carrier" >&2
fi

# Without python3 nothing can be read with confidence — and this guard never
# blocks on what it cannot read.
command -v python3 >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=scripts/lib/orch-json.sh
[[ -f "${HOOK_DIR}/../lib/orch-json.sh" ]] && source "${HOOK_DIR}/../lib/orch-json.sh"
declare -f orch_json_field >/dev/null 2>&1 || exit 0

INPUT=""
[[ -t 0 ]] || INPUT=$(cat || true)
[[ -n "$INPUT" ]] || exit 0

MODEL=$(orch_json_field "$INPUT" tool_input.model)
[[ -n "$MODEL" ]] && exit 0

# Empty could mean several different things: the payload did not parse, there is
# no tool_input, tool_input is not an OBJECT, or the model really is absent.
# Only the last is a refusal. orch_json_has_field is not enough on its own — it
# is true for `"tool_input": ["a"]`, a structurally malformed payload that
# decision 8 puts squarely on the fail-open side, and the guard blocked it.
# Anything that is not a real object of tool arguments is unreadable, so it
# exits 0 (R-10).
printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") if isinstance(d, dict) else None
sys.exit(0 if isinstance(ti, dict) else 1)
' 2>/dev/null || exit 0

cat <<'MSG' >&2
LLM Orchestrator cadence guard: this dispatch names no model.
Please name the model: one model for every seat, a different one only for the plain-language adversarial seat, per LAWS.md. A dispatch with no `model` inherits whatever the session happens to be running, and a seat's verdict is then not comparable with any other seat's. Add `model` to the tool input and retry.
MSG
exit 2
