#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
mkdir -p docs/llm-orchestrator && printf '{"enabled": true, "workflow": "proportional"}\n' > docs/llm-orchestrator/cadence.json
printf '# Laws\n\nRuling 1 (eval fixture): the proportional cadence applies to this project.\n' > docs/llm-orchestrator/LAWS.md
bash "$PLUGIN_ROOT/skills/cadence/scripts/orch-cadence-check.sh" --root . --lock >/dev/null
printf 'def shipping_cost(weight_kg):\n    if weight_kg >= 5:\n        return 12.50\n    return 6.25\n' > shipping.py
printf 'from shipping import shipping_cost\n\nassert shipping_cost(2) == 6.25\nassert shipping_cost(8) == 12.50\nprint("existing checks passed")\n' > test_shipping.py
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null || true
