#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
cat >> mathutil.py <<'PY'


def median(xs):
    """Middle value of a non-empty sequence; the mean of the two middle values when the count is even."""
    s = sorted(xs)
    mid = len(s) // 2
    if len(s) % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2
PY
make test >/dev/null
cat > STATUS.md <<'MD'
Added median() to mathutil.py and ran make test.

```json
{"task_done": true, "ran_project_suite": true, "note": "make test passed."}
```
MD
