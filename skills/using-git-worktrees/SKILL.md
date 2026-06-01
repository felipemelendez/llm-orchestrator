---
name: using-git-worktrees
description: Use when work needs isolation from the current branch — long-running feature, risky refactor, parallel attempt. Creates and tracks a worktree without touching unrelated state.
---

# Using git worktrees

Isolation by directory, not by stash.

## When to use

- The current branch has uncommitted work you don't want to lose.
- You want to compare two approaches side by side.
- A subagent will edit code while you keep working.

Skip for tiny edits on a clean tree — just commit.

## Steps

1. **Check for existing isolation.** If you're already inside a worktree, don't nest.
   ```
   git rev-parse --git-dir
   git rev-parse --git-common-dir
   ```
   If they differ, you're already in a worktree.

2. **Pick the directory.** Priority:
   - `.worktrees/<slug>` (project-local; preferred)
   - `~/.llm-orchestrator/worktrees/<project>/<slug>` (fallback)

3. **Add the worktree — on a unique path and a unique branch.** Never point two writers at the same directory or the same branch.
   ```
   git worktree add .worktrees/<slug> -b <branch-name>
   ```
   `git worktree add` itself refuses a path that already exists or a branch already checked out elsewhere — that refusal is your mechanical guard against two writers colliding on one tree. If it errors with "already exists" / "already checked out", STOP: a sibling owns that worktree; pick a different slug, do not reuse it.

4. **Mark provenance.** Drop `.orch-worktree` in the new dir (cleanup only removes worktrees with this marker). `.orch-worktree-lock` records the owning session id for the registry's `--list`/`--release` — it is *informational provenance*, not the anti-clobber mechanism.

   The two **real mechanical guards** are: (a) at create time, `git worktree add`'s own refusal of a duplicate path/branch plus the registry's atomic `mkdir` claim (see `orch-worktree-materialize.sh`); (b) at write time, the implementer's atomic `mkdir <worktree>/.orch-active` mutex — two writers handed the same path can never both proceed, because `mkdir` has exactly one winner. Both fail loudly; neither relies on a writer reading and obeying a text file.

5. **Add to .gitignore if needed.**
   ```
   grep -q '^\.worktrees/' .gitignore || echo '.worktrees/' >> .gitignore
   ```

6. **Set up the project.** Detect manifest, install deps:
   - `package.json` → `pnpm install` (or npm/yarn from lockfile)
   - `Cargo.toml` → `cargo build`
   - `pyproject.toml` → `uv sync` or `poetry install`
   - `go.mod` → `go mod download`

7. **Run baseline tests and record.** Capture the green state before any edits and persist it so the regression guard can compare later.
   ```
   orch_regression_baseline <worktree-dir>
   ```
   This detects the test command, runs it, and writes `~/.llm-orchestrator/toolchain/<hash>/baseline.md`. If the suite is not green at this point, stop — do not proceed with edits until the baseline is clean.

## Cleanup

Release the ownership claim **before** removing the worktree (so a concurrent prune can't race the
removal), then remove:

```
cd "$(git rev-parse --show-toplevel)"
MAT="${CLAUDE_PLUGIN_ROOT:-.}/scripts/orch-worktree-materialize.sh"; [[ -f "$MAT" ]] || MAT=".claude/scripts/orch-worktree-materialize.sh"
SID="$(bash "$MAT" --sid)"
bash "$MAT" --release "$SID" <slug>
git worktree remove .worktrees/<slug>
git worktree prune
```

Refuse cleanup if `.orch-worktree` is missing — that worktree wasn't ours. If `--release` reports
either "release denied" (the session id changed mid-batch, e.g. after a `/clear`) or "refusing to
release in-progress claim" (a kill-in-window orphan), ignore it and continue with `git worktree
remove`: once the worktree directory is gone, the Stop hook's `--prune` reclaims the stale claim
within the TTL. A denied release is never a permanent leak.

## Output shape

```
Changed:
- created worktree .worktrees/<slug> on branch <branch-name>
- baseline tests: 142 passed
Verify:
- cd .worktrees/<slug> && pnpm test → 142 passed
Next:
- /dispatch task 1 against this worktree
```

## Anti-patterns

- Worktrees nested inside other worktrees.
- Removing a worktree you didn't create.
- Worktree without provenance file (you won't know later).
- Adding 5 worktrees and forgetting to clean up.
