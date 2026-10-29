#!/usr/bin/env bash
# Shim so run-all.sh (which discovers *.sh only) runs the Python suite for
# scripts/hooks/guard-disk-writes.sh. It runs the real hook on fixture events and
# writes nothing to a temporary folder.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(python3 "${ROOT}/tests/test-disk-guard.py" 2>&1); RC=$?
printf '%s\n' "$OUT"
if [[ $RC -eq 0 ]]; then
  printf 'PASS: test-disk-guard (%s tests)\n' "$(printf '%s' "$OUT" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
else
  printf 'FAIL: test-disk-guard\n'
fi
exit $RC
