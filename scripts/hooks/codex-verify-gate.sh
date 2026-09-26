#!/usr/bin/env bash
# Codex completion check. The Codex twin of orch-verify-gate.sh.
#
# The question is the same: the reply declared "Verification: PASS" — did a
# check actually run and succeed in this turn? Codex's Stop hook hands over the
# reply and the path of the session log it already keeps, so there is nothing
# to observe, hash or classify. The logic is in ../lib/codex-completion-check.py.
#
# Where the note goes differs from Claude Code, and on purpose: Codex offers no
# way to give the agent a note without a continuation, and its only other
# output is a warning in the person's UI. The person is never the audience for
# an agent's missing check, so the note is a one-shot continuation to the agent
# and nothing is printed for the person. Registered on Stop only: Codex does
# not give a subagent's own log to SubagentStop in a form this can read.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# An ordinary hook: it honours the same off switches as the rest of the plugin.
[[ "${ORCH_HOOK_PROFILE:-standard}" == "minimal" ]] && exit 0
[[ ",${ORCH_DISABLED_HOOKS:-}," == *",codex-verify-gate,"* ]] && exit 0

# Never read a terminal: a hook that can hang is worse than one that learns less.
[[ -t 0 ]] && exit 0
INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

CHECK="${HOOK_DIR}/../lib/codex-completion-check.py"
[[ -f "${CHECK}" && -f "${HOOK_DIR}/../lib/orch-completion-check.py" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# stdin, never argv: a long reply overflows ARG_MAX and the check would vanish.
# Which commands count is described once, in orch-completion-check.py.
printf '%s' "${INPUT}" | python3 "${CHECK}"
exit 0
