#!/usr/bin/env bash
# Portable file lock for LLM Orchestrator memory writes.
# Works on macOS (no flock by default), Linux (with or without flock),
# and any POSIX system with mkdir (which is atomic).
#
# Usage:
#   source scripts/lib/orch-lock.sh
#   with_lock /path/to/file my_function arg1 arg2
#
# Or inline:
#   ORCH_LOCK_TIMEOUT=10 with_lock /path/to/file bash -c 'cat >> /path/to/file <<EOF
#   content
#   EOF'

with_lock() {
  local target="$1"; shift
  local lockfile="${target}.lock"
  local lockdir="${target}.lockdir"
  local timeout="${ORCH_LOCK_TIMEOUT:-10}"

  if command -v flock >/dev/null 2>&1; then
    # GNU/BSD systems with util-linux flock or compatible.
    ( flock -w "${timeout}" 9 || { echo "lock timeout on ${target}" >&2; exit 1; }
      "$@"
    ) 9>>"${lockfile}"
    return $?
  fi

  # Portable fallback: mkdir is atomic on POSIX.
  # `waited` counts tenths-of-a-second so timeout (in seconds) maps to waited * 10.
  local waited=0
  while ! mkdir "${lockdir}" 2>/dev/null; do
    if (( waited >= timeout * 10 )); then
      echo "lock timeout on ${target}" >&2
      return 1
    fi
    # macOS sleep doesn't support sub-second; use perl if available (100ms),
    # else fall back to a full second.
    if command -v perl >/dev/null 2>&1; then
      perl -e 'select(undef, undef, undef, 0.1)'
      waited=$((waited + 1))
    else
      sleep 1
      waited=$((waited + 10))  # advance by a full second's worth of tenths
    fi
  done

  # Run the command, then always release the lock.
  local rc=0
  "$@" || rc=$?
  rmdir "${lockdir}" 2>/dev/null
  return ${rc}
}

# Convenience: append a single line to a file under lock, format-safe.
# Usage: append_line <file> <line>
append_line() {
  local file="$1"
  local line="$2"
  with_lock "${file}" bash -c "printf '%s\n' \"\$1\" >> \"\$2\"" _ "${line}" "${file}"
}

# Append a bullet line under a markdown section header, in-place, under lock.
# Creates the section at the end of the file if not present.
# Pure-bash implementation — no inline awk to escape.
# Usage: append_under_section <file> <section-name> <line>
#   <section-name> is "Conventions" (matches "## Conventions" in the file)
#   <line> is the full bullet to insert (e.g., "- pnpm not npm (2026-05-23)")
append_under_section() {
  local file="$1" section="$2" line="$3"
  with_lock "${file}" _orch_append_under_section_unlocked "${file}" "${section}" "${line}"
}

# Internal: the actual rewrite, assumed already locked.
# Called via with_lock — must be visible in the same shell as the caller.
_orch_append_under_section_unlocked() {
  local file="$1" section="$2" line="$3"

  if [[ ! -f "$file" ]]; then
    # File doesn't exist — create with just the section + line.
    printf '## %s\n%s\n' "$section" "$line" > "$file"
    return 0
  fi

  # Do the rewrite in a subshell with an EXIT-scoped tempfile cleanup. A subshell
  # EXIT trap fires on normal completion and on a signal that terminates the
  # subshell, so a killed write leaves no ${file}.tmp.$$ behind — and because the
  # trap lives in the subshell it never touches the caller's own traps (an
  # EXIT/INT trap in this function's shell would clobber them). with_lock still
  # releases the lockdir when this returns, so the lock is not stranded.
  (
    local tmp="${file}.tmp.$$"
    local inserted=0 l
    trap 'rm -f "${tmp}"' EXIT

    while IFS= read -r l || [[ -n "$l" ]]; do
      printf '%s\n' "$l"
      if [[ "$l" == "## $section" && "$inserted" == "0" ]]; then
        printf '%s\n' "$line"
        inserted=1
      fi
    done < "$file" > "$tmp"

    if [[ "$inserted" == "0" ]]; then
      printf '\n## %s\n%s\n' "$section" "$line" >> "$tmp"
    fi

    mv "$tmp" "$file"
  )
}
