#!/usr/bin/env bash
# LLM Orchestrator Stop hook.
# Fires when Claude finishes responding to a turn (NOT at session end).
#
# Defensive cleanup only. Two responsibilities:
#   1. Prune memory/.trash/ older than ORCH_SESSION_RETENTION_DAYS (default 90).
#   2. Prune research/cache/ older than per-file or default ORCH_RESEARCH_RETENTION_DAYS.

set -uo pipefail

DISABLED="${ORCH_DISABLED_HOOKS:-}"
RETENTION_DAYS="${ORCH_SESSION_RETENTION_DAYS:-90}"
RESEARCH_RETENTION_DAYS="${ORCH_RESEARCH_RETENTION_DAYS:-30}"

if [[ ",${DISABLED}," == *",orch-stop,"* ]]; then
  exit 0
fi

HOME_DIR="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
TRASH_DIR="${HOME_DIR}/memory/.trash"
RESEARCH_CACHE_DIR="${HOME_DIR}/research/cache"

TOOLCHAIN_CACHE_DIR="${HOME_DIR}/toolchain"
ARCH_CACHE_DIR="${HOME_DIR}/architecture"
HANDOFF_STATE_DIR="${HOME_DIR}/handoff"

# Pruning runs every turn (cheap, idempotent). Suppress errors so a missing
# dir doesn't fail the hook.
[[ -d "${TRASH_DIR}" ]] && find "${TRASH_DIR}" -name '*.md' -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
# Toolchain cache: prune stale detection results.
[[ -d "${TOOLCHAIN_CACHE_DIR}" ]] && find "${TOOLCHAIN_CACHE_DIR}" -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
# Stranded .lockdir directories: `-type f -delete` above can NEVER remove one —
# a lockdir is a DIRECTORY — yet this file used to claim it did. With_lock's
# own dead-pid/TTL steal is the primary recovery; this is the janitor for lock
# paths nothing contends on anymore, and it exists to break the PID-reuse
# deadlock (a rebooted host where the recorded pid now names an unrelated live
# process that with_lock will wait on forever).
#
# Age alone is NOT proof of death — the exact rule with_lock's TTL branch was
# fixed to enforce. A bare `find ... -exec rm -rf` robbed a live holder mid-
# write on the strength of a slow turn. So: read the lockdir's recorded pid
# and SKIP when that process is alive (ps as the arbiter when kill -0 fails —
# EPERM against another uid's live process is not death). A missing or
# non-numeric pid proves nothing is holding it: sweep.
_orch_sweep_lockdirs() { # <dir>
  local d pid
  while IFS= read -r d; do
    [[ -n "${d}" && -d "${d}" ]] || continue
    pid="$(cat "${d}/pid" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" != *[!0-9]* ]]; then
      if kill -0 "${pid}" 2>/dev/null || ps -p "${pid}" >/dev/null 2>&1; then
        continue   # live holder — a slow turn is not a stranded lock
      fi
    fi
    rm -rf "${d}" 2>/dev/null || true
  done < <(find "$1" -name '*.lockdir' -type d -mmin +60 2>/dev/null)
}
[[ -d "${TOOLCHAIN_CACHE_DIR}" ]] && _orch_sweep_lockdirs "${TOOLCHAIN_CACHE_DIR}" || true
[[ -d "${HOME_DIR}/memory" ]] && _orch_sweep_lockdirs "${HOME_DIR}/memory" || true
# Architecture study cache: prune stale decisions files at same retention as toolchain.
[[ -d "${ARCH_CACHE_DIR}" ]] && find "${ARCH_CACHE_DIR}" -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
# Handoff nudge markers (Layer 9 fire-once state): short-lived, prune after 1 day.
[[ -d "${HANDOFF_STATE_DIR}" ]] && find "${HANDOFF_STATE_DIR}" -name 'nudged.*' -type f -mtime +1 -delete 2>/dev/null || true
# Evidence ledgers + mutex maps (per-session, written by orch-evidence-ledger.sh)
# and retry-cap fingerprints: session-scoped, prune after 7 days.
STATE_DIR="${HOME_DIR}/state"
if [[ -d "${STATE_DIR}" ]]; then
  # briefs-index accumulates a row per research pass and was pruned by nothing.
  [[ -d "${HOME_DIR}/research/briefs-index" ]] && find "${HOME_DIR}/research/briefs-index" -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
  find "${STATE_DIR}" \( -name 'evidence.*.tsv' -o -name 'mutex-map.*.tsv' -o -name 'retry-cap*' -o -name 'turn-start.*' \) -type f -mtime +7 -delete 2>/dev/null || true
fi
# Research cache uses its own (shorter) retention since docs change faster than sessions.
# Per-library overrides are honored: a cache file with `cache_ttl_days: <N>` in
# frontmatter is pruned at <N> days instead of the global default.
if [[ -d "${RESEARCH_CACHE_DIR}" ]]; then
  while IFS= read -r cache_file; do
    [[ -z "${cache_file}" ]] && continue
    # Extract per-file TTL from frontmatter if present
    per_file_ttl=$(awk '
      BEGIN { in_fm=0 }
      /^---$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
      in_fm==1 && /^cache_ttl_days:[[:space:]]*[0-9]+/ {
        gsub(/[^0-9]/, ""); print; exit
      }
    ' "${cache_file}" 2>/dev/null)
    ttl="${per_file_ttl:-${RESEARCH_RETENTION_DAYS}}"
    if [[ -n "$(find "${cache_file}" -mtime "+${ttl}" -print 2>/dev/null)" ]]; then
      rm -f "${cache_file}" 2>/dev/null || true
    fi
  done < <(find "${RESEARCH_CACHE_DIR}" -name '*.md' -type f 2>/dev/null)
fi

# Worktree registry: drop ownership claims whose worktree directory is gone.
# Safe to run every turn — an active worktree still exists on disk, so a claim
# for in-flight work is never pruned.
_ORCH_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
[[ -f "${_ORCH_ROOT}/scripts/orch-worktree-materialize.sh" ]] && \
  bash "${_ORCH_ROOT}/scripts/orch-worktree-materialize.sh" --prune >/dev/null 2>&1 || true

exit 0
