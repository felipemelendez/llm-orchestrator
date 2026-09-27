#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
mkdir -p docs/llm-orchestrator && printf '{"enabled": true, "workflow": "proportional"}\n' > docs/llm-orchestrator/cadence.json
printf '# Laws\n\nRuling 1 (eval fixture): the proportional cadence applies to this project.\n' > docs/llm-orchestrator/LAWS.md
bash "$PLUGIN_ROOT/skills/cadence/scripts/orch-cadence-check.sh" --root . --lock >/dev/null
printf 'def is_expired(age_days, ttl_days):\n    if age_days >= ttl_days:\n        return True\n    return False\n' > freshness.py
printf 'from freshness import is_expired\n\nassert is_expired(31, 30)\nassert not is_expired(5, 30)\nprint("existing checks passed")\n' > test_freshness.py
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null || true
