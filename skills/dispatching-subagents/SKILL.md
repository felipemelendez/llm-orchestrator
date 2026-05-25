---
name: dispatching-subagents
description: Use when running one or more plan tasks sequentially with per-task two-stage review. The default for any task that has dependencies, touches sensitive code, or follows another task that already changed shared files.
---

# Dispatching subagents (sequential, per-task review)

Run one task to completion before the next. Review each task's diff before moving on.

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
     - Model: sonnet (default) or haiku for mechanical tasks.

  2. Read the returned Status:
     - DONE                → go to step 3
     - DONE_WITH_CONCERNS  → record concerns, go to step 3
     - BLOCKED             → run the recovery tree (below)
     - NEEDS_CONTEXT       → answer the Ask:, re-dispatch (step 1)

  3. Dispatch orch-spec-reviewer with templates/spec-reviewer-prompt.md.
     - Paste the spec, the plan task, and `git diff` since this task's first commit.
     - Confidence threshold: ≥80%.

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

1. **Missing context** (file content, decision, convention): paste it inline and re-dispatch with same model.
2. **Waiting on a sibling task** (needs output of a not-yet-run plan task): dispatch the sibling first; once `DONE`, paste its diff or artifact into the blocked task's envelope and re-dispatch. If the sibling is later in the plan, hoist it up.
3. **Task is too large / ambiguous**: decompose into 2–3 smaller tasks, update the plan file, dispatch task A.
4. **Implementer can't reason about it**: re-dispatch with a more capable model (sonnet → opus).
5. **Genuinely needs the user**: that's where you stop. Report `Blocked:` with the question.

Don't try (1) → (5) blindly. Pick one based on what the `Need:` line says.

## Continuous execution

Run all tasks in the set without pausing to ask the user. The only acceptable stops are:
- All tasks `DONE` or `DONE_WITH_CONCERNS`.
- An unresolvable `BLOCKED` (after the recovery tree).
- A reviewer's `no` verdict that the implementer can't fix in 2 attempts.

If you find yourself wanting to ask "should I proceed?" — the answer is yes.

## Model selection (per task)

- **Haiku**: mechanical edits (rename a symbol, add a `Date:` header, sort imports).
- **Sonnet** (default): typical implementation, debugging, refactoring.
- **Opus**: design-shaped tasks, architecture questions, multi-file rewrites where decisions propagate.

The implementer agent picks; you can override via the dispatch envelope's `model:` field.

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
- /verify, then /finish
```

## Anti-patterns

- Dispatching the spec-reviewer before the implementer is DONE.
- Running both review stages from a single subagent.
- Asking the user "ready to proceed to task 3?".
- Stopping after one BLOCKED without trying the recovery tree.
- Dispatching the implementer with a file path instead of pasted content.
