#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
cat > review.md <<'MD'
# Review

apply_refunds skips the balance check apply_refund enforces: apply_refunds(Order(100), [500]) refunds 500.

recent_refunds(order, 0) returns the whole history, because history[-0:] is history[:].

```json
[
  {"symbol": "apply_refunds", "severity": "critical", "issue": "Batch refunds can exceed the outstanding balance."},
  {"symbol": "recent_refunds", "severity": "minor", "issue": "n=0 returns the whole history instead of an empty list."}
]
```
MD
