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
- Anything you can finish yourself in a handful of tool calls. A subagent buys a fresh context that has to rediscover what you already know.
- Double-checking your own work. The reviewers here read *another* agent's diff with no memory of writing it; a subagent sent to re-read yours is self-critique with extra steps and no extra eyes.
- Tasks where you don't yet understand the problem.

## State tracking

Record enough per task that a fresh controller after `/clear` knows both what is
done and where an unfinished task resumes. A tick is not enough — it cannot say
"round 2 of 3, two findings addressed, one open".

```
### 4. Add the retry breaker  - [x]   complete (commits a1b2c3d..d4e5f6a, review clean)
### 5. Wire the breaker in    - [ ]   fix round 2/3 (2 addressed, 1 open)
### 6. Document the knob      - [x]   complete (commits d4e5f6a..99f0e12, 1 parked)
```

After a compaction, trust the plan file and `git log` over your own
recollection. A controller that lost its place and re-dispatched an already
completed sequence is the most expensive failure available to you.

Before the first dispatch, `TaskCreate` one task per plan task. Mark each `in_progress` via `TaskUpdate` when you dispatch, `completed` when the inner loop finishes. This is your state board.

## Inner loop (per task)

```
For each task:
  1. Dispatch the orch-implementer agent with templates/implementer-prompt.md.
     - Declare the isolation mode in the working-directory slot: a worktree path, or the exact line `shared checkout; controller-partitioned file ownership` plus the task's exclusive files, or the exact line `main checkout — you are the only writer` for a solo sequential task. A writer envelope declaring neither mode fails closed (BLOCKED).
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
     - Ready: with-fixes   → Critical present → enter the fix loop below
                             Important only  → enter the fix loop below
                             Minor only      → record in the plan file, continue to step 5
     - Ready: no           → enter the fix loop below

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

**Stale-mutex corner.** If a dispatch returns `BLOCKED — Need: a worktree not already being written by another agent` and no implementer is currently running in that worktree, the previous holder died without releasing. The reaper hook usually frees it at that agent's stop; if it could not (ambiguous parallel case), release by hand — `rmdir <worktree>/.orch-active` — and re-dispatch. But first check the shape of what is at the path: a held mutex is only ever a *directory* created by `mkdir`. A regular file at `<worktree>/.orch-active` is protocol corruption (an improvised hold-marker the tooling never defined), not a held lock — no writer holds the tree, the reaper cannot release a marker no successful mkdir claimed, and `mkdir` will fail against it forever. Remedy: inspect and delete the file (`rm`, not `rmdir`); don't chase a phantom writer, and never create such a file yourself.

## The fix loop, and how it ends

A review that finds something starts a loop. The loop needs a bound, an
escalation, and a disposition for what survives — otherwise a single contested
finding runs until the context does.

**Three rounds per task, maximum.**

- **Rounds 1–2** — resume the same implementer by `agentId` with the open
  findings pasted verbatim. It keeps the files it read and the reasoning it
  formed; a cold re-dispatch pays to rederive all of it.
- **Round 3** — dispatch a *fresh* implementer one model tier up: "a prior
  implementer attempted this task twice; you own it now." Two failed resumes is
  evidence the context is not the problem.

The bound is deliberately tight. A longer budget buys a few more contested
findings at the cost of a round of implementer plus reviewer each time, and the
thing that was missing here was never a bigger budget — it was knowing what to
do with a finding that survives.

**Re-review only the fix.** Diff from the head the previous review saw, not from
the task base. For each open finding, the reviewer returns exactly one of
`ADDRESSED` or `NOT ADDRESSED` — and *attempted* is not addressed; the specific
defect has to be gone. New breakage introduced by the fix diff joins the open
list. Anything the reviewer notices outside the fix range is recorded and does
not extend this loop; a reviewer discovering fresh material on untouched code is
how a bounded loop becomes an unbounded one.

**At the cap, stop dispatching and adjudicate.** Every still-open finding gets
exactly one disposition, recorded in the plan file:

| Disposition | When |
|---|---|
| `parked — contested — ruling: <why the code stands>` | The finding is wrong or arguable, and you can say why. |
| `parked — real, not load-bearing — ruling: deferred` | Real, but nothing later builds on it. |
| `BLOCKED` | Real **and** load-bearing — a later task depends on it, or it exposes a defect in the plan. Stop and report to the user with the finding, the plan text it collides with, and the fix history. |

Adjudicate only at the cap. Adjudicating early to end a loop is pre-judging with
a different name. A finding that is silently dropped is the one failure mode
this section exists to prevent, so every disposition is a written line.

**Never fix a finding yourself in the controller session.** Your context is for
coordination, and a controller fix skips review entirely.

## After the last task

One fix wave, not one fixer per finding. Dispatch a single implementer with the
complete findings list from the final review — per-finding fixers each rebuild
the same context and re-run the same suite, and that cost exceeds the tasks
themselves. Then exactly one scoped re-review of the fix diff. There is no
second wave; anything still open goes through the adjudication table above.

## Continuous execution

Run all tasks in the set without pausing to ask the user. The only acceptable stops are:
- All tasks `DONE` or `DONE_WITH_CONCERNS`.
- An unresolvable `BLOCKED` (after the recovery tree).
- A reviewer's `no` verdict that survives the three-round fix loop and adjudicates to `BLOCKED`.

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

## Dispatch hygiene

Paste what the task needs: the task text, its interfaces, the conventions and
decisions it must honour, and the plan's global constraints. Nothing else.

Do not accumulate. Pasting "state after tasks 1–3" into task 4, and 1–4 into
task 5, ends with a dispatch that is almost entirely history the implementer
cannot act on. Paste-don't-reference applies to what the task needs, not to
everything that has happened.

## Anti-patterns

- Computing a task's diff with `HEAD~1`. A task is often several commits; `HEAD~1` silently reviews only the last one. Diff from the recorded task base.

- Dispatching the spec-reviewer before the implementer is DONE.
- Running both review stages from a single subagent.
- Asking the user "ready to proceed to task 3?".
- Stopping after one BLOCKED without trying the recovery tree.
- Dispatching the implementer with a file path instead of pasted content.
