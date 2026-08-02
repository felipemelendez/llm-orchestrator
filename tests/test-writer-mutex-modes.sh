#!/usr/bin/env bash
# Writer-mutex isolation modes: contract + corruption tests.
#
# Field incident (2026-08-02): a project with a no-worktrees ruling ran every
# writer against ONE repo-root lock; a controller improvised a "hold" as a
# regular FILE at the mutex path. mkdir fails forever against a file, the
# reaper had no claim to release, one obedient implementer stopped dead and
# the rest learned to bypass the lock. The fix is two EXPLICIT modes:
#
#   worktree mode        envelope names a worktree path → atomic mkdir mutex
#   shared-checkout mode envelope declares "shared checkout; controller-
#                        partitioned file ownership" + exclusive file list →
#                        NO lock; the file list is the ownership boundary
#   neither declared     fail closed (BLOCKED)
#
# This test pins that contract across every surface that carries it
# (agent def, envelope template, both dispatching skills, worktree skill),
# and mechanically checks the reaper reports a FILE at a mutex path as
# protocol corruption instead of staying silent.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPL="${ROOT}/agents/orch-implementer.md"
TMPL="${ROOT}/templates/implementer-prompt.md"
PAR="${ROOT}/skills/dispatching-parallel-agents/SKILL.md"
SEQ="${ROOT}/skills/dispatching-subagents/SKILL.md"
WTS="${ROOT}/skills/using-git-worktrees/SKILL.md"
DSP="${ROOT}/commands/dispatch.md"
VAL="${ROOT}/tests/validate-skills.sh"
HOOK="${ROOT}/scripts/hooks/orch-worktree-reaper.sh"

MODE_DECL='shared checkout; controller-partitioned file ownership'
MAIN_DECL='main checkout — you are the only writer'

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

has() { grep -qF -- "$2" "$1"; }   # has <file> <literal>

finish() { # finish [note] — summarize honestly; never PASS over accumulated failures
  printf '\n'
  if (( FAIL == 0 )); then
    printf '%sPASS: test-writer-mutex-modes%s (%d checks%s)\n' "$GREEN" "$RESET" "$PASS" "${1:+; $1}"; exit 0
  else
    printf '%sFAIL: test-writer-mutex-modes — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
    for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done; exit 1
  fi
}

printf '%s== implementer agent: the two-mode rule ==%s\n' "$DIM" "$RESET"
has "$IMPL" 'Worktree mode' && has "$IMPL" 'Shared-checkout mode' \
  && ok "names both modes explicitly" || fail "implementer mode names" "expected 'Worktree mode' and 'Shared-checkout mode' in $IMPL"
has "$IMPL" "$MODE_DECL" \
  && ok "carries the shared-checkout declaration string" || fail "implementer declaration string" "missing '$MODE_DECL'"
grep -qiF 'no lock of any kind' "$IMPL" \
  && ok "shared mode takes no lock (no mkdir mutex)" || fail "implementer shared no-lock" "missing 'no lock of any kind'"
has "$IMPL" 'changes under you' \
  && ok "shared mode: an owned file changing under you mid-task → stop and report" || fail "implementer changed-under-you" "missing 'changes under you'"
has "$IMPL" 'hold-marker' \
  && ok "shared mode bans improvised locks and hold-markers" || fail "implementer hold-marker ban" "missing 'hold-marker'"
has "$IMPL" 'isolated worktree path or an explicit shared-checkout declaration' \
  && ok "neither mode declared → BLOCKED (fail closed)" || fail "implementer fail-closed Need" "missing the neither-declared Need: line"
has "$IMPL" 'protocol corruption' && has "$IMPL" 'regular file' \
  && ok "worktree mode distinguishes held (directory) from corrupted (regular file)" || fail "implementer corruption shape" "missing 'protocol corruption' / 'regular file'"

printf '\n%s== envelope template mirrors the contract ==%s\n' "$DIM" "$RESET"
has "$TMPL" 'Worktree mode' && has "$TMPL" 'Shared-checkout mode' \
  && ok "template names both modes" || fail "template mode names" "$TMPL"
has "$TMPL" "$MODE_DECL" \
  && ok "template carries the declaration string" || fail "template declaration string" "missing '$MODE_DECL'"
grep -qiF 'no lock of any kind' "$TMPL" \
  && ok "template: shared mode takes no lock" || fail "template shared no-lock" "missing 'no lock of any kind'"
has "$TMPL" 'hold-marker' \
  && ok "template bans improvised hold-markers" || fail "template hold-marker ban" "missing 'hold-marker'"
has "$TMPL" 'isolated worktree path or an explicit shared-checkout declaration' \
  && ok "template: neither declared → BLOCKED" || fail "template fail-closed Need" "missing the Need: line"
has "$TMPL" 'protocol corruption' \
  && ok "template: corruption-shaped BLOCKED is distinct from held-by-writer" || fail "template corruption shape" "missing 'protocol corruption'"

printf '\n%s== controller skills declare the mode ==%s\n' "$DIM" "$RESET"
has "$PAR" "$MODE_DECL" \
  && ok "dispatching-parallel-agents carries the declaration string" || fail "parallel declaration string" "$PAR"
has "$SEQ" "$MODE_DECL" \
  && ok "dispatching-subagents carries the declaration string" || fail "sequential declaration string" "$SEQ"
grep -qiF 'writer cap' "$PAR" \
  && ok "parallel shared-checkout requires a stated writer cap" || fail "parallel writer cap" "missing 'writer cap'"
grep -qiF 'disjoint' "$PAR" \
  && ok "parallel shared-checkout requires disjoint file lists" || fail "parallel disjoint" "missing 'disjoint'"
has "$PAR" 'hold-marker' \
  && ok "parallel bans controller-side hold-markers" || fail "parallel hold-marker ban" "missing 'hold-marker'"
has "$DSP" "$MODE_DECL" \
  && ok "dispatch command carries the declaration string (mode reachable from /dispatch)" || fail "dispatch declaration string" "missing '$MODE_DECL' in $DSP"
has "$SEQ" "$MAIN_DECL" && has "$TMPL" "$MAIN_DECL" \
  && ok "solo main-checkout literal is identical in dispatch skill and template" || fail "main-checkout literal drift" "expected '$MAIN_DECL' in both $SEQ and $TMPL — a bare 'main checkout' envelope reads as fail-closed"

printf '\n%s== the corruption case is documented where operators look ==%s\n' "$DIM" "$RESET"
has "$SEQ" 'protocol corruption' && grep -qiF 'regular file' "$SEQ" \
  && ok "stale-mutex corner distinguishes a held directory from a corrupted file" || fail "sequential corruption corner" "$SEQ"
has "$WTS" 'protocol corruption' && grep -qiF 'regular file' "$WTS" \
  && ok "using-git-worktrees documents the file-at-path corruption case" || fail "worktrees corruption doc" "$WTS"
grep -qiF 'delete the file' "$WTS" \
  && ok "using-git-worktrees names the operator remedy (inspect + delete)" || fail "worktrees remedy" "missing 'delete the file'"

printf '\n%s== the maxTurns ban is enforced, not just narrated ==%s\n' "$DIM" "$RESET"
# The rationale (worktree-mode mutex release must never be cut off) lives in a
# comment; pin the behavior it explains: an implementer carrying maxTurns must
# fail validation.
VTMP=$(mktemp -d)
mkdir -p "$VTMP/v/tests" "$VTMP/v/skills" "$VTMP/v/commands" "$VTMP/v/agents"
cp "$VAL" "$VTMP/v/tests/validate-skills.sh"
printf -- '---\nname: orch-implementer\ndescription: x\nmaxTurns: 5\n---\nbody\n' > "$VTMP/v/agents/orch-implementer.md"
VOUT=$(bash "$VTMP/v/tests/validate-skills.sh" 2>&1); VRC=$?
rm -rf "$VTMP"
[[ $VRC -ne 0 ]] && printf '%s' "$VOUT" | grep -q 'must not set maxTurns' \
  && ok "validator rejects maxTurns on the implementer (mutex-strand rationale)" || fail "validator maxTurns enforcement" "rc=$VRC out=$(printf '%s' "$VOUT" | head -2)"

printf '\n%s== reaper: a FILE at a mutex path is reported as corruption ==%s\n' "$DIM" "$RESET"
command -v python3 >/dev/null 2>&1 || finish "reaper checks skipped — python3 unavailable"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ORCH_HOME="$TMP/home"

fire() { # fire <cwd> <last_assistant_message>
  python3 -c "
import json, sys
print(json.dumps({'hook_event_name':'SubagentStop','session_id':'mode-test','agent_id':'a1',
                  'cwd':sys.argv[1],'last_assistant_message':sys.argv[2]}))" "$1" "$2" \
  | bash "$HOOK" 2>&1
}

# A regular file planted at a worktree mutex path (the improvised hold-marker).
W="$TMP/a"; mkdir -p "$W/.worktrees/only"; : > "$W/.worktrees/only/.orch-active"
OUT=$(fire "$W" 'Status: DONE
Summary: finished the task in .worktrees/only')
printf '%s' "$OUT" | grep -qi 'regular file' && printf '%s' "$OUT" | grep -q 'protocol corruption' \
  && ok "worktree-path FILE reported as protocol corruption, not a held lock" || fail "reaper worktree-file report" "$OUT"
[[ -f "$W/.worktrees/only/.orch-active" ]] \
  && ok "the file is reported, never deleted (report, never guess)" || fail "reaper deleted the file" "$OUT"
printf '%s' "$OUT" | grep -q 'still held' \
  && fail "corrupted file listed among held mutexes" "$OUT" || ok "corrupted file is NOT listed as a held mutex (no phantom writer)"

# The incident shape: a controller hold FILE at the repo root's mutex path.
W="$TMP/b"; mkdir -p "$W"; : > "$W/.orch-active"
OUT=$(fire "$W" 'Status: DONE
Summary: all good')
printf '%s' "$OUT" | grep -qi 'regular file' && printf '%s' "$OUT" | grep -q 'protocol corruption' \
  && ok "repo-root FILE (controller hold) reported as corruption" || fail "reaper root-file report" "$OUT"
[[ -f "$W/.orch-active" ]] \
  && ok "repo-root file left for the operator" || fail "reaper deleted root file" "$OUT"

# A dangling symlink at the mutex path: mkdir fails against it exactly like a
# file, and it must be reported as corruption, not silently invisible.
W="$TMP/d"; mkdir -p "$W/.worktrees/only"; ln -s /nonexistent "$W/.worktrees/only/.orch-active"
OUT=$(fire "$W" 'Status: DONE
Summary: finished the task in .worktrees/only')
printf '%s' "$OUT" | grep -q 'protocol corruption' \
  && ok "dangling symlink at the mutex path reported as corruption" || fail "reaper symlink blind spot" "$OUT"

# The scan must find the repo ROOT even when the agent's cwd is a subdirectory
# of the checkout (shared-checkout writers routinely cd into a package to test).
W="$TMP/e"; mkdir -p "$W/sub"; git -C "$W" init -q 2>/dev/null; : > "$W/.orch-active"
OUT=$(fire "$W/sub" 'Status: DONE
Summary: all good')
printf '%s' "$OUT" | grep -q 'protocol corruption' \
  && ok "root corruption found from a subdirectory cwd (git toplevel)" || fail "reaper subdir blind spot" "$OUT"

# Corruption is reported even when this invocation successfully reaps a mutex —
# the reap-and-exit paths must not swallow the report.
W="$TMP/f"; mkdir -p "$W/.worktrees/mine/.orch-active"; : > "$W/.orch-active"
OUT=$(fire "$W/.worktrees/mine" 'Status: DONE
Summary: done here')
printf '%s' "$OUT" | grep -q 'protocol corruption' \
  && ok "corruption reported even when a mutex was successfully reaped" || fail "early exit swallows corruption" "$OUT"
[[ ! -d "$W/.worktrees/mine/.orch-active" ]] \
  && ok "the reap itself still happened alongside the corruption report" || fail "reap suppressed by corruption scan" "$OUT"

# Regression guard: a real held mutex (directory) is still reaped on CWD proof.
W="$TMP/c"; mkdir -p "$W/.worktrees/mine/.orch-active"
OUT=$(fire "$W/.worktrees/mine" 'Status: DONE
Summary: done here')
[[ ! -d "$W/.worktrees/mine/.orch-active" ]] \
  && ok "directory mutex still released on CWD-proved ownership" || fail "reaper stopped reaping directories" "$OUT"

finish
