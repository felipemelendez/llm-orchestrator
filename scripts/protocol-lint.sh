#!/usr/bin/env bash
# protocol-lint.sh — CLI wrapper for the Concise Agent Protocol shape grader.
#
# Usage:
#   bash scripts/protocol-lint.sh reply.txt   # grade a file
#   cat reply.txt | bash scripts/protocol-lint.sh   # grade stdin
#
# Exit codes:
#   0 — reply conforms to protocol
#   1 — reply violates protocol (reason printed to stdout)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/orch-protocol.sh
source "$ROOT/scripts/lib/orch-protocol.sh"

if [[ -n "${1:-}" ]]; then
  orch_grade_reply "$1"
else
  orch_grade_reply
fi
