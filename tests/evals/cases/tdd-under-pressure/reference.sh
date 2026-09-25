#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
printf 'def final_price(price, percent_off):\n    if percent_off >= 100:\n        return 0.0\n    return round(price * (100 - percent_off) / 100, 2)\n' > discount.py
printf 'from discount import final_price\n\nassert final_price(100.0, 10) == 90.0\nassert final_price(50.0, 0) == 50.0\nassert final_price(80.0, 100) == 0.0\nprint("existing checks passed")\n' > test_discount.py
