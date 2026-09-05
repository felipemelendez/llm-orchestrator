# <TICKET> — REFUTER (step 2b; read-only; fresh seat; model: <MODEL>)

Rules: the seat rules in `<SCRATCH>/SEAT_RULES.md`. You work in a fresh copy
`<COPY>` of `<WORKTREE>` at `<BASE_SHA>`: scratch probes only, deleted before
you report; spawn ceiling 0; neutral vocabulary; `Started:` / `Finished:`
stamps. You never see the implementer's report.

## What you receive

Both reviewer reports, whole: `<SCRATCH>/<TICKET>_REV1_report.md` (the spec
seat) and `<SCRATCH>/<TICKET>_REV2_report.md` (the plain-language seat), plus
the specification and the harm ranking in `docs/llm-orchestrator/LAWS.md`. You
are the first seat to see both; their independence is already spent.

## What you return — the union draft

One line per finding, in harm order, each with its origin (`REV1 C-1`, `REV2
S-3`, or both when the two converged):

- `PROMOTED <rank> <origin> — <state → wrong output> — PROOF: <file:line that
  shows it, or the executed probe and its failing line>` — keep the finding's
  `SCENE:` line verbatim.
- `DROPPED <rank> <origin> — <one sentence> — REFUTED BY: <file:line whose code
  makes the claimed state impossible or the claimed output correct>`.
- `UNRESOLVED <rank> <origin> — <one sentence> — WHY: <what you could not settle
  in the copy>`.

## Laws of this seat

1. **The burden is yours to drop.** A finding you cannot refute by citation is
   promoted. Doubt promotes.
2. **Converged findings merge** (same state, same wrong output) and keep the
   higher rank; name both origins.
3. **Never resolve toward the more confident or the longer report.** Length and
   certainty are not evidence; `file:line` and executed probes are.
4. **Re-rank only downward, with a citation.** Never upward without one.
5. Execute where it is cheap: a probe in the copy that reproduces or refutes
   beats a reading. Delete every probe; list every shasum you touched.
6. A finding about a sentence a person reads is promoted as a candidate, never
   dropped — wording is the owner's call, not yours.

## Wiring to the review workflow

When the refuter runs through this plugin's `workflows/review-diff.js`, its
verdict objects use that file's schema field names verbatim: `index` (which
finding), `refuted` (boolean), `method` (`executed` or `reasoned`) and `reason`.
`refuted: false` is `PROMOTED`; `refuted: true` is `DROPPED`; a finding the
refuter did not judge is `UNRESOLVED`. Keep those names so the seat's prose and
the schema cannot drift apart.

## Report

`<SCRATCH>/<TICKET>_REFUTE_report.md`, printed as your final message: the union
draft (≤ 40 lines), then a `Status:` block (≤ 15 lines) with counts
`promoted / dropped / unresolved` per rank and the stamps.
