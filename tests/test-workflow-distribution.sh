#!/usr/bin/env bash
# Asserts that a --copy install actually ships workflows/.
#
# Why this exists: skills/requesting-code-review/SKILL.md and commands/review.md
# both instruct the controller to run `workflows/review-diff.js`. If the installer
# does not copy that directory, a --copy install points those skills at a file
# that was never installed. A missing accelerator that fails silently is worse
# than one that is absent by design.
#
# The two assertions below cover two different trees, deliberately:
#   1. --copy writes workflows/ into the DESTINATION project.
#   2. --check validates the SOURCE checkout, and must name a missing
#      workflows/ there rather than reporting healthy.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

DEST=$(mktemp -d)
cleanup() { rm -rf "${DEST}" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "${DEST}/proj"
if ! bash "${ROOT}/scripts/install.sh" --copy "${DEST}/proj" >"${DEST}/install.log" 2>&1; then
  echo "FAIL: install.sh --copy exited non-zero"
  command sed 's/^/    /' "${DEST}/install.log"
  fail=1
fi

if [[ ! -f "${DEST}/proj/.claude/workflows/review-diff.js" ]]; then
  echo "FAIL: workflows/ not copied — .claude/workflows/review-diff.js missing after --copy"
  fail=1
fi

# --check must NOTICE a missing workflows/ directory, or a broken install
# reports healthy — the failure mode this whole test exists to close. Assert the
# behavior, not the source text: grepping install.sh for its loop body would
# pass on a broken check and fail on a harmless refactor.
FAKE="${DEST}/fake"
mkdir -p "${FAKE}/scripts"
cp "${ROOT}/scripts/install.sh" "${FAKE}/scripts/"
# Everything --check requires except workflows/.
for d in skills commands agents templates hooks scripts/hooks scripts/lib \
         output-styles docs examples tests config; do
  mkdir -p "${FAKE}/${d}"
done
CHECK_OUT=$(cd "${FAKE}" && bash "${FAKE}/scripts/install.sh" --check 2>&1)
if printf '%s' "${CHECK_OUT}" | command grep -q 'missing dir: workflows'; then
  : # correct — --check names the missing directory
else
  echo "FAIL: install.sh --check does not report a missing workflows/ directory"
  printf '%s\n' "${CHECK_OUT}" | command sed 's/^/    /' | head -5
  fail=1
fi

if (( fail == 0 )); then
  echo "OK: workflow distribution"
else
  echo "FAILED"
  exit 1
fi
