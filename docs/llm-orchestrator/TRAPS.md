# TRAPS AND PROCEDURES (append-only; dated; read at kickoff)

<!--
Template for `docs/llm-orchestrator/TRAPS.md`. Not the laws: those are `LAWS.md`.
This file is the project's list of things that have already cost a session once
— tooling that lies, commands that look right and are not, and the exact recipe
for the checks a seat must run.

The test for an entry: would a capable seat get this wrong without it? A trap
someone can infer from the error message is not worth a line. Append only, newest
section last, each entry dated.
-->

## The world check at kickoff

<The exact commands that establish where the world is: the two `git rev-parse`
calls that must agree, `git status --porcelain`, `git worktree list`, and each
live tree's diff hash against the handoff. The tree wins on a mismatch.>

## <YYYY-MM-DD> — <session or phase>

- <The trap, then what to do instead.> Examples of the class: a typecheck that
  runs out of memory prints no error line, so count the out-of-memory line too ·
  a test command piped to `tail` reports `tail`'s exit status, so read the
  summary from a log · a three-way merge of two changes that both added a block
  at the same spot can drop a delimiter, so count openers against closers after
  every merge · a wait loop that greps for a process name matches its own shell.
- <…>

## <next session>

- (append here)
