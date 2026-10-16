#!/usr/bin/env bash
# The landing rules (skills/finishing-a-branch/references/landing-rules.md) are
# stated once and cited by every flow skill; the landing board script lists the
# open branches and never caps them. This suite checks both.
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
for phrase in "One branch per piece of work, opened when the work starts" \
              "A READY verdict is a landing event" \
              "Say what a ticket builds on" \
              "or on the open branch the work depends on" \
              "Keep your own open branches current, bottom up" \
              "The review loop ends on evidence, not on a count" \
              "Reproduce to block" \
              "Keep each pull request small and land what is green" \
              "Nobody edits another agent's branch or pull request" \
              "Never wait on a person to keep building"; do
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
# A stacked ticket's PR targets its base branch, and the finish step points it at main afterwards.
f=skills/finishing-a-branch/SKILL.md
has "$ROOT/$f" "Requires landed:" && has "$ROOT/$f" "retarget their own" \
  && ok "$f picks the stacked base and leaves retargeting to each PR's owner" \
  || fail "$f picks the stacked base and leaves retargeting to each PR's owner" "missing"
has "$ROOT/$f" "never merged here" && has "$ROOT/$f" "delete-branch-on-merge" && has "$ROOT/$f" "never merged locally" \
  && has "$ROOT/$f" "--draft" && has "$ROOT/$f" "gh pr ready" && has "$ROOT/$f" "baseRefName" \
  && has "$ROOT/$f" '`OPEN`' && has "$ROOT/$f" '`MERGED`' && has "$ROOT/$f" "run the checks and push" \
  && has "$ROOT/$f" "--auto --merge" && has "$ROOT/$f" "Do not wait" && ! has "$ROOT/$f" "git/refs/heads" \
  && ok "$f never merges a stacked PR into its base, pushes the retarget merge, waits for MERGED, reuses only an open PR, and handles drafts" \
  || fail "$f never merges a stacked PR into its base, pushes the retarget merge, waits for MERGED, reuses only an open PR, and handles drafts" "missing"
f=commands/finish.md
has "$ROOT/$f" "Requires landed:" && has "$ROOT/$f" 'a PR number: its `headRefName`' \
  && has "$ROOT/$f" "follow \`finishing-a-branch\` option 1 exactly" && ! grep -qE 'gh pr edit|wait until|In short|never merged here' "$ROOT/$f" \
  && ok "$f points at the skill's option 1 without restating it, and keeps the two hard stops" \
  || fail "$f points at the skill's option 1 without restating it, and keeps the two hard stops" "missing or restated"
f=skills/finishing-a-branch/SKILL.md
has "$ROOT/$f" "git switch --detach" && has "$ROOT/$f" "from the ticket's own worktree" \
  && has "$ROOT/$f" "hand the person" && ! has "$ROOT/$f" "git switch --detach && git branch -D" \
  && ! has "$ROOT/$f" "gh pr close <n> --delete-branch" \
  && ok "$f discards from the ticket's worktree and hands the guarded delete to the person" \
  || fail "$f discards from the ticket's worktree and hands the guarded delete to the person" "missing"
f=commands/finish.md
has "$ROOT/$f" "follow the skill's option 2 exactly" && has "$ROOT/$f" "follow the skill's option 4 exactly" \
  && ! grep -qE 'delete-branch|git branch -D|merge --no-ff' "$ROOT/$f" \
  && ok "$f points at the skill's options 2 and 4 without restating them" \
  || fail "$f points at the skill's options 2 and 4 without restating them" "missing or restated"
f=skills/finishing-a-branch/SKILL.md
has "$ROOT/$f" 'If the PR'"'"'s `baseRefName` differs from `<base>`' && has "$ROOT/$f" "Before any merge, whether or not the PR was retargeted" \
  && ok "$f retargets a reused PR to <base> and always fetches, merges, checks and pushes before merging" \
  || fail "$f retargets a reused PR to <base> and always fetches, merges, checks and pushes before merging" "missing"
for f in skills/executing-plans/SKILL.md skills/dispatching-subagents/SKILL.md skills/cadence/CADENCE.md; do
  grep -qiE "merge the base into (the branch|each still-open)|the base merged into each still-open" "$ROOT/$f" \
    && fail "$f merges the fetched remote ref, not a bare base" "stale phrase" || ok "$f merges the fetched remote ref, not a bare base"
done
for f in commands/worktree.md skills/using-git-worktrees/SKILL.md; do
  has "$ROOT/$f" "gh pr create --draft --base" && has "$ROOT/$f" "when a remote" && has "$ROOT/$f" "--fill --head <branch" \
    && ok "$f opens the draft PR after the first commit, with a remote, naming its head" \
    || fail "$f opens the draft PR after the first commit, with a remote, naming its head" "missing"
done
for f in skills/executing-plans/SKILL.md skills/dispatching-subagents/SKILL.md skills/cadence/CADENCE.md; do
  tr '\n' ' ' < "$ROOT/$f" | tr -s ' ' | grep -qE -- '--base +<base>' && fail "$f passes the review base as a remote ref" "bare --base <base> found" \
    || ok "$f passes the review base as a remote ref"
  has "$ROOT/$f" "no remote" && ok "$f says what to do with no remote" || fail "$f says what to do with no remote" "missing"
done
has "$ROOT/skills/finishing-a-branch/references/landing-rules.md" "read it as the local" && ok "the rules define origin/<x> once, with the no-remote reading" \
  || fail "the rules define origin/<x> once, with the no-remote reading" "missing"
has "$ROOT/skills/finishing-a-branch/SKILL.md" "stacked children" && ok "the finish skill updates open branches bottom up" \
  || fail "the finish skill updates open branches bottom up" "missing"
has "$ROOT/skills/finishing-a-branch/SKILL.md" 'gh pr edit <n> --title "<title>" --body-file <file>' && has "$ROOT/skills/finishing-a-branch/SKILL.md" "Either way" \
  && ok "the finish skill writes the body onto a reused PR and marks it ready" || fail "the finish skill writes the body onto a reused PR and marks it ready" "missing"
for f in skills/finishing-a-branch/SKILL.md commands/finish.md commands/dispatch.md skills/executing-plans/SKILL.md; do
  has "$ROOT/$f" "CLOSED" && ok "$f stops on an abandoned dependency" || fail "$f stops on an abandoned dependency" "missing"
done
grep -A1 "reuse it" "$ROOT/skills/finishing-a-branch/SKILL.md" | grep -q "rule 9" || grep -B1 "reuse it" "$ROOT/skills/finishing-a-branch/SKILL.md" | grep -q "yours" \
  && ok "the finish skill reuses only the agent's own PR" || fail "the finish skill reuses only the agent's own PR" "missing"
SNIP=$(sed -n '/^   orch_board()/,/^   B=/p' "$ROOT/commands/dispatch.md")
NB=$(mktemp -d) || exit 1
( cd "$NB" && env -u CLAUDE_PLUGIN_ROOT HOME="$NB/nohome" bash -c "$SNIP" ) >/dev/null 2>&1; rc=$?
rm -rf "$NB"
[[ $rc -eq 0 ]] && ok "dispatch step 0 exits 0 when no board script is found" || fail "dispatch step 0 exits 0 when no board script is found" "exit $rc"
for f in $(cd "$ROOT" && find skills commands -name '*.md' | sort); do
  grep -qiE "stop and ask|stop to ask|ask its owner what|and ask the user|ask the user what|needs the user\*\* → stop|stop and report to the user|Legitimate stops|Stops: unresolvable|unless the user is genuinely needed|only then moves to the next pull request" "$ROOT/$f" \
    && fail "$f never stops to wait on a person" "$(grep -niE 'stop and ask|stop to ask|ask its owner what|and ask the user|ask the user what|needs the user\*\* → stop|stop and report to the user|Legitimate stops|Stops: unresolvable|unless the user is genuinely needed|only then moves to the next pull request' "$ROOT/$f" | head -1)" \
    || ok "$f never stops to wait on a person"
done
has "$ROOT/skills/finishing-a-branch/SKILL.md" "when auto-merge is off" && has "$ROOT/skills/finishing-a-branch/SKILL.md" "requires its checks before a" && has "$ROOT/skills/finishing-a-branch/SKILL.md" "move your work to a new branch before pushing" \
  && ok "the finish skill uses auto-merge only on required checks and checks ownership before pushing" \
  || fail "the finish skill uses auto-merge only on required checks and checks ownership before pushing" "missing"
has "$ROOT/skills/finishing-a-branch/references/landing-rules.md" "cherry-pick only" \
  && has "$ROOT/skills/finishing-a-branch/references/landing-rules.md" "run the full suite on it" \
  && ok "rules drop an abandoned dependency's commits and run the suite on main after a deferred merge" \
  || fail "rules drop an abandoned dependency's commits and run the suite on main after a deferred merge" "missing"
has "$ROOT/commands/dispatch.md" "open its draft PR as the worktree step" && ok "dispatch opens the draft PR after the first commit, as the worktree step says" \
  || fail "dispatch opens the draft PR after the first commit, as the worktree step says" "missing"
for f in commands/worktree.md skills/using-git-worktrees/SKILL.md; do
  has "$ROOT/$f" "isCrossRepository" && ok "$f refuses a fork PR as a start point" || fail "$f refuses a fork PR as a start point" "missing"
done
for f in skills/requesting-code-review/SKILL.md; do
  has "$ROOT/$f" "when the PR is yours" && ok "$f retargets only the agent's own PR" || fail "$f retargets only the agent's own PR" "missing"
done
has "$ROOT/commands/review.md" '`requesting-code-review` defines' && ok "commands/review.md takes its base from the review skill" \
  || fail "commands/review.md takes its base from the review skill" "missing"
for f in commands/worktree.md skills/using-git-worktrees/SKILL.md; do
  has "$ROOT/$f" "--no-track" && has "$ROOT/$f" "origin/<dependency>" \
    && ok "$f starts a worktree from the remote ref without tracking it" \
    || fail "$f starts a worktree from the remote ref without tracking it" "missing"
done
has "$ROOT/templates/plan.md" "Path: Simple | Standard | Full" && ok "templates/plan.md carries the Path: line" \
  || fail "templates/plan.md carries the Path: line" "missing"
for f in skills/writing-plans/SKILL.md skills/dispatching-subagents/SKILL.md skills/dispatching-parallel-agents/SKILL.md; do
  has "$ROOT/$f" '`Path:`' && ok "$f names the task's Path: line" || fail "$f names the task's Path: line" "missing"
done
for f in skills/dispatching-subagents/SKILL.md skills/dispatching-parallel-agents/SKILL.md; do
  has "$ROOT/$f" "a reviewer may raise it" && ok "$f says the path is reassessed and a reviewer may raise it" \
    || fail "$f says the path is reassessed and a reviewer may raise it" "missing"
done
for f in skills/cadence/references/laws.md skills/cadence/references/laws-example.md; do
  has "$ROOT/$f" "**Branches:**" && ok "$f has the Branches line" || fail "$f has the Branches line" "missing"
done
for f in skills/finishing-a-branch/SKILL.md commands/finish.md skills/requesting-code-review/SKILL.md \
         skills/receiving-code-review/SKILL.md skills/executing-plans/SKILL.md docs/specs/review-design.md; do
  has "$ROOT/$f" "follow-up" && ok "$f names the follow-up disposition" || fail "$f names the follow-up disposition" "missing"
done
has "$ROOT/scripts/hooks/session-start.sh" "orch-landing-board.sh" && ok "the session-start hook runs the board script" \
  || fail "the session-start hook runs the board script" "no call"
# No shipped file or user doc mentions a branch cap, past or present: every markdown file
# under skills/, commands/, templates/, agents/, docs/ (research records and the changelog aside)
# and the top-level docs.
SCAN=$(cd "$ROOT" && find skills commands templates agents docs examples output-styles -name '*.md' -not -path 'docs/llm-orchestrator/research/*' 2>/dev/null | sort; ls CLAUDE.md CONTRIBUTING.md concise-agent-protocol.md 2>/dev/null)
REQUIRED="skills/finishing-a-branch/references/landing-rules.md skills/finishing-a-branch/SKILL.md commands/dispatch.md commands/finish.md commands/worktree.md templates/plan.md skills/executing-plans/SKILL.md skills/cadence/CADENCE.md skills/cadence/references/laws.md skills/cadence/references/laws-example.md docs/specs/landing-discipline.md docs/specs/shared-project-policy.md docs/project-policy.md README.md ARCHITECTURE.md AGENTS.md docs/commands-guide.md"
for f in $(printf '%s\n' $SCAN $REQUIRED | sort -u); do
  [[ -f "$ROOT/$f" ]] || { fail "$f mentions no branch cap, age reminder or cut-from-main rule" "file missing"; continue; }
  P="at most (two|[0-9]+) (unmerged|open|active) (implementation )?branches|limited to two|at the limit of|past the limit|wip_limit|ORCH_WIP_LIMIT|WIP limit|a third ticket waits|branches at a time|not a hard cap|hard cap on (open |unmerged )?branches|(three|[0-9]+) or fewer active branches|limit of (two|[0-9]+) (open |unmerged )?branches|max(imum)? (of )?(two|[0-9]+) (open |unmerged )?branches|no cap on|no longer caps|branch cap|no limit on open|two active tasks|how many (branches |may be )?open|cut from main|working day of its first|older than a (working )?day|exits 3 (when|over|at)"
  if grep -qiE "$P" "$ROOT/$f"; then
    fail "$f mentions no branch cap, age reminder or cut-from-main rule" "$(grep -niE "$P" "$ROOT/$f" | head -1)"
  else ok "$f mentions no branch cap, age reminder or cut-from-main rule"; fi
done

# =============================================================================
printf '%s== the landing board lists, and never caps ==%s\n' "$DIM" "$RESET"
# =============================================================================
command -v git >/dev/null 2>&1 || { printf '%sSKIP: git unavailable for the board checks%s\n' "$DIM" "$RESET"; }
TMP=$(mktemp -d) || exit 1; trap 'rm -rf "$TMP"' EXIT
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

# Three branches: two orchestrators' tickets and a draft parked on someone else's decision.
for b in t-a t-b t-c; do git -C "$REPO" branch "$b" main; done
add_commit_on t-a 5; add_commit_on t-b 1; add_commit_on t-c 0
OUT=$(bash "$BOARD" --root "$REPO"); rc=$?
case "$OUT" in *"3 unmerged branch(es) against main"*) ok "counts three unmerged branches against main" ;;
  *) fail "counts three unmerged branches against main" "output: $OUT" ;; esac
case "$OUT" in *"oldest 5d"*) ok "reports the oldest branch's age in days" ;;
  *) fail "reports the oldest branch's age in days" "output: $OUT" ;; esac
case "$OUT" in *"t-a"*"t-b"*"t-c"*) ok "names the branches" ;; *) fail "names the branches" "output: $OUT" ;; esac
case "$OUT" in *"limit"*) fail "three open branches: no limit is mentioned" "output: $OUT" ;;
  *) ok "three open branches: no limit is mentioned" ;; esac
[[ $rc -eq 0 ]] && ok "exit 0 with three open branches" || fail "exit 0 with three open branches" "exit $rc"
# --check is what every installed dispatch.md before 0.18.0 runs; it must never block.
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "--check exits 0 with three open branches: the board is a report, not a gate" \
  || fail "--check exits 0 with three open branches" "exit $rc"
for b in t-d t-e t-f t-g; do git -C "$REPO" branch "$b" main; add_commit_on "$b" 0; done
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "--check exits 0 with seven open branches: there is no cap" \
  || fail "--check exits 0 with seven open branches" "exit $rc"
OUT=$(bash "$BOARD" --root "$REPO"); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"7 unmerged branch(es)"*"…"*) ok "seven branches: exit 0, counted in full, names truncated after six" ;;
  *) fail "seven branches: counted in full, names truncated after six" "output: $OUT" ;; esac \
  || fail "seven branches without --check exit 0" "exit $rc"
for b in t-d t-e t-f t-g; do git -C "$REPO" branch -D "$b" >/dev/null 2>&1; done
# The obsolete limit inputs are accepted and ignored.
OUT=$(ORCH_WIP_LIMIT=1 bash "$BOARD" --root "$REPO" --check); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"limit"*) fail "ORCH_WIP_LIMIT=1 is ignored" "output: $OUT" ;; *) ok "ORCH_WIP_LIMIT=1 is ignored" ;; esac \
  || fail "ORCH_WIP_LIMIT=1 is ignored" "exit $rc"
OUT=$(bash "$BOARD" --root "$REPO" --limit 1 --check); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"3 unmerged branch(es)"*) ok "--limit 1 is accepted and ignored" ;; *) fail "--limit 1 is accepted and ignored" "output: $OUT" ;; esac \
  || fail "--limit 1 is accepted and ignored" "exit $rc, output: $OUT"
mkdir -p "$REPO/docs/llm-orchestrator"; printf '{ "schema": 1, "enabled": true, "wip_limit": 1 }\n' > "$REPO/docs/llm-orchestrator/cadence.json"
bash "$BOARD" --root "$REPO" --check >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "cadence.json wip_limit is ignored" || fail "cadence.json wip_limit is ignored" "exit $rc"
rm -rf "$REPO/docs"
bash "$BOARD" --root "$REPO" --bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "an unknown argument still exits 2" || fail "an unknown argument still exits 2" "exit $rc"
# --limit with no value must not loop: the alarm would kill it with 142.
if command -v perl >/dev/null 2>&1; then
OUT=$(perl -e 'alarm 5; exec @ARGV' bash "$BOARD" --root "$REPO" --limit 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"3 unmerged branch(es)"*) ok "--limit with no value is ignored and the board still prints" ;; *) fail "--limit with no value" "output: $OUT" ;; esac \
  || fail "--limit with no value is ignored (no hang)" "exit $rc"
OUT=$(perl -e 'alarm 5; exec @ARGV' bash "$BOARD" --limit --root "$REPO" 2>/dev/null); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"3 unmerged branch(es)"*) ok "--limit before --root does not eat the next flag" ;; *) fail "--limit before --root" "output: $OUT" ;; esac \
  || fail "--limit before --root does not eat the next flag" "exit $rc"
else printf '%s  (perl unavailable: the two no-hang checks skipped)%s\n' "$DIM" "$RESET"; fi
bash "$BOARD" --root >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "--root without a value exits 2 with a message" || fail "--root without a value exits 2" "exit $rc"
bash "$BOARD" --root --check >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "--root followed by a flag exits 2" || fail "--root followed by a flag exits 2" "exit $rc"
# A directory whose name starts with a dash is still a value.
( cd "$TMP" && mkdir -p -- ./-scratch && cp -R -- "$REPO/." ./-scratch/ ) && OUT=$(cd "$TMP" && bash "$BOARD" --root -scratch); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"3 unmerged branch(es)"*) ok "--root accepts an existing directory named with a leading dash" ;; *) fail "--root -scratch" "output: $OUT" ;; esac \
  || fail "--root accepts an existing directory named with a leading dash" "exit $rc"
rm -rf -- "$TMP/-scratch"
OUT=$(bash "$BOARD" --limit -h 2>/dev/null | head -1); case "$OUT" in *"landing board"*) ok "--limit does not swallow a following short flag" ;;
  *) fail "--limit does not swallow a following short flag" "output: $OUT" ;; esac
OUT=$(bash "$BOARD" --root "$REPO" --limit abc --check 2>&1); rc=$?
[[ $rc -eq 0 ]] && case "$OUT" in *"3 unmerged branch(es)"*) ok "--limit with a non-numeric value is ignored" ;; *) fail "--limit abc" "output: $OUT" ;; esac \
  || fail "--limit with a non-numeric value is ignored" "exit $rc, output: $OUT"
OUT=$(bash "$BOARD" --root "$REPO" --limit "" --check 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--limit with an empty value is ignored" || fail "--limit with an empty value is ignored" "exit $rc, output: $OUT"
# The age is the branch's first commit off the base, so a fresh tip commit on an old branch keeps its age.
add_commit_on t-a 0
OUT=$(bash "$BOARD" --root "$REPO")
case "$OUT" in *"oldest 5d"*) ok "a new tip commit does not make an old branch look fresh" ;;
  *) fail "a new tip commit does not make an old branch look fresh" "output: $OUT" ;; esac
bash "$BOARD" -h | grep -q 'accepted and ignored' && ok "--help prints the whole header" || fail "--help prints the whole header" "truncated"
# Task worktree branches of the materialize engine are one ticket's tasks, not tickets.
git -C "$REPO" branch orch/sid1/task-x t-a; add_commit_on orch/sid1/task-x 0
OUT=$(bash "$BOARD" --root "$REPO")
case "$OUT" in *"3 unmerged branch(es)"*) ok "orch/<sid>/<slug> task branches are not listed" ;;
  *) fail "orch/<sid>/<slug> task branches are not listed" "output: $OUT" ;; esac
git -C "$REPO" branch -D orch/sid1/task-x >/dev/null 2>&1
git -C "$REPO" branch -D t-a t-b >/dev/null 2>&1
OUT=$(bash "$BOARD" --root "$REPO")
case "$OUT" in *"1 unmerged branch(es)"*) ok "one branch is listed" ;; *) fail "one branch is listed" "output: $OUT" ;; esac
# A remote base: a branch merged on the forge stops counting before the local base is pulled.
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse t-c)"
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
