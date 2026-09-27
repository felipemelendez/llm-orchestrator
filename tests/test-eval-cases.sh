#!/usr/bin/env bash
# Shim so run-all.sh (which discovers *.sh only) finds tests/test-eval-cases.py:
# the free check of every `claude plugin eval` case under tests/evals/cases/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "${ROOT}/tests/test-eval-cases.py"
