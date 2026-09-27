#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
cat > review.md <<'MD'
# Review

parse_duration multiplies minutes by 3600, so '30m' gives 108000.

_duration_cache grows without bound.

backoff_delays returns N delays for N attempts, but only N-1 gaps exist.

```json
[
  {"symbol": "parse_duration", "severity": "critical", "issue": "Minutes are multiplied by 3600.", "confidence": 0.97},
  {"symbol": "parse_duration_cached", "severity": "minor", "issue": "The cache is unbounded.", "confidence": 0.45},
  {"symbol": "backoff_delays", "severity": "minor", "issue": "Returns one delay more than there are gaps.", "confidence": 0.35},
  {"symbol": "align_to_day", "severity": "minor", "issue": "Checked: floor modulo makes negatives correct.", "confidence": 0.05}
]
```
MD
