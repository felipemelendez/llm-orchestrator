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
# Toolchain cache: prune stale detection results (also clears any stranded .lock/.lockdir files).
[[ -d "${TOOLCHAIN_CACHE_DIR}" ]] && find "${TOOLCHAIN_CACHE_DIR}" -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
# Architecture study cache: prune stale decisions files at same retention as toolchain.
[[ -d "${ARCH_CACHE_DIR}" ]] && find "${ARCH_CACHE_DIR}" -type f -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true
# Handoff nudge markers (Layer 9 fire-once state): short-lived, prune after 1 day.
[[ -d "${HANDOFF_STATE_DIR}" ]] && find "${HANDOFF_STATE_DIR}" -name 'nudged.*' -type f -mtime +1 -delete 2>/dev/null || true
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

exit 0
