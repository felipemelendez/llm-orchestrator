#!/usr/bin/env bash
# Both harnesses retry only explicitly finished task resources.
set -uo pipefail
PROFILE="${ORCH_HOOK_PROFILE:-standard}"
DISABLED="${ORCH_DISABLED_HOOKS:-}"
if [[ "${PROFILE}" == "minimal" || ",${DISABLED}," == *",orch-task-cleanup,"* ]]; then
  exit 0
fi
if [[ "${ORCH_HOOK_DRY_RUN:-0}" == "1" ]]; then
  printf 'orch-dry-run[orch-task-cleanup]: would retry explicitly finished task resources\n' >&2
  exit 0
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "${script_dir}/../lib/orch-task-resources.py" hook-retry
