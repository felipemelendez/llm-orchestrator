#!/usr/bin/env bash
# LLM Orchestrator — architecture-decision cache.
#
# Stores and reads the recorded `## Decisions` for a project, keyed by the sha1
# of its manifest content so the cache invalidates when the project changes.
#
# Public API:
#   orch_arch_record <dir> <decisions-text>  — write decisions under a lock
#   orch_arch_cached <dir>                    — print decisions on a cache hit, else exit 1
#
# Sourced via orch-detect.sh, which defines _orch_manifest_sha and sources the
# orch-project / orch-lock helpers these functions rely on. Bash 3.2 compatible.

if ! declare -f orch_arch_record >/dev/null 2>&1; then

# ---------------------------------------------------------------------------
# orch_arch_record <dir> <decisions-text>
#
# Writes the studied architectural decisions to:
#   ${ORCH_HOME:-~/.llm-orchestrator}/architecture/<project-hash>/decisions.md
#
# The file is written under with_lock and stamped with a manifest-sha: line
# (from _orch_manifest_sha "<dir>") so orch_arch_cached can detect staleness.
# ---------------------------------------------------------------------------
orch_arch_record() {
  local dir="${1:-.}"
  dir="${dir%/}"
  local decisions="${2:-}"

  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi

  local arch_dir="${home_dir}/architecture/${proj_hash}"
  mkdir -p "$arch_dir"

  local decisions_file="${arch_dir}/decisions.md"
  local manifest_sha
  manifest_sha=$(_orch_manifest_sha "$dir")

  _orch_arch_write() {
    local d_file="$1" m_sha="$2" d_text="$3"
    {
      printf 'manifest-sha: %s\n\n' "$m_sha"
      printf '%s\n' "$d_text"
    } > "$d_file"
  }

  local lock_rc=0
  with_lock "$decisions_file" _orch_arch_write "$decisions_file" "$manifest_sha" "$decisions" || lock_rc=$?
  if [[ $lock_rc -ne 0 ]]; then
    _orch_arch_write "$decisions_file" "$manifest_sha" "$decisions"
  fi
}

# ---------------------------------------------------------------------------
# orch_arch_cached <dir>
#
# Returns cached architectural decisions for <dir> if they exist and the stored
# manifest-sha matches the current one (cache hit).
#
# Exit 0 + prints decisions  — cache hit (study still valid).
# Exit 1                      — cache miss or stale (study needed).
#
# Mirrors the read/staleness logic of orch_detect_cached.
# ---------------------------------------------------------------------------
orch_arch_cached() {
  local dir="${1:-.}"
  dir="${dir%/}"

  local home_dir="${ORCH_HOME:-${HOME}/.llm-orchestrator}"
  local proj_hash
  proj_hash=$(cd "$dir" 2>/dev/null && orch_project_hash 2>/dev/null) || proj_hash=""
  if [[ -z "$proj_hash" ]]; then
    proj_hash=$(orch_sha1_of "$dir")
  fi

  local decisions_file="${home_dir}/architecture/${proj_hash}/decisions.md"

  if [[ ! -f "$decisions_file" ]]; then
    return 1
  fi

  local current_sha stored_sha
  current_sha=$(_orch_manifest_sha "$dir")
  stored_sha=$(grep -E '^manifest-sha:' "$decisions_file" 2>/dev/null | head -1 | awk '{print $2}')

  if [[ "$stored_sha" != "$current_sha" ]]; then
    return 1
  fi

  # Cache hit — print decisions (skip manifest-sha header line).
  grep -v '^manifest-sha:' "$decisions_file"
  return 0
}

fi  # end double-source guard
