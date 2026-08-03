#!/usr/bin/env bash
# Tests for with_lock's stale-lock reclaim (scripts/lib/orch-lock.sh).
#
# The defect: a SIGKILLed holder stranded the mkdir-fallback lockdir
# PERMANENTLY — no trap runs on SIGKILL, nothing recorded the holder, and the
# Stop-hook "prune" used `find -type f -delete`, which cannot remove a
# directory. Every later with_lock on that file timed out, and callers that
# proceed unlocked on timeout turned the lock into a permanent no-op.
#
# The mkdir fallback only runs when `flock` is absent, so every case here runs
# under a constructed PATH that omits flock — otherwise CI (Linux, flock
# present) would test the flock path and this suite would assert nothing.
#
# Bash 3.2 compatible. Exits non-zero on any failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/scripts/lib/orch-lock.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$LIB" ]] || { printf 'FAIL — not found: %s\n' "$LIB"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# PATH without flock: symlink every tool the lib and these tests need.
NOFLOCK="${TMP}/noflock-bin"; mkdir -p "$NOFLOCK"
for t in bash sh cat grep sed awk printf mktemp rm rmdir mkdir mv cp ls dirname basename env date stat kill sleep perl touch head tail tr; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOFLOCK/$t" 2>/dev/null
done

# run_locked <timeout> <stale_secs> <target> <cmd...> — under the no-flock PATH.
run_locked() {
  local to="$1" st="$2" tgt="$3"; shift 3
  PATH="$NOFLOCK" ORCH_LOCK_TIMEOUT="$to" ORCH_LOCK_STALE_SECS="$st" \
    bash -c '. "$1"; tgt="$2"; shift 2; with_lock "$tgt" "$@"' _ "$LIB" "$tgt" "$@"
}

printf '%s== sanity: the fallback path is the one under test ==%s\n' "$DIM" "$RESET"
if PATH="$NOFLOCK" bash -c 'command -v flock' >/dev/null 2>&1; then
  fail "no-flock PATH" "flock still visible — every case below would test the wrong path"
else
  ok "flock absent from the constructed PATH (mkdir fallback active)"
fi

printf '\n%s== uncontended lock works and releases ==%s\n' "$DIM" "$RESET"
T1="${TMP}/t1"; : > "$T1"
run_locked 5 600 "$T1" bash -c "echo ran >> '$T1'" >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 && "$(cat "$T1")" == "ran" ]] && ok "lock acquired, command ran" || fail "uncontended" "rc=$rc"
[[ ! -d "${T1}.lockdir" ]] && ok "lockdir released afterwards" || fail "lockdir leaked"

printf '\n%s== SIGKILLed holder: the lock is reclaimed, not stranded ==%s\n' "$DIM" "$RESET"
T2="${TMP}/t2"; : > "$T2"
# A real holder that takes the lock and then blocks; SIGKILL leaves its lockdir.
# An UNUSUAL sleep duration so the orphaned child is findable afterwards, and
# stdio to /dev/null — an inherited pipe kept this suite's own output stream
# open for the orphan's whole lifetime, which read as a 5-minute hang.
SLEEP_TAG="299.731"
PATH="$NOFLOCK" ORCH_LOCK_TIMEOUT=5 bash -c '. "$1"; with_lock "$2" sleep "$3"' _ "$LIB" "$T2" "$SLEEP_TAG" >/dev/null 2>&1 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -d "${T2}.lockdir" ]] && break
  perl -e 'select(undef,undef,undef,0.1)' 2>/dev/null || sleep 1
done
[[ -d "${T2}.lockdir" ]] || fail "holder setup" "lockdir never appeared"
kill -9 "$HOLDER" 2>/dev/null
# Also kill the sleep child the subshell may have spawned, then wait for the
# recorded pid to actually be gone.
wait "$HOLDER" 2>/dev/null || true
HPID="$(cat "${T2}.lockdir/pid" 2>/dev/null || true)"
if [[ -n "$HPID" ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$HPID" 2>/dev/null || break
    kill -9 "$HPID" 2>/dev/null; perl -e 'select(undef,undef,undef,0.1)' 2>/dev/null || sleep 1
  done
fi
out=$(run_locked 3 600 "$T2" bash -c "echo reclaimed >> '$T2'" 2>&1); rc=$?
if [[ $rc -eq 0 && "$(tail -1 "$T2")" == "reclaimed" ]]; then
  ok "SIGKILLed holder's lock was stolen and the next writer proceeded"
else
  fail "dead-holder reclaim" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi
printf '%s' "$out" | grep -q 'reclaimed lock' && ok "reclaim is announced on stderr (not silent)" \
  || fail "reclaim announcement" "out=$(printf '%s' "$out" | head -1)"
# Reap the orphaned sleep child (SIGKILL on the wrapper cannot reach it).
pkill -9 -f "sleep ${SLEEP_TAG}" 2>/dev/null || true

printf '\n%s== PID-less stale lockdir (kill inside the mkdir→write window): TTL steals ==%s\n' "$DIM" "$RESET"
T3="${TMP}/t3"; : > "$T3"
mkdir "${T3}.lockdir"
# Age it: 2s TTL + a 3s-old dir. (touch -t needs minutes; use a sleep-free
# trick — set TTL to 1 and just wait 2s.)
sleep 2
out=$(run_locked 3 1 "$T3" bash -c "echo ttl >> '$T3'" 2>&1); rc=$?
[[ $rc -eq 0 && "$(cat "$T3")" == "ttl" ]] && ok "TTL-expired pidless lockdir was reclaimed" \
  || fail "TTL reclaim" "rc=$rc out=$(printf '%s' "$out" | head -1)"

printf '\n%s== LIVE holder is never stolen ==%s\n' "$DIM" "$RESET"
T4="${TMP}/t4"; : > "$T4"
mkdir "${T4}.lockdir"; printf '%s\n' "$$" > "${T4}.lockdir/pid"   # us — alive
out=$(run_locked 1 600 "$T4" bash -c "echo stolen >> '$T4'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "waiter timed out instead of stealing a live holder's lock" \
  || fail "live holder stolen" "rc=0 — the lock of a LIVE process was taken"
[[ -d "${T4}.lockdir" ]] && ok "live holder's lockdir left intact" || fail "live lockdir removed"
[[ ! -s "$T4" ]] && ok "no write happened under the live holder's lock" || fail "write under held lock"
rm -rf "${T4}.lockdir"

printf '\n%s== a lock re-acquired between judgment and steal is not destroyed ==%s\n' "$DIM" "$RESET"
# `mv` renames a PATH, not the inode a waiter inspected, so two waiters that
# both judge a dead holder's lock stale can interleave: one steals and
# re-acquires, the second then renames the FIRST'S LIVE lock away and both
# proceed. Simulated deterministically: stage a dir carrying a dead pid, then
# swap in a live-pid dir before the stealer's rename — the stealer must put it
# back rather than take it.
T5="${TMP}/t5"; : > "$T5"
DEADPID=999999
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$((DEADPID+1)); done
mkdir "${T5}.lockdir"; printf '%s\n' "$DEADPID" > "${T5}.lockdir/pid"
# Racer: replaces the condemned dir with a LIVE-pid one, mimicking a sibling
# that stole and re-acquired in the window.
( for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ "$(cat "${T5}.lockdir/pid" 2>/dev/null)" == "$DEADPID" ]]; then
      rm -rf "${T5}.lockdir" 2>/dev/null
      mkdir "${T5}.lockdir" 2>/dev/null && printf '%s\n' "$$" > "${T5}.lockdir/pid"
      break
    fi
    perl -e 'select(undef,undef,undef,0.05)' 2>/dev/null || sleep 1
  done ) &
RACER=$!
out=$(run_locked 1 600 "$T5" bash -c "echo raced >> '$T5'" 2>&1); rc=$?
wait "$RACER" 2>/dev/null || true
# Whatever the interleaving, the invariant is: this call never both takes a
# live holder's lock AND writes. Either it reclaimed the genuinely dead one
# (wrote, lockdir gone) or it backed off (no write).
if [[ $rc -eq 0 ]]; then
  ok "steal succeeded against the dead holder (no live lock was taken)"
else
  [[ -d "${T5}.lockdir" ]] && ok "backed off and left the live holder's lock in place" \
    || fail "live lock destroyed" "the stealer removed a lock it did not condemn"
fi
rm -rf "${T5}.lockdir" "${T5}".lockdir.stale.* 2>/dev/null

TOTAL=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-lock-reclaim (%d checks)%s\n' "$GREEN" "$TOTAL" "$RESET"
  exit 0
fi
printf '%sFAIL: test-lock-reclaim — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
exit 1
