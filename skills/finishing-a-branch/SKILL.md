---
name: finishing-a-branch
description: Use when a branch's work is done and tests pass, to land it through a pull request (the default), or merge locally, keep or discard. Nothing destructive without confirmation.
---

# Finishing a branch

## A READY verdict is a landing event

[references/landing-rules.md](references/landing-rules.md) holds the rules for
ticket work on a long project. This skill enforces three: a landing verdict is
landed now, in this session, never held for a sibling; nothing new is
committed on that head; after the merge, `origin/<main>` is merged into your own
still-open branches, bottom up. The landing board at session start lists what is waiting.

## Proportional cadence

For enabled `workflow: proportional`, finish the cadence's selected path.
Reuse valid checks; validate changed inputs. Land through option 1 below (push,
PR, merge, base checks) without another menu when the laws' Landing rule or the
user authorizes it. Commit/push/merge/discard need authorization; the laws'
Landing rule is that authorization. After consumers stop
and work is preserved, finish resources through the task helper: clean disposable
copies; retain unique/dirty/active work and report its path. Stop here; the
preconditions below are for projects without an enabled cadence.

## Preconditions

Before this skill runs:
- `/llm-orchestrator:verify` has been run; tests pass.
- `/llm-orchestrator:review` has been run on the whole branch; the verdict is `READY`; or `READY-WITH-FIXES` with its mild findings handled and recorded; or `NOT-READY` with every blocking finding recorded `refuted`, `settled` or `follow-up` and the mild ones handled. None of these needs another review, unless a mild fix changed behaviour (`receiving-code-review`).
- **Regression check passes.** Run:
  ```bash
  orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
  L=$(orch_lib orch-detect.sh) && . "$L" && orch_regression_check <project-dir>
  ```
  Exit codes: `0` — passes (or no green baseline). `1` — a previously green suite now fails: **refuse to merge or open a PR**, report what regressed, fix that first. `2` — unknown: no baseline recorded (`using-git-worktrees` step 7 skipped), or **no test command detected anymore**; stderr says which. A missing baseline: say so and continue on `/llm-orchestrator:verify`. A vanished test command is a blocker: find what removed it. The check only reads and runs tests.

If any precondition is false, stop and do that first.

## Detect environment

```
git rev-parse --abbrev-ref HEAD          # current branch
git rev-parse --git-dir                  # detect worktree
git rev-parse --git-common-dir
git status --porcelain                    # clean tree?
```

If HEAD is detached, drop options 2 and 4 — there is no branch to merge and none to delete.
Options 1 and 3 still apply; push with `git push origin HEAD:refs/heads/<new-branch>`.

Confirm it is a worktree, not a submodule: `git rev-parse --show-superproject-working-tree`
returns a path inside a submodule, where `GIT_DIR != GIT_COMMON_DIR` also holds.

## Options (always present this menu)

```
1. Push and open PR (default)
2. Merge locally into <base> (only when the user picks it)
3. Keep as-is (no action; come back later)
4. Discard
```

## Behaviors

### 1. Push and open PR (default)
- Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` without its `origin/`
  prefix (`main`, not `origin/main`), or ask. A ticket stacked on an open branch (its
  `Requires landed:` dependency is not landed by landing rule 4's test; a PR number: its
  `headRefName`; `CLOSED` unmerged or `isCrossRepository`: build on the default branch,
  dropping its commits as rule 4 says) uses that branch as `<base>`, so its PR targets it (rule 3). Such a PR is opened,
  never merged here: it lands after its base does, once it points at the default branch.
- First, if the branch has an `OPEN` PR someone else owns (`gh pr view <branch> --json
  state,author`), move your work to a new branch before pushing (rule 9). Then
  `git push -u origin <branch>` (detached HEAD: `git push origin HEAD:refs/heads/<new-branch>`).
  Never rewrite pushed history; investigate a rejected push; force-push only with explicit
  user authorization.
- One PR per ticket, keeping the project's naming. If the branch already has a PR
  (`gh pr view <branch> --json number,state,isDraft,baseRefName`, `state` `OPEN`), and it is
  yours (rule 9; someone else's: open your own PR from a new branch), reuse it
  (after the next bullet when its `baseRefName` is not the `<base>` above) and write its
  title and body: `gh pr edit <n> --title "<title>" --body-file <file>`. Otherwise
  `gh pr create --base <base> --head <branch> --title "<title>" --body-file <file>`,
  `--draft` while work is in progress. Either way, `gh pr ready <n>` on a landing verdict
  unless the person wants it kept a draft.
  Write the title and body by
  [references/pr-body.md](references/pr-body.md) — plain words, short, outcome first, in six
  sections: Summary / Decisions / Review / Verification / Manual checklist for the owner /
  Open items.
- If the PR's `baseRefName` differs from `<base>` (its old base landed by landing rule 4's
  test, or the plan now names another open branch): `gh pr edit <n> --base <base>`.
- Before any merge, whether or not the PR was retargeted: `git fetch origin`, merge
  `origin/<base>` in (a squash-merged base: landing rule 5 says how to resolve),
  run the checks and push (a no-op when the branch is already current). A merge that
  needed conflict resolution gets one scoped Standard review of the resolution diff first
  (rule 2).
- Merge only when the laws' Landing rule or the user authorizes it and the PR's own
  `baseRefName` is the default branch: when the repository requires its checks before a
  merge (branch protection or a ruleset), `gh pr merge <n> --auto --merge` (GitHub merges
  once they pass, or through the merge queue); otherwise, or when auto-merge is off,
  `gh pr merge <n> --merge` once `gh pr checks <n>` is all green. Never `--delete-branch` (from a
  worktree it also switches and deletes locally). Do not wait: move on, and do the steps
  below once `gh pr view <n> --json state` says `MERGED`; rule 5's session-start catch-up
  runs them, the full suite on `<main>` included, otherwise. If the queue drops it or a check fails, fix it and turn auto-merge
  on again. With the repository setting
  `delete-branch-on-merge` on, GitHub then points the PRs stacked on `<branch>` at `<main>`;
  otherwise their owners retarget their own PRs (landing rule 5). Then, in the checkout that holds `<main>`
  (`git worktree list`), `git pull --ff-only` and run the full suite there, one suite at a
  time. If none holds it: `git fetch origin <main>:<main>`, run the suite in a new detached
  worktree of `<main>`, then remove that worktree. Red: stop and report.
- Many tickets: one PR at a time, base checks green between them. After each merge, fetch and
  merge `origin/<main>` into each still-open branch you own that builds on `<main>`, then
  each updated parent into its stacked children, and run the checks (rule 5).
- Keep the worktree until the PR is merged, then offer cleanup if marked `.orch-worktree` and
  `git branch -d <branch>`. Not authorized to merge: stop after opening, report the URL.

### 2. Merge locally (opt-out)
- Only when the user chose it; it suits a branch without a PR, for example in a repository
  with no remote.
  A ticket stacked on an open branch, or one with an open PR, is never merged locally: refuse
  and offer option 1 (landing rule 3; a PR landed locally would stay open and its dependents stale).
- `git checkout <base>`, then `git pull --ff-only` when a remote exists — merge into the
  current base.
- `git merge --no-ff <branch>`
- **Run the suite on the merged tree.** Base has moved; a textual conflict is loud, a
  semantic one is silent, and only this step catches it.
- If it fails: stop. Leave the branch and the worktree exactly where they are and report what
  broke. Nothing has been pushed, so the merge is local and recoverable (`git merge --abort`,
  or reset the base branch to its pre-merge commit).
- Only once green: offer cleanup if the branch lived in a worktree marked `.orch-worktree`,
  then `git branch -d <branch>`.

### 3. Keep
- No-op. Print where the branch and worktree live.

### 4. Discard
- Require the user to type the word `discard` literally.
- Only then, from the ticket's own worktree: `git switch --detach`, then hand the person
  `git branch -D <branch>` to run (the plugin's guard refuses it; from anywhere else they
  remove the marked worktree first; never a checkout of `<base>` by bare name, which can
  create a tracking copy of another owner's branch). If the branch has a PR you own, `gh pr close <n>` (someone else's: leave it)
  (never its `--delete-branch`, which deletes the local branch behind the guard). When
  `gh pr list --base <branch>` is empty, hand the person the remote deletion too; otherwise
  comment on each stacked PR that its base was discarded, since deleting a branch closes
  every PR stacked on it.
- Cleanup worktree only if marked `.orch-worktree`.

## Output shape

Before:

```
Found:
- Branch: feat/x
- Worktree: .worktrees/feat-x (LLM Orchestrator-created)
- Tests: 142 passed
- Review: READY
Options:
- 1. Push and open PR (default)
- 2. Merge locally into main
- 3. Keep
- 4. Discard (requires "discard" confirmation)
Recommendation:
- 1 — the default; the PR carries the summary and the review record
```

After landing:

```
Changed:
- Pushed feat/x to origin
- Opened PR #142: <title> — <url>
- Merged PR #142 with a merge commit; pulled main
Verify:
- <full suite command on main> → <result line>
Next:
- PR for the next ticket, or none.
```
