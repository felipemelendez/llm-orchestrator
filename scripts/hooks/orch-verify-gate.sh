#!/usr/bin/env bash
# Completion check. Warns; never blocks.
#
# The question: the reply declared "Verification: PASS" — did a check actually
# run and succeed in this turn? The transcript the harness already writes has
# the answer, so there is nothing to observe, hash or classify. The 2,201-line
# module that used to watch every command and fingerprint the repository was
# removed on 2026-09-21; this is what replaced it.
#
# Three rules, each learned the hard way and each having cost a defect:
#
#   1. Never read the reply's prose. The old version searched for phrases like
#      "tests pass" anywhere in the text, so an audit QUOTING a passing result
#      was treated as claiming one. Only the explicit `Verification:` label
#      counts, and only outside code fences.
#
#   2. Never block. docs/MEASUREMENTS.md, 2026-08-05: 200 runs comparing warn
#      against block scored 100/100 both ways — "the dishonest claim the gate
#      exists to catch never occurred". A block costs the whole answer twice,
#      in the terminal and in the context window.
#
#   3. Say it where it is read. stderr alone is a no-op on this harness
#      (CHANGELOG.md:769), so the note also goes out as additionalContext.
#
# The logic is in ../lib/orch-completion-check.py. It lives in its own file so
# it can be tested directly, and because inlining python in a quoted heredoc is
# how the first version of this hook broke.
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
