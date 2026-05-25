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

3. **Add the worktree.**
   ```
   git worktree add .worktrees/<slug> -b <branch-name>
   ```

4. **Mark provenance.** Drop `.orch-worktree` in the new dir. This file is LLM Orchestrator's signal that *we* created it — cleanup will only remove worktrees with this marker.

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

```
cd <main-repo-root>
git worktree remove .worktrees/<slug>
git worktree prune
```

Refuse cleanup if `.orch-worktree` is missing — that worktree wasn't ours.

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
