---
name: dispatching-parallel-agents
description: Use when 3+ tasks are independent — no shared files, no order dependency — and can run concurrently. Fan-out only; per-task review happens after all return.
---

# Dispatching parallel agents (fan-out)

Send N agents in one batch. Collect N returns. Then review.

## The isolation invariant — read this first

**No two agents ever write the same file at the same time, and no undeclared writers ever share a tree.** Concurrent writes to one checkout race and clobber each other — a parallel agent running `git stash`/`reset`/`add` on the shared tree once silently destroyed in-flight work. So parallelism is allowed in exactly three safe shapes:

- **Read-only fan-out** — reviewers, explorers, researchers. They only read, run tests read-only, and report; they never edit files or mutate git. Safe to run together on the shared checkout.
- **Isolated writers** — each writing agent works in its **own git worktree** (separate directory, own branch), so its edits and commits physically cannot touch the shared tree or another agent's. Branches merge back sequentially afterward. This is the default for parallel writers.
- **Declared shared-checkout writers** — only when the project rules out worktrees (an owner wants one visible tree, or waves stack on uncommitted sibling diffs a private worktree cannot see). Writers share the checkout under an explicit, controller-partitioned file-ownership discipline — see the shared-checkout steps below.

Every writer envelope declares its mode: a worktree path, or the shared-checkout declaration plus an exclusive file list. An envelope with neither dispatches a writer that fails closed (`BLOCKED`). If you can't isolate the writers and won't declare a partition, run them sequentially (`dispatching-subagents`) — sequential never loses work.

## When (not) to apply

3+ read-only agents, or 3+ writer tasks all `Independent: yes` in separate worktrees, with no two tasks touching the same file (so the merges stay trivial). Not for: tasks with dependencies (sequential), fewer than 3 tasks (coordination cost beats the speedup), writers you can't or won't isolate on a project that allows worktrees (sequential), or a problem you haven't understood — don't parallelize confusion. Once the fan-out is decided, `using-workflows` chooses the substrate (Workflow tool or inline): this skill decides *whether*, that one decides *where*.

## Read-only fan-out

Build N envelopes (`templates/dispatch-prompt.md`), each stating explicitly: read-only — do not edit files or run any mutating git (`stash`/`reset`/`clean`/`checkout --`/`add`/`commit`). Spell that out because the destructive-git guard is only a backstop: it blocks stash/reset/clean/checkout/restore but not `git add`/`commit` or `Edit`/`Write` tool calls. Send in one message, wait for all returns, triage by Status, synthesize. Nothing to merge — they wrote nothing.

## Isolated writers

1. **Confirm independence and no file overlap.** Two tasks sharing a file run sequentially instead — separate worktrees just turn that race into a merge conflict.
2. **Materialize one worktree per writer with the engine — not by hand.** It atomically claims, creates, and rolls back the whole batch on any failure:
   ```bash
   cd "$(git rev-parse --show-toplevel)"          # the engine builds paths from repo root
   MAT="${CLAUDE_PLUGIN_ROOT:-.}/scripts/orch-worktree-materialize.sh"; [[ -f "$MAT" ]] || MAT=".claude/scripts/orch-worktree-materialize.sh"
   SID="$(bash "$MAT" --sid)"                      # reads the persisted session id
   bash "$MAT" "$SID" <slug1> <slug2> <slug3>
   ```
   It prints one `<slug>\t<path>\t<branch>` line per worktree. Non-zero exit → it found a conflict (duplicate slug, existing path/branch, already-claimed slug) and created nothing — do not dispatch. The implementer still self-defends: atomic `.orch-active` mutex on entry, `BLOCKED` if handed neither a worktree nor a shared-checkout declaration.
3. **`TaskCreate` the set**, mark `in_progress`.
4. **Build N envelopes** (`templates/implementer-prompt.md`), each pinned to its printed worktree path, each self-contained.
5. **Send in parallel, one message. Wait for all N returns** before any follow-up.
6. **Triage each Status:** `DONE`/`DONE_WITH_CONCERNS` → mark completed, tick the plan checkbox. `BLOCKED` → the recovery tree in `dispatching-subagents` (missing context resumes the same agent via `SendMessage` by agentId — its partial context survives; sibling-wait, decomposition, and model escalation re-dispatch fresh). `NEEDS_CONTEXT` → answer the `Ask:` via `SendMessage`; the resume returns in the background — don't spawn a duplicate while waiting. `PARTIAL` → record `Progress:`, resume with unblocking guidance, or re-dispatch fresh with `Progress:`/`Remaining:` pasted if the transcript shows a retry storm.
7. **Review** after all are done: per-task spec+code review for high-risk surface, or `/llm-orchestrator:review` on the combined diff for low-risk.
8. **Merge back with the integration engine — don't merge by hand:**
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   INTEG="${CLAUDE_PLUGIN_ROOT:-.}/scripts/orch-worktree-integrate.sh"; [[ -f "$INTEG" ]] || INTEG=".claude/scripts/orch-worktree-integrate.sh"
   bash "$INTEG" --test "<suite command>" "$SID" <slug1> <slug2> ...
   ```
   By default it runs a speculative merge queue: every branch batch-merges onto an isolated integration worktree, the suite runs once at the combined tip, and the base fast-forwards only to a suite-green SHA — so expect one `tests:` line shared by all landed branches, not one per branch. On a red tip it re-tests the base state (environmental red falls back to `--serial`), bisects out the first regressor (kept on the integration branch for inspection), lands the tested-green prefix, and reports the rest `Pending` with a `Re-run:` line. On non-zero, read the report: `CONFLICT` means the independence check was wrong (reconcile by hand); `TEST_FAILED` leaves the base at the named SHA — the merge is not auto-undone, inspect or revert; `EMPTY` means a writer produced nothing and that task isn't done. `--serial` restores the merge-test-per-branch engine; `--allow-no-tests` covers projects with no runner (the run is reported UNVERIFIED). Either way it releases each landed claim and removes each landed worktree.

## Shared-checkout writers (declared)

Only when the project rules out worktrees. The partition replaces the mutex, and nothing mechanical enforces it — the guard blocks destructive git but not `add`/`commit` or `Edit` — so every requirement here is load-bearing, not ceremony:

1. **Declare the mode in every writer envelope** — the exact line `shared checkout; controller-partitioned file ownership`, followed by that writer's exclusive file list.
2. **Partition the files.** Exclusive lists must be pairwise disjoint across concurrent writers — verify before dispatch; two tasks sharing a file run sequentially instead. The lists are the only ownership boundary there is.
3. **State a writer cap** in the plan (e.g. "max 3 concurrent writers") and hold it.
4. **No locks, no hold-markers — from anyone.** Writers take no mutex, and the controller creates none either: never drop a hold-marker at `<repo>/.orch-active` or any mutex path. A regular file at a mutex path is what actually broke the field deployment: `mkdir` fails against it forever, the reaper cannot release a claim no successful mkdir made, and the stale residue blocks every obedient writer while training the rest to bypass the lock.
5. **Writers do not mutate git.** Index and tree are shared, so no `add`/`commit`/`stash`/`reset` from writers — the controller owns all git operations.
6. **Triage and review** as in the isolated-writer steps. Nothing to merge — work lands directly in the shared tree.

## Sizing and cadence

Sweet spot is 3–5 agents; past 8, re-think the decomposition — coordination cost dominates. Review is sequential to implementation, so don't mix parallel writers with parallel reviewers. Don't pause between fan-out and review/merge unless the user is genuinely needed, don't trust a `DONE` without a matching `Verify:`, and keep `TaskUpdate` current or state drifts.

## Output shape

```
Found:
- Dispatched <N> agents in parallel (<read-only | isolated writers | shared-checkout>)
- DONE: <list>   DONE_WITH_CONCERNS: <list>   BLOCKED: <list>   NEEDS_CONTEXT: <list>
Merged:
- <branch> → <base> (clean)   ×N    (or "n/a — read-only / shared checkout")
Verify:
- <combined test command> → <line>
Next:
- /llm-orchestrator:review the combined diff (or per-task review if high-risk)
```
