#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
mkdir -p docs/llm-orchestrator && printf '{"enabled": true, "workflow": "proportional"}\n' > docs/llm-orchestrator/cadence.json
printf '# Laws\n\nRuling 1 (eval fixture): the proportional cadence applies to this project.\n' > docs/llm-orchestrator/LAWS.md
bash "$PLUGIN_ROOT/skills/cadence/scripts/orch-cadence-check.sh" --root . --lock >/dev/null
printf 'def add(a, b):\n    return a + b\n\n\ndef mul(a, b):\n    return a + b\n' > calc.py
printf 'from calc import add, mul\n\nassert add(2, 3) == 5\nassert mul(2, 3) == 6\nassert mul(0, 5) == 0\nprint("all checks passed")\n' > test_calc.py
