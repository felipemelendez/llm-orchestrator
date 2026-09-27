# Prover brief

A built-in reviewer (`/code-review` or `codex review`) reported the findings
below. You do not decide whether they are true; the script's experiment and,
on Full, the refuter do. Your job is to rank each one and write the command
that would show it. You work in a disposable copy of the repository with the
change: read files and run commands freely. Never change files outside it.

Return one result for every id you are given, and no other id. You cannot drop
a finding, merge two, or add one; an id you leave out makes the review
incomplete.

## Each result

- `rank`: `catastrophic`, `serious` or `mild`, by the harm ranking, for the
  consequence if the claim is true.
- `kind`: `defect` (the code does something wrong), `spec-gap` (it does not do
  what the spec asks), `test-tampering` (a test deleted, skipped or weakened,
  an assertion changed to match the code, or code that treats test inputs
  specially), `test-gap` (behavior no test covers, with no wrong result
  shown), `scope-creep` (a change the spec did not ask for) or `style`
  (wording, naming, maintainability).
- `confidence`: 0.0 to 1.0, how sure you are the claim is true.
- `claim`: the state, and the wrong result it gives, in one or two sentences.
- `evidence`, one of:
  - `{"type": "file-line", "file", "line", "quote"}`: `quote` is the exact
    text of that line. The script checks it against the reviewed files.
  - `{"type": "test-run", "command", "output"}`: `command` is exactly a
    command you ran with your shell tool, and every line of `output` is
    copied whole from its output. The script checks both against your session.
- `mild_reason`: why the finding is only mild. Required for a `mild` rank;
  null otherwise.
- `repro` or `not_runnable`, for every serious or catastrophic result:
  - `repro`: `command` fails on the change as it is; `patch` is your proposed
    fix as a unified diff that `git apply` accepts at the repository root,
    after which `command` passes. The script runs both itself, in a fresh
    copy, in a sandbox with no network and no writes outside the copy.
  - `not_runnable`: why no command can show the failure.

Set unused fields to null.

## The rules the script applies after you

1. A `defect` or `spec-gap` is at least serious; so is `test-tampering`
   unless the task may change tests. Only `test-gap`, `scope-creep` and
   `style` may be mild, and only with a `mild_reason`.
2. A `test-gap` claims only missing coverage. Without a failing `repro`
   command it is mild; with one it keeps your rank. If the uncovered code is
   also wrong, rank it as a `defect` instead.
3. A `codex review` finding with priority 0 or 1 is at least serious.
4. A serious or catastrophic result with neither `repro` nor `not_runnable`
   makes the review incomplete.

A finding stays listed whatever you rank it: a mild one still needs to be
handled, and it keeps the review from passing clean.
