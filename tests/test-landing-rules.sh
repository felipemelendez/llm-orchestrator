#!/usr/bin/env bash
# The landing rules (skills/finishing-a-branch/references/landing-rules.md) are
# stated once and cited by every flow skill; the landing board script reads the
# work-in-progress limit the way the rules say. This suite checks both.
#
# Bash 3.2 compatible.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES="skills/finishing-a-branch/references/landing-rules.md"
BOARD="$ROOT/scripts/orch-landing-board.sh"

if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else GREEN=""; RED=""; DIM=""; RESET=""; fi
PASS=0; FAIL=0; FAILED=()
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '  %s✗%s %s\n    %s\n' "$RED" "$RESET" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }

# =============================================================================
printf '%s== the rules exist and say the nine things ==%s\n' "$DIM" "$RESET"
# =============================================================================
[[ -f "$ROOT/$RULES" ]] && ok "$RULES exists" || fail "$RULES exists" "missing"
for phrase in "At most two unmerged implementation branches" \
              "A READY verdict is a landing event" \
              "No \"merge after X\" chains" \
              "Every branch is cut from main; a hub change lands first" \
              "Main is merged into every open branch at every landing" \
              "The review loop ends on evidence, not on a count" \
              "Reproduce to block" \
              "within one working day of its first green test" \
              "The board is read first"; do
  has "$ROOT/$RULES" "$phrase" && ok "rule: $phrase" || fail "rule: $phrase" "not in $RULES"
done

# =============================================================================
printf '%s== every flow skill, command and template cites them ==%s\n' "$DIM" "$RESET"
# =============================================================================
for f in skills/executing-plans/SKILL.md \
         skills/dispatching-parallel-agents/SKILL.md \
         skills/dispatching-subagents/SKILL.md \
         skills/requesting-code-review/SKILL.md \
         skills/finishing-a-branch/SKILL.md \
         skills/cadence/SKILL.md \
         skills/cadence/CADENCE.md \
         skills/brainstorming/SKILL.md \
         skills/writing-plans/SKILL.md \
         skills/using-orchestrator/SKILL.md \
         skills/cadence/references/laws.md \
         skills/cadence/references/laws-example.md \
         skills/receiving-code-review/SKILL.md \
         commands/dispatch.md \
         commands/finish.md; do
  has "$ROOT/$f" "landing-rules.md" && ok "$f cites landing-rules.md" || fail "$f cites landing-rules.md" "no mention"
done
has "$ROOT/templates/plan.md" "Requires landed:" && ok "templates/plan.md carries Requires landed:" \
  || fail "templates/plan.md carries Requires landed:" "missing"
for f in skills/cadence/references/laws.md skills/cadence/references/laws-example.md; do
  has "$ROOT/$f" "**Branches:**" && ok "$f has the Branches line" || fail "$f has the Branches line" "missing"
done
for f in skills/finishing-a-branch/SKILL.md commands/finish.md skills/requesting-code-review/SKILL.md \
         skills/receiving-code-review/SKILL.md skills/executing-plans/SKILL.md docs/specs/review-design.md; do
  has "$ROOT/$f" "follow-up" && ok "$f names the follow-up disposition" || fail "$f names the follow-up disposition" "missing"
done
has "$ROOT/scripts/hooks/session-start.sh" "orch-landing-board.sh" && ok "the session-start hook runs the board script" \
  || fail "the session-start hook runs the board script" "no call"

# =============================================================================
printf '%s== the landing board reads the limit ==%s\n' "$DIM" "$RESET"
# =============================================================================
command -v git >/dev/null 2>&1 || { printf '%sSKIP: git unavailable for the board checks%s\n' "$DIM" "$RESET"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q && git -C "$REPO" checkout -q -b main; }
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
# A commit on a branch without checking it out, dated <days-ago> days back.
add_commit_on() { # add_commit_on <branch> <days-ago>
  local parent; parent=$(git -C "$REPO" rev-parse "$1")
  local tree; tree=$(git -C "$REPO" rev-parse "$1^{tree}")
  local when="$(( $(date +%s) - $2 * 86400 )) +0000"
  local sha; sha=$(GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$REPO" commit-tree "$tree" -p "$parent" -m "work on $1")
  git -C "$REPO" update-ref "refs/heads/$1" "$sha"
}

OUT=$(bash "$BOARD" --root "$REPO"); rc=$?
[[ $rc -eq 0 && -z "$OUT" ]] && ok "no unmerged branches: prints nothing, exit 0" \
  || fail "no unmerged branches: prints nothing, exit 0" "exit $rc, output: $OUT"

for b in t-a t-b t-c; do git -C "$REPO" branch "$b" main; done
add_commit_on t-a 5; add_commit_on t-b 1; add_commit_on t-c 0
OUT=$(bash "$BOARD" --root "$REPO"); rc=$?
case "$OUT" in *"3 unmerged branch(es) against main"*) ok "counts three unmerged branches against main" ;;
  *) fail "counts three unmerged branches against main" "output: $OUT" ;; esac
case "$OUT" in *"oldest 5d"*) ok "reports the oldest branch's age in days" ;;
  *) fail "reports the oldest branch's age in days" "output: $OUT" ;; esac
case "$OUT" in *"t-a"*"t-b"*"t-c"*) ok "names the branches" ;; *) fail "names the branches" "output: $OUT" ;; esac
case "$OUT" in *"over the limit of 2"*) ok "three is over the default limit of two" ;;
  *) fail "three is over the default limit of two" "output: $OUT" ;; esac
[[ $rc -eq 0 ]] && ok "without --check the exit is 0 even over the limit" || fail "without --check the exit is 0" "exit $rc"
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 3 ]] && ok "--check exits 3 over the limit" || fail "--check exits 3 over the limit" "exit $rc"
# The age is the branch's first commit off the base, so a fresh tip commit on an old branch keeps its age.
add_commit_on t-a 0
OUT=$(bash "$BOARD" --root "$REPO")
case "$OUT" in *"oldest 5d"*) ok "a new tip commit does not make an old branch look fresh" ;;
  *) fail "a new tip commit does not make an old branch look fresh" "output: $OUT" ;; esac
# Task worktree branches of the materialize engine are one ticket's tasks, not tickets.
git -C "$REPO" branch orch/sid1/task-x t-a; add_commit_on orch/sid1/task-x 0
OUT=$(bash "$BOARD" --root "$REPO")
case "$OUT" in *"3 unmerged branch(es)"*) ok "orch/<sid>/<slug> task branches are not counted" ;;
  *) fail "orch/<sid>/<slug> task branches are not counted" "output: $OUT" ;; esac
git -C "$REPO" branch -D orch/sid1/task-x >/dev/null 2>&1
OUT=$(ORCH_WIP_LIMIT=5 bash "$BOARD" --root "$REPO" --check); rc=$?
[[ $rc -eq 0 ]] && ! printf '%s' "$OUT" | grep -q "the limit" \
  && ok "ORCH_WIP_LIMIT=5 lifts the limit" || fail "ORCH_WIP_LIMIT=5 lifts the limit" "exit $rc, output: $OUT"
OUT=$(bash "$BOARD" --root "$REPO" --limit 4 --check); rc=$?
[[ $rc -eq 0 ]] && ok "--limit 4 leaves room for one more beside three" || fail "--limit 4 leaves room beside three" "exit $rc, output: $OUT"
OUT=$(bash "$BOARD" --root "$REPO" --limit 3 --check); rc=$?
[[ $rc -eq 3 ]] && case "$OUT" in *"at the limit of 3"*) ok "--limit 3 with three open: at the limit, no room for one more, exit 3" ;; *) fail "at-the-limit wording" "output: $OUT" ;; esac \
  || fail "--limit 3 with three open exits 3" "exit $rc, output: $OUT"
OUT=$(ORCH_WIP_LIMIT=abc bash "$BOARD" --root "$REPO" --check); rc=$?
[[ $rc -eq 3 ]] && ok "a non-numeric limit falls back to two" || fail "a non-numeric limit falls back to two" "exit $rc"
mkdir -p "$REPO/docs/llm-orchestrator"; printf '{ "schema": 1, "enabled": true, "wip_limit": 4 }\n' > "$REPO/docs/llm-orchestrator/cadence.json"
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "cadence.json wip_limit is read when no flag or variable is set" || fail "cadence.json wip_limit is read" "exit $rc"
OUT=$(ORCH_WIP_LIMIT=2 bash "$BOARD" --root "$REPO" --check); rc=$?
[[ $rc -eq 3 ]] && ok "ORCH_WIP_LIMIT wins over cadence.json" || fail "ORCH_WIP_LIMIT wins over cadence.json" "exit $rc"
rm -rf "$REPO/docs"
git -C "$REPO" branch -D t-c >/dev/null 2>&1
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 3 ]] && ok "two open branches fill the limit of two: --check exits 3, no room for a third" \
  || fail "two open branches fill the limit of two" "exit $rc"
git -C "$REPO" branch -D t-b >/dev/null 2>&1
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "one branch leaves room for one more" || fail "one branch leaves room for one more" "exit $rc"
# A remote base: a branch merged on the forge stops counting before the local base is pulled.
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse t-a)"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
OUT=$(bash "$BOARD" --root "$REPO"); rc=$?
[[ $rc -eq 0 && -z "$OUT" ]] && ok "the remote's view of the base is preferred: a branch merged there is not counted" \
  || fail "the remote's view of the base is preferred" "exit $rc, output: $OUT"
OUT=$(bash "$BOARD" --root "$TMP"); rc=$?
[[ $rc -eq 0 && -z "$OUT" ]] && ok "outside a repository: prints nothing, exit 0" \
  || fail "outside a repository: prints nothing, exit 0" "exit $rc, output: $OUT"

printf '\n'
if (( FAIL == 0 )); then
  printf '%sPASS: test-landing-rules%s (%d checks)\n' "$GREEN" "$RESET" "$PASS"
  exit 0
else
  printf '%sFAIL: test-landing-rules — %d passed, %d failed.%s\n' "$RED" "$PASS" "$FAIL" "$RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
