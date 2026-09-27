#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
printf 'def add(a, b):\n    return a + b\n' > calc.py
