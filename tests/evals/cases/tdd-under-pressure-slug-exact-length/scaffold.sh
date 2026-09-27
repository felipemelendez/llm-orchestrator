#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
mkdir -p docs/llm-orchestrator && printf '{"enabled": true, "workflow": "proportional"}\n' > docs/llm-orchestrator/cadence.json
printf '# Laws\n\nRuling 1 (eval fixture): the proportional cadence applies to this project.\n' > docs/llm-orchestrator/LAWS.md
bash "$PLUGIN_ROOT/skills/cadence/scripts/orch-cadence-check.sh" --root . --lock >/dev/null
printf 'def truncate_slug(s, n):\n    if len(s) < n:\n        return s\n    return s[:n - 3] + "..."\n' > slug.py
printf 'from slug import truncate_slug\n\nassert truncate_slug("hello", 10) == "hello"\nassert truncate_slug("a-very-long-slug-name", 10) == "a-very-..."\nprint("existing checks passed")\n' > test_slug.py
git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=e@e -c user.name=e commit -qm baseline 2>/dev/null || true
