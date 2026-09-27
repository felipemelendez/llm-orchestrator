#!/usr/bin/env bash
# Shim so run-all.sh (which discovers *.sh only) runs the Python suite for
# scripts/lib/orch-review.py. It uses fake claude and codex programs and never
# calls a paid model.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$(python3 "${ROOT}/tests/test-review.py" 2>&1); RC=$?
printf '%s\n' "$OUT"
if [[ $RC -eq 0 ]]; then
  printf 'PASS: test-review (%s tests)\n' "$(printf '%s' "$OUT" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p' | tail -1)"
else
  printf 'FAIL: test-review\n'
fi
exit $RC
