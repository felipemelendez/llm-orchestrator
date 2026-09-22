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

## 2026-09-19 — plain-language hook messages

- The evidence hook (`scripts/lib/orch-proportional-evidence.py`) runs live from
  this checkout on every tool call. An edit that calls a name before the edit
  that defines it crashes the hook, the wrapper exits 2, and every write is
  blocked, including the fix; only plain single read commands still work. Make
  each edit to that file self-contained (add the helper and its first call in
  one edit), and keep a scratch copy path ready. Recovery needs the person to
  copy the fixed file in from their own shell.
  - _2026-09-21: that file was deleted. The lesson still holds for every hook
    script that runs live from this checkout — the guards, `session-start.sh`,
    `orch-verify-gate.sh`. A half-finished edit to any of them can still lock
    the session out of writing._
- Once a shell command is marked "may have changed files", even a read such as
  `sed -n 1,5p f; echo` with a `;` or `$(...)` counts as a possible write and is
  blocked the same way. During such a lockout, read with one plain command per
  call.
  - _2026-09-21: removed. Nothing classifies shell commands as possible writes
    any more, so this lockout cannot happen._
- A test whose output quotes a line like `'0 passed, 1 failed.'` is recorded by
  the evidence hook as a failed check (`fail_count_re` matches the quoted text).
  `tests/test-cadence-gate.sh` does this. Do not read the hook's "failed" note
  as a real failure without looking at the suite's own PASS line.
  - _2026-09-21: the evidence hook is gone, but `fail_count_re` is still read by
    `skills/cadence/scripts/orch-cadence-gate.sh`, so the same false "failed"
    can still come from there. Check the suite's own PASS line first._

## <next session>

- (append here)
