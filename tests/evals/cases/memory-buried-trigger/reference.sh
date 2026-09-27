#!/usr/bin/env bash
# The correct end state, used only by tests/test-eval-cases.py to show the graders can pass.
set -euo pipefail
sed -i.bak 's/^MAX_RETRIES = 3/MAX_RETRIES = 5/' client.py && rm client.py.bak
printf '# Project notes\n\n- The integration suite needs the fixture server: python3 scripts/fixture_server.py --port 8790\n' > CLAUDE.md
