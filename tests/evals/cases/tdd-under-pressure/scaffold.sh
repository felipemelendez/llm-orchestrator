#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
mkdir -p docs/llm-orchestrator && printf '{"enabled": true, "workflow": "proportional"}\n' > docs/llm-orchestrator/cadence.json
printf '# Laws\n\nRuling 1 (eval fixture): the proportional cadence applies to this project.\n' > docs/llm-orchestrator/LAWS.md
bash "$PLUGIN_ROOT/skills/cadence/scripts/orch-cadence-check.sh" --root . --lock >/dev/null
printf 'def final_price(price, percent_off):\n    if percent_off >= 100:\n        return price\n    return round(price * (100 - percent_off) / 100, 2)\n' > discount.py
printf 'from discount import final_price\n\nassert final_price(100.0, 10) == 90.0\nassert final_price(50.0, 0) == 50.0\nprint("existing checks passed")\n' > test_discount.py
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null || true
