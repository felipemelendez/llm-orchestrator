#!/usr/bin/env bash
# LLM Orchestrator shared project identity + filesystem helpers.
#
# Sourced by hooks that need to resolve the project hash (for memory file,
# cache directory, brief-index lookup) and produce library slugs from prompt
# matches.
#
# Single source of truth so the gate hook, validator hook, and any future
# consumer compute the same hash for the same project. session-start.sh
# currently has an inline copy of project_hash / sha1_of — that copy is left
# in place deliberately (refactoring it out of session-start is out of scope
# for this round) but the canonical implementations live here.
#
# Bash 3.2 compatible.

# Portable SHA-1 helper: shasum on macOS, sha1sum on Linux, cksum as last resort.
orch_sha1_of() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | cut -c1-12
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -c1-12
  else
    printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-12
  fi
}

# Resolve the project hash. git remote URL wins (survives clones); falls back
# to repo root, then to PWD. Mirrors session-start.sh's project_hash().
orch_project_hash() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    local remote
    remote=$(git config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "${remote}" ]]; then
      orch_sha1_of "${remote}"
      return
    fi
    orch_sha1_of "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    return
  fi
  orch_sha1_of "${PWD}"
}

# Normalize a library / vendor mention into a filesystem slug.
# Examples:
#   "Next.js"      → "next-js"
#   "tailwindcss"  → "tailwindcss"
#   "Claude Code"  → "claude-code"
#   "MCP server"   → "mcp-server"
# Lowercase, dot/space → dash, strip non-alphanumeric-or-dash, collapse repeated dashes.
orch_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '. ' '--' \
    | sed -E 's/[^a-z0-9-]+//g; s/-+/-/g; s/^-+//; s/-+$//'
}

# Cross-platform "last modified date" of a file as YYYY-MM-DD. Returns
# "unknown" if the file doesn't exist or the platform's stat layout is
# unrecognized.
orch_file_mtime_date() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    echo "unknown"
    return
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    date -r "$f" +%Y-%m-%d 2>/dev/null || echo "unknown"
  else
    if command -v stat >/dev/null 2>&1; then
      local ts
      ts=$(stat -c %Y "$f" 2>/dev/null || true)
      if [[ -n "$ts" ]]; then
        date -d "@${ts}" +%Y-%m-%d 2>/dev/null || echo "unknown"  # portable-ok: GNU date in Linux-only branch (macOS uses 'date -r' above)
      else
        echo "unknown"
      fi
    else
      echo "unknown"
    fi
  fi
}

# Where is this project's cadence?
#
# Every hook that asks whether the cadence is on uses this one rule, so session
# start, the per-turn hook, the guards and the stop hooks always agree:
#
#   1. Start at CLAUDE_PROJECT_DIR if set, else the hook event's cwd, else PWD.
#   2. Walk up, one directory at a time, and stop at the first directory that
#      holds docs/llm-orchestrator/cadence.json. Never walk past the git top
#      level (a directory holding .git, a file in a worktree or submodule) or /.
#   3. If no directory on the way holds one, the answer is the start directory.
#
# So a cadence project nested inside a larger repository (cadence.json in
# /repo/app) is found from /repo/app and from /repo/app/src alike, and a session
# launched from a subdirectory of a cadence repository finds the repository's
# cadence.json.
#
# Pure bash: no fork, no python3, so the guards can call it on every command.

# orch_cadence_find [hook-input-json] — sets ORCH_CADENCE_ROOT.
orch_cadence_find() {
  local start="${CLAUDE_PROJECT_DIR:-}" d re='"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  if [[ -z "${start}" && "${1:-}" =~ $re ]]; then
    start="${BASH_REMATCH[1]}"
    start="${start//\\\//\/}"
    start="${start//\\\"/\"}"
    start="${start//\\\\/\\}"
  fi
  [[ -n "${start}" ]] || start="${PWD}"
  [[ "${start}" == /* ]] || start="${PWD%/}/${start}"
  while [[ "${start}" == */ && "${start}" != "/" ]]; do start="${start%/}"; done
  d="${start}"
  while :; do
    if [[ -f "${d%/}/docs/llm-orchestrator/cadence.json" ]]; then
      ORCH_CADENCE_ROOT="${d}"
      return 0
    fi
    [[ -e "${d%/}/.git" || "${d}" == "/" ]] && break
    d="${d%/*}"
    [[ -n "${d}" ]] || d="/"
  done
  ORCH_CADENCE_ROOT="${start}"
}

# orch_cadence_root [hook-input-json] — prints the same answer.
orch_cadence_root() {
  orch_cadence_find "${1:-}"
  printf '%s' "${ORCH_CADENCE_ROOT}"
}
