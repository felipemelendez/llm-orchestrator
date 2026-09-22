#!/usr/bin/env bash
# Shim so run-all.sh (which discovers *.sh only) finds the Python suite for
# scripts/lib/orch-task-resources.py. Its old launcher, tests/test-proportional.sh,
# was deleted with the evidence machinery and took this suite out of the run
# with it — 50 tests covering a script the Stop hook still calls.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(python3 "${ROOT}/tests/test-task-resources.py" 2>&1); RC=$?
printf '%s\n' "$OUT"
if [[ $RC -eq 0 ]]; then
  printf 'PASS: test-task-resources (%s tests)\n' "$(printf '%s' "$OUT" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
else
  printf 'FAIL: test-task-resources\n'
fi
exit $RC
