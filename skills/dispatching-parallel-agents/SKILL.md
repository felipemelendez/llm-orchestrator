---
name: dispatching-parallel-agents
description: Use when 3+ tasks are independent — no shared files, no order dependency — and can run concurrently. Fan-out only; per-task review happens after all return.
---

# Dispatching parallel agents (fan-out)

Send N agents in one batch. Collect N returns. Then review.

## The isolation invariant — read this first

**No two agents ever write the same file at the same time, and no undeclared writers ever share a tree.** Concurrent writes to one checkout race and clobber each other (a parallel agent running `git stash`/`reset`/`add` on the shared tree once silently destroyed in-flight work). So parallelism is allowed in exactly three safe shapes:

- **Read-only fan-out** — reviewers, explorers, researchers. They only read, run tests read-only, and report; they **never** edit files or mutate git. Safe to run together on the shared checkout.
- **Isolated writers** — each writing agent works in its **own git worktree** (a separate directory on its own branch), so its edits and commits cannot touch the shared tree or another agent's. You merge the branches back **sequentially** afterward. This is the default for parallel writers.
- **Declared shared-checkout writers** — only when the project rules out worktrees (an owner wants one visible tree, or waves stack on uncommitted sibling diffs a private worktree cannot see). Concurrent writers share the checkout under an explicit, controller-partitioned file-ownership discipline — see the shared-checkout steps below.

Never run two writers concurrently on one checkout *undeclared*. If you can't isolate the writers and won't declare a shared-checkout partition, run them sequentially (`dispatching-subagents`).

Every writer envelope MUST declare its mode: a worktree path (worktree mode) or the shared-checkout declaration plus an exclusive file list. An envelope with neither dispatches a writer that fails closed (`BLOCKED`).

## When this applies

- 3+ read-only agents (review/explore/research), **or** 3+ writer tasks all `Independent: yes` that you will run in **separate worktrees**.
- For writers: no two selected tasks touch the same files (so the branch merges stay trivial).
- Substrate: once the fan-out is decided, `using-workflows` chooses whether it runs on the Workflow tool or inline. This skill decides *whether* to parallelize; that one decides *where*.

## When this does NOT apply

- Tasks have dependencies → `dispatching-subagents`.
- Writers you can't (or won't) isolate in worktrees, on a project that hasn't ruled worktrees out → run sequential.
- Fewer than 3 independent tasks → sequential; coordination cost wins.
- You haven't understood the problem → don't parallelize confusion.

## Steps — read-only fan-out

1. **Build N envelopes** (`templates/dispatch-prompt.md`). State explicitly: read-only — do not edit files or run any mutating git (`stash`/`reset`/`clean`/`checkout -- `/`add`/`commit`).
2. **Send in parallel** in one message. **Wait for all returns.**
3. **Triage by Status** (below) and synthesize. Nothing to merge — they wrote nothing.

## Steps — isolated writers

1. **Confirm independence + no file overlap.** If two tasks share a file, run them sequential instead.
2. **Materialize one worktree per writer — mechanically.** Don't hand-create worktrees. Run the engine, which atomically claims, creates, and (on any failure) rolls back the whole batch:
   ```bash
   cd "$(git rev-parse --show-toplevel)"          # the engine builds paths from repo root
   MAT="${CLAUDE_PLUGIN_ROOT:-.}/scripts/orch-worktree-materialize.sh"; [[ -f "$MAT" ]] || MAT=".claude/scripts/orch-worktree-materialize.sh"
   SID="$(bash "$MAT" --sid)"                      # reads the persisted session id
   bash "$MAT" "$SID" <slug1> <slug2> <slug3>
   ```
   It prints one `<slug>\t<path>\t<branch>` line per worktree. **If it exits non-zero, do NOT dispatch** — it found a conflict (duplicate slug, path/branch exists, slug already claimed) and created nothing. Paste each printed `<path>` into the matching writer envelope as its working directory. Distinctness is now enforced by the engine, not a manual `uniq` — and the implementer still self-defends (atomic `.orch-active` mutex on entry; `BLOCKED` if handed no worktree).
3. **`TaskCreate` the set**, mark `in_progress`.
4. **Build N envelopes** (`templates/implementer-prompt.md`), each pinned to its worktree path. Each is self-contained.
5. **Send in parallel**, one message. **Wait for all N returns** before any follow-up.
6. **Triage each Status:**
   - `DONE`/`DONE_WITH_CONCERNS` → mark completed, tick the plan checkbox.
   - `BLOCKED` → route through the recovery tree in `dispatching-subagents`: missing context resumes the same agent via `SendMessage` (by agentId — the partial context survives); sibling-wait, decomposition, and model escalation re-dispatch fresh.
   - `NEEDS_CONTEXT` → answer `Ask:` via `SendMessage` to that agentId; the resume returns in the background — don't spawn a duplicate while waiting.
   - `PARTIAL` → its Stop-if fired: record `Progress:`, resume with unblocking guidance, or re-dispatch fresh with `Progress:`/`Remaining:` pasted if the transcript shows a retry storm.
7. **Review** (after all `DONE`): per-task spec+code review for high-risk surface, or `/llm-orchestrator:review` on the combined diff for low-risk.
8. **Merge back — run the integration engine (don't merge by hand).** By default it runs a speculative merge queue: every branch batch-merges onto an isolated integration worktree, the suite runs ONCE at the combined tip, and the base fast-forwards only to a suite-green SHA. On a red tip it re-tests the base state (environmental red falls back to `--serial`), bisects out the first regressor (kept on the integration branch for inspection), lands the tested-green prefix, and reports the rest `Pending` with a `Re-run:` line. Expect ONE `tests:` line shared by all landed branches, not one per branch. `--serial` restores the old merge-test-merge-test engine. Either way it releases each landed claim and removes each landed worktree:
   ```bash
   cd "$(git rev-parse --show-toplevel)"
   INTEG="${CLAUDE_PLUGIN_ROOT:-.}/scripts/orch-worktree-integrate.sh"; [[ -f "$INTEG" ]] || INTEG=".claude/scripts/orch-worktree-integrate.sh"
   bash "$INTEG" --test "<suite command>" "$SID" <slug1> <slug2> ...
   ```
   On non-zero, read the report: `CONFLICT` means the independence check was wrong (reconcile by hand), `TEST_FAILED` leaves the base at the named SHA (the merge is NOT auto-undone — inspect or revert), `EMPTY` means a writer produced nothing (that task isn't done). Resolve the named slug, then run the printed `Re-run:` command for the rest. If the project has no test runner, pass `--allow-no-tests` (the run is reported UNVERIFIED).

## Steps — shared-checkout writers (declared)

Only when the project rules out worktrees. The partition replaces the mutex, and nothing mechanical enforces it (the guard blocks destructive git but not `add`/`commit` or `Edit`) — so every requirement below is load-bearing, not ceremony.

1. **Declare the mode in every writer envelope** — the exact line `shared checkout; controller-partitioned file ownership`, followed by that writer's exclusive file list.
2. **Partition the files.** Exclusive lists must be pairwise disjoint across concurrent writers — verify before dispatch; two tasks sharing a file run sequentially instead. The lists are the only ownership boundary there is.
3. **State a writer cap** (e.g. "max 3 concurrent writers") in the plan, and hold it.
4. **No locks, no hold-markers — from anyone.** Writers take no mutex, and the controller creates none either: never drop a hold-marker at `<repo>/.orch-active` or any mutex path. A regular FILE at a mutex path is what actually broke the field deployment: `mkdir` fails against it forever, the reaper cannot release a marker no successful mkdir claimed, and the stale residue blocks every obedient writer while training the rest to bypass the lock.
5. **Writers do not mutate git.** No `add`/`commit`/`stash`/`reset` from writers — index and tree are shared; the controller owns all git operations.
6. **Triage and review** as in the isolated-writer steps. Nothing to merge — work lands directly in the shared tree.

## Sizing

- Sweet spot: 3–5 parallel agents. More than 8 → re-think the decomposition.
- Don't mix parallel writers with parallel reviewers — review is sequential to implementation.

## Continuous execution

Don't pause between fan-out and review/merge unless the user is genuinely needed.

## Output shape

```
Found:
- Dispatched <N> agents in parallel (<read-only | isolated writers>)
- DONE: <list>   DONE_WITH_CONCERNS: <list>   BLOCKED: <list>   NEEDS_CONTEXT: <list>
Merged:
- <branch> → <base> (clean)   ×N    (or "n/a — read-only")
Verify:
- <combined test command> → <line>
Next:
- /llm-orchestrator:review the combined diff (or per-task review if high-risk)
```

## Anti-patterns

- **Undeclared parallel writers on the same checkout** — the cardinal sin; isolate them in worktrees, declare a shared-checkout partition, or go sequential.
- A read-only agent that edits files or runs `git stash`/`reset`/`checkout` — it isn't read-only. The guard blocks the *destructive* git (stash/reset/clean/checkout/restore), but it does NOT block `git add`/`commit` or `Edit`/`Write` tool calls — so the envelope must forbid those too. Isolation (separate worktrees) is the real protection; the guard is only the backstop.
- Parallel agents on the same file, even in separate worktrees (merge conflicts).
- Trusting a `DONE` without a matching `Verify:`.
- Dispatching 10 agents because you can; coordination cost dominates.
- Forgetting to `TaskUpdate` → state drifts.
