#!/usr/bin/env bash
# Portable file lock for LLM Orchestrator memory writes.
# Works on macOS, Linux, and any POSIX system with mkdir (which is atomic).
#
# ONE mechanism on purpose. There used to be a flock fast path with the mkdir
# loop as fallback, and the two locked DIFFERENT objects (<t>.lock file vs
# <t>.lockdir directory) — so a process with flock on its PATH and one without
# excluded each other not at all: both entered. The flock branch also ran the
# command in a subshell while the fallback ran it in the caller's shell, a
# side-effect divergence between Linux and macOS. A mutex whose behaviour
# depends on the caller's PATH is not a mutex; mkdir is atomic everywhere, so
# it is the only mechanism.
#
# Usage:
#   source scripts/lib/orch-lock.sh
#   with_lock /path/to/file my_function arg1 arg2
#
# Or inline:
#   ORCH_LOCK_TIMEOUT=10 with_lock /path/to/file bash -c 'cat >> /path/to/file <<EOF
#   content
#   EOF'

# True pid of the CALLING process — call it ONLY as `$(_orch_self_pid)`. `$$`
# is the ORIGINAL shell's pid inside any subshell, and bash 3.2 has no BASHPID
# — so a holder that acquired inside `( ... ) &` recorded its PARENT, and the
# moment the parent exited every waiter judged the recorded pid dead and stole
# the lock mid-critical-section (measured: two processes inside the lock at
# once). The command substitution forks exactly one child; `exec` replaces
# that child with sh, whose $PPID is therefore the real calling process. The
# function must exec directly (no nested $(...)), or the answer would be the
# pid of a substitution shell that is already gone.
_orch_self_pid() { exec sh -c 'echo "$PPID"'; }

# Liveness that does not mistake EPERM for death. `kill -0` returns non-zero
# both for "no such process" and for a LIVE process owned by another uid
# (EPERM) — and a lock steal justified by the latter robs a live holder. ps
# can see any uid's process; it is the arbiter whenever kill -0 says no.
_orch_pid_alive() {
  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1
}

# _restore_steal <moved-dir> <original-path>
# Put back a lockdir we moved but did not condemn — WITHOUT nesting it.
#
# POSIX `mv` moves a directory INTO an existing directory rather than failing,
# so a plain `mv "$_steal" "$lockdir"` after another waiter had already
# mkdir'd the path deposited `<target>.lockdir.stale.PID.RAND/` INSIDE the new
# owner's live lockdir. That owner's release then ran `rmdir`, which fails
# silently on a non-empty directory — leaving a lockdir with no pid file and a
# fresh mtime, i.e. stranded for the full TTL. Callers that respond to a lock
# timeout by writing UNLOCKED (orch-detect.sh, orch-arch.sh) turn that into
# exactly the permanent no-op this whole mechanism exists to prevent.
#
# If the path is occupied again, the new holder is legitimate: drop our copy
# rather than nest it. A post-check catches the residual race.
_restore_steal() {
  local moved="$1" dest="$2"
  if [[ -e "${dest}" ]]; then
    rm -rf "${moved}" 2>/dev/null
    return 0
  fi
  mv "${moved}" "${dest}" 2>/dev/null || { rm -rf "${moved}" 2>/dev/null; return 0; }
  # If the rename nested (the path reappeared between the test and the mv),
  # undo it — a nested directory is what makes the lock unreleasable.
  if [[ -d "${dest}/$(basename "${moved}")" ]]; then
    rm -rf "${dest}/$(basename "${moved}")" 2>/dev/null
  fi
}

with_lock() {
  local target="$1"; shift
  local lockdir="${target}.lockdir"
  # Numeric-only, with a fallback to the default. Under `set -u` an arithmetic
  # test against a non-numeric value ("abc") is an UNBOUND VARIABLE error, so
  # `with_lock` returned 1 and the callers that proceed unlocked on failure
  # did so — a typo in an env var silently disabled the mutex.
  local timeout="${ORCH_LOCK_TIMEOUT:-10}"
  case "${timeout}" in ''|*[!0-9]*) timeout=10 ;; esac
  # Resolved ONCE, before acquisition, and reused verbatim at release: the
  # write and the compare must talk about the same process. Falls back to $$
  # only if the probe produced garbage (no sh?) — degraded, but never empty.
  local _mypid; _mypid="$(_orch_self_pid 2>/dev/null)"
  case "${_mypid}" in (''|*[!0-9]*) _mypid="$$" ;; esac

  # mkdir is atomic on POSIX.
  #
  # STALE-LOCK RECLAIM. A SIGKILLed holder used to strand the lockdir
  # PERMANENTLY: no trap can run on SIGKILL, nothing recorded who held it, and
  # the Stop-hook prune that claimed to clear stranded locks used
  # `find -type f -delete`, which cannot remove a directory. One killed
  # process then made every later with_lock on that file time out for good —
  # and callers that respond to a timeout by proceeding unlocked turned the
  # lock into a permanent no-op. So the holder now records its PID inside the
  # lockdir, and a waiter steals the lock when EITHER proof of death holds:
  #   - the recorded PID no longer exists (kill -0 fails; same-host locks), or
  #   - the lockdir is older than ORCH_LOCK_STALE_SECS (default 600) — covers
  #     a PID-less dir from a kill inside the mkdir→write window, and PID
  #     reuse after reboot.
  # The steal is `mv` to a unique name, then a VERIFY, then a delete.
  #
  # The verify is not optional. `mv` renames a PATH, not the inode a waiter
  # inspected, so two waiters that both judge the lock stale can interleave:
  #
  #   A holds, is SIGKILLed          lockdir has pid=A
  #   B reads pid=A, judges it dead
  #   C reads pid=A, judges it dead
  #   C mv's it away, then mkdir's   C is now the LIVE holder, pid=C
  #   B mv's ... and takes C's dir   both proceed -> TWO WRITERS
  #
  # So after winning the rename we re-read the pid from the directory we
  # actually moved. If it is not the pid we condemned, we moved a live
  # holder's lock and put it straight back, then keep waiting. That leaves a
  # sub-millisecond window where the path is absent (a third waiter could
  # mkdir into it) — strictly better than the alternative, since the failure
  # it replaces is two concurrent writers to the user's CLAUDE.md.
  # `waited` counts tenths-of-a-second so timeout (in seconds) maps to waited * 10.
  local waited=0 stale_secs="${ORCH_LOCK_STALE_SECS:-600}" holder_pid="" lock_age=""
  case "${stale_secs}" in ''|*[!0-9]*) stale_secs=600 ;; esac
  local _steal _moved_pid
  while ! mkdir "${lockdir}" 2>/dev/null; do
    holder_pid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
    if [[ -n "${holder_pid}" && "${holder_pid}" != *[!0-9]* ]] && ! _orch_pid_alive "${holder_pid}"; then
      _steal="${lockdir}.stale.$$.${RANDOM}"
      if mv "${lockdir}" "${_steal}" 2>/dev/null; then
        _moved_pid="$(cat "${_steal}/pid" 2>/dev/null || true)"
        if [[ "${_moved_pid}" == "${holder_pid}" ]]; then
          rm -rf "${_steal}" 2>/dev/null
          echo "orch-lock: reclaimed lock on ${target} from dead pid ${holder_pid}" >&2
        else
          # Someone re-acquired between our judgment and our rename. Not ours.
          _restore_steal "${_steal}" "${lockdir}"
        fi
      fi
    fi
    # The TTL branch is a fallback for a lockdir with NO usable pid — a kill
    # inside the mkdir→write window, or a pid from a previous boot. It must
    # never fire against a recorded, LIVE process: age alone is not a proof of
    # death, and treating it as one let a slow-but-alive holder be robbed
    # (measured: two holders inside the lock at once).
    if [[ -z "${holder_pid}" ]] || [[ "${holder_pid}" == *[!0-9]* ]] \
       || ! _orch_pid_alive "${holder_pid}"; then
      lock_age="$( _orch_lock_age_secs "${lockdir}" )"
      if [[ -n "${lock_age}" ]] && (( lock_age > stale_secs )); then
        _steal="${lockdir}.stale.$$.${RANDOM}"
        if mv "${lockdir}" "${_steal}" 2>/dev/null; then
          # Same verify-after-move as above: re-measure the directory we
          # actually moved, and check it still carries no live holder.
          lock_age="$( _orch_lock_age_secs "${_steal}" )"
          _moved_pid="$(cat "${_steal}/pid" 2>/dev/null || true)"
          if [[ -n "${lock_age}" ]] && (( lock_age > stale_secs )) \
             && { [[ -z "${_moved_pid}" ]] || [[ "${_moved_pid}" == *[!0-9]* ]] \
                  || ! _orch_pid_alive "${_moved_pid}"; }; then
            rm -rf "${_steal}" 2>/dev/null
            echo "orch-lock: reclaimed lock on ${target} — ${lock_age}s old (> ${stale_secs}s TTL), no live holder" >&2
          else
            _restore_steal "${_steal}" "${lockdir}"
          fi
        fi
      fi
    fi
    # EVERY path through this loop reaches the timeout check and the sleep.
    # The steal branches used to `continue`, so on any iteration that ATTEMPTED
    # a steal the timeout was unreachable and nothing slept — a steal that can
    # never succeed (read-only parent directory, for instance) spun this loop
    # forever at 100% CPU instead of returning 1. A lock helper that hangs is
    # worse than one that gives up.
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
  # A holder that cannot record its identity cannot release its own lock: the
  # ownership check below would read an empty pid, conclude "not ours", and
  # skip the rmdir — stranding a lock we legitimately held. Give it up instead
  # of proceeding with a lock we can never hand back. The pid recorded is the
  # TRUE pid of this process (_orch_self_pid), never `$$` — see the helper.
  if ! printf '%s\n' "${_mypid}" > "${lockdir}/pid" 2>/dev/null; then
    rm -f "${lockdir}/pid" 2>/dev/null
    rmdir "${lockdir}" 2>/dev/null
    echo "orch-lock: could not record ownership of ${target}; releasing rather than holding an unreleasable lock" >&2
    return 1
  fi

  # Run the command, then release ONLY IF THE LOCK IS STILL OURS.
  #
  # Release used to operate on the path unconditionally. If our lock was
  # stolen while we ran (a stale-judgment race, or a TTL expiry on a long
  # operation), our release then deleted the THIEF'S live lockdir and a third
  # process walked straight in — measured: max 2 concurrent holders, with the
  # third entering while the second was still inside. Checking the pid makes a
  # stolen lock a no-op on release instead of a cascade.
  local rc=0
  "$@" || rc=$?
  if [[ "$(cat "${lockdir}/pid" 2>/dev/null)" == "${_mypid}" ]]; then
    rm -f "${lockdir}/pid" 2>/dev/null
    rmdir "${lockdir}" 2>/dev/null
  else
    echo "orch-lock: not releasing ${target} — the lock is no longer ours (it was reclaimed while we held it)" >&2
  fi
  return ${rc}
}

# Age in whole seconds of a path, or nothing if it cannot be determined (a
# stat that fails, or non-numeric output). GNU stat first — GNU's `stat -f`
# succeeds with the MOUNT POINT, so BSD-first poisons the arithmetic on Linux.
_orch_lock_age_secs() {
  local m now
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=""
  [[ -n "${m}" && "${m}" != *[!0-9]* ]] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  printf '%s\n' $(( now - m ))
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
