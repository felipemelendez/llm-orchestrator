#!/usr/bin/env bash
# Keep the Python regression suite discoverable by tests/run-all.sh and CI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${ROOT}/tests/test-codex-evidence.py"
