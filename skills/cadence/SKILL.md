---
name: cadence
description: Use when changing production code or tests in projects with enabled docs/llm-orchestrator/cadence.json. Not for ordinary documentation or questions.
license: MIT
compatibility: Claude Code or Codex; bash 3.2+, git and python3
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-gate.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/orch-cadence-check.sh *), Bash(${CLAUDE_SKILL_DIR}/scripts/cadence-detect.sh *)
---

# The cadence

Read the project's `docs/llm-orchestrator/LAWS.md` and configuration first,
and on Codex its `CODEX.md`. User instructions and project amendments govern.

Check `workflow`: any value but `proportional`, or none, is a configuration
error; fix it (`"workflow": "proportional"`) before working, never guessing a
process.

## Proportional paths

Choose by impact, uncertainty, contracts and reversibility.
Reassess if scope grows. Honour requested reviewers and models.

| Path | Use when | Required work |
|---|---|---|
| Simple | Clear, local, reversible and low risk | Edit, inspect the full diff, run applicable existing checks. |
| Standard | Bounded behavior with meaningful edge cases | State acceptance criteria, implement, check, run the Standard review (`requesting-code-review`), resolve findings. |
| Full | Any Full signal below | Review the spec, implement, run the Full review, resolve findings (bounded rounds; settled decisions in the spec), independently verify. |

Full whenever one of these is present: permissions, identity, privacy, or
data whose loss is hard to undo; effects that cannot be reversed, or recovery
that is hard; concurrency, shared state, retries with side effects, ordering;
contracts between components or repositories whose failure breaks the whole;
invariants not obvious from the code. Any one signal is enough, never averaged
away, and unknown risk counts as high. A one-line permission change can need
Full; a large mechanical change can be Simple.

Simple needs no extra agent, spec, worktree, report or invented test; Standard
adds only one independent review and fixes for its findings.
Writers may inspect diffs and run checks, not supply independent review or
gates.
Every review, self-check and gate asks: Is this the simplest correct version?
A design finding names its simpler alternative (`requesting-code-review`'s
`references/design-simplicity.md`).

Every path lands through a PR via `finishing-a-branch`; never merge locally
unasked. Its
`references/landing-rules.md` governs ticket branches: a READY verdict landed
the same session, rounds bounded by evidence.

Read the [Full path](CADENCE.md#proportional-full-path) only for Full.

## Check once, with evidence

Use relevant checks and meaningful regression tests within build/dependency
limits; no default broad suites or mutation batteries for Simple/Standard.
Change existing tests only when the task says so; report each change and why.

Run each check as one plain foreground command so the transcript shows it.
A Stop hook warns when a reply's `Verification: PASS` label has no passing
check that turn; it never blocks or reads the prose.

Reuse a check while its covered inputs are unchanged; rerun after changes,
failures or open concerns. Unrelated green cannot erase failure. End with
`Verification: PASS — checks and scope`, `PENDING — remaining validation` or
`BLOCKED — unavailable prerequisite`. For low-risk work with no meaningful
automated check: `NOT APPLICABLE — reason; manual diff inspection performed`,
which cannot waive failures, uncertain writes or stale/unavailable required checks.

## Finish and clean up

Keep maintained specifications, research conclusions, design decisions and
runbooks. Reviews, temporary plans/logs and disposable copies belong outside Git.

Task resources: this skill's `scripts/orch-task-resources.py --help`. Lease
before use; finish after consumers stop and deliverables are preserved (stop
is not completion). Never force removal, adopt old paths or discard another
session's work.

## Protected policy

The [lock and numbered-ruling mechanism](CADENCE.md#the-lock) is binding.
Propose rule changes as a patch; only the person runs
`scripts/cadence-ruling.sh`. Honour commit/push/merge authorization separately
from implementation.
Name dispatched models. Hooks require installation, enablement and trust;
Git policy checks do not prove execution or review quality.
