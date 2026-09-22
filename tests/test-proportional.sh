#!/usr/bin/env bash
# Discoverable entrypoint for the proportional Python suites (run-all scans .sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "${ROOT}/tests/test-proportional-evidence.py"
python3 "${ROOT}/tests/test-task-resources.py"
python3 "${ROOT}/tests/test-proportional-install.py"
printf 'PASS: test-proportional (3 suites)\n'
