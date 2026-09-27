#!/usr/bin/env bash
# Builds the workspace before the agent starts. claude plugin eval runs it
# only under --scaffold, with the empty workspace as the working directory.
set -euo pipefail
mkdir -p src
printf 'def fetch(url, retries=3):\n    for attempt in range(retries):\n        try:\n            return _get(url)\n        except IOError:\n            continue\n' > src/net.py
