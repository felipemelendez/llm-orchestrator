---
name: dispatching-subagents
description: Use when running plan tasks sequentially with per-task two-stage review — the default for tasks with dependencies, sensitive code, or shared files another task changed.
---

# Dispatching subagents (sequential, per-task review)

Run one task to completion before the next; review each task's diff before moving on. This is also the safe default whenever writers would share a checkout — one writer at a time cannot race or clobber. Reach for `dispatching-parallel-agents` only when the writers are isolated in separate worktrees or the fan-out is read-only. When in doubt, stay here: sequential never loses work.

Not for: 3+ independent tasks with no shared files (parallel wins), work small enough to inline or finish yourself in a few tool calls (a subagent is a fresh context that must rediscover what you already know), re-checking your own diff (the reviewers here read *another* agent's work with no memory of writing it — a subagent re-reading yours is self-critique with extra steps), or a problem you don't yet understand.

## State

`TaskCreate` one task per plan task before the first dispatch; `TaskUpdate` as you go. The durable copy is the plan file: flip each task's `### N. <name>  - [ ]` heading checkbox to `- [x]` on completion — the heading checkbox only; sub-step boxes are progress notes and counting them corrupts the resume count. Record enough per task that a fresh controller after `/clear` knows where an unfinished task resumes ("fix round 2/3, one finding open", not just a tick). After compaction, trust the plan file and `git log` over your recollection — a controller that lost its place and re-dispatched a completed sequence is the most expensive failure available to you.

## Per task

1. **Dispatch `orch-implementer`** with `templates/implementer-prompt.md`. The working-directory slot declares the isolation mode: a worktree path, or the exact line `shared checkout; controller-partitioned file ownership` plus the task's exclusive files, or the exact line `main checkout — you are the only writer` for a solo sequential task. An envelope declaring neither dispatches a writer that fails closed (BLOCKED). Paste the task text, files in scope, Verify command, and the relevant `## Conventions` and `## Decisions` sections of ./CLAUDE.md — content, not file paths. Leave the agent's declared model and effort alone unless the task gives you a reason (see Model and effort).

2. **Route the Status.** Note the agentId from the spawn result — resume addresses agents by ID; names collide on serial reuse.
   - `DONE` / `DONE_WITH_CONCERNS` → record any concerns, go to review.
   - `BLOCKED` → the recovery tree below.
   - `NEEDS_CONTEXT` → answer the `Ask:` via `SendMessage` to that agentId. The agent resumes with everything it already read and reasoned; a cold re-dispatch pays to re-derive all of it. The resume returns in the background — never spawn a duplicate while waiting.
   - `PARTIAL` → its Stop-if fired. Record `Progress:`, then resume with unblocking guidance (the partial work and context survive) — unless the transcript shows repeated failed attempts (a retry-cap warning), in which case re-dispatch fresh with `Progress:`/`Remaining:` pasted into the new envelope: a context polluted by failures hurts more than a cold start costs.

3. **Review in two stages**, each in a fresh subagent so no context reviews its own reasoning. First `orch-spec-reviewer` (`templates/spec-reviewer-prompt.md`) — paste the spec, the plan task, and the diff since this task's first commit. Not `HEAD~1`: a task is often several commits, and `HEAD~1` silently reviews only the last one. Only after the spec verdict clears, `orch-code-reviewer` (`templates/code-reviewer-prompt.md`) with the diff and the relevant CLAUDE.md section. Reviewers tag every finding with a confidence; you demote anything below 0.8 into `Notes:` — the threshold lives in your filter, never in the reviewer's instructions, because a reviewer told to withhold loses recall. Verdict routing per stage: `Ready: yes` → proceed; Critical or Important findings, or `Ready: no` → the fix loop; Minor only → record in the plan file and proceed.

4. **Tick and continue.** Mark the task `completed` via `TaskUpdate`, flip its plan heading checkbox, start the next task without asking the user.

## BLOCKED recovery

Route by what the `Need:` line says — don't try branches in order:

1. **Missing context** (file content, decision, convention) → `SendMessage` it to the blocked agent's agentId. Resume, don't re-dispatch: the agent kept its full history and continues from the exact point it stopped; redo-from-zero is itself a step-repetition failure. Fall back to a fresh dispatch (context pasted into the envelope) only if the resume errors or the agent is gone.
2. **Waiting on a sibling task** → dispatch the sibling first; once DONE, re-dispatch the blocked task *fresh* with the sibling's output pasted. Fresh on purpose: the sibling's output changes the task's ground truth, and the blocked agent's stale assumptions would fight it.
3. **Too large / ambiguous** → decompose into 2–3 smaller tasks, update the plan file, dispatch fresh — decomposition redefines the work.
4. **Can't reason about it** → re-dispatch on a more capable model. Necessarily fresh: `SendMessage` has no model parameter.
5. **Genuinely needs the user** → stop. Report `Blocked:` with the question.

**Stale-mutex corner.** `BLOCKED — Need: a worktree not already being written by another agent`, with no implementer currently running there, means the previous holder died without releasing. The reaper hook usually frees it at that agent's stop; if it could not, check the *shape* of what is at `<worktree>/.orch-active` before acting. A held mutex is only ever a directory created by `mkdir` — release with `rmdir` and re-dispatch. A regular file at that path is protocol corruption (an improvised hold-marker the tooling never defined): no writer holds the tree, the reaper cannot release a claim no successful mkdir made, and `mkdir` will fail against it forever. Inspect and delete the file with `rm`; don't chase a phantom writer, and never create such a file yourself.

## The fix loop

Bounded at **three rounds per task**. The failure this bound prevents is a single contested finding looping until the context runs out — and the cure was never a bigger budget, it was a disposition for what survives.

- Rounds 1–2: resume the same implementer by agentId with the open findings pasted verbatim — it keeps the files it read and the reasoning it formed.
- Round 3: a *fresh* implementer one model tier up ("a prior implementer attempted this task twice; you own it now"). Two failed resumes is evidence the context is not the problem.

Re-review only the fix: diff from the head the previous review saw, not the task base. Each open finding comes back exactly `ADDRESSED` or `NOT ADDRESSED` — attempted is not addressed; the specific defect has to be gone. New breakage introduced by the fix diff joins the open list; anything the reviewer notices on untouched code is recorded but does not extend the loop — fresh material on old code is how a bounded loop becomes an unbounded one.

At the cap, stop dispatching and adjudicate. Every still-open finding gets one written disposition in the plan file: `parked — contested — ruling: <why the code stands>` when the finding is wrong or arguable and you can say why; `parked — real, not load-bearing — ruling: deferred` when it's real but nothing later builds on it; or `BLOCKED` when it's real *and* load-bearing (a later task depends on it, or it exposes a plan defect) — stop and report to the user with the finding, the plan text it collides with, and the fix history. Adjudicate only at the cap — adjudicating early to end a loop is pre-judging with a different name — and never drop a finding silently; the written line per finding is the point of this section.

**Never fix a finding yourself in the controller session.** Your context is for coordination, and a controller fix skips review entirely.

## After the last task

One fix wave, not one fixer per finding: dispatch a single implementer with the complete findings list from the final review (per-finding fixers each rebuild the same context and re-run the same suite — a cost exceeding the tasks themselves), then exactly one scoped re-review of the fix diff. Anything still open goes through the adjudication table; there is no second wave.

## Continuous execution

Run the whole set without pausing. Legitimate stops: all tasks done, an unresolvable BLOCKED after the recovery tree, or a `no` verdict that survives the fix loop and adjudicates to BLOCKED. If you find yourself wanting to ask "should I proceed?" — the answer is yes.

## Model and effort

Agents ship with role-appropriate models (see `docs/anthropic-ecosystem.md`); effort deliberately inherits the session preference. Override only when a dispatch gives you a reason, on the axis that matches the failure: the agent didn't *know* enough → raise the model; it didn't *try* hard enough (skipped a file, didn't run the tests, stopped early) → raise the effort. The Agent tool takes a per-invocation `model` but no `effort`, so a one-off effort change routes through a workflow script or `ultrathink` in the prompt. Never dispatch a reviewer on a weaker model than the implementer it reviews.

## Dispatch hygiene

Paste what the task needs — its text, interfaces, conventions, decisions, and the plan's global constraints — and nothing else. Don't accumulate: pasting "state after tasks 1–3" into task 4, and 1–4 into task 5, ends with an envelope that is mostly history the implementer cannot act on.

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
