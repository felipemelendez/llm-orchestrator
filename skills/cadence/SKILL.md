---
name: cadence
description: Use when changing production code or tests in projects with enabled docs/llm-orchestrator/cadence.json. Not for ordinary documentation or questions.
license: MIT
compatibility: Claude Code or Codex; bash 3.2+, git and python3
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/cadence-detect.sh *)
---

# The cadence

Read the project's `docs/llm-orchestrator/LAWS.md` and configuration first.
On Codex also read its `CODEX.md` for installed tools, evidence and trust.
Absent/disabled cadence and ordinary documentation/questions are out of scope.
User instructions and project amendments govern.

Check `workflow`: `proportional` uses the paths below. Missing or `legacy`
uses the [legacy procedure](CADENCE.md#legacy-procedure). Unknown values are a
configuration error; do not silently choose the lighter process.

## Proportional paths

Choose by impact, uncertainty, contracts and reversibility, not line count.
Reassess if scope grows. Honour requested reviewers and models.

| Path | Use when | Required work |
|---|---|---|
| Simple | Clear, local, reversible and low risk | Edit, inspect the full diff, run applicable existing checks, deliver. |
| Standard | Bounded behavior with meaningful edge cases | State acceptance criteria, implement, check, run the Standard review (`requesting-code-review`), resolve findings. |
| Full | Interacting architecture, difficult recovery, substantial uncertainty or consequential contracts | Review the spec, implement, run the Full review, resolve findings, independently verify. |

Simple needs no extra agent, spec, worktree, report or invented test; Standard
adds only one independent review and fixes for its findings.
Writers can inspect diffs and run checks, but cannot provide independent
review or gates.

Read the [Full path](CADENCE.md#proportional-full-path) and role briefs only
when required. Simple and Standard need only this page.

## Check once, with evidence

Use relevant checks and meaningful regression tests. Honour build/dependency
restrictions. No default broad suites or mutation batteries for Simple/Standard.
Change existing tests only when the task says so; report each change and why.

Run each check as one plain foreground command, so it appears in the transcript
as itself. A Stop hook reads that transcript and warns if a reply says
`Verification: PASS` when no check ran and passed in the turn. It only warns,
and it reads only that label — never the prose around it.

Reuse checks across turns/commits preserving covered inputs. Rerun for changes,
failures or unresolved concerns. Unrelated green cannot erase failure.
Use the shared completion line: `Verification: PASS — checks and scope`,
`Verification: PENDING — remaining validation`, or
`Verification: BLOCKED — unavailable prerequisite`.
For low-risk work with no meaningful automated check, use
`Verification: NOT APPLICABLE — reason; manual diff inspection performed`.
This cannot waive failures, uncertain writes or stale/unavailable required checks.

## Finish and clean up

Keep maintained specifications, research conclusions, design decisions and
runbooks. Reviews, temporary plans/logs and disposable copies belong outside Git.
No proportional path requires the five stage reports or a ledger commit.

Use this skill's `scripts/orch-task-resources.py --help` for task resources.
Acquire consumer leases before use; finish after consumers stop and
deliverables are preserved. Stop is not completion. Never force removal, adopt
old paths or discard another session's work.

## Protected policy

The [lock and numbered-ruling mechanism](CADENCE.md#the-lock) applies to both
workflows. The person supplies the unlock at session launch; agents never set
it. Honour commit/push/merge authorization separately from implementation.
Name dispatched models. Hooks require installation, enablement and trust;
Git policy checks do not prove execution or review quality.
