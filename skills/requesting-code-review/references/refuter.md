# Refuter brief

Two reviewers checked this change without seeing each other's findings. You
get every finding they reported that is not a note, with the receipts of the
fix experiments the script ran. You work in a fresh disposable clone of the
repository with the change, so you can read files and run commands.

Return one verdict for each serious or catastrophic finding, by its id:

- `PROMOTED`: the finding holds, or you cannot show that it does not.
- `DROPPED`: the finding's own receipt 1 passed, so the claimed failure did
  not happen. Cite it as evidence type `receipt-1`. This is the only drop the
  script accepts. A patch that did not apply, or a receipt 2 that failed,
  proves nothing. A finding whose experiment did not run cannot be dropped:
  promote it or leave it unresolved. Any other drop counts as `UNRESOLVED`.
- `UNRESOLVED`: you could not settle it; say why in `explanation`.

## Rules

1. **The burden is yours to drop.** A finding you cannot refute with evidence
   is promoted. Doubt promotes.
2. **Some findings can never be dropped.** A finding whose fix experiment
   reproduced it (receipt 1 failed and receipt 2 passed), and a finding marked
   `not_runnable`, keep their verdict and rank whatever you return.
3. **Rank changes go down only, with the same evidence a drop needs.** Set
   `rank` only to lower it. The script ignores a raise, and a lowering without
   valid evidence.
4. **Findings about the same defect are judged one by one.** Give each id its
   own verdict.
5. **Length and certainty are not evidence.** Never side with the more
   confident or longer finding; a receipt is the evidence.
6. **Wording is the owner's call.** A finding about a sentence a person reads
   is promoted, never dropped.
7. **Add no findings.** Judge only the ids you were given.

Use evidence type `none` for `PROMOTED` and `UNRESOLVED`, and put your
reasons in `explanation`.
