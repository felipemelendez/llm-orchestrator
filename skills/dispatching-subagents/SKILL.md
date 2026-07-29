---
name: dispatching-subagents
description: Use when running plan tasks sequentially with per-task two-stage review — the default for tasks with dependencies, sensitive code, or shared files another task changed.
---

# Dispatching subagents (sequential, per-task review)

Run one task to completion before the next. Review each task's diff before moving on.

This is also the safe default whenever writers share a checkout: because tasks run one at a time
on the same tree, they cannot race or clobber each other. Only reach for
`dispatching-parallel-agents` when the writers are isolated in separate worktrees (or the fan-out
is read-only). When in doubt, stay here — sequential never loses work.

## When to use

- A task that depends on prior tasks (the plan marks `Independent: no` or `depends on N`).
- A task that touches files another task already changed.
- A single task small enough to do solo but big enough to want review.
- Any task where shipping the wrong thing is worse than shipping nothing.

## When NOT to use

- 3+ tasks all marked `Independent: yes` with no shared files → use `dispatching-parallel-agents`.
- Tasks small enough to inline (a typo, a one-line rename).
- Tasks where you don't yet understand the problem.

## State tracking

Before the first dispatch, `TaskCreate` one task per plan task. Mark each `in_progress` via `TaskUpdate` when you dispatch, `completed` when the inner loop finishes. This is your state board.

## Inner loop (per task)

```
For each task:
  1. Dispatch the orch-implementer agent with templates/implementer-prompt.md.
     - Paste the task text, the files-in-scope list, and the Verify command.
     - Paste the relevant `## Conventions` section of ./CLAUDE.md into the conventions slot.
     - Paste the `## Decisions` section of ./CLAUDE.md into the decisions slot.
     - Leave the agent's declared model alone unless the task gives you a reason to override; effort is not pinned — it inherits the session preference.

  2. Read the returned Status. Note the agentId from the spawn result — resume
     addresses the agent by ID (names collide on serial reuse; collisions refuse).
     - DONE                → go to step 3
     - DONE_WITH_CONCERNS  → record concerns, go to step 3
     - BLOCKED             → run the recovery tree (below)
     - NEEDS_CONTEXT       → answer the Ask: by SendMessage to that agentId —
                             the agent resumes with its full working context
                             (files read, hypotheses formed) instead of paying
                             for a cold re-dispatch that re-derives everything.
                             The resume returns in the background: continue when
                             its result arrives; never spawn a duplicate while
                             waiting.
     - PARTIAL             → the task's Stop-if fired. Record Progress:, then
                             either resume via SendMessage with the unblocking
                             guidance (default — the partial work and context
                             survive), or, if the transcript shows repeated
                             failed attempts (retry-cap warning), re-dispatch
                             FRESH with Progress:/Remaining: pasted into the
                             new envelope — a context polluted by failures
                             hurts more than a cold start costs.

  3. Dispatch orch-spec-reviewer with templates/spec-reviewer-prompt.md.
     - Paste the spec, the plan task, and `git diff` since this task's first commit.
     - Reviewer reports everything with a confidence tag; you filter below 0.8 into `Notes:`.

  4. Read the verdict:
     - Ready: yes          → go to step 5
     - Ready: with-fixes   → Critical issues → re-dispatch implementer with the fix list
                             Important/Minor only → record and continue to step 5
     - Ready: no           → re-dispatch implementer with the full issue list

  5. Dispatch orch-code-reviewer with templates/code-reviewer-prompt.md.
     - Paste the diff and the relevant CLAUDE.md section.

  6. Same verdict routing as step 4.

  7. Mark the task `completed` via `TaskUpdate`. Tick the plan file's per-task header checkbox.

     Each task in a plan has a task-level checkbox on its `### N. <name>` line:
     ```
     ### 3. Add limiter middleware  - [ ]
     ```

     Use the `Edit` tool (or sed for batch) to flip `- [ ]` → `- [x]` on that task's heading line only. Sub-step checkboxes inside the task body are progress notes; do not count them.

     Sed one-liner for task N (portable):
     ```bash
     # GNU
     sed -i  -E "/^### ${N}\. /s/- \[ \]/- [x]/" <plan-file>
     # BSD/macOS
     sed -i '' -E "/^### ${N}\. /s/- \[ \]/- [x]/" <plan-file>
     ```

     Verify after each tick: `grep -cE '^### [0-9]+\. .*- \[x\]' <plan-file>` should equal the number of completed tasks. This count is the only durable state across `/clear`.

  8. Continue to next task. Do not stop to ask the user.
```

## BLOCKED recovery tree

When an implementer returns `BLOCKED`, route by what they `Need:`:

1. **Missing context** (file content, decision, convention): send it via `SendMessage` to the blocked agent's agentId — resume, don't re-dispatch. The agent kept its full history (files already read, the exact point it stopped), so it continues instead of redoing the task from zero; redo-from-zero is itself a step-repetition failure. The resume returns in the background — wait for its result, never spawn a duplicate meanwhile. Fall back to a fresh dispatch (context pasted into the envelope) only if the resume errors or the agent is gone.
2. **Waiting on a sibling task** (needs output of a not-yet-run plan task): dispatch the sibling first; once `DONE`, paste its diff or artifact into the blocked task's envelope and re-dispatch fresh. (Fresh on purpose: the sibling's output changes the task's ground truth, and the blocked agent's stale assumptions would fight it.)
3. **Task is too large / ambiguous**: decompose into 2–3 smaller tasks, update the plan file, dispatch task A. Fresh dispatches — decomposition redefines the work.
4. **Implementer can't reason about it**: re-dispatch with a more capable model. This cannot be a resume — SendMessage has no model parameter; a fresh dispatch is the only way to change the model.
5. **Genuinely needs the user**: that's where you stop. Report `Blocked:` with the question.

Don't try (1) → (5) blindly. Pick one based on what the `Need:` line says.

**Stale-mutex corner.** If a dispatch returns `BLOCKED — Need: a worktree not already being written by another agent` and no implementer is currently running in that worktree, the previous holder died without releasing. The reaper hook usually frees it at that agent's stop; if it could not (ambiguous parallel case), release by hand — `rmdir <worktree>/.orch-active` — and re-dispatch.

## Continuous execution

Run all tasks in the set without pausing to ask the user. The only acceptable stops are:
- All tasks `DONE` or `DONE_WITH_CONCERNS`.
- An unresolvable `BLOCKED` (after the recovery tree).
- A reviewer's `no` verdict that the implementer can't fix in 2 attempts.

If you find yourself wanting to ask "should I proceed?" — the answer is yes.

## Model selection (per task)

Each agent ships with a model chosen for its role — see the table in
[`docs/anthropic-ecosystem.md`](../../docs/anthropic-ecosystem.md). Effort is deliberately
NOT pinned (it inherits the session preference — see the same doc for the evidence).
Leave both alone unless a dispatch gives you a reason to override.

When you do override, pick the axis that matches the failure: the agent **didn't know
enough** → raise the model; it **didn't try hard enough** (skipped a file, didn't run the
tests, stopped early) → raise the effort. The Agent tool accepts a per-invocation `model`;
it does not accept `effort`, so a one-off effort change means routing through a workflow
script or adding `ultrathink` to the dispatch prompt.

Never dispatch a reviewer on a weaker model than the implementer whose work it reviews.

## Output shape

After the task set completes:

```
Found:
- Dispatched <N> tasks sequentially
- DONE: <list of task numbers>
- DONE_WITH_CONCERNS: <list, with one-line concerns>
- BLOCKED: <list, if any, with Need:>
Concerns:
- <one-line per recorded concern>
Verify:
- <combined test command> → <line>
Next:
- /llm-orchestrator:verify, then /llm-orchestrator:finish
```

## Anti-patterns

- Dispatching the spec-reviewer before the implementer is DONE.
- Running both review stages from a single subagent.
- Asking the user "ready to proceed to task 3?".
- Stopping after one BLOCKED without trying the recovery tree.
- Dispatching the implementer with a file path instead of pasted content.
