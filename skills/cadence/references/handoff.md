# <PROJECT> — kickoff handoff (written <YYYY-MM-DD HH:MM> by the previous orchestrator; state only, under the handoff law in `LAWS.md`)

<!--
Template for `docs/llm-orchestrator/HANDOFF_TEMPLATE.md`. State only: where the
world is now. History belongs in the ledger row this file cites. This handoff
supersedes the previous one whole and inherits nothing from it.
-->

**Read first, in this order:** `docs/llm-orchestrator/LAWS.md` (the laws; never
restated here) · the `cadence` skill's `CADENCE.md` (the cadence) · the seat
rules (pasted into every dispatch; `<SCRATCH>` is this project's `notes_dir`) ·
`DESIGN_RULINGS.md` · `TRAPS.md`. **History:** the ledger at
`<notes_dir>/LEDGER.md`, from the row that opens the previous session. **This
file supersedes the previous handoff whole.**

## 1. Where the world is

`HEAD` == `origin` == `<sha>`. The porcelain: <the exact expected list, or
"clean">. The green floor at that head: <the project's floors and their counts,
each read from a log>. Active skips: <one line per live skip from
`<notes_dir>/CADENCE_STATE.md` — stage, class, expiry — or "none">.

## 2. Live trees — one line each; the tree wins on a mismatch

| tree | base | `git diff \| md5` | ticket | stage reached | next seat | its brief |
|---|---|---|---|---|---|---|
| `<WORKTREE>` | `<BASE_SHA>` | `<md5>` | `<TICKET>` | <implementer done / pair in / refuter in / union written / fixer done / gate round <k>> | <seat> | `<path>` |

## 3. What landed this session — one line each

- `<sha>` **<TICKET>** — <one sentence: what the person gets>. Ledger row <HH:MM>.

## 4. What is left, in order

1. The world check (`LAWS.md` and `TRAPS.md` name it); each live tree's hash
   against §2.
2. …

## 5. What only the owner decides

- <one line each: the decision, and what stands until it is ruled>

## 6. The numbers — one line per ticket this session

| ticket | class | rounds | wall-clock (impl / pair / refuter / fixer / gate / landing) | raw / promoted / dropped | first found by stage | gate finding class | minutes lost to the environment | skips applied |
|---|---|---|---|---|---|---|---|---|

## 7. Proposed amendments (never applied here; only the owner turns one into a ruling)

- <what should change, why, the evidence — or "none">

Closing stamp: <"final at HH:MM — every seat finished" or "living draft; these
seats were live: …">

---

## Kickoff prompt (paste to the next orchestrator)

You are the orchestrator for <PROJECT> on branch `<branch>`. Your seat is
<model>; every seat you dispatch names its model, per `LAWS.md`.

Read first, in this order, and treat as binding: `docs/llm-orchestrator/LAWS.md`
(the laws, the harm ranking, the rulings, the silence rule, the handoff law) →
the `cadence` skill's `CADENCE.md` (the cadence: class and split at brief
review, the blind pair, the refuter above the threshold, rounds on severity and
the stop rule on repeated class, the fixer's pin from the scene, the gate script
before the gate seat, the amendment mechanism, the stamps) →
`TRAPS.md` → `DESIGN_RULINGS.md` → then this handoff (state only).

Then verify the world fresh, never assume: `git rev-parse --short HEAD` and
`git rev-parse --short origin/<branch>` (two calls; equal); `git status
--porcelain` (exactly the §1 list); `git worktree list`; each live tree's diff
hash against §2 — the tree wins on a mismatch, and say so. Fill the seat rules'
`<SCRATCH>` with this project's `notes_dir`.

Your work: §4 in order, every code change through the full cadence, never
thinned. Keep the ledger: one row per seat outcome, one row per landing on the
shape `CADENCE.md` names — ticket · class · rounds · wall-clock (impl / pair /
refuter / fixer / gate / landing) · raw / promoted / dropped · first found by
stage · gate finding class · minutes lost to the environment · skips applied.
Append design rulings and traps to their files as they arise. When
context fills or the owner asks: the seat reports are already flat in
`notes_dir`, so copy nothing — snapshot every live tree's diff wherever this
session keeps snapshots, leave the evidence where it is, write the next handoff
on this template (state only), and hand over the filled-in kickoff prompt from
this last section.

Standing orders, verbatim and binding: <STANDING_ORDERS>
