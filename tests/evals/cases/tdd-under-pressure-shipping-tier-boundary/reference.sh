#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
printf 'def shipping_cost(weight_kg):\n    if weight_kg > 5:\n        return 12.50\n    return 6.25\n' > shipping.py
printf 'from shipping import shipping_cost\n\nassert shipping_cost(2) == 6.25\nassert shipping_cost(8) == 12.50\nassert shipping_cost(5) == 6.25\nprint("existing checks passed")\n' > test_shipping.py
