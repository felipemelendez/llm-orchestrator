#!/usr/bin/env bash
# Shim so run-all.sh (which discovers *.sh only) finds tests/test-review-compare.py:
# the free check of the review comparison set, its build and its scorer.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(python3 "${ROOT}/tests/test-review-compare.py" 2>&1); RC=$?
printf '%s\n' "$OUT"
if [[ $RC -eq 0 ]]; then
  printf 'PASS: test-review-compare (%s tests)\n' "$(printf '%s' "$OUT" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
else
  printf 'FAIL: test-review-compare\n'
fi
exit $RC
