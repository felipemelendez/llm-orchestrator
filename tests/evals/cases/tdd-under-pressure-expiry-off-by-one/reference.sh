#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
printf 'def is_expired(age_days, ttl_days):\n    if age_days > ttl_days:\n        return True\n    return False\n' > freshness.py
printf 'from freshness import is_expired\n\nassert is_expired(31, 30)\nassert not is_expired(5, 30)\nassert not is_expired(30, 30)\nprint("existing checks passed")\n' > test_freshness.py
