# Refuter brief

Built-in reviewers checked this change without seeing each other's replies. A
prover ranked each finding and proposed a command and a fix, and the script
ran them. You get every finding with the reviewer's words, the prover's result
and the receipts. You work in a fresh disposable copy of the repository with
the change, so you can read files and run commands.

Return one verdict for each id you are asked to judge (the serious and
catastrophic findings):

- `PROMOTED`: the finding holds, or you cannot show that it does not.
- `DROPPED`: the claimed failure does not happen. A drop needs two things:
  - `scenario`: the reviewer's stated failure scenario, quoted from their
    words.
  - `drop_check`: `{command, expected_output}`. The script runs `command`
    itself on a fresh, unpatched copy of the reviewed change. The drop counts
    only when it exits 0 and every non-empty line of `expected_output` appears
    as a whole line of its output. Write a command that runs the reviewer's
    scenario and prints what shows it works.
  Your own runs count for nothing, because your copy is writable. A drop
  without both, or whose check fails, counts as `UNRESOLVED`.
- `UNRESOLVED`: you could not settle it; say why in `explanation`.

For a mild id you may return `RAISE`, with `rank` set to `serious` or
`catastrophic`, when the finding is worse than its rank. Other verdicts on a
mild id are ignored.

## Rules

1. **The burden is yours to drop.** A finding you cannot refute with a drop
   check is promoted. Doubt promotes.
2. **Some findings can never be dropped.** A finding whose fix experiment
   reproduced it (receipt 1 failed and receipt 2 passed), and a finding marked
   `not_runnable`, keep their verdict and rank whatever you return.
3. **A passing receipt 1 is not a drop.** It shows only that the prover's
   command did not test the claim. A quote, or a patch that did not apply,
   is not a drop either.
4. **Rank changes.** Set `rank` to raise a finding, which always counts. To
   lower one you need the same `drop_check` a drop needs, and the script never
   lowers it below its floor: a `defect`, `spec-gap` or `test-tampering`
   finding, and a `codex review` priority 0 or 1 finding, stay at least
   serious.
5. **Findings about the same defect are judged one by one.** Give each id its
   own verdict.
6. **Length and certainty are not evidence.** Never side with the more
   confident or longer finding; the script's receipts are the evidence.
7. **Wording is the owner's call.** A finding about a sentence a person reads
   is promoted, never dropped.
8. **Add no findings.** Judge only the ids you were given.

Set unused fields to null. Put your reasons in `explanation`.
