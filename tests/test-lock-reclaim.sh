#!/usr/bin/env bash
# Tests for with_lock's stale-lock reclaim (scripts/lib/orch-lock.sh).
#
# The defect: a SIGKILLed holder stranded the mkdir-fallback lockdir
# PERMANENTLY — no trap runs on SIGKILL, nothing recorded the holder, and the
# Stop-hook "prune" used `find -type f -delete`, which cannot remove a
# directory. Every later with_lock on that file timed out, and callers that
# proceed unlocked on timeout turned the lock into a permanent no-op.
#
# These cases run under the REAL PATH on purpose. The suite used to construct
# a no-flock PATH so the mkdir fallback would run even on Linux — which meant
# the flock branch and the mixed-mechanism case (one process with flock on its
# PATH, one without, locking DIFFERENT objects and both entering) were tested
# by nothing. The lib now has exactly one mechanism (mkdir), so the real PATH
# exercises the real code on every platform, and a pinned check below fails if
# a second mechanism ever reappears.
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

# run_locked <timeout> <stale_secs> <target> <cmd...> — real PATH, real code.
run_locked() {
  local to="$1" st="$2" tgt="$3"; shift 3
  ORCH_LOCK_TIMEOUT="$to" ORCH_LOCK_STALE_SECS="$st" \
    bash -c '. "$1"; tgt="$2"; shift 2; with_lock "$tgt" "$@"' _ "$LIB" "$tgt" "$@"
}

printf '%s== sanity: ONE lock mechanism, so these cases test the code that runs ==%s\n' "$DIM" "$RESET"
# Two mechanisms meant two processes with different PATHs locked DIFFERENT
# objects (flock → <t>.lock file, fallback → <t>.lockdir) and BOTH entered the
# critical section — and the flock branch ran the command in a subshell while
# the fallback ran it in the caller's shell, a side-effect divergence between
# Linux and macOS. The lib must not branch on flock at all.
if grep -q 'command -v flock' "$LIB"; then
  fail "mixed lock mechanisms" "orch-lock.sh still branches on flock — a flock-PATH process and a no-flock process would lock different objects and both enter"
else
  ok "orch-lock.sh has a single (mkdir) mechanism — no PATH-dependent divergence"
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
ORCH_LOCK_TIMEOUT=5 bash -c '. "$1"; with_lock "$2" sleep "$3"' _ "$LIB" "$T2" "$SLEEP_TAG" >/dev/null 2>&1 &
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

printf '\n%s== the timeout is reachable even when a steal can never succeed ==%s\n' "$DIM" "$RESET"
# The steal branches used to `continue` without advancing `waited` or
# sleeping, so on any iteration that ATTEMPTED a steal the timeout check was
# unreachable and nothing slept: a steal that can never succeed spun forever
# at 100% CPU instead of returning 1. Reproduced with a read-only parent
# directory, where both mkdir and mv fail with EACCES.
T6DIR="${TMP}/ro"; mkdir -p "$T6DIR"
T6="${T6DIR}/t6"; : > "$T6"
DEADPID2=999999
while kill -0 "$DEADPID2" 2>/dev/null; do DEADPID2=$((DEADPID2+1)); done
mkdir "${T6}.lockdir"; printf '%s\n' "$DEADPID2" > "${T6}.lockdir/pid"
chmod a-w "$T6DIR"
( run_locked 2 600 "$T6" true >/dev/null 2>&1 ) &
SPINNER=$!
SPUN=0
for _ in $(seq 1 60); do
  kill -0 "$SPINNER" 2>/dev/null || { SPUN=1; break; }
  perl -e 'select(undef,undef,undef,0.25)' 2>/dev/null || sleep 1
done
if [[ $SPUN -eq 1 ]]; then
  ok "an impossible steal times out instead of spinning forever"
else
  kill -9 "$SPINNER" 2>/dev/null
  fail "unbounded spin" "with_lock never returned with ORCH_LOCK_TIMEOUT=2 — the timeout is unreachable from the steal branch"
fi
wait "$SPINNER" 2>/dev/null || true
chmod u+w "$T6DIR"; rm -rf "$T6DIR"

printf '\n%s== the TTL branch never robs a LIVE recorded holder ==%s\n' "$DIM" "$RESET"
# Age alone is not a proof of death. The TTL branch fired whenever the pid
# branch had not, which includes "pid present and process ALIVE" — measured
# with a short TTL against a slow holder: two holders inside the lock at once.
T7="${TMP}/t7"; : > "$T7"
mkdir "${T7}.lockdir"; printf '%s\n' "$$" > "${T7}.lockdir/pid"   # us — alive
perl -e 'select(undef,undef,undef,1.2)' 2>/dev/null || sleep 2
out=$(run_locked 1 1 "$T7" bash -c "echo robbed >> '$T7'" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a live holder's lock is not stolen on age alone" \
  || fail "TTL robbed a live holder" "rc=0 — two processes would be inside the lock"
[[ -s "$T7" ]] && fail "wrote under a live holder's lock" "" || ok "no write happened"
rm -rf "${T7}.lockdir"

printf '\n%s== release is a no-op once the lock is no longer ours ==%s\n' "$DIM" "$RESET"
# Release operated on the PATH, so a victim whose lock had been stolen deleted
# the THIEF'S live lockdir on the way out and a third process walked in
# (measured: max 2 concurrent holders). Simulated by swapping the pid under a
# holder while it runs: its release must leave the directory alone.
T8="${TMP}/t8"; : > "$T8"
out=$(ORCH_LOCK_TIMEOUT=5 bash -c '
  . "$1"
  with_lock "$2" bash -c "printf 99999\\\n > \"$2.lockdir/pid\""
' _ "$LIB" "$T8" 2>&1)
if [[ -d "${T8}.lockdir" ]]; then
  ok "a holder whose lock was taken does not delete the new owner's lockdir"
else
  fail "stolen-lock release cascade" "the victim's release removed a lockdir it no longer owned"
fi
printf '%s' "$out" | grep -q 'no longer ours' && ok "the refusal is announced, not silent" \
  || fail "silent refusal" "out=$(printf '%s' "$out" | head -1)"
rm -rf "${T8}.lockdir"

printf '\n%s== a put-back never NESTS into a re-taken lock path ==%s\n' "$DIM" "$RESET"
# POSIX mv moves a directory INTO an existing directory rather than failing.
# The put-back therefore deposited `<t>.lockdir.stale.PID.RAND/` inside the
# NEW owner's live lockdir; that owner's release ran rmdir, which fails
# silently on a non-empty directory, leaving a lockdir with no pid file and a
# fresh mtime — stranded for the full TTL. Callers that write unlocked on a
# lock timeout then turn it into the permanent no-op this mechanism exists to
# prevent.
T9="${TMP}/t9"; : > "$T9"
mkdir "${T9}.lockdir.stale.probe"; printf '111\n' > "${T9}.lockdir.stale.probe/pid"
mkdir "${T9}.lockdir";             printf '222\n' > "${T9}.lockdir/pid"
bash -c '. "$1"; _restore_steal "$2" "$3"' _ "$LIB" \
  "${T9}.lockdir.stale.probe" "${T9}.lockdir" >/dev/null 2>&1
[[ ! -d "${T9}.lockdir/$(basename "${T9}.lockdir.stale.probe")" ]] \
  && ok "the moved dir was not nested inside the new owner's lockdir" \
  || fail "put-back nested" "the new owner's lockdir is now un-rmdir-able"
rm -f "${T9}.lockdir/pid"
if rmdir "${T9}.lockdir" 2>/dev/null; then
  ok "the new owner can still release its lock"
else
  fail "new owner cannot release" "rmdir failed — the lock is stranded"
  rm -rf "${T9}.lockdir"
fi
rm -rf "${T9}".lockdir.stale.* 2>/dev/null

printf '\n%s== a non-numeric env override must not disable the lock ==%s\n' "$DIM" "$RESET"
# Under `set -u`, an arithmetic test against a non-numeric value is an UNBOUND
# VARIABLE error, so with_lock returned 1 — and the callers that proceed
# unlocked on failure did so. A typo in an env var silently disabled the mutex.
for _bad in ORCH_LOCK_STALE_SECS=abc ORCH_LOCK_TIMEOUT=abc ORCH_LOCK_TIMEOUT=; do
  T10="${TMP}/t10.${RANDOM}"; : > "$T10"
  rc=0
  env "${_bad}" bash -c '. "$1"; with_lock "$2" true' _ "$LIB" "$T10" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 0 ]] && ok "lock still works with ${_bad}" \
    || fail "env typo disabled the lock: ${_bad}" "with_lock rc=$rc"
done

printf '\n%s== a LIVE holder inside a background subshell is not robbed when its parent dies ==%s\n' "$DIM" "$RESET"
# with_lock recorded `$$` — which inside ANY subshell is still the ORIGINAL
# shell's pid (bash 3.2 has no BASHPID). A holder that acquires inside
# `( ... ) &` therefore records its parent; once the parent exits, every
# waiter judges the recorded pid dead and steals the lock MID-CRITICAL-SECTION
# — two writers. The holder must record its own true pid.
T11="${TMP}/t11"; : > "$T11"; L11="${TMP}/t11.log"; : > "$L11"
SLEEP11="297.313"
bash -c '
  ( . "$1"; with_lock "$2" sh -c "echo enter >> \"$3\"; sleep '"$SLEEP11"'; echo exit >> \"$3\"" ) >/dev/null 2>&1 &
' _ "$LIB" "$T11" "$L11"
# The wrapper bash has already exited; the subshell holder lives on inside the lock.
for _ in $(seq 1 50); do grep -q enter "$L11" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.1)' 2>/dev/null || sleep 1; done
if ! grep -q enter "$L11" 2>/dev/null; then
  fail "subshell holder setup" "the background holder never entered the critical section"
else
  out=$(run_locked 1 600 "$T11" sh -c "echo intruder >> '$L11'" 2>&1); rc=$?
  if [[ $rc -ne 0 ]] && ! grep -q intruder "$L11"; then
    ok "waiter timed out — the live subshell holder kept its lock (true pid recorded)"
  else
    fail "live subshell holder robbed" "rc=$rc log='$(tr '\n' ' ' < "$L11")' — \$\$ recorded the dead parent, so the waiter judged the LIVE holder dead and stole mid-critical-section"
  fi
fi
pkill -9 -f "sleep ${SLEEP11}" 2>/dev/null || true
rm -rf "${T11}.lockdir" 2>/dev/null

printf '\n%s== the Stop-hook janitor: age alone is not proof of death ==%s\n' "$DIM" "$RESET"
# orch-stop.sh swept hour-old *.lockdir dirs with a bare rm -rf — no kill -0 on
# the recorded pid — robbing a live holder mid-write: the exact rule
# with_lock's own TTL branch was fixed to enforce. It exists to break the
# PID-reuse deadlock, so it must still sweep dead locks; it must READ the pid
# and skip a live one.
STOPHOOK="${ROOT}/scripts/hooks/orch-stop.sh"
SH_HOME="${TMP}/stophome"
mkdir -p "${SH_HOME}/toolchain" "${SH_HOME}/memory"
LIVE_LD="${SH_HOME}/toolchain/detect.json.lockdir"
DEAD_LD="${SH_HOME}/memory/CLAUDE.md.lockdir"
NOPID_LD="${SH_HOME}/memory/notes.md.lockdir"
mkdir -p "$LIVE_LD" "$DEAD_LD" "$NOPID_LD"
printf '%s\n' "$$" > "$LIVE_LD/pid"                     # us — alive
DEADPID4=999999; while kill -0 "$DEADPID4" 2>/dev/null; do DEADPID4=$((DEADPID4+1)); done
printf '%s\n' "$DEADPID4" > "$DEAD_LD/pid"              # provably dead
touch -t 202401010000 "$LIVE_LD" "$DEAD_LD" "$NOPID_LD" # all past the 60-minute gate
ORCH_HOME="$SH_HOME" bash "$STOPHOOK" >/dev/null 2>&1
[[ -d "$LIVE_LD" ]] && ok "an hour-old lockdir with a LIVE recorded pid survives the janitor" \
  || fail "janitor robbed a live holder" "orch-stop rm -rf'd a lock whose recorded pid is alive — age alone is not proof of death"
[[ ! -d "$DEAD_LD" ]] && ok "an hour-old lockdir with a dead pid is still swept (PID-reuse deadlock breaker intact)" \
  || fail "dead lockdir kept" "the janitor no longer clears dead locks"
[[ ! -d "$NOPID_LD" ]] && ok "an hour-old pid-less lockdir is swept (kill-in-window orphan)" \
  || fail "pid-less lockdir kept" ""

TOTAL=$((PASS + FAIL))
printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-lock-reclaim (%d checks)%s\n' "$GREEN" "$TOTAL" "$RESET"
  exit 0
fi
printf '%sFAIL: test-lock-reclaim — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
exit 1
