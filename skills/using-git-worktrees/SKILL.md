---
name: using-git-worktrees
description: Use when work needs isolation from the current branch — long-running feature, risky refactor, parallel attempt. Creates and tracks a worktree without touching unrelated state.
---

# Using git worktrees

Isolation by directory, not by stash. Use for work that must not touch the current branch —
uncommitted work you can't lose, side-by-side approaches, a subagent editing while you keep
working. Skip for tiny edits on a clean tree — just commit.

## Delegation

Do not hand the checkout to the harness's per-agent worktree isolation (`isolation: worktree` on
dispatch) — it was evaluated and rejected, and the reasons apply to the interactive single-writer
case as much as to batch fan-out: the harness branches from the default branch, not your current
`HEAD`, so the subagent edits against the wrong base; the `worktree.baseRef: head` mitigation is a
user setting a plugin cannot ship; the harness never reports the worktree path, so the registry
claim, provenance marker, and green-baseline capture below have nowhere to land; and native
cleanup keeps changed worktrees in a location the reaper never scans. (The dated evaluation brief
lives under `docs/llm-orchestrator/research/`, a local working directory that is not distributed;
the operative reasons are all inline here.) Create the worktree yourself with the steps below —
for parallel writers, the materialize engine per `dispatching-parallel-agents` — and pass the path
into the dispatch envelope.

## Steps

1. **Check for existing isolation.** If `git rev-parse --git-dir` and `--git-common-dir` differ,
   you're already in a worktree — don't nest.

2. **Pick the directory.** `.worktrees/<slug>` — project-local, and the only path the tooling
   knows: `scripts/orch-worktree-materialize.sh` hardcodes `${PWD}/.worktrees/` and the reaper
   only scans there (a `~/.llm-orchestrator/worktrees/` fallback was documented once but never
   implemented). If the project-local path is unusable, stop and say so rather than inventing a
   location nothing else knows about.

3. **Add the worktree — on a unique path and a unique branch.** Never point two writers at the
   same directory or the same branch.
   ```
   git worktree add .worktrees/<slug> -b <branch-name>
   ```
   `git worktree add` itself refuses a path that already exists or a branch already checked out
   elsewhere — that refusal is your mechanical guard against two writers colliding on one tree.
   If it errors with "already exists" / "already checked out", stop: a sibling owns that
   worktree; pick a different slug, do not reuse it.

4. **Mark provenance.** Drop `.orch-worktree` in the new dir (cleanup only removes worktrees with
   this marker). `.orch-worktree-lock` records the owning session id for the registry's
   `--list`/`--release` — it is *informational provenance*, not the anti-clobber mechanism.

   The two **real mechanical guards** are: (a) at create time, `git worktree add`'s refusal of a
   duplicate path/branch plus the registry's atomic `mkdir` claim (see
   `orch-worktree-materialize.sh`); (b) at write time, the implementer's atomic
   `mkdir <worktree>/.orch-active` mutex — two writers handed the same path can never both
   proceed, because `mkdir` has exactly one winner. Both fail loudly; neither relies on a writer
   reading and obeying a text file.

   The mutex guard only means something when the thing at the path is what the protocol defines:
   a *directory* created by `mkdir`. A **regular file** at an `.orch-active` path is
   **protocol corruption**, not a held lock — a hold-marker something improvised outside the protocol (a
   controller once dropped one at the repo root and blocked every obedient writer). `mkdir` fails
   against it forever, no writer owns it, and the reaper refuses to remove what no successful
   mkdir claimed. Operator remedy: inspect and delete the file (`rm`, not `rmdir`). The
   implementer's BLOCKED message distinguishes "held by a writer (directory)" from "corrupted
   (file)" so nobody chases a phantom writer.

5. **Add to .gitignore if needed.**
   ```
   grep -q '^\.worktrees/' .gitignore || echo '.worktrees/' >> .gitignore
   ```

6. **Set up the project.** Install dependencies per the manifest (`package.json` → pnpm/npm/yarn
   from lockfile, `Cargo.toml` → `cargo build`, `pyproject.toml` → `uv sync`/`poetry install`,
   `go.mod` → `go mod download`).

7. **Run baseline tests and record.** Capture the green state before any edits and persist it so
   the regression guard can compare later.
   ```
   orch_lib() { local n="$1" p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/$n" "$HOME/.claude/llm-orchestrator/scripts/lib/$n" "$(pwd)/.claude/scripts/lib/$n"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name "$n" -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
   L=$(orch_lib orch-detect.sh) && . "$L" && orch_regression_baseline <worktree-dir>
   ```
   This detects the test command, runs it, and writes
   `~/.llm-orchestrator/toolchain/<hash>/baseline.<tree-hash>.md` — the filename is keyed on the
   worktree's absolute path, so sibling worktrees of one repo each get their own baseline and
   cannot disarm each other's regression guard. If the suite is not green at this point, stop —
   do not proceed with edits until the baseline is clean.

## A submodule is not a worktree

`GIT_DIR != GIT_COMMON_DIR` is true inside a git submodule as well as inside a linked worktree,
so that comparison alone misidentifies one as the other. Check before acting:

```bash
git rev-parse --show-superproject-working-tree   # non-empty ⇒ you are in a submodule
```

Inside a submodule, worktree creation and cleanup are the wrong operations.

## Cleanup

Release the ownership claim **before** removing the worktree (so a concurrent prune can't race
the removal), then remove:

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
- /llm-orchestrator:dispatch task 1 against this worktree
```
