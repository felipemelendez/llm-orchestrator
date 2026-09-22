#!/usr/bin/env bash
# Completion check. Warns; never blocks.
#
# The question: the reply declared "Verification: PASS" — did a check actually
# run and succeed in this turn? The transcript the harness already writes has
# the answer, so there is nothing to observe, hash or classify.
#
# Three rules. Each has already cost a defect, so change them deliberately:
#
#   1. Read only the explicit `Verification:` label, outside code fences —
#      never the reply's prose. Searching the text for phrases like "tests
#      pass" treats a review QUOTING a passing result as claiming one.
#
#   2. Warn; never block. 200 runs comparing the two scored 100/100 either way
#      (docs/MEASUREMENTS.md, 2026-08-05). A block costs the whole answer
#      twice, in the terminal and in the context window.
#
#   3. Print the note as additionalContext, not only stderr. stderr alone is
#      not delivered to the model on this harness.
#
# The logic is in ../lib/orch-completion-check.py, in its own file so it can be
# tested directly and so the python is not trapped inside a quoted heredoc.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# An ordinary hook: it honours the same off switches as the rest of the plugin.
[[ "${ORCH_HOOK_PROFILE:-standard}" == "minimal" ]] && exit 0
[[ ",${ORCH_DISABLED_HOOKS:-}," == *",orch-verify-gate,"* ]] && exit 0

# Never read a terminal: a hook that can hang is worse than one that learns less.
[[ -t 0 ]] && exit 0
INPUT=$(cat || true)
[[ -n "${INPUT}" ]] || exit 0

CHECK="${HOOK_DIR}/../lib/orch-completion-check.py"
[[ -f "${CHECK}" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Which commands count as a real check, and which only print, are already
# described once in orch-signals.sh. Reuse that rather than writing a second,
# narrower pattern that misses `uv run pytest` and `./gradlew test`.
SIG_LIB="${HOOK_DIR}/../lib/orch-signals.sh"
# shellcheck source=scripts/lib/orch-signals.sh
[[ -f "${SIG_LIB}" ]] && source "${SIG_LIB}"

# The payload goes in on stdin, never argv: a long reply overflows ARG_MAX and
# the check would silently vanish.
printf '%s' "${INPUT}" \
  | ORCH_VERIFY_CMD_RE="${ORCH_SIG_VERIFY_CMD:-}" \
    ORCH_VERIFY_NONRUN_RE="${ORCH_SIG_VERIFY_NONRUN:-}" \
    python3 "${CHECK}"
exit 0
