---
description: Run tasks from the current plan, one at a time or in parallel.
---

You are running `/llm-orchestrator:dispatch`.

User input: $ARGUMENTS — task selector. Forms accepted:
- empty → all remaining unchecked tasks in the latest plan
- `1` → just task 1
- `1,2,4` → tasks 1, 2, and 4
- `1-3` → tasks 1 through 3

Steps:

0. Check the landing rules (`finishing-a-branch`'s `references/landing-rules.md`)
   before dispatching anything. Run the board with its check:
   ```bash
   orch_board() { local p; for p in "${CLAUDE_PLUGIN_ROOT:-}/scripts/orch-landing-board.sh" "$HOME/.claude/llm-orchestrator/scripts/orch-landing-board.sh" "$(pwd)/.claude/scripts/orch-landing-board.sh"; do [ -f "$p" ] && { printf '%s\n' "$p"; return; }; done; find "$HOME/.claude/plugins" -name orch-landing-board.sh -path '*llm-orchestrator*' 2>/dev/null | sort -V | tail -1; }
   bash "$(orch_board)" --check    # exit 3: no room for one more ticket branch (limit two, or the project's cadence.json wip_limit)
   ```
   Exit 3 → report `Blocked:` with the branches it names and land one first.
   Any other non-zero exit means the check could not run: stop and say so;
   never dispatch on an unchecked count.
   The plan's `Requires landed:` naming a branch or PR not yet on main
   (`git merge-base --is-ancestor <sha> <base>` false) → land that first and
   cut this branch from main afterwards. A READY branch on the board is landed
   before any new dispatch.

1. Load the latest plan from `docs/llm-orchestrator/plans/` (or accept `--plan <path>` if passed).

2. Resolve `$ARGUMENTS` into a task set.

3. Decide routing per task by reading its `Independent:` line:
   - **Three or more** selected tasks, all `Independent: yes`, no shared files → invoke `dispatching-parallel-agents` (one batch; review happens **after** the batch, not per task — that skill's step 6 does per-task review for high-risk surface and a combined-diff review otherwise). Below three, coordination cost beats the speedup and the skill itself declines the work, so route them sequentially.
   - One task, or tasks with dependencies → invoke `dispatching-subagents` (sequential, with a review after each task).
   - Mixed → run the independent set first in parallel, then sequential for the rest.

   Before any parallel batch, satisfy that skill's hard precondition: **every
   writer envelope declares its isolation mode.** Default: run
   `scripts/orch-worktree-materialize.sh` first and give each agent its own
   worktree. Only when the project rules out worktrees, use the declared
   shared-checkout mode ("Shared-checkout writers (declared)" in
   `dispatching-parallel-agents`): the exact line
   `shared checkout; controller-partitioned file ownership` plus that writer's
   exclusive files, pairwise-disjoint lists across writers, a stated writer
   cap, and no locks or hold-markers from anyone. "Never dispatch two implementers against the same
   file" alone is weaker than either mode and does not substitute for one —
   undeclared writers in one checkout race on every file, not just the ones
   they both edit. An envelope declaring neither mode dispatches a writer that
   fails closed (BLOCKED).

   For a multi-tier plan, drive it through `executing-plans` rather than calling
   the dispatch skills directly: it owns the post-group assertions and the
   tier-boundary handoff that routing straight to a dispatch skill skips.

4. Follow the invoked skill exactly. After each task completes, tick its heading checkbox in the plan file.

5. Continuous execution: do not ask the user between tasks. Stop only on unresolvable `BLOCKED`, genuine ambiguity, or all-done.

6. When the task set is empty, report:

```
Found:
- Dispatched <N> subagents
- DONE: <list of task numbers>
- DONE_WITH_CONCERNS: <list>
- BLOCKED: <list, if any>
Next:
- merge the base in, /llm-orchestrator:verify, /llm-orchestrator:review on the whole branch
- then /llm-orchestrator:finish in this session (landing rule 2)
```

Constraints:
- Never dispatch two implementers against the same file.
- Never trust a `DONE` without a `Verify:` line that actually ran.
- Do not pass file paths as "context" — paste the content.
